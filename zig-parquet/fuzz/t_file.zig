//! Fuzz targets `file` / `file-oom`: whole-file read, metamorphic across reader modes.
//!
//! The reference is `readAllRows` over the first min(row groups, 16) row groups, stopping at about
//! 4096 rows. Each other mode must reproduce it whenever it succeeds: the row iterator, the
//! streaming iterator (rows compared as they are produced) and a projected read of a column subset.
//! `file-oom` takes a u16 prefix naming the allocation that fails (0xffff = never).
const std = @import("std");
const parquet = @import("parquet");
const common = @import("common.zig");

const Row = parquet.Row;
const Value = parquet.Value;

const max_row_groups = 16;
const max_ref_rows = 4096;

/// Feedback.detail bits: the reader modes that produced every row they were compared on.
const mode_iterator: u64 = 1 << 0;
const mode_streaming: u64 = 1 << 1;
const mode_projected: u64 = 1 << 2;

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback, oom: bool) !void {
    var input: common.Input = .{ .bytes = bytes };
    var file = bytes;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var a = gpa;
    if (oom) {
        const fail_at = input.int(u16);
        file = input.rest();
        failing = std.testing.FailingAllocator.init(gpa, .{
            .fail_index = if (fail_at == 0xffff) std.math.maxInt(usize) else fail_at,
        });
        a = failing.allocator();
    }

    const h = std.hash.Wyhash.hash(0, file);
    var r = try parquet.openBufferDynamic(a, file, .{
        .checksum = .{ .validate_page_checksum = (h & 7) == 0 },
    });
    defer r.deinit();

    // Reference. Freed before `r` (defers run in reverse), since rows point into the reader's arena.
    var ref: std.ArrayList([]Row) = .empty;
    defer {
        for (ref.items) |rows| common.freeRows(a, rows);
        ref.deinit(a);
    }
    var ref_rows: usize = 0;
    const rg_count = @min(r.getNumRowGroups(), max_row_groups);
    for (0..rg_count) |rg| {
        if (ref_rows >= max_ref_rows) break;
        try ref.ensureUnusedCapacity(a, 1);
        const rows = try r.readAllRows(rg);
        ref.appendAssumeCapacity(rows);
        ref_rows += rows.len;
    }
    fb.rows = ref_rows;

    var detail: u64 = 0;
    var it = r.rowIterator();
    defer it.deinit();
    if (compareIter("rowIterator", &it, ref.items, ref_rows, oom)) detail |= mode_iterator;

    var st = r.rowIteratorStreaming();
    defer st.deinit();
    if (compareIter("rowIteratorStreaming", &st, ref.items, ref_rows, oom)) detail |= mode_streaming;

    // Top-level column width comes from the reference rows (`getNumColumns` counts leaves).
    const width: usize = for (ref.items) |rows| {
        if (rows.len > 0) break rows[0].values.len;
    } else 0;
    var proj_buf: [64]usize = undefined;
    const proj = projection(&proj_buf, width, h >> 3);
    if (proj.len > 0 and compareProjected(&r, a, ref.items, proj, oom)) detail |= mode_projected;

    fb.detail = detail;
}

/// Columns whose bit is set in `mask` (bit c = column c, c < 64). At least column 0 when none is set.
fn projection(buf: *[64]usize, width: usize, mask: u64) []const usize {
    var n: usize = 0;
    for (0..@min(width, 64)) |c| {
        const shift: u6 = @truncate(c); // c < 64
        if (((mask >> shift) & 1) == 1) {
            buf[n] = c;
            n += 1;
        }
    }
    if (n == 0 and width > 0) {
        buf[0] = 0;
        n = 1;
    }
    return buf[0..n];
}

/// Walks `it` against the first `ref_rows` reference rows, comparing each row as it is produced
/// (streaming rows are valid only until the next call). Returns false when an injected OOM stopped
/// the mode; any other error or any difference is a finding.
fn compareIter(comptime mode: []const u8, it: anytype, ref: []const []Row, ref_rows: usize, oom: bool) bool {
    var rg: usize = 0;
    var j: usize = 0;
    var seen: usize = 0;
    while (seen < ref_rows) : (seen += 1) {
        while (rg < ref.len and j >= ref[rg].len) {
            rg += 1;
            j = 0;
        }
        if (rg >= ref.len) std.debug.panic("fuzz-mismatch: {s} reference cursor past its last row", .{mode});
        const got_opt = it.next() catch |e| {
            if (oom) return false;
            std.debug.panic("fuzz-mismatch: {s} errored ({s}) at rg {d} row {d}, reference read succeeded", .{ mode, @errorName(e), rg, j });
        };
        const got = got_opt orelse std.debug.panic("fuzz-mismatch: {s} ended after {d} of {d} rows", .{ mode, seen, ref_rows });
        if (rowDiff(got.values, ref[rg][j].values)) |col| {
            std.debug.panic("fuzz-mismatch: {s} rg {d} row {d} col {d}", .{ mode, rg, j, col });
        }
        j += 1;
    }
    return true;
}

/// Projected reads of every reference row group, column `proj[k]` compared with reference column
/// `proj[k]`. Returns false when an injected OOM stopped the read.
fn compareProjected(r: *parquet.DynamicReader, gpa: std.mem.Allocator, ref: []const []Row, proj: []const usize, oom: bool) bool {
    for (ref, 0..) |want_rows, rg| {
        const got = r.readRowsProjected(rg, proj) catch |e| {
            if (oom) return false;
            std.debug.panic("fuzz-mismatch: projected rg {d} errored ({s}), reference read succeeded", .{ rg, @errorName(e) });
        };
        defer common.freeRows(gpa, got);
        if (got.len != want_rows.len) {
            std.debug.panic("fuzz-mismatch: projected rg {d} returned {d} rows, reference {d}", .{ rg, got.len, want_rows.len });
        }
        for (got, want_rows, 0..) |g, w, row| {
            if (projectedDiff(g.values, w.values, proj)) |col| {
                std.debug.panic("fuzz-mismatch: projected rg {d} row {d} col {d}", .{ rg, row, col });
            }
        }
    }
    return true;
}

/// Index of the first column where a row differs from the reference row, or null when equal.
fn rowDiff(got: []const Value, want: []const Value) ?usize {
    if (got.len != want.len) return @min(got.len, want.len);
    for (got, want, 0..) |g, w, c| {
        if (!common.valuesEqual(g, w)) return c;
    }
    return null;
}

/// Projected row `got` (dense, column j = reference column `proj[j]`) against reference row `want`.
fn projectedDiff(got: []const Value, want: []const Value, proj: []const usize) ?usize {
    if (got.len != proj.len) return 0;
    for (proj, 0..) |c, j| {
        if (c >= want.len or !common.valuesEqual(got[j], want[c])) return j;
    }
    return null;
}
