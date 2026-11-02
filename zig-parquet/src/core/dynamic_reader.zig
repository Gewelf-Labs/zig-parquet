//! Dynamic Row Reader
//!
//! Schema-agnostic Parquet reader that reads files into dynamic Value/Row types
//! without requiring compile-time type information.
//!
//! This is inspired by parquet-go's Row/Value API and enables:
//! - Reading files without knowing the schema at compile time
//! - Generic validation tools (like `pq validate`)
//! - Schema evolution and migration utilities
//!
//! ## Example
//! ```zig
//! var reader = try DynamicReader.init(allocator, file);
//! defer reader.deinit();
//!
//! for (0..reader.getNumRowGroups()) |rg_idx| {
//!     const rows = try reader.readAllRows(rg_idx);
//!     defer for (rows) |row| row.deinit();
//!
//!     for (rows) |row| {
//!         // row.values[i] contains Value for column i
//!     }
//! }
//! ```

const std = @import("std");
const safe = @import("safe.zig");
const format = @import("format.zig");
const thrift = @import("thrift/mod.zig");
const compress = @import("compress/mod.zig");
const dictionary = @import("encoding/dictionary.zig");
const column_decoder = @import("column_decoder.zig");
const value_mod = @import("value.zig");
const seekable_reader = @import("seekable_reader.zig");
const parquet_reader = @import("parquet_reader.zig");
const errors_mod = @import("errors.zig");
const schema_mod = @import("schema.zig");
const nested_mod = @import("nested.zig");
const row_ranges_mod = @import("row_ranges.zig");
const page_filter_mod = @import("page_filter.zig");
const page_index_reader_mod = @import("page_index_reader.zig");
const page_range_reader_mod = @import("page_range_reader.zig");

pub const Value = value_mod.Value;
pub const Row = value_mod.Row;
pub const SeekableReader = seekable_reader.SeekableReader;
pub const BackendCleanup = parquet_reader.BackendCleanup;
pub const ChecksumOptions = parquet_reader.ChecksumOptions;
pub const RowRanges = row_ranges_mod.RowRanges;
pub const ColumnFilter = page_filter_mod.ColumnFilter;

/// Options for DynamicReader initialization
pub const DynamicReaderOptions = struct {
    /// Checksum validation options
    checksum: ChecksumOptions = .{},
};

/// Error type for dynamic reader operations.
/// Composed from categorized error sets — no more `SchemaParseError` coalescing.
pub const DynamicReaderError = errors_mod.DynamicReaderError;

/// Compute CRC32 checksum for page data (per Parquet spec, covers compressed data)
fn computePageCrc(data: []const u8) i32 {
    return @bitCast(@import("crc32.zig").hash(data));
}

/// Safely cast i32 page size/count to usize, validating non-negative.
fn safePageSize(size: i32) error{InvalidPageSize}!usize {
    return safe.cast(size) catch return error.InvalidPageSize;
}

/// Safely cast i64 row count to usize, validating non-negative.
fn safeRowCount(count: i64) error{InvalidRowCount}!usize {
    return safe.cast(count) catch return error.InvalidRowCount;
}

const safeTypeLength = column_decoder.safeTypeLength;

