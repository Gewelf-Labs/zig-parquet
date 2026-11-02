//! Page Writer
//!
//! Creates data pages by combining definition levels with encoded values.
//! For V1 data pages, the format is:
//!   - Repetition levels (RLE encoded, with 4-byte length prefix) - not used for flat schemas
//!   - Definition levels (RLE encoded, with 4-byte length prefix)
//!   - Values (PLAIN encoded)

const std = @import("std");
const format = @import("format.zig");
const types = @import("types.zig");
const safe = @import("safe.zig");
const rle_encoder = @import("encoding/rle_encoder.zig");
const plain_encoder = @import("encoding/plain_encoder.zig");
const byte_stream_split_encoder = @import("encoding/byte_stream_split_encoder.zig");
const delta_binary_packed_encoder = @import("encoding/delta_binary_packed_encoder.zig");
const delta_length_byte_array_encoder = @import("encoding/delta_length_byte_array_encoder.zig");
const delta_byte_array_encoder = @import("encoding/delta_byte_array_encoder.zig");

const Optional = types.Optional;
const Int96 = types.Int96;

pub const PageWriteError = error{
    OutOfMemory,
    InvalidFixedLength,
    IntegerOverflow,
    ValueTooLarge,
    UnsupportedEncoding,
    NullInRequiredColumn,
};

/// Result of writing a data page
pub const DataPageResult = struct {
    /// The raw page data (definition levels + values)
    data: []u8,
    /// Number of values in the page
    num_values: usize,
    /// Number of non-null values
    num_non_null: usize,

    pub fn deinit(self: *DataPageResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// =============================================================================
// Byte Array Data Pages (non-generic encoding)
// =============================================================================

/// Write a data page for Optional fixed-length byte array values with a specific encoding.
pub fn writeDataPageFixedByteArrayOptionalWithEncoding(
    allocator: std.mem.Allocator,
    values: []const Optional([]const u8),
    fixed_len: usize,
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    var non_null_values: std.ArrayList([]const u8) = .empty;
    defer non_null_values.deinit(allocator);

    var is_defined: std.ArrayList(bool) = .empty;
    defer is_defined.deinit(allocator);

    for (values) |v| {
        const defined = v != .null_value;
        try is_defined.append(allocator, defined);
        if (defined) {
            if (v.value.len != fixed_len) return error.InvalidFixedLength;
            try non_null_values.append(allocator, v.value);
        }
    }

    if (!is_optional and non_null_values.items.len != values.len) return error.NullInRequiredColumn;

    const encoded_values = try encodeFixedByteArraysWithEncoding(allocator, non_null_values.items, fixed_len, encoding);
    defer allocator.free(encoded_values);

    if (!is_optional) {
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = values.len,
        };
    }
    return combineDefLevelsAndValues(allocator, is_defined.items, encoded_values, values.len);
}

/// Internal generic function to write a typed data page
fn writeDataPageTyped(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    is_defined: ?[]const bool,
    is_optional: bool,
) PageWriteError!DataPageResult {
    // Encode values based on type
    const encoded_values = switch (T) {
        i32 => try plain_encoder.encodeInt32(allocator, values),
        i64 => try plain_encoder.encodeInt64(allocator, values),
        f32 => try plain_encoder.encodeFloat(allocator, values),
        f64 => try plain_encoder.encodeDouble(allocator, values),
        bool => try plain_encoder.encodeBooleans(allocator, values),
        else => @compileError("Unsupported type for writeDataPageTyped: " ++ @typeName(T)),
    };
    defer allocator.free(encoded_values);

    const total_values = if (is_defined) |def| def.len else values.len;

    if (!is_optional) {
        // No definition levels needed
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = values.len,
        };
    }

    // Create definition levels
    const def_levels = if (is_defined) |def|
        def
    else blk: {
        // All values are defined
        const all_defined = try allocator.alloc(bool, values.len);
        @memset(all_defined, true);
        break :blk all_defined;
    };
    defer if (is_defined == null) allocator.free(def_levels);

    return combineDefLevelsAndValues(allocator, def_levels, encoded_values, total_values);
}

