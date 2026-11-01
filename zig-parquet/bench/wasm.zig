//! zig-parquet WASM benchmark module (wasm32-freestanding, no codecs).
//!
//! Built by `zig build bench-wasm` (or `make bench-wasm`) and driven by the JS
//! harness in `bench/js/`. Mirrors `bench/main.zig`: the same six scenarios and
//! writers, and the streaming row iterator for reads, but on in-memory buffers.
//!
//! The JS side copies its column data into wasm memory (`zpb_alloc`), calls
//! `zpb_write`, and copies the file bytes out of `zpb_out_ptr()`. For reads it
//! copies the file in, calls `zpb_read`, and sums column 0 from the f64 array at
//! `zpb_col_ptr()`. Those copies are part of the timed region on the JS side.
//!
//! The library's own freestanding API is compiled in too (lib.zig exports it on
//! every wasm build), so the module imports `env.host_read_at`, `env.host_size`,
//! `env.host_write` and `env.host_close`. The benchmark never calls them; the
//! host passes stubs.
//!
//! Scenario inputs (`a`..`f` are pointers into wasm memory, unused ones 0):
//!   0 int64_plain    a = i64[rows]
//!   1 f64_plain      a = f64[rows]
//!   2 int64_nullable a = i64[rows], b = u8[rows] validity (1 = present)
//!   3 str_dict       a = u32 offsets[rows + 1], b = UTF-8 bytes
//!   4 str_unique     same as 3
//!   5 mixed5         a = i32[rows], b = i64[rows], c = f64[rows], d = u8[rows] bools,
//!                    e = u32 offsets[rows + 1], f = UTF-8 bytes

const std = @import("std");
const parquet = @import("parquet");

const gpa = std.heap.wasm_allocator;

var out_buf: []u8 = &.{};
var col_buf: []f64 = &.{};

export fn zpb_alloc(len: u32) usize {
    const mem = gpa.alignedAlloc(u8, .@"8", len) catch return 0;
    return @intFromPtr(mem.ptr);
}

export fn zpb_free(ptr: [*]align(8) u8, len: u32) void {
    gpa.free(ptr[0..len]);
}

export fn zpb_out_ptr() usize {
    return @intFromPtr(out_buf.ptr);
}

export fn zpb_out_free() void {
    gpa.free(out_buf);
    out_buf = &.{};
}

export fn zpb_col_ptr() usize {
    return @intFromPtr(col_buf.ptr);
}

export fn zpb_col_free() void {
    gpa.free(col_buf);
    col_buf = &.{};
}

export fn zpb_write(scenario: u32, rows: u32, a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) i32 {
    zpb_out_free();
    out_buf = write(scenario, rows, .{ a, b, c, d, e, f }) catch return -1;
    return std.math.cast(i32, out_buf.len) orelse -1;
}

export fn zpb_read(ptr: [*]const u8, len: u32) i32 {
    zpb_col_free();
    const n = read(ptr[0..len]) catch return -1;
    return std.math.cast(i32, n) orelse -1;
}

fn slice(comptime T: type, addr: usize, n: usize) []const T {
    const p: [*]const T = @ptrFromInt(addr);
    return p[0..n];
}

fn bytesAt(offsets: []const u32, data: [*]const u8, i: usize) []const u8 {
    return data[offsets[i]..offsets[i + 1]];
}

fn write(scenario: u32, rows: usize, p: [6]usize) ![]u8 {
    switch (scenario) {
        0 => return writeStatic(i64, .int64, false, slice(i64, p[0], rows), null),
        1 => return writeStatic(f64, .double, false, slice(f64, p[0], rows), null),
        2 => return writeStatic(i64, .int64, true, slice(i64, p[0], rows), slice(u8, p[1], rows)),
        3, 4 => {
            const offsets = slice(u32, p[0], rows + 1);
            const data: [*]const u8 = @ptrFromInt(p[1]);
            var w = try parquet.createBufferDynamic(gpa);
            defer w.deinit();
            try w.addColumn("s", parquet.TypeInfo.string, .{});
            try w.begin();
            for (0..rows) |i| {
                try w.setBytes(0, bytesAt(offsets, data, i));
                try w.addRow();
            }
            try w.close();
            return w.toOwnedSlice();
        },
        5 => {
            const i32s = slice(i32, p[0], rows);
            const i64s = slice(i64, p[1], rows);
            const f64s = slice(f64, p[2], rows);
            const bools = slice(u8, p[3], rows);
            const offsets = slice(u32, p[4], rows + 1);
            const data: [*]const u8 = @ptrFromInt(p[5]);
            var w = try parquet.createBufferDynamic(gpa);
            defer w.deinit();
            try w.addColumn("i32", parquet.TypeInfo.int32, .{});
            try w.addColumn("i64", parquet.TypeInfo.int64, .{});
            try w.addColumn("f64", parquet.TypeInfo.double_, .{});
            try w.addColumn("flag", parquet.TypeInfo.bool_, .{});
            try w.addColumn("name", parquet.TypeInfo.string, .{});
            try w.begin();
            for (0..rows) |i| {
                try w.setInt32(0, i32s[i]);
                try w.setInt64(1, i64s[i]);
                try w.setDouble(2, f64s[i]);
                try w.setBool(3, bools[i] != 0);
                try w.setBytes(4, bytesAt(offsets, data, i));
                try w.addRow();
            }
            try w.close();
            return w.toOwnedSlice();
        },
        else => return error.UnknownScenario,
    }
}

fn writeStatic(comptime T: type, comptime ty: parquet.format.PhysicalType, comptime optional: bool, values: []const T, valid: ?[]const u8) ![]u8 {
    const opt = try gpa.alloc(parquet.Optional(T), values.len);
    defer gpa.free(opt);
    for (opt, values, 0..) |*o, v, i| {
        o.* = if (valid) |m| (if (m[i] != 0) .{ .value = v } else .{ .null_value = {} }) else .{ .value = v };
    }
    var w = try parquet.writeToBuffer(gpa, &.{.{ .name = "v", .type_ = ty, .optional = optional }});
    defer w.deinit();
    try w.writeColumnOptional(T, 0, opt);
    try w.close();
    return w.toOwnedSlice();
}

fn read(bytes: []const u8) !usize {
    var reader = try parquet.openBufferDynamic(gpa, bytes, .{});
    defer reader.deinit();
    const total = std.math.cast(usize, reader.metadata.num_rows) orelse return error.InvalidRowCount;
    col_buf = try gpa.alloc(f64, total);
    var it = reader.rowIteratorStreaming();
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |row| : (n += 1) {
        if (n >= total) return error.InvalidRowCount;
        col_buf[n] = switch (row.values[0]) {
            .int32_val => |x| @floatFromInt(x),
            .int64_val => |x| @floatFromInt(x),
            .double_val => |x| x,
            .bytes_val => |s| @floatFromInt(s.len),
            else => 0,
        };
    }
    if (n != total) return error.InvalidRowCount;
    return n;
}
