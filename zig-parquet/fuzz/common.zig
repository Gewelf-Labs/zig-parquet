//! Shared fuzz helpers.
const std = @import("std");
const parquet = @import("parquet");

/// Fuzz decisions read from the input. Exhausted input yields zeros, so a shorter
/// input is always a smaller case: truncating is our shrinker.
pub const Input = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn byte(in: *Input) u8 {
        if (in.pos >= in.bytes.len) return 0;
        defer in.pos += 1;
        return in.bytes[in.pos];
    }
    /// In [0, n); 0 when n == 0.
    pub fn below(in: *Input, n: usize) usize {
        if (n == 0) return 0;
        return (@as(usize, in.byte()) | @as(usize, in.byte()) << 8) % n;
    }
    /// Little-endian, zero-padded past the end.
    pub fn int(in: *Input, comptime T: type) T {
        var buf: [@sizeOf(T)]u8 = @splat(0);
        for (&buf) |*b| b.* = in.byte();
        return std.mem.readInt(T, &buf, .little);
    }
    pub fn rest(in: *Input) []const u8 {
        const r = in.bytes[@min(in.pos, in.bytes.len)..];
        in.pos = in.bytes.len;
        return r;
    }
};

/// What one execution looked like; a new `sig` grows the run loop's corpus.
pub const Feedback = struct {
    err: ?anyerror = null,
    rows: u64 = 0,
    detail: u64 = 0, // target-specific bits (encodings seen, reader modes that succeeded, ...)

    pub fn sig(f: Feedback) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (f.err) |e| @errorName(e) else "ok");
        h.update(std.mem.asBytes(&@min(f.rows, 8)));
        h.update(std.mem.asBytes(&f.detail));
        return h.final();
    }
};

/// Deep equality of two decoded values. Floats compare by bit pattern (so -0.0 != 0.0), except
/// that any NaN equals any NaN. Lists and maps compare entry by entry in order; struct fields
/// compare in order with names checked.
pub fn valuesEqual(a: parquet.Value, b: parquet.Value) bool {
    return switch (a) {
        .null_val => b == .null_val,
        .bool_val => |x| b == .bool_val and b.bool_val == x,
        .int32_val => |x| b == .int32_val and b.int32_val == x,
        .int64_val => |x| b == .int64_val and b.int64_val == x,
        .float_val => |x| b == .float_val and floatEq(x, b.float_val),
        .double_val => |x| b == .double_val and floatEq(x, b.double_val),
        .bytes_val => |x| b == .bytes_val and std.mem.eql(u8, x, b.bytes_val),
        .fixed_bytes_val => |x| b == .fixed_bytes_val and std.mem.eql(u8, x, b.fixed_bytes_val),
        .list_val => |xs| b == .list_val and valueSlicesEqual(xs, b.list_val),
        .map_val => |xs| b == .map_val and mapEntriesEqual(xs, b.map_val),
        .struct_val => |xs| b == .struct_val and fieldsEqual(xs, b.struct_val),
    };
}

// f32 is widened to f64 first: widening keeps sign and NaN-ness and is injective on non-NaN bits.
fn floatEq(x: anytype, y: anytype) bool {
    const xw: f64 = x;
    const yw: f64 = y;
    if (std.math.isNan(xw) or std.math.isNan(yw)) return std.math.isNan(xw) and std.math.isNan(yw);
    return @as(u64, @bitCast(xw)) == @as(u64, @bitCast(yw));
}

fn valueSlicesEqual(xs: []const parquet.Value, ys: []const parquet.Value) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| if (!valuesEqual(x, y)) return false;
    return true;
}

fn mapEntriesEqual(xs: []const parquet.Value.MapEntryValue, ys: []const parquet.Value.MapEntryValue) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| {
        if (!valuesEqual(x.key, y.key) or !valuesEqual(x.value, y.value)) return false;
    }
    return true;
}

fn fieldsEqual(xs: []const parquet.Value.FieldValue, ys: []const parquet.Value.FieldValue) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !valuesEqual(x.value, y.value)) return false;
    }
    return true;
}

/// Frees rows from `readAllRows` / `readRowsProjected` (the pattern from roundtrip_test.zig).
pub fn freeRows(gpa: std.mem.Allocator, rows: []parquet.Row) void {
    for (rows) |row| row.deinit();
    gpa.free(rows);
}

test "valuesEqual: floats, nesting, names, map order" {
    const V = parquet.Value;
    const nan_a = V{ .double_val = std.math.nan(f64) };
    const nan_b = V{ .double_val = @bitCast(@as(u64, 0xfff8000000000001)) };
    try std.testing.expect(valuesEqual(nan_a, nan_b));
    try std.testing.expect(valuesEqual(.{ .float_val = std.math.nan(f32) }, .{ .float_val = -std.math.nan(f32) }));
    // -0.0 and 0.0 differ by bit pattern.
    try std.testing.expect(!valuesEqual(.{ .double_val = -0.0 }, .{ .double_val = 0.0 }));
    try std.testing.expect(!valuesEqual(.{ .float_val = -0.0 }, .{ .float_val = 0.0 }));
    try std.testing.expect(valuesEqual(.{ .double_val = 1.5 }, .{ .double_val = 1.5 }));

    // Nested list vs struct with the same payload: different variants.
    const list = V{ .list_val = &.{V{ .int32_val = 1 }} };
    const strct = V{ .struct_val = &.{.{ .name = "a", .value = V{ .int32_val = 1 } }} };
    try std.testing.expect(valuesEqual(list, list));
    try std.testing.expect(!valuesEqual(list, strct));
    try std.testing.expect(!valuesEqual(V{ .int32_val = 1 }, V{ .int64_val = 1 }));

    // Struct field names must match; field order matters.
    const named_b = V{ .struct_val = &.{.{ .name = "b", .value = V{ .int32_val = 1 } }} };
    try std.testing.expect(!valuesEqual(strct, named_b));
    const two = V{ .struct_val = &.{ .{ .name = "x", .value = V{ .null_val = {} } }, .{ .name = "y", .value = V{ .bool_val = true } } } };
    const swapped = V{ .struct_val = &.{ .{ .name = "y", .value = V{ .bool_val = true } }, .{ .name = "x", .value = V{ .null_val = {} } } } };
    try std.testing.expect(!valuesEqual(two, swapped));

    // Map entries compare in order.
    const m1 = V{ .map_val = &.{ .{ .key = V{ .int32_val = 1 }, .value = V{ .bytes_val = "a" } }, .{ .key = V{ .int32_val = 2 }, .value = V{ .bytes_val = "b" } } } };
    const m2 = V{ .map_val = &.{ .{ .key = V{ .int32_val = 2 }, .value = V{ .bytes_val = "b" } }, .{ .key = V{ .int32_val = 1 }, .value = V{ .bytes_val = "a" } } } };
    try std.testing.expect(valuesEqual(m1, m1));
    try std.testing.expect(!valuesEqual(m1, m2));
}