/// Combine definition levels and values into a data page
fn combineDefLevelsAndValues(
    allocator: std.mem.Allocator,
    is_defined: []const bool,
    encoded_values: []const u8,
    total_values: usize,
) PageWriteError!DataPageResult {
    // Encode definition levels with length prefix
    const def_level_data = try rle_encoder.encodeDefLevelsWithLength(allocator, is_defined);
    defer allocator.free(def_level_data);

    // Count non-null values
    var num_non_null: usize = 0;
    for (is_defined) |d| {
        if (d) num_non_null += 1;
    }

    // Combine: def levels + values
    const total_size = def_level_data.len + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    @memcpy(result[0..def_level_data.len], def_level_data);
    @memcpy(result[def_level_data.len..], encoded_values);

    return .{
        .data = result,
        .num_values = total_values,
        .num_non_null = num_non_null,
    };
}

/// Write a data page for list columns with definition and repetition levels.
/// This is used for nested types (lists, structs, maps).
pub fn writeDataPageWithLevels(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
) PageWriteError!DataPageResult {
    // Encode values based on type
    const encoded_values = switch (T) {
        i32 => try plain_encoder.encodeInt32(allocator, values),
        i64 => try plain_encoder.encodeInt64(allocator, values),
        f32 => try plain_encoder.encodeFloat(allocator, values),
        f64 => try plain_encoder.encodeDouble(allocator, values),
        bool => try plain_encoder.encodeBooleans(allocator, values),
        []const u8 => try plain_encoder.encodeByteArrays(allocator, values),
        else => @compileError("Unsupported type for writeDataPageWithLevels"),
    };
    defer allocator.free(encoded_values);

    // Encode repetition levels with length prefix (if max_rep_level > 0)
    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    // Encode definition levels with length prefix (if max_def_level > 0)
    // When max_def_level=0, all values are required and no def levels are stored
    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    // Calculate total size: rep_levels + def_levels + values
    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    // Write repetition levels (if any)
    if (rep_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    // Write definition levels (if any)
    if (def_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    // Write values
    @memcpy(result[offset..], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len, // Total slots
        .num_non_null = values.len, // Actual values
    };
}

/// Like writeDataPageWithLevels but uses a specified value encoding instead of PLAIN.
pub fn writeDataPageWithLevelsAndEncoding(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    const encoded_values = try encodeValuesWithEncoding(allocator, T, values, encoding);
    defer allocator.free(encoded_values);

    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    if (rep_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    if (def_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    @memcpy(result[offset..], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len,
        .num_non_null = values.len,
    };
}

/// Like writeDataPageWithLevelsByteArray but uses a specified value encoding instead of PLAIN.
pub fn writeDataPageWithLevelsByteArrayWithEncoding(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    const encoded_values = try encodeByteArraysWithEncoding(allocator, values, encoding);
    defer allocator.free(encoded_values);

    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    if (rep_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    if (def_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    @memcpy(result[offset..], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len,
        .num_non_null = values.len,
    };
}

/// Write a data page for byte array values with definition and repetition levels.
/// This is used for nested types (structs, lists) with string/binary fields.
pub fn writeDataPageWithLevelsByteArray(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
) PageWriteError!DataPageResult {
    // Encode values as byte arrays (length-prefixed)
    const encoded_values = try plain_encoder.encodeByteArrays(allocator, values);
    defer allocator.free(encoded_values);

    // Encode repetition levels with length prefix (if max_rep_level > 0)
    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    // Encode definition levels with length prefix (if max_def_level > 0)
    // When max_def_level=0, all values are required and no def levels are stored
    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    // Calculate total size: rep_levels + def_levels + values
    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    // Write repetition levels (if any)
    if (rep_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    // Write definition levels (if any)
    if (def_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    // Write values
    @memcpy(result[offset..], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len, // Total slots
        .num_non_null = values.len, // Actual values
    };
}

/// Write a data page for fixed-length byte array values with definition and repetition levels.
/// This is used for nested types (structs, lists) with fixed-length binary fields like UUID.
pub fn writeDataPageWithLevelsFixedByteArray(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    fixed_len: usize,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
) PageWriteError!DataPageResult {
    return writeDataPageWithLevelsFixedByteArrayWithEncoding(allocator, values, fixed_len, def_levels, rep_levels, max_def_level, max_rep_level, .plain);
}

/// Write a data page for fixed-length byte array values with definition/repetition levels and a specific encoding.
pub fn writeDataPageWithLevelsFixedByteArrayWithEncoding(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    fixed_len: usize,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    const encoded_values = try encodeFixedByteArraysWithEncoding(allocator, values, fixed_len, encoding);
    defer allocator.free(encoded_values);

    // Encode repetition levels with length prefix (if max_rep_level > 0)
    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    // Encode definition levels with length prefix (if max_def_level > 0)
    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    // Calculate total size: rep_levels + def_levels + values
    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var write_offset: usize = 0;

    // Write repetition levels (if any)
    if (rep_level_data) |d| {
        @memcpy(result[write_offset..][0..d.len], d);
        write_offset += d.len;
    }

    // Write definition levels (if any)
    if (def_level_data) |d| {
        @memcpy(result[write_offset..][0..d.len], d);
        write_offset += d.len;
    }

    // Write values
    @memcpy(result[write_offset..], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len, // Total slots
        .num_non_null = values.len, // Actual values
    };
}

// =============================================================================
// Encoding-aware Data Page Writers
// =============================================================================

/// Write a data page with a specific value encoding
pub fn writeDataPageWithEncoding(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    return writeDataPageTypedWithEncoding(allocator, T, values, null, is_optional, encoding);
}

/// Internal function to write a typed data page with encoding
fn writeDataPageTypedWithEncoding(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    is_defined: ?[]const bool,
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    // Encode values based on type and encoding
    const encoded_values = try encodeValuesWithEncoding(allocator, T, values, encoding);
    defer allocator.free(encoded_values);

    const total_values = if (is_defined) |def| def.len else values.len;

    if (!is_optional) {
        // No definition levels needed
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = values.len,
        };
    }

    // Create definition levels
    const def_levels = if (is_defined) |def|
        def
    else blk: {
        // All values are defined
        const all_defined = try allocator.alloc(bool, values.len);
        @memset(all_defined, true);
        break :blk all_defined;
    };
    defer if (is_defined == null) allocator.free(def_levels);

    return combineDefLevelsAndValues(allocator, def_levels, encoded_values, total_values);
}

/// Encode values with the specified encoding
fn encodeValuesWithEncoding(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const T,
    encoding: format.Encoding,
) ![]u8 {
    return switch (encoding) {
        .byte_stream_split => blk: {
            if (T == f32) {
                break :blk byte_stream_split_encoder.encodeFloat32(allocator, values) catch return error.OutOfMemory;
            } else if (T == f64) {
                break :blk byte_stream_split_encoder.encodeFloat64(allocator, values) catch return error.OutOfMemory;
            } else if (T == i32) {
                break :blk byte_stream_split_encoder.encodeInt32(allocator, values) catch return error.OutOfMemory;
            } else if (T == i64) {
                break :blk byte_stream_split_encoder.encodeInt64(allocator, values) catch return error.OutOfMemory;
            } else if (T == f16) {
                break :blk byte_stream_split_encoder.encodeFloat16(allocator, values) catch return error.OutOfMemory;
            } else {
                return error.UnsupportedEncoding;
            }
        },
        .delta_binary_packed => blk: {
            if (T == i32) {
                break :blk delta_binary_packed_encoder.encodeInt32(allocator, values) catch return error.OutOfMemory;
            } else if (T == i64) {
                break :blk delta_binary_packed_encoder.encodeInt64(allocator, values) catch return error.OutOfMemory;
            } else {
                return error.UnsupportedEncoding;
            }
        },
        .rle => blk: {
            if (T == bool) {
                break :blk rle_encoder.encodeBooleans(allocator, values) catch return error.OutOfMemory;
            } else {
                return error.UnsupportedEncoding;
            }
        },
        else => try encodePlain(allocator, T, values),
    };
}

/// Encode values using PLAIN encoding
fn encodePlain(allocator: std.mem.Allocator, comptime T: type, values: []const T) ![]u8 {
    return switch (T) {
        i32 => try plain_encoder.encodeInt32(allocator, values),
        i64 => try plain_encoder.encodeInt64(allocator, values),
        f32 => try plain_encoder.encodeFloat(allocator, values),
        f64 => try plain_encoder.encodeDouble(allocator, values),
        bool => try plain_encoder.encodeBooleans(allocator, values),
        else => @compileError("Unsupported type for encodePlain: " ++ @typeName(T)),
    };
}

// =============================================================================
// Unified Optional Data Page Writers (Phase 11 style)
// =============================================================================

/// Write a data page with Optional(T) values and a specific encoding.
/// This is the unified function that handles both nullable and non-nullable cases.
pub fn writeDataPageOptionalWithEncoding(
    allocator: std.mem.Allocator,
    comptime T: type,
    values: []const Optional(T),
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    if (encoding == .plain and (T == i32 or T == i64 or T == f32 or T == f64 or T == bool)) return writePlainPageOptional(allocator, T, values, is_optional);

    // Separate into non-null values and definition mask
    var non_null_values: std.ArrayList(T) = .empty;
    defer non_null_values.deinit(allocator);

    var is_defined: std.ArrayList(bool) = .empty;
    defer is_defined.deinit(allocator);

    for (values) |v| {
        const defined = v != .null_value;
        try is_defined.append(allocator, defined);
        if (defined) {
            try non_null_values.append(allocator, v.value);
        }
    }

    if (!is_optional and non_null_values.items.len != values.len) return error.NullInRequiredColumn;

    return writeDataPageTypedWithEncoding(
        allocator,
        T,
        non_null_values.items,
        is_defined.items,
        is_optional,
        encoding,
    );
}

/// Write a byte array data page with a specific encoding
pub fn writeDataPageByteArrayWithEncoding(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    // Encode byte arrays with specified encoding
    const encoded_values = try encodeByteArraysWithEncoding(allocator, values, encoding);
    defer allocator.free(encoded_values);

    if (!is_optional) {
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = values.len,
        };
    }

    // For optional, create all-defined mask
    const is_defined = try allocator.alloc(bool, values.len);
    defer allocator.free(is_defined);
    @memset(is_defined, true);

    return combineDefLevelsAndValues(allocator, is_defined, encoded_values, values.len);
}

/// Encode byte arrays with the specified encoding
fn encodeByteArraysWithEncoding(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    encoding: format.Encoding,
) ![]u8 {
    return switch (encoding) {
        .delta_length_byte_array => delta_length_byte_array_encoder.encode(allocator, values) catch return error.OutOfMemory,
        .delta_byte_array => delta_byte_array_encoder.encode(allocator, values) catch return error.OutOfMemory,
        else => try plain_encoder.encodeByteArrays(allocator, values),
    };
}

/// Encode fixed-length byte arrays with the specified encoding
fn encodeFixedByteArraysWithEncoding(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    fixed_len: usize,
    encoding: format.Encoding,
) PageWriteError![]u8 {
    return switch (encoding) {
        .byte_stream_split => byte_stream_split_encoder.encodeFixedByteArray(allocator, values, fixed_len) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArgument => return error.InvalidFixedLength,
        },
        else => plain_encoder.encodeFixedByteArrays(allocator, values, fixed_len) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFixedLength => return error.InvalidFixedLength,
            error.ValueTooLarge => return error.ValueTooLarge,
        },
    };
}

// =============================================================================
// INT96 Data Page Writers (Legacy timestamp format)
// =============================================================================

/// Encode INT96 values from i64 nanoseconds
/// Each value is 12 bytes: 8 bytes nanoseconds within day + 4 bytes Julian day
fn encodeInt96Values(allocator: std.mem.Allocator, values: []const i64) ![]u8 {
    const result = try allocator.alloc(u8, values.len * 12);
    errdefer allocator.free(result);

    for (values, 0..) |nanos, i| {
        const int96 = Int96.fromNanos(nanos);
        @memcpy(result[i * 12 ..][0..12], &int96.bytes);
    }

    return result;
}

/// Write a data page for Optional INT96 values (with nulls)
pub fn writeDataPageInt96Optional(
    allocator: std.mem.Allocator,
    values: []const Optional(i64),
    is_optional: bool,
) PageWriteError!DataPageResult {
    // Separate into non-null values and definition mask
    var non_null_values: std.ArrayList(i64) = .empty;
    defer non_null_values.deinit(allocator);

    var is_defined: std.ArrayList(bool) = .empty;
    defer is_defined.deinit(allocator);

    for (values) |v| {
        const defined = v != .null_value;
        try is_defined.append(allocator, defined);
        if (defined) {
            try non_null_values.append(allocator, v.value);
        }
    }

    if (!is_optional and non_null_values.items.len != values.len) return error.NullInRequiredColumn;

    // Encode the non-null values as INT96
    const encoded_values = try encodeInt96Values(allocator, non_null_values.items);
    defer allocator.free(encoded_values);

    if (!is_optional) {
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = non_null_values.items.len,
        };
    }
    return combineDefLevelsAndValues(allocator, is_defined.items, encoded_values, values.len);
}

/// Write a data page for INT96 values with explicit definition and repetition levels.
/// Used for list and list-of-struct contexts where def/rep levels encode the nesting structure.
pub fn writeDataPageInt96WithLevels(
    allocator: std.mem.Allocator,
    values: []const i64,
    def_levels: []const u32,
    rep_levels: []const u32,
    max_def_level: u8,
    max_rep_level: u8,
) PageWriteError!DataPageResult {
    const encoded_values = try encodeInt96Values(allocator, values);
    defer allocator.free(encoded_values);

    var rep_level_data: ?[]u8 = null;
    if (max_rep_level > 0) {
        rep_level_data = try rle_encoder.encodeLevelsWithLength(allocator, rep_levels, max_rep_level);
    }
    defer if (rep_level_data) |d| allocator.free(d);

    var def_level_data: ?[]u8 = null;
    if (max_def_level > 0) {
        def_level_data = try rle_encoder.encodeLevelsWithLength(allocator, def_levels, max_def_level);
    }
    defer if (def_level_data) |d| allocator.free(d);

    const rep_size = if (rep_level_data) |d| d.len else 0;
    const def_size = if (def_level_data) |d| d.len else 0;
    const total_size = rep_size + def_size + encoded_values.len;
    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    if (rep_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    if (def_level_data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    @memcpy(result[offset..][0..encoded_values.len], encoded_values);

    return .{
        .data = result,
        .num_values = def_levels.len,
        .num_non_null = values.len,
    };
}

/// Write a byte array data page with Optional values and a specific encoding.
/// Unified function for byte arrays (Phase 11 style).
/// Definition levels are written based on is_optional (schema), not data content.
pub fn writeDataPageByteArrayOptionalWithEncoding(
    allocator: std.mem.Allocator,
    values: []const Optional([]const u8),
    is_optional: bool,
    encoding: format.Encoding,
) PageWriteError!DataPageResult {
    if (encoding == .plain) return writePlainByteArrayPageOptional(allocator, values, is_optional);

    var non_null_values: std.ArrayList([]const u8) = .empty;
    defer non_null_values.deinit(allocator);

    var is_defined: std.ArrayList(bool) = .empty;
    defer is_defined.deinit(allocator);

    for (values) |v| {
        const defined = v != .null_value;
        try is_defined.append(allocator, defined);
        if (defined) {
            try non_null_values.append(allocator, v.value);
        }
    }

    if (!is_optional and non_null_values.items.len != values.len) return error.NullInRequiredColumn;

    // Encode the non-null values with specified encoding
    const encoded_values = try encodeByteArraysWithEncoding(allocator, non_null_values.items, encoding);
    defer allocator.free(encoded_values);

    if (!is_optional) {
        const result = try allocator.dupe(u8, encoded_values);
        return .{
            .data = result,
            .num_values = values.len,
            .num_non_null = values.len,
        };
    }
    return combineDefLevelsAndValues(allocator, is_defined.items, encoded_values, values.len);
}

// =============================================================================
// PLAIN fast paths: the whole page is built in one buffer
// =============================================================================

/// PLAIN page built in one buffer: [u32 len + def levels] (optional only), then
/// the non-null values. Byte-identical to the general path.
fn writePlainPageOptional(allocator: std.mem.Allocator, comptime T: type, values: []const Optional(T), is_optional: bool) PageWriteError!DataPageResult {
    var non_null: usize = 0;
    for (values) |v| {
        if (v != .null_value) non_null += 1;
    }
    if (!is_optional and non_null != values.len) return error.NullInRequiredColumn;

    const value_bytes = if (T == bool) (non_null + 7) / 8 else std.math.mul(usize, non_null, @sizeOf(T)) catch return error.IntegerOverflow;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, value_bytes + values.len / 4 + 16);
    if (is_optional) try rle_encoder.appendDefLevelsWithLength(T, &out, allocator, values);

    const start = out.items.len;
    try out.appendNTimes(allocator, 0, value_bytes); // zeroed: bool packing ORs bits in
    const dst = out.items[start..];
    var k: usize = 0;
    for (values) |v| switch (v) {
        .null_value => {},
        .value => |x| {
            if (T == bool) {
                if (x) dst[k / 8] |= @as(u8, 1) << @as(u3, @truncate(k)); // k % 8 fits u3 (LSB-first bit order)
            } else {
                const Bits = if (@sizeOf(T) == 4) u32 else u64;
                std.mem.writeInt(Bits, dst[k * @sizeOf(T) ..][0..@sizeOf(T)], @bitCast(x), .little);
            }
            k += 1;
        },
    };
    return .{ .data = try out.toOwnedSlice(allocator), .num_values = values.len, .num_non_null = non_null };
}

/// PLAIN byte-array page built in one buffer: [u32 len + def levels] (optional
/// only), then `u32 LE len + bytes` per non-null value. Byte-identical to the
/// general path, including its error order (NullInRequiredColumn before ValueTooLarge).
fn writePlainByteArrayPageOptional(allocator: std.mem.Allocator, values: []const Optional([]const u8), is_optional: bool) PageWriteError!DataPageResult {
    var non_null: usize = 0;
    var payload: usize = 0;
    var too_large = false;
    for (values) |v| switch (v) {
        .null_value => {},
        .value => |s| {
            non_null += 1;
            if (s.len > std.math.maxInt(i32)) too_large = true;
            const entry = std.math.add(usize, 4, s.len) catch return error.OutOfMemory;
            payload = std.math.add(usize, payload, entry) catch return error.OutOfMemory;
        },
    };
    if (!is_optional and non_null != values.len) return error.NullInRequiredColumn;
    if (too_large) return error.ValueTooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, payload + values.len / 4 + 16);
    if (is_optional) try rle_encoder.appendDefLevelsWithLength([]const u8, &out, allocator, values);

    for (values) |v| switch (v) {
        .null_value => {},
        .value => |s| {
            // Lengths were checked against maxInt(i32) in the count pass, so the u32 cast cannot fail.
            const len32 = safe.castTo(u32, s.len) catch unreachable; // checked against maxInt(i32) above
            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_bytes, len32, .little);
            try out.appendSlice(allocator, &len_bytes);
            try out.appendSlice(allocator, s);
        },
    };
    return .{ .data = try out.toOwnedSlice(allocator), .num_values = values.len, .num_non_null = non_null };
}

fn testSampleValue(comptime T: type, i: usize) T {
    return switch (T) {
        i64 => @as(i64, @intCast(i)) * 1000003 - 17,
        f32 => @as(f32, @floatFromInt(i)) * 0.25 - 3.0,
        bool => i % 3 == 1,
        else => @compileError("no test sample for " ++ @typeName(T)),
    };
}

test "PLAIN fixed-width optional page is byte-identical to the general path" {
    const allocator = std.testing.allocator;
    const sizes = [_]usize{ 0, 1, 7, 8, 9, 100, 1000 };
    const null_pcts = [_]u32{ 0, 5, 33, 100 };
    var prng = std.Random.DefaultPrng.init(0x3303);
    const random = prng.random();

    inline for (.{ i64, f32, bool }) |T| {
        for (sizes) |n| {
            for (null_pcts) |pct| {
                for ([_]bool{ true, false }) |is_optional| {
                    if (!is_optional and pct != 0) continue; // required columns cannot hold nulls

                    const vals = try allocator.alloc(Optional(T), n);
                    defer allocator.free(vals);
                    const is_def = try allocator.alloc(bool, n);
                    defer allocator.free(is_def);
                    var non_null: std.ArrayList(T) = .empty;
                    defer non_null.deinit(allocator);
                    for (vals, is_def, 0..) |*v, *d, i| {
                        const is_null = random.uintLessThan(u32, 100) < pct;
                        d.* = !is_null;
                        v.* = if (is_null) .null_value else .{ .value = testSampleValue(T, i) };
                        if (!is_null) try non_null.append(allocator, testSampleValue(T, i));
                    }

                    var want = try writeDataPageTypedWithEncoding(allocator, T, non_null.items, is_def, is_optional, .plain);
                    defer want.deinit(allocator);
                    var got = try writeDataPageOptionalWithEncoding(allocator, T, vals, is_optional, .plain);
                    defer got.deinit(allocator);

                    try std.testing.expectEqualSlices(u8, want.data, got.data);
                    try std.testing.expectEqual(want.num_values, got.num_values);
                    try std.testing.expectEqual(want.num_non_null, got.num_non_null);
                }
            }
        }
    }
}

test "PLAIN optional page: null in a required column is an error" {
    const allocator = std.testing.allocator;
    const vals = [_]Optional(i64){ .{ .value = 1 }, .null_value };
    try std.testing.expectError(error.NullInRequiredColumn, writeDataPageOptionalWithEncoding(allocator, i64, &vals, false, .plain));
}

test "PLAIN byte-array optional page is byte-identical to the general path" {
    const allocator = std.testing.allocator;
    const sizes = [_]usize{ 0, 1, 7, 8, 9, 100, 1000 };
    const null_pcts = [_]u32{ 0, 5, 33, 100 };
    var prng = std.Random.DefaultPrng.init(0x3304);
    const random = prng.random();

    for (sizes) |n| {
        for (null_pcts) |pct| {
            for ([_]bool{ true, false }) |is_optional| {
                if (!is_optional and pct != 0) continue;

                // Owned byte strings of varying length (including empty), as a flat list.
                const bufs = try allocator.alloc([]u8, n);
                defer allocator.free(bufs);
                var made: usize = 0;
                defer for (bufs[0..made]) |b| allocator.free(b);
                for (bufs, 0..) |*b, i| {
                    b.* = try allocator.alloc(u8, i % 7);
                    @memset(b.*, @as(u8, @intCast('a' + i % 26)));
                    made += 1;
                }

                const vals = try allocator.alloc(Optional([]const u8), n);
                defer allocator.free(vals);
                const is_def = try allocator.alloc(bool, n);
                defer allocator.free(is_def);
                var non_null: std.ArrayList([]const u8) = .empty;
                defer non_null.deinit(allocator);
                for (vals, is_def, bufs) |*v, *d, b| {
                    const is_null = random.uintLessThan(u32, 100) < pct;
                    d.* = !is_null;
                    v.* = if (is_null) .null_value else .{ .value = b };
                    if (!is_null) try non_null.append(allocator, b);
                }

                // General path: encode the non-null values, then add levels.
                const enc = try encodeByteArraysWithEncoding(allocator, non_null.items, .plain);
                defer allocator.free(enc);
                const want_data: []u8 = if (is_optional) blk: {
                    const combined = try combineDefLevelsAndValues(allocator, is_def, enc, n);
                    break :blk combined.data;
                } else try allocator.dupe(u8, enc);
                defer allocator.free(want_data);

                var got = try writeDataPageByteArrayOptionalWithEncoding(allocator, vals, is_optional, .plain);
                defer got.deinit(allocator);

                try std.testing.expectEqualSlices(u8, want_data, got.data);
                try std.testing.expectEqual(n, got.num_values);
                try std.testing.expectEqual(non_null.items.len, got.num_non_null);
            }
        }
    }
}

test "PLAIN byte-array optional page: NullInRequiredColumn is reported before ValueTooLarge" {
    const allocator = std.testing.allocator;
    // Fake slice: only its length is read before the error is returned, never its bytes.
    const huge_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0..huge_len];

    const null_then_huge = [_]Optional([]const u8){ .null_value, .{ .value = huge } };
    try std.testing.expectError(error.NullInRequiredColumn, writeDataPageByteArrayOptionalWithEncoding(allocator, &null_then_huge, false, .plain));

    const huge_only = [_]Optional([]const u8){.{ .value = huge }};
    try std.testing.expectError(error.ValueTooLarge, writeDataPageByteArrayOptionalWithEncoding(allocator, &huge_only, true, .plain));
}