/// Schema-agnostic Parquet reader
pub const DynamicReader = struct {
    allocator: std.mem.Allocator,
    source: SeekableReader,
    metadata: format.FileMetaData,
    footer_data: []u8,
    checksum_options: ChecksumOptions,
    _backend_cleanup: ?BackendCleanup = null,
    /// Arena for `bytes_val` / `fixed_bytes_val` payloads decoded into rows.
    /// Lives as long as the reader — caller must deinit rows before the reader.
    /// Rows produced by the reader set `bytes_borrowed = true` so their byte
    /// payloads are not freed per-value; the arena is freed en masse in deinit.
    bytes_arena: std.heap.ArenaAllocator,

    const Self = @This();

    const TopColInfo = struct {
        leaf_start: usize,
        leaf_count: usize,
        is_nested: bool,
        schema_node: *const schema_mod.SchemaNode,
    };

    /// Get the SeekableReader interface.
    pub fn getSource(self: *const Self) SeekableReader {
        return self.source;
    }

    /// Initialize from a SeekableReader. The caller manages backend lifetime
    /// unless _backend_cleanup is set (by convenience constructors in api/zig/).
    pub fn initFromSeekable(allocator: std.mem.Allocator, source: SeekableReader, options: DynamicReaderOptions) DynamicReaderError!Self {
        const info = try parquet_reader.parseFooter(allocator, source);
        return Self{
            .allocator = allocator,
            .source = source,
            .metadata = info.metadata,
            .footer_data = info.footer_data,
            .checksum_options = options.checksum,
            .bytes_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.metadata.deinit(self.allocator);

        self.allocator.free(self.footer_data);

        self.bytes_arena.deinit();

        if (self._backend_cleanup) |cleanup| {
            cleanup.deinit_fn(cleanup.ptr, self.allocator);
        }
    }

    /// Get the schema
    pub fn getSchema(self: *const Self) []const format.SchemaElement {
        return self.metadata.schema;
    }

    /// Get the number of row groups
    pub fn getNumRowGroups(self: *const Self) usize {
        return self.metadata.row_groups.len;
    }

    /// Get the number of rows in a specific row group
    pub fn getRowGroupNumRows(self: *const Self, row_group_index: usize) i64 {
        if (row_group_index >= self.metadata.row_groups.len) return 0;
        return self.metadata.row_groups[row_group_index].num_rows;
    }

    /// Get total number of rows across all row groups
    pub fn getTotalNumRows(self: *const Self) i64 {
        return self.metadata.num_rows;
    }

    /// Get the number of leaf columns
    pub fn getNumColumns(self: *const Self) usize {
        var count: usize = 0;
        for (self.metadata.schema) |elem| {
            if (elem.type_ != null and elem.num_children == null) {
                count += 1;
            }
        }
        return count;
    }

    /// Get the schema element for a leaf column by column index
    pub fn getLeafSchemaElement(self: *const Self, col_idx: usize) ?format.SchemaElement {
        var count: usize = 0;
        for (self.metadata.schema) |elem| {
            if (elem.type_ != null and elem.num_children == null) {
                if (count == col_idx) {
                    return elem;
                }
                count += 1;
            }
        }
        return null;
    }

    /// Get the logical type for a column, if any
    pub fn getColumnLogicalType(self: *const Self, col_idx: usize) ?format.LogicalType {
        const elem = self.getLeafSchemaElement(col_idx) orelse return null;
        return elem.logical_type;
    }

    /// Check if a column has a specific logical type
    pub fn isColumnType(self: *const Self, col_idx: usize, logical: format.LogicalType) bool {
        const lt = self.getColumnLogicalType(col_idx) orelse return false;
        return std.meta.eql(lt, logical);
    }

    /// Get statistics for a column in a specific row group.
    /// Returns null if the column or row group doesn't exist, or if no statistics are available.
    pub fn getColumnStatistics(
        self: *const Self,
        column_index: usize,
        row_group_index: usize,
    ) ?format.Statistics {
        if (row_group_index >= self.metadata.row_groups.len) return null;
        const rg = self.metadata.row_groups[row_group_index];
        if (column_index >= rg.columns.len) return null;
        const col = rg.columns[column_index];
        const meta = col.meta_data orelse return null;
        return meta.statistics;
    }

    /// Get column metadata for a specific column in a row group.
    /// Returns null if the column or row group doesn't exist.
    pub fn getColumnMetaData(
        self: *const Self,
        column_index: usize,
        row_group_index: usize,
    ) ?format.ColumnMetaData {
        if (row_group_index >= self.metadata.row_groups.len) return null;
        const rg = self.metadata.row_groups[row_group_index];
        if (column_index >= rg.columns.len) return null;
        return rg.columns[column_index].meta_data;
    }

    /// Streaming row iterator that advances through row groups automatically.
    /// Holds at most one row group's worth of rows in memory at a time.
    pub const RowIterator = struct {
        reader: *Self,
        current_rows: ?[]Row,
        cursor: usize,
        current_rg: usize,
        num_rgs: usize,
        col_indices: ?[]const usize,
        /// Backs the value slices of `current_rows` (flat reads). Reset when the
        /// iterator moves past a row group; freed by `deinit`.
        arena: std.heap.ArenaAllocator,

        /// Advance to the next row. Returns a pointer to the current row,
        /// or null when all row groups have been exhausted.
        /// The returned pointer is valid until the next call to `next()` that
        /// crosses a row group boundary, or until `deinit()` is called.
        pub fn next(self: *RowIterator) !?*const Row {
            while (true) {
                if (self.current_rows) |rows| {
                    if (self.cursor < rows.len) {
                        const row = &rows[self.cursor];
                        self.cursor += 1;
                        return row;
                    }
                    self.freeCurrentRows();
                }

                if (self.current_rg >= self.num_rgs) {
                    // Exhausted: release the arena so iterating to the end
                    // without deinit() leaks nothing.
                    _ = self.arena.reset(.free_all);
                    return null;
                }

                const rows = try self.reader.readRowsInternal(self.current_rg, self.col_indices, &self.arena);
                self.current_rg += 1;

                if (rows.len > 0) {
                    self.current_rows = rows;
                    self.cursor = 1;
                    return &rows[0];
                }
                self.reader.allocator.free(rows);
            }
        }

        /// Free any currently held rows and the iterator arena.
        pub fn deinit(self: *RowIterator) void {
            self.freeCurrentRows();
            self.arena.deinit();
        }

        fn freeCurrentRows(self: *RowIterator) void {
            if (self.current_rows) |rows| {
                for (rows) |row| row.deinit();
                self.reader.allocator.free(rows);
                self.current_rows = null;
            }
            _ = self.arena.reset(.retain_capacity);
        }
    };

    /// Create a row iterator that streams through all row groups.
    /// No I/O occurs until the first call to `next()`.
    pub fn rowIterator(self: *Self) RowIterator {
        return .{
            .reader = self,
            .current_rows = null,
            .cursor = 0,
            .current_rg = 0,
            .num_rgs = self.metadata.row_groups.len,
            .col_indices = null,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }

    /// Create a row iterator with column projection.
    /// Only the specified top-level columns are read and returned.
    pub fn rowIteratorProjected(self: *Self, col_indices: []const usize) RowIterator {
        return .{
            .reader = self,
            .current_rows = null,
            .cursor = 0,
            .current_rg = 0,
            .num_rgs = self.metadata.row_groups.len,
            .col_indices = col_indices,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }

    /// Row iterator that builds each row on `next()` in one reused buffer, with
    /// no per-row allocation.
    ///
    /// Contract: the row returned by `next()`, its `values` and any byte slices
    /// inside them are valid only until the next call to `next()` or `deinit()`.
    /// The next call overwrites them; copy anything you need to keep. Do not call
    /// `deinit()` on the returned row.
    ///
    /// Memory is bounded by one row group: its decoded columns plus their byte
    /// payloads, which live in an iterator arena reset at each row group. When a
    /// requested column is nested, that row group is assembled whole, as by
    /// `RowIterator` (same results, no speedup; byte payloads then live in the
    /// reader's arena until the reader is deinitialized).
    pub const StreamingRowIterator = struct {
        reader: *Self,
        col_indices: ?[]const usize,
        current_rg: usize = 0,
        cursor: usize = 0,
        num_rows: usize = 0,
        /// Flat row group: decoded columns indexed by leaf, the leaf of each
        /// output column, and the reused row (`row.values` is the row buffer).
        column_values: [][]Value = &.{},
        leaves: []usize = &.{},
        row: Row,
        /// Nested row group: all of its rows.
        fallback_rows: ?[]Row = null,
        /// Byte payloads of the current flat row group.
        arena: std.heap.ArenaAllocator,

        /// Return the next row, or null when all row groups are exhausted. See
        /// the type's doc comment for the lifetime of the returned row.
        pub fn next(self: *StreamingRowIterator) !?*const Row {
            while (self.cursor >= self.num_rows) {
                self.freeGroup();
                if (self.current_rg >= self.reader.metadata.row_groups.len) return null;
                // Advance only after a successful load, as RowIterator does, so
                // a failed group is retried by the next call.
                try self.loadGroup(self.current_rg);
                self.current_rg += 1;
            }
            const r = self.cursor;
            self.cursor += 1;
            if (self.fallback_rows) |rows| return &rows[r];
            fillFlatRow(self.row.values, self.column_values, self.leaves, r);
            return &self.row;
        }

        /// Free the current row group and the iterator arena.
        pub fn deinit(self: *StreamingRowIterator) void {
            self.freeGroup();
            self.arena.deinit();
        }

        /// Decode row group `rg_idx`. On error, whatever was loaded stays in
        /// `self` with `num_rows == 0`, so the next `next()` or `deinit()` frees it.
        fn loadGroup(self: *StreamingRowIterator, rg_idx: usize) !void {
            const reader = self.reader;
            const gpa = reader.allocator;
            const rg = &reader.metadata.row_groups[rg_idx];
            const num_rows = try safeRowCount(rg.num_rows);
            if (num_rows == 0 or rg.columns.len == 0) return;

            self.leaves = (try reader.planFlatLeaves(rg.columns.len, self.col_indices)) orelse {
                const rows = try reader.readRowsInternal(rg_idx, self.col_indices, null);
                self.fallback_rows = rows;
                self.num_rows = rows.len;
                return;
            };
            self.column_values = try gpa.alloc([]Value, rg.columns.len);
            @memset(self.column_values, &.{});
            self.row.values = try gpa.alloc(Value, self.leaves.len);

            const prev_bytes_alloc = value_mod.bytes_arena_allocator;
            value_mod.bytes_arena_allocator = self.arena.allocator();
            defer value_mod.bytes_arena_allocator = prev_bytes_alloc;
            try reader.readFlatColumns(rg_idx, self.leaves, self.column_values);
            self.num_rows = num_rows;
        }

        fn freeGroup(self: *StreamingRowIterator) void {
            const gpa = self.reader.allocator;
            if (self.fallback_rows) |rows| {
                for (rows) |row| row.deinit();
                gpa.free(rows);
                self.fallback_rows = null;
            }
            // Flat leaf values are scalars or byte slices in `arena`, so only the
            // arrays are freed; the arena reset releases the bytes.
            for (self.column_values) |vals| gpa.free(vals);
            gpa.free(self.column_values);
            self.column_values = &.{};
            gpa.free(self.leaves);
            self.leaves = &.{};
            gpa.free(self.row.values);
            self.row.values = &.{};
            _ = self.arena.reset(.retain_capacity);
            self.cursor = 0;
            self.num_rows = 0;
        }
    };

    /// Create a streaming row iterator over all row groups (see
    /// `StreamingRowIterator` for the row lifetime contract).
    /// No I/O occurs until the first call to `next()`.
    pub fn rowIteratorStreaming(self: *Self) StreamingRowIterator {
        return self.rowIteratorStreamingInternal(null);
    }

    /// Streaming row iterator over the given top-level columns, in that order.
    /// `col_indices` must outlive the iterator.
    pub fn rowIteratorStreamingProjected(self: *Self, col_indices: []const usize) StreamingRowIterator {
        return self.rowIteratorStreamingInternal(col_indices);
    }

    fn rowIteratorStreamingInternal(self: *Self, col_indices: ?[]const usize) StreamingRowIterator {
        return .{
            .reader = self,
            .col_indices = col_indices,
            .row = .{ .values = &.{}, .allocator = self.allocator, .bytes_borrowed = true, .values_borrowed = true },
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }

    /// Read all rows from a row group as dynamic Value types
    pub fn readAllRows(self: *Self, row_group_index: usize) ![]Row {
        return self.readRowsInternal(row_group_index, null, null);
    }

    /// Read rows from a row group, returning only the specified top-level columns.
    /// Column indices refer to top-level schema columns (not leaf columns).
    /// Returned rows contain values in dense order matching the projection list.
    pub fn readRowsProjected(self: *Self, row_group_index: usize, col_indices: []const usize) ![]Row {
        return self.readRowsInternal(row_group_index, col_indices, null);
    }

    /// Read rows from a row group, applying page-index-driven filters to skip
    /// pages whose min/max ranges cannot match the predicates.
    ///
    /// Behavior:
    ///   - Every leaf column in the row group must advertise an `OffsetIndex`;
    ///     otherwise `error.PageIndexMissing` is returned (use `readAllRows`
    ///     for unindexed files).
    ///   - Only flat schemas are supported; `error.NestedNotSupported` is
    ///     returned for nested / list / map / struct columns.
    ///   - `filters` target leaf column indices. Columns without a filter are
    ///     treated as wildcards (`full(rg_num_rows)`).
    ///   - Pages whose row ranges don't intersect the final (intersected)
    ///     `RowRanges` are never read or decompressed.
    ///
    /// The returned rows are in row-group order, restricted to the final
    /// `RowRanges`. A stats-level predicate pushdown may still leave rows that
    /// don't actually match — apply value-level predicates post-decode.
    pub fn readRowsFiltered(
        self: *Self,
        row_group_index: usize,
        filters: []const ColumnFilter,
    ) ![]Row {
        if (row_group_index >= self.metadata.row_groups.len) {
            return try self.allocator.alloc(Row, 0);
        }

        // Route bytes through reader-owned arena, mirroring readRowsInternal.
        const prev_bytes_alloc = value_mod.bytes_arena_allocator;
        value_mod.bytes_arena_allocator = self.bytes_arena.allocator();
        defer value_mod.bytes_arena_allocator = prev_bytes_alloc;

        const rg = &self.metadata.row_groups[row_group_index];
        const num_rows = try safeRowCount(rg.num_rows);
        const num_leaf_columns = rg.columns.len;
        if (num_rows == 0 or num_leaf_columns == 0) {
            return try self.allocator.alloc(Row, 0);
        }

        // Flat-schema-only in this first cut.
        const schema = self.metadata.schema;
        const num_top: usize = if (schema.len > 0)
            safe.castTo(usize, schema[0].num_children orelse 0) catch 0
        else
            0;
        if (num_top != 0 and num_top != num_leaf_columns) {
            return error.NestedNotSupported;
        }

        // Validate filter column indices.
        for (filters) |f| {
            if (f.column >= num_leaf_columns) return error.InvalidArgument;
        }

        // Load offset + column indexes for the whole row group.
        var pir = page_index_reader_mod.PageIndexReader.init(self.allocator, self.getSource());
        const offset_indexes = try pir.readOffsetIndexesForRowGroup(rg);
        defer page_index_reader_mod.freeOptionalIndexes(format.OffsetIndex, self.allocator, offset_indexes);
        for (offset_indexes) |oi| {
            if (oi == null) return error.PageIndexMissing;
        }
        const column_indexes = try pir.readColumnIndexesForRowGroup(rg);
        defer page_index_reader_mod.freeOptionalIndexes(format.ColumnIndex, self.allocator, column_indexes);

        // Compute final_ranges by intersecting each filter's RowRanges.
        var final_ranges = try RowRanges.full(self.allocator, num_rows);
        defer final_ranges.deinit(self.allocator);

        for (filters) |f| {
            const oi_ref = &offset_indexes[f.column].?;
            const ci_ref: ?*const format.ColumnIndex = if (column_indexes[f.column]) |*ci| ci else null;

            var per_filter = try f.evaluate(ci_ref, oi_ref, num_rows, self.allocator);
            defer per_filter.deinit(self.allocator);

            const next = try RowRanges.intersect(self.allocator, final_ranges, per_filter);
            final_ranges.deinit(self.allocator);
            final_ranges = next;
            // Early exit if the intersection is already empty — no column read needed.
            if (final_ranges.isEmpty()) break;
        }

        if (final_ranges.isEmpty()) {
            return try self.allocator.alloc(Row, 0);
        }

        // Per-column: fetch just the pages intersecting final_ranges and decode.
        const column_values = try self.allocator.alloc([]Value, num_leaf_columns);
        @memset(column_values, &.{});
        defer {
            for (column_values) |vals| {
                for (vals) |v| v.deinit(self.allocator);
                if (vals.len > 0) self.allocator.free(vals);
            }
            self.allocator.free(column_values);
        }

        const column_rg_indices = try self.allocator.alloc([]u64, num_leaf_columns);
        @memset(column_rg_indices, &.{});
        defer {
            for (column_rg_indices) |idx| {
                if (idx.len > 0) self.allocator.free(idx);
            }
            self.allocator.free(column_rg_indices);
        }

        for (0..num_leaf_columns) |col_idx| {
            const chunk = &rg.columns[col_idx];
            const oi = &offset_indexes[col_idx].?;

            var page_result = try page_range_reader_mod.readSelectedPages(
                self.allocator,
                self.getSource(),
                chunk,
                oi,
                final_ranges,
                num_rows,
            );
            defer page_result.deinit(self.allocator);

            if (page_result.data.len == 0) {
                // Nothing selected for this column → no decoded values.
                continue;
            }

            // Decode using the substituted buffer.
            const decoded = try self.readColumnDynamicWithData(col_idx, row_group_index, page_result.data, false);
            // We don't use def/rep levels in the flat path; free them if present.
            if (decoded.def_levels) |dl| self.allocator.free(dl);
            if (decoded.rep_levels) |rl| self.allocator.free(rl);

            // Build the decoded-row-idx → rg-local-row-idx mapping, constrained
            // to final_ranges. For flat columns, each decoded value is one row.
            const total = decoded.values.len;
            var kept_values = try std.ArrayList(Value).initCapacity(self.allocator, total);
            errdefer {
                for (kept_values.items) |v| v.deinit(self.allocator);
                kept_values.deinit(self.allocator);
            }
            var kept_indices = try std.ArrayList(u64).initCapacity(self.allocator, total);
            errdefer kept_indices.deinit(self.allocator);

            for (decoded.values, 0..) |v, i| {
                const rg_row = page_result.mapDecodedRow(i) orelse {
                    // Shouldn't happen if the decoder produced the expected count.
                    return error.InvalidPageData;
                };
                if (final_ranges.contains(rg_row)) {
                    try kept_values.append(self.allocator, v);
                    try kept_indices.append(self.allocator, rg_row);
                } else {
                    v.deinit(self.allocator);
                }
            }

            // Free the now-drained values slice (values themselves were moved or freed above).
            self.allocator.free(decoded.values);

            column_values[col_idx] = try kept_values.toOwnedSlice(self.allocator);
            column_rg_indices[col_idx] = try kept_indices.toOwnedSlice(self.allocator);
        }

        // Every column must agree on the kept row indices.
        const first_non_empty = blk: {
            for (column_rg_indices, 0..) |idx, i| {
                if (idx.len > 0) break :blk i;
            }
            break :blk null;
        };
        if (first_non_empty == null) {
            return try self.allocator.alloc(Row, 0);
        }
        const canonical = column_rg_indices[first_non_empty.?];
        for (column_rg_indices) |idx| {
            if (idx.len == 0) continue;
            if (idx.len != canonical.len) return error.InconsistentPageAlignment;
            for (idx, canonical) |a, b| {
                if (a != b) return error.InconsistentPageAlignment;
            }
        }

        // Assemble flat rows from the kept per-column values.
        return self.assembleFlatRows(canonical.len, num_leaf_columns, column_values, null, null);
    }

    fn readRowsInternal(
        self: *Self,
        row_group_index: usize,
        col_indices: ?[]const usize,
        rows_arena: ?*std.heap.ArenaAllocator,
    ) ![]Row {
        if (row_group_index >= self.metadata.row_groups.len) {
            return try self.allocator.alloc(Row, 0);
        }

        // Route byte payloads produced via `value_mod.dupeBytes` into the
        // reader-owned arena for the duration of this decode. The emitted
        // Rows below are marked `bytes_borrowed = true` so their byte
        // slices are not individually freed; the arena is released by
        // `DynamicReader.deinit`.
        const prev_bytes_alloc = value_mod.bytes_arena_allocator;
        value_mod.bytes_arena_allocator = self.bytes_arena.allocator();
        defer value_mod.bytes_arena_allocator = prev_bytes_alloc;

        const rg = &self.metadata.row_groups[row_group_index];
        const num_rows = try safeRowCount(rg.num_rows);
        const num_leaf_columns = rg.columns.len;

        if (num_rows == 0 or num_leaf_columns == 0) {
            return try self.allocator.alloc(Row, 0);
        }

        // Read needed leaf columns into fixed-size arrays
        const column_values = try self.allocator.alloc([]Value, num_leaf_columns);
        @memset(column_values, &.{});
        defer self.freeColumnValues(column_values);

        // Flat read (also validates `col_indices`): every requested column is
        // one primitive leaf, so no levels are kept and cells are moved.
        if (try self.planFlatLeaves(num_leaf_columns, col_indices)) |leaves| {
            defer self.allocator.free(leaves);
            try self.readFlatColumns(row_group_index, leaves, column_values);
            // The footer's row count must be backed by decoded values before it sizes any array;
            // every row has at least one entry in each leaf column.
            for (leaves) |leaf| if (column_values[leaf].len < num_rows) return error.InvalidRowCount;
            return self.assembleFlatRows(num_rows, num_leaf_columns, column_values, leaves, rows_arena);
        }

        // Nested read: compute the top-level-to-leaf mapping.
        var schema_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer schema_arena.deinit();
        const top_infos = try self.buildTopInfos(schema_arena.allocator());

        // Build set of leaf columns to read
        const leaf_needed = try self.allocator.alloc(bool, num_leaf_columns);
        defer self.allocator.free(leaf_needed);

        if (col_indices) |indices| {
            @memset(leaf_needed, false);
            for (indices) |top_idx| {
                const info = top_infos[top_idx];
                for (info.leaf_start..info.leaf_start + info.leaf_count) |leaf| {
                    if (leaf < num_leaf_columns) leaf_needed[leaf] = true;
                }
            }
        } else {
            @memset(leaf_needed, true);
        }

        const column_def_levels = try self.allocator.alloc(?[]u32, num_leaf_columns);
        @memset(column_def_levels, null);
        defer {
            for (column_def_levels) |levels| {
                if (levels) |l| self.allocator.free(l);
            }
            self.allocator.free(column_def_levels);
        }

        const column_rep_levels = try self.allocator.alloc(?[]u32, num_leaf_columns);
        @memset(column_rep_levels, null);
        defer {
            for (column_rep_levels) |levels| {
                if (levels) |l| self.allocator.free(l);
            }
            self.allocator.free(column_rep_levels);
        }

        for (0..num_leaf_columns) |col_idx| {
            if (!leaf_needed[col_idx]) continue;
            const result = try self.readColumnDynamic(col_idx, row_group_index, true);
            column_values[col_idx] = result.values;
            column_def_levels[col_idx] = result.def_levels;
            column_rep_levels[col_idx] = result.rep_levels;
        }
        for (0..num_leaf_columns) |col_idx| {
            if (leaf_needed[col_idx] and column_values[col_idx].len < num_rows) return error.InvalidRowCount; // as for flat columns
        }

        return self.assembleNestedRows(
            num_rows,
            num_leaf_columns,
            column_values,
            column_def_levels,
            column_rep_levels,
            top_infos,
            col_indices,
        );
    }

    /// Number of top-level columns declared by the schema root (0 when the
    /// root declares none; leaves are then the top-level columns).
    fn numTopColumns(self: *const Self) usize {
        const schema = self.metadata.schema;
        return if (schema.len > 0)
            safe.castTo(usize, schema[0].num_children orelse 0) catch 0
        else
            0;
    }

    /// Top-level-to-leaf mapping for a schema with `numTopColumns() > 0`.
    /// Infos and schema nodes are allocated in `sa`.
    fn buildTopInfos(self: *const Self, sa: std.mem.Allocator) ![]TopColInfo {
        const schema = self.metadata.schema;
        const infos = try sa.alloc(TopColInfo, self.numTopColumns());
        var schema_idx: usize = 1;
        var leaf_offset: usize = 0;
        for (infos) |*info| {
            if (schema_idx >= schema.len) return error.InvalidSchema;
            const build_result = try schema_mod.SchemaNode.buildFromElements(sa, schema, schema_idx);
            const lc = build_result.node.countLeafColumns();
            info.* = .{
                .leaf_start = leaf_offset,
                .leaf_count = lc,
                .is_nested = lc > 1 or !build_result.node.unwrapOptional().isPrimitive(),
                .schema_node = build_result.node,
            };
            schema_idx = build_result.next_idx;
            leaf_offset += lc;
        }
        return infos;
    }

    /// Validate `col_indices` (top-level columns). When every requested column
    /// is a single primitive leaf present in the row group, return the leaf
    /// index of each output column (caller frees); return null when the read
    /// needs nested assembly. Only the requested columns are considered.
    fn planFlatLeaves(self: *const Self, num_leaf_columns: usize, col_indices: ?[]const usize) !?[]usize {
        const num_top = self.numTopColumns();
        const is_flat = num_top == 0;
        const num_top_columns = if (is_flat) num_leaf_columns else num_top;
        if (col_indices) |indices| {
            for (indices) |idx| {
                if (idx >= num_top_columns) return error.InvalidArgument;
            }
        }

        const leaves = try self.allocator.alloc(usize, if (col_indices) |c| c.len else num_top_columns);
        errdefer self.allocator.free(leaves);
        for (leaves, 0..) |*l, i| l.* = if (col_indices) |c| c[i] else i;
        if (is_flat) return leaves;

        var schema_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer schema_arena.deinit();
        const top_infos = try self.buildTopInfos(schema_arena.allocator());
        for (leaves) |*l| {
            const info = top_infos[l.*];
            if (info.is_nested or info.leaf_start >= num_leaf_columns) {
                self.allocator.free(leaves);
                return null;
            }
            l.* = info.leaf_start;
        }
        return leaves;
    }

    /// Decode each leaf in `leaves` into `column_values[leaf]`, dropping levels.
    /// The caller owns `column_values` (pre-filled with empty slices) and frees
    /// it on error as well.
    fn readFlatColumns(self: *Self, row_group_index: usize, leaves: []const usize, column_values: [][]Value) !void {
        for (leaves) |leaf| {
            if (column_values[leaf].len > 0) continue; // projected more than once
            const result = try self.readColumnDynamic(leaf, row_group_index, false);
            // keep_levels = false, so no level arrays are returned.
            std.debug.assert(result.def_levels == null and result.rep_levels == null);
            column_values[leaf] = result.values;
        }
    }

    fn freeColumnValues(self: *Self, column_values: [][]Value) void {
        for (column_values) |vals| {
            for (vals) |v| v.deinit(self.allocator);
            if (vals.len > 0) self.allocator.free(vals);
        }
        self.allocator.free(column_values);
    }

    /// Read a single column dynamically
    fn readColumnDynamic(self: *Self, column_index: usize, row_group_index: usize, keep_levels: bool) !column_decoder.DynamicDecodeResult {
        return self.readColumnDynamicWithData(column_index, row_group_index, null, keep_levels);
    }

    /// Read a single column, optionally using caller-supplied page bytes.
    ///
    /// When `override_page_data` is non-null it must contain `[dict_page?]
    /// [data_pages...]` in the layout produced by `PageRangeReader`. This is
    /// the hook for filtered reads: the caller pre-reads just the data pages
    /// whose rows intersect the wanted `RowRanges`.
    fn readColumnDynamicWithData(
        self: *Self,
        column_index: usize,
        row_group_index: usize,
        override_page_data: ?[]const u8,
        keep_levels: bool,
    ) !column_decoder.DynamicDecodeResult {
        const rg = &self.metadata.row_groups[row_group_index];
        if (column_index >= rg.columns.len) return error.InvalidArgument;

        const chunk = &rg.columns[column_index];
        const meta = chunk.meta_data orelse return error.InvalidArgument;

        // Zero-copy BYTE_ARRAY values (see `column_decoder.borrow_bytes`): when
        // byte payloads go to a bytes arena and this function owns the page
        // buffers, those buffers are allocated from that arena and decoded values
        // point into them. They then live exactly as long as arena copies would
        // have (until the arena's reset/deinit); nothing frees them per value.
        const borrow_arena: ?std.mem.Allocator = if (override_page_data == null and
            if (format.getColumnInfo(self.metadata.schema, column_index)) |ci| ci.element.type_ == .byte_array else false)
            value_mod.bytes_arena_allocator
        else
            null;
        // Page buffers (the whole chunk and every decompressed page) go to the
        // arena when borrowing and are then never freed here: an arena free of
        // its last allocation would hand the bytes to the next page. The chunk
        // goes there whatever the codec: a V2 page with is_compressed = false
        // (or an empty values section) is decoded straight from the chunk.
        const page_alloc = borrow_arena orelse self.allocator;
        const free_pages = borrow_arena == null;

        // Read the raw page data (or use caller's buffer).
        const owned_page_data: ?[]u8 = if (override_page_data == null)
            try self.readColumnChunkData(page_alloc, chunk)
        else
            null;
        defer if (owned_page_data) |pd| if (free_pages) page_alloc.free(pd);
        const page_data: []const u8 = owned_page_data orelse override_page_data.?;

        // Set only after the chunk read: no I/O happens below while the
        // threadlocal flag is on, so an evented Io cannot run another decoder
        // on this thread with it set.
        const prev_borrow = column_decoder.borrow_bytes;
        column_decoder.borrow_bytes = borrow_arena != null;
        defer column_decoder.borrow_bytes = prev_borrow;

        var pos: usize = 0;

        // Check if we have a dictionary page
        var string_dict: ?dictionary.StringDictionary = null;
        defer if (string_dict) |*d| d.deinit();
        var int32_dict: ?dictionary.Int32Dictionary = null;
        defer if (int32_dict) |*d| d.deinit();
        var int64_dict: ?dictionary.Int64Dictionary = null;
        defer if (int64_dict) |*d| d.deinit();
        var float32_dict: ?dictionary.Float32Dictionary = null;
        defer if (float32_dict) |*d| d.deinit();
        var float64_dict: ?dictionary.Float64Dictionary = null;
        defer if (float64_dict) |*d| d.deinit();
        var fixed_byte_array_dict: ?dictionary.FixedByteArrayDictionary = null;
        defer if (fixed_byte_array_dict) |*d| d.deinit();
        var int96_dict: ?dictionary.Int96Dictionary = null;
        defer if (int96_dict) |*d| d.deinit();

        // Check for dictionary page - might be indicated by metadata OR by first page in stream
        // Some writers don't set dictionary_page_offset but still include dictionary pages
        {
            // Check if first page is a dictionary page (consumes header if so)
            var peek_thrift = thrift.CompactReader.init(page_data[pos..]);
            const first_header = try format.PageHeader.parse(self.allocator, &peek_thrift);
            defer self.freePageHeaderContents(&first_header);

            if (first_header.dictionary_page_header) |dph| {
                // This is a dictionary page - consume it
                pos += peek_thrift.pos;

                const dict_compressed_size = try safePageSize(first_header.compressed_page_size);
                const dict_uncompressed_size = try safePageSize(first_header.uncompressed_page_size);
                const dict_num_values = try safePageSize(dph.num_values);

                const dict_compressed = try safe.slice(page_data, pos, dict_compressed_size);
                pos += dict_compressed_size;

                // Validate CRC32 checksum if enabled
                if (self.checksum_options.validate_page_checksum) {
                    if (first_header.crc) |expected_crc| {
                        const actual_crc = computePageCrc(dict_compressed);
                        if (actual_crc != expected_crc) {
                            return error.PageChecksumMismatch;
                        }
                    } else if (self.checksum_options.strict_checksum) {
                        return error.MissingPageChecksum;
                    }
                }

                // Decompress dictionary page if needed
                const dict_data = if (meta.codec != .uncompressed) blk: {
                    break :blk try self.decompressData(page_alloc, dict_compressed, meta.codec, dict_uncompressed_size);
                } else dict_compressed;
                defer if (meta.codec != .uncompressed and free_pages) self.allocator.free(dict_data);

                // Build dictionaries based on physical type
                const column_info_for_dict = format.getColumnInfo(self.metadata.schema, column_index);
                if (column_info_for_dict) |info| {
                    if (info.element.type_) |phys_type| {
                        switch (phys_type) {
                            .byte_array => {
                                string_dict = if (borrow_arena != null)
                                    try dictionary.StringDictionary.fromPlainBorrowed(self.allocator, dict_data, dict_num_values)
                                else
                                    try dictionary.StringDictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            .int32 => {
                                int32_dict = try dictionary.Int32Dictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            .int64 => {
                                int64_dict = try dictionary.Int64Dictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            .float => {
                                float32_dict = try dictionary.Float32Dictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            .double => {
                                float64_dict = try dictionary.Float64Dictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            .fixed_len_byte_array => {
                                const fixed_len = try safeTypeLength(info.element.type_length);
                                if (fixed_len > 0) {
                                    fixed_byte_array_dict = try dictionary.FixedByteArrayDictionary.fromPlain(self.allocator, dict_data, dict_num_values, fixed_len);
                                }
                            },
                            .int96 => {
                                int96_dict = try dictionary.Int96Dictionary.fromPlain(self.allocator, dict_data, dict_num_values);
                            },
                            else => {},
                        }
                    }
                }
            }
            // If not a dictionary page, pos is unchanged and we'll process it as data
        }

        // Get column info
        const column_info = format.getColumnInfo(self.metadata.schema, column_index) orelse
            return error.InvalidArgument;

        // Accumulate values from all data pages
        var all_values: std.ArrayListUnmanaged(Value) = .empty;
        errdefer {
            for (all_values.items) |v| v.deinit(self.allocator);
            all_values.deinit(self.allocator);
        }

        var all_def_levels: std.ArrayListUnmanaged(u32) = .empty;
        errdefer all_def_levels.deinit(self.allocator);

        var all_rep_levels: std.ArrayListUnmanaged(u32) = .empty;
        errdefer all_rep_levels.deinit(self.allocator);

        // A page cannot hold more values than the chunk declares. Without this a header
        // that claims 2^31 values makes the decoders allocate arrays that size from a few bytes.
        var values_left = try safeRowCount(meta.num_values);

        // Loop through all data pages
        while (pos < page_data.len) {
            // Parse data page header
            var thrift_reader = thrift.CompactReader.init(page_data[pos..]);
            const page_header = try format.PageHeader.parse(self.allocator, &thrift_reader);
            defer self.freePageHeaderContents(&page_header);

            pos += thrift_reader.pos;

            // Skip non-data pages (neither V1 nor V2)
            if (page_header.data_page_header == null and page_header.data_page_header_v2 == null) {
                const skip_size = try safePageSize(page_header.compressed_page_size);
                if (pos + skip_size > page_data.len) return error.EndOfData;
                pos += skip_size;
                continue;
            }

            const compressed_size = try safePageSize(page_header.compressed_page_size);
            if (pos + compressed_size > page_data.len) return error.EndOfData;
            const compressed_body = try safe.slice(page_data, pos, compressed_size);
            pos += compressed_size;

            // Validate CRC32 checksum if enabled
            if (self.checksum_options.validate_page_checksum) {
                if (page_header.crc) |expected_crc| {
                    const actual_crc = computePageCrc(compressed_body);
                    if (actual_crc != expected_crc) {
                        return error.PageChecksumMismatch;
                    }
                } else if (self.checksum_options.strict_checksum) {
                    return error.MissingPageChecksum;
                }
            }

            // Handle V2 vs V1 page format differently
            if (page_header.data_page_header_v2) |v2| {
                // DataPageV2: levels are uncompressed, stored before values
                const rep_len = try safePageSize(v2.repetition_levels_byte_length);
                const def_len = try safePageSize(v2.definition_levels_byte_length);
                const num_values = try safePageSize(v2.num_values);

                if (num_values == 0) continue;
                if (num_values > values_left) return error.InvalidPageSize;
                values_left -= num_values;

                // Extract level data (uncompressed, at start of page body)
                const rep_levels_data = try safe.slice(compressed_body, 0, rep_len);
                const def_levels_data = try safe.slice(compressed_body, rep_len, def_len);
                const levels_total = std.math.add(usize, rep_len, def_len) catch return error.EndOfData;
                if (levels_total > compressed_body.len) return error.EndOfData;
                const values_compressed = compressed_body[levels_total..];

                // Decompress only the values section if needed
                // For V2, uncompressed_page_size is the size of the ENTIRE uncompressed page
                // But the levels are already uncompressed, so we need to calculate values size differently
                // The compressed_page_size in header is: rep_len + def_len + compressed_values_len
                // The uncompressed_page_size is: rep_len + def_len + uncompressed_values_len
                var values_data_allocated = false;
                const values_data = if (v2.is_compressed and meta.codec != .uncompressed) blk: {
                    const uncompressed_size = try safePageSize(page_header.uncompressed_page_size);
                    // Levels are uncompressed, so uncompressed values size = total - levels
                    if (uncompressed_size < levels_total) return error.EndOfData;
                    const values_uncompressed_size = uncompressed_size - levels_total;
                    // Handle empty values case - skip decompression for empty data pages
                    if (values_uncompressed_size == 0 or values_compressed.len == 0) {
                        break :blk values_compressed; // Return empty slice, no decompression needed
                    }
                    values_data_allocated = true;
                    break :blk try self.decompressData(page_alloc, values_compressed, meta.codec, values_uncompressed_size);
                } else values_compressed;
                defer if (values_data_allocated and free_pages) self.allocator.free(values_data);

                // Get value encoding from page header (used for delta encodings)
                const value_encoding = v2.encoding;
                const uses_dict = string_dict != null or int32_dict != null or int64_dict != null or float32_dict != null or float64_dict != null or int96_dict != null;

                // Decode with V2 format (levels already extracted, no length prefix)
                var page_result = try column_decoder.decodeColumnDynamicV2(
                    self.allocator,
                    column_info.element,
                    rep_levels_data,
                    def_levels_data,
                    values_data,
                    num_values,
                    column_info.max_def_level,
                    column_info.max_rep_level,
                    uses_dict or fixed_byte_array_dict != null,
                    if (string_dict) |*d| d else null,
                    if (int32_dict) |*d| d else null,
                    if (int64_dict) |*d| d else null,
                    if (float32_dict) |*d| d else null,
                    if (float64_dict) |*d| d else null,
                    if (fixed_byte_array_dict) |*d| d else null,
                    if (int96_dict) |*d| d else null,
                    value_encoding,
                );
                errdefer page_result.deinit(self.allocator);

                // Take ownership of the page's values. The first page's buffer becomes
                // the chunk buffer, so single-page chunks are never copied.
                if (all_values.capacity == 0) {
                    all_values = .fromOwnedSlice(page_result.values);
                } else {
                    try all_values.appendSlice(self.allocator, page_result.values);
                    self.allocator.free(page_result.values);
                }
                page_result.values = &.{};

                // Levels are only consumed by nested assembly.
                if (page_result.def_levels) |dl| {
                    if (keep_levels) try all_def_levels.appendSlice(self.allocator, dl);
                    self.allocator.free(dl);
                    page_result.def_levels = null;
                }
                if (page_result.rep_levels) |rl| {
                    if (keep_levels) try all_rep_levels.appendSlice(self.allocator, rl);
                    self.allocator.free(rl);
                    page_result.rep_levels = null;
                }
            } else if (page_header.data_page_header) |dph| {
                // DataPageV1: levels are inside compressed data with length prefixes

                // Decompress entire page if needed
                const value_data = if (meta.codec != .uncompressed) blk: {
                    const uncompressed_size = try safePageSize(page_header.uncompressed_page_size);
                    break :blk try self.decompressData(page_alloc, compressed_body, meta.codec, uncompressed_size);
                } else compressed_body;
                defer if (meta.codec != .uncompressed and free_pages) self.allocator.free(value_data);

                const num_values = try safePageSize(dph.num_values);
                if (num_values == 0) continue;
                if (num_values > values_left) return error.InvalidPageSize;
                values_left -= num_values;

                // Get encodings from page header
                const uses_dict_v1 = string_dict != null or int32_dict != null or int64_dict != null or float32_dict != null or float64_dict != null or fixed_byte_array_dict != null or int96_dict != null;
                const def_level_encoding = dph.definition_level_encoding;
                const rep_level_encoding = dph.repetition_level_encoding;
                const value_encoding_v1 = dph.encoding;

                // Decode dynamically with level and value encodings
                var page_result = try column_decoder.decodeColumnDynamicWithValueEncoding(
                    self.allocator,
                    column_info.element,
                    value_data,
                    num_values,
                    column_info.max_def_level,
                    column_info.max_rep_level,
                    uses_dict_v1,
                    if (string_dict) |*d| d else null,
                    if (int32_dict) |*d| d else null,
                    if (int64_dict) |*d| d else null,
                    if (float32_dict) |*d| d else null,
                    if (float64_dict) |*d| d else null,
                    if (fixed_byte_array_dict) |*d| d else null,
                    if (int96_dict) |*d| d else null,
                    def_level_encoding,
                    rep_level_encoding,
                    value_encoding_v1,
                );
                errdefer page_result.deinit(self.allocator);

                // Take ownership of the page's values. The first page's buffer becomes
                // the chunk buffer, so single-page chunks are never copied.
                if (all_values.capacity == 0) {
                    all_values = .fromOwnedSlice(page_result.values);
                } else {
                    try all_values.appendSlice(self.allocator, page_result.values);
                    self.allocator.free(page_result.values);
                }
                page_result.values = &.{};

                // Levels are only consumed by nested assembly.
                if (page_result.def_levels) |dl| {
                    if (keep_levels) try all_def_levels.appendSlice(self.allocator, dl);
                    self.allocator.free(dl);
                    page_result.def_levels = null;
                }
                if (page_result.rep_levels) |rl| {
                    if (keep_levels) try all_rep_levels.appendSlice(self.allocator, rl);
                    self.allocator.free(rl);
                    page_result.rep_levels = null;
                }
            }
        }

        // Each toOwnedSlice empties its list (and its errdefer above), so own the results
        // here until the struct is returned.
        const values = try all_values.toOwnedSlice(self.allocator);
        errdefer {
            for (values) |v| v.deinit(self.allocator);
            self.allocator.free(values);
        }
        const def_levels: ?[]u32 = if (all_def_levels.items.len > 0) try all_def_levels.toOwnedSlice(self.allocator) else null;
        errdefer if (def_levels) |dl| self.allocator.free(dl);
        const rep_levels: ?[]u32 = if (all_rep_levels.items.len > 0) try all_rep_levels.toOwnedSlice(self.allocator) else null;
        return .{ .values = values, .def_levels = def_levels, .rep_levels = rep_levels };
    }

    /// Assemble rows from columnar data.
    /// Uses the file schema to reconstruct logical top-level columns, properly
    /// rebuilding nested types (structs, maps, nested lists) via assembleValues.
    fn assembleNestedRows(
        self: *Self,
        num_rows: usize,
        num_leaf_columns: usize,
        column_values: [][]Value,
        column_def_levels: []?[]u32,
        column_rep_levels: []?[]u32,
        top_infos: []const TopColInfo,
        projected_top_indices: ?[]const usize,
    ) ![]Row {
        const num_top = top_infos.len;

        // Phase 1: For each nested top-level column, assemble all rows at once.
        const assembled_cols = try self.allocator.alloc(?[]Value, num_top);
        defer {
            for (assembled_cols) |opt_vals| {
                if (opt_vals) |vals| {
                    for (vals) |v| v.deinit(self.allocator);
                    self.allocator.free(vals);
                }
            }
            self.allocator.free(assembled_cols);
        }
        @memset(assembled_cols, null);

        for (0..num_top) |top_idx| {
            const info = top_infos[top_idx];
            if (!info.is_nested) continue;
            if (projected_top_indices) |indices| {
                var needed = false;
                for (indices) |pi| {
                    if (pi == top_idx) {
                        needed = true;
                        break;
                    }
                }
                if (!needed) continue;
            }

            const slices = try self.allocator.alloc(nested_mod.FlatColumnSlice, info.leaf_count);
            defer self.allocator.free(slices);

            for (0..info.leaf_count) |li| {
                const phys = info.leaf_start + li;
                if (phys < num_leaf_columns) {
                    slices[li] = .{
                        .values = column_values[phys],
                        .def_levels = column_def_levels[phys] orelse &.{},
                        .rep_levels = column_rep_levels[phys] orelse &.{},
                    };
                } else {
                    slices[li] = .{ .values = &.{}, .def_levels = &.{}, .rep_levels = &.{} };
                }
            }

            assembled_cols[top_idx] = try nested_mod.assembleValues(
                self.allocator,
                info.schema_node,
                slices,
                num_rows,
            );
        }

        // Phase 2: Build rows with only the projected columns
        const output_indices = projected_top_indices orelse blk: {
            const all = try self.allocator.alloc(usize, num_top);
            for (0..num_top) |i| all[i] = i;
            break :blk all;
        };
        defer if (projected_top_indices == null) self.allocator.free(output_indices);

        const num_output_cols = output_indices.len;
        const rows = try self.allocator.alloc(Row, num_rows);
        errdefer self.allocator.free(rows);
        var rows_initialized: usize = 0;
        errdefer {
            for (rows[0..rows_initialized]) |row| row.deinit();
        }

        for (0..num_rows) |row_idx| {
            const values = try self.allocator.alloc(Value, num_output_cols);
            errdefer self.allocator.free(values);
            var vals_initialized: usize = 0;
            errdefer {
                for (values[0..vals_initialized]) |v| v.deinit(self.allocator);
            }

            for (output_indices, 0..) |top_idx, out_idx| {
                const info = top_infos[top_idx];
                if (assembled_cols[top_idx]) |assembled| {
                    values[out_idx] = try cloneValue(self.allocator, assembled[row_idx]);
                } else {
                    const phys = info.leaf_start;
                    if (phys < num_leaf_columns and row_idx < column_values[phys].len) {
                        values[out_idx] = try cloneValue(self.allocator, column_values[phys][row_idx]);
                    } else {
                        values[out_idx] = .{ .null_val = {} };
                    }
                }
                vals_initialized += 1;
            }

            rows[row_idx] = .{ .values = values, .allocator = self.allocator, .bytes_borrowed = true };
            rows_initialized += 1;
        }

        // Free assembled_cols now (will be freed by defer, setting to null avoids double-free)
        for (0..num_top) |top_idx| {
            if (assembled_cols[top_idx]) |vals| {
                for (vals) |v| v.deinit(self.allocator);
                self.allocator.free(vals);
                assembled_cols[top_idx] = null;
            }
        }

        return rows;
    }

    fn assembleFlatRows(
        self: *Self,
        num_rows: usize,
        num_columns: usize,
        column_values: [][]Value,
        projected_col_indices: ?[]const usize,
        rows_arena: ?*std.heap.ArenaAllocator,
    ) ![]Row {
        const output_indices = projected_col_indices orelse blk: {
            const all = try self.allocator.alloc(usize, num_columns);
            for (0..num_columns) |i| all[i] = i;
            break :blk all;
        };
        defer if (projected_col_indices == null) self.allocator.free(output_indices);

        const num_output_cols = output_indices.len;
        const rows = try self.allocator.alloc(Row, num_rows);
        errdefer self.allocator.free(rows);

        // Flat values are scalars or byte slices owned by the reader's bytes arena
        // (bytes_arena_allocator is set for the whole read), so cells are moved, not
        // cloned. The caller's `column_values` cleanup then frees only the arrays.
        if (rows_arena) |arena| {
            const cells = std.math.mul(usize, num_rows, num_output_cols) catch return error.OutOfMemory;
            const block = try arena.allocator().alloc(Value, cells);
            for (rows, 0..) |*row, r| {
                const vals = block[r * num_output_cols ..][0..num_output_cols];
                fillFlatRow(vals, column_values, output_indices, r);
                row.* = .{ .values = vals, .allocator = self.allocator, .bytes_borrowed = true, .values_borrowed = true };
            }
            return rows;
        }

        var rows_initialized: usize = 0;
        errdefer for (rows[0..rows_initialized]) |row| row.deinit();
        for (rows, 0..) |*row, r| {
            const vals = try self.allocator.alloc(Value, num_output_cols);
            fillFlatRow(vals, column_values, output_indices, r);
            row.* = .{ .values = vals, .allocator = self.allocator, .bytes_borrowed = true };
            rows_initialized += 1;
        }
        return rows;
    }

    /// Read raw page data for a column chunk
    fn readColumnChunkData(self: *Self, allocator: std.mem.Allocator, chunk: *const format.ColumnChunk) ![]u8 {
        return parquet_reader.readColumnChunkData(allocator, self.getSource(), chunk) catch |e| {
            return switch (e) {
                error.InvalidArgument => error.InvalidArgument,
                error.OutOfMemory => error.OutOfMemory,
                error.InputOutput => error.InputOutput,
                error.InvalidPageSize => error.InvalidPageSize,
                else => error.InputOutput,
            };
        };
    }

    /// Decompress page data
    fn decompressData(self: *Self, allocator: std.mem.Allocator, compressed: []const u8, codec: format.CompressionCodec, uncompressed_size: usize) ![]u8 {
        _ = self;
        return compress.decompress(allocator, compressed, codec, uncompressed_size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DecompressionError => return error.DecompressionError,
            error.UnsupportedCompression => return error.UnsupportedCompression,
        };
    }

    /// Free the allocated contents within a PageHeader (statistics min/max values).
    /// Does NOT free the PageHeader struct itself.
    fn freePageHeaderContents(self: *Self, header: *const format.PageHeader) void {
        // Use mutable copy to call deinit
        var mutable_header = header.*;
        mutable_header.deinit(self.allocator);
    }
};

/// Move row `row` of each projected column into `dst` (no cloning). Missing
/// trailing values in a column become null.
fn fillFlatRow(dst: []Value, column_values: []const []Value, output_indices: []const usize, row: usize) void {
    for (output_indices, dst) |col_idx, *d| {
        const col = column_values[col_idx];
        d.* = if (row < col.len) col[row] else .{ .null_val = {} };
    }
}

/// Clone a Value, allocating new memory for any heap data
fn cloneValue(allocator: std.mem.Allocator, v: Value) !Value {
    return switch (v) {
        .null_val => .{ .null_val = {} },
        .bool_val => |b| .{ .bool_val = b },
        .int32_val => |i| .{ .int32_val = i },
        .int64_val => |i| .{ .int64_val = i },
        .float_val => |f| .{ .float_val = f },
        .double_val => |d| .{ .double_val = d },
        .bytes_val => |b| .{ .bytes_val = try value_mod.dupeBytes(allocator, b) },
        .fixed_bytes_val => |b| .{ .fixed_bytes_val = try value_mod.dupeBytes(allocator, b) },
        .list_val => |items| blk: {
            const cloned = try allocator.alloc(Value, items.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned[0..cloned_count]) |cv| cv.deinit(allocator);
                allocator.free(cloned);
            }
            for (items) |item| {
                cloned[cloned_count] = try cloneValue(allocator, item);
                cloned_count += 1;
            }
            break :blk .{ .list_val = cloned };
        },
        .map_val => |entries| blk: {
            const cloned = try allocator.alloc(Value.MapEntryValue, entries.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned[0..cloned_count]) |e| {
                    e.key.deinit(allocator);
                    e.value.deinit(allocator);
                }
                allocator.free(cloned);
            }
            for (entries) |entry| {
                const key = try cloneValue(allocator, entry.key);
                errdefer key.deinit(allocator);
                const value = try cloneValue(allocator, entry.value);
                cloned[cloned_count] = .{ .key = key, .value = value };
                cloned_count += 1;
            }
            break :blk .{ .map_val = cloned };
        },
        .struct_val => |fields| blk: {
            const cloned = try allocator.alloc(Value.FieldValue, fields.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned[0..cloned_count]) |f| {
                    allocator.free(f.name);
                    f.value.deinit(allocator);
                }
                allocator.free(cloned);
            }
            for (fields) |field| {
                const name = try allocator.dupe(u8, field.name);
                errdefer allocator.free(name);
                const value = try cloneValue(allocator, field.value);
                cloned[cloned_count] = .{ .name = name, .value = value };
                cloned_count += 1;
            }
            break :blk .{ .struct_val = cloned };
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

test "nested row assembly groups values by rep_level" {
    const allocator = std.testing.allocator;

    // Simulate a nested column with rep_levels:
    // rep=0 means new row, rep>0 means continuation
    // Values: [a, b, c, d, e]
    // Rep levels: [0, 1, 0, 1, 1]
    // Expected: Row 0 = [a, b], Row 1 = [c, d, e]

    const col_values = [_]Value{
        .{ .bytes_val = "a" },
        .{ .bytes_val = "b" },
        .{ .bytes_val = "c" },
        .{ .bytes_val = "d" },
        .{ .bytes_val = "e" },
    };

    const rep_levels = [_]u32{ 0, 1, 0, 1, 1 };

    // Test the row boundary detection logic that assembleNestedRows uses
    // Find row boundaries (where rep_level == 0)
    var row_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer row_starts.deinit(allocator);

    for (rep_levels, 0..) |rl, i| {
        if (rl == 0) {
            try row_starts.append(allocator, i);
        }
    }

    // Verify row boundaries
    try std.testing.expectEqual(@as(usize, 2), row_starts.items.len);
    try std.testing.expectEqual(@as(usize, 0), row_starts.items[0]);
    try std.testing.expectEqual(@as(usize, 2), row_starts.items[1]);

    // Verify row 0 would contain values[0..2] = [a, b]
    const row0_start = row_starts.items[0];
    const row0_end = row_starts.items[1];
    try std.testing.expectEqual(@as(usize, 2), row0_end - row0_start);

    // Verify row 1 would contain values[2..5] = [c, d, e]
    const row1_start = row_starts.items[1];
    const row1_end = col_values.len;
    try std.testing.expectEqual(@as(usize, 3), row1_end - row1_start);
}
