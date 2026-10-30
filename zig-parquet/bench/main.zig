//! zig-parquet benchmark harness.
//!
//! Usage: zig build bench -Dcodecs=zig-only -Doptimize=ReleaseFast -- [rows]
//!
//! For each scenario: generates data (untimed), writes a Parquet file (timed),
//! reads all rows back with DynamicReader (timed). Each phase runs 3 times and
//! the best time is reported.

const std = @import("std");
const parquet = @import("parquet");

const Allocator = std.mem.Allocator;

const runs = 3;
const default_rows: usize = 1_000_000;
const bench_dir = ".zig-cache/bench";

/// Pre-generated column data for one scenario. Built outside the timed region.
const Data = struct {
    i32s: []i32 = &.{},
    i64s: []i64 = &.{},
    i64_opt: []parquet.Optional(i64) = &.{},
    f64s: []f64 = &.{},
    f64_opt: []parquet.Optional(f64) = &.{},
    bools: []bool = &.{},
    strs: [][]const u8 = &.{},
};

const Scenario = struct {
    name: []const u8,
    build: *const fn (Allocator, usize) anyerror!Data,
    write: *const fn (Allocator, std.Io, []const u8, *const Data) anyerror!void,
};

const scenarios = [_]Scenario{
    .{ .name = "int64_plain", .build = buildInt64Plain, .write = writeInt64Plain },
    .{ .name = "f64_plain", .build = buildF64Plain, .write = writeF64Plain },
    .{ .name = "int64_nullable", .build = buildInt64Nullable, .write = writeInt64Nullable },
    .{ .name = "str_dict", .build = buildStrDict, .write = writeStrings },
    .{ .name = "str_unique", .build = buildStrUnique, .write = writeStrings },
    .{ .name = "mixed5", .build = buildMixed5, .write = writeMixed5 },
};

// ---------------------------------------------------------------------------
// Data generation (untimed)
// ---------------------------------------------------------------------------

fn buildInt64Plain(arena: Allocator, n: usize) anyerror!Data {
    const v = try arena.alloc(parquet.Optional(i64), n);
    var c: i64 = 0;
    for (v) |*x| {
        x.* = .{ .value = c };
        c += 1;
    }
    return .{ .i64_opt = v };
}

fn buildF64Plain(arena: Allocator, n: usize) anyerror!Data {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const v = try arena.alloc(parquet.Optional(f64), n);
    for (v) |*x| x.* = .{ .value = rand.float(f64) };
    return .{ .f64_opt = v };
}

fn buildInt64Nullable(arena: Allocator, n: usize) anyerror!Data {
    const v = try arena.alloc(parquet.Optional(i64), n);
    var c: i64 = 0;
    for (v, 0..) |*x, i| {
        if (i % 3 == 2) {
            x.* = .{ .null_value = {} };
        } else {
            x.* = .{ .value = c };
            c += 1;
        }
    }
    return .{ .i64_opt = v };
}

fn buildStrDict(arena: Allocator, n: usize) anyerror!Data {
    var dict: [100][]const u8 = undefined;
    for (&dict, 0..) |*d, i| d.* = try std.fmt.allocPrint(arena, "dictval-{d:0>5}", .{i});
    const strs = try arena.alloc([]const u8, n);
    for (strs, 0..) |*s, i| s.* = dict[i % 100];
    return .{ .strs = strs };
}

fn buildStrUnique(arena: Allocator, n: usize) anyerror!Data {
    const strs = try arena.alloc([]const u8, n);
    for (strs, 0..) |*s, i| s.* = try std.fmt.allocPrint(arena, "row-{d}", .{i});
    return .{ .strs = strs };
}

fn buildMixed5(arena: Allocator, n: usize) anyerror!Data {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var dict: [1000][]const u8 = undefined;
    for (&dict, 0..) |*d, i| d.* = try std.fmt.allocPrint(arena, "category-{d:0>4}", .{i});

    const i32s = try arena.alloc(i32, n);
    const i64s = try arena.alloc(i64, n);
    const f64s = try arena.alloc(f64, n);
    const bools = try arena.alloc(bool, n);
    const strs = try arena.alloc([]const u8, n);
    for (0..n) |i| {
        i32s[i] = rand.int(i32);
        i64s[i] = rand.int(i64);
        f64s[i] = rand.float(f64);
        bools[i] = rand.boolean();
        strs[i] = dict[rand.intRangeLessThan(usize, 0, 1000)];
    }
    return .{ .i32s = i32s, .i64s = i64s, .f64s = f64s, .bools = bools, .strs = strs };
}

// ---------------------------------------------------------------------------
// Writers (timed)
// ---------------------------------------------------------------------------

fn writeStatic(comptime T: type, a: Allocator, io: std.Io, path: []const u8, cols: []const parquet.ColumnDef, values: []const parquet.Optional(T)) anyerror!void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = try parquet.writeToFile(a, file, io, cols);
    defer writer.deinit();
    try writer.writeColumnOptional(T, 0, values);
    try writer.close();
}

fn writeInt64Plain(a: Allocator, io: std.Io, path: []const u8, d: *const Data) anyerror!void {
    try writeStatic(i64, a, io, path, &.{.{ .name = "v", .type_ = .int64, .optional = false }}, d.i64_opt);
}

fn writeF64Plain(a: Allocator, io: std.Io, path: []const u8, d: *const Data) anyerror!void {
    try writeStatic(f64, a, io, path, &.{.{ .name = "v", .type_ = .double, .optional = false }}, d.f64_opt);
}

fn writeInt64Nullable(a: Allocator, io: std.Io, path: []const u8, d: *const Data) anyerror!void {
    try writeStatic(i64, a, io, path, &.{.{ .name = "v", .type_ = .int64, .optional = true }}, d.i64_opt);
}

fn writeStrings(a: Allocator, io: std.Io, path: []const u8, d: *const Data) anyerror!void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = try parquet.createFileDynamic(a, file, io);
    defer writer.deinit();
    try writer.addColumn("s", parquet.TypeInfo.string, .{});
    try writer.begin();
    for (d.strs) |s| {
        try writer.setBytes(0, s);
        try writer.addRow();
    }
    try writer.close();
}

fn writeMixed5(a: Allocator, io: std.Io, path: []const u8, d: *const Data) anyerror!void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = try parquet.createFileDynamic(a, file, io);
    defer writer.deinit();
    try writer.addColumn("i32", parquet.TypeInfo.int32, .{});
    try writer.addColumn("i64", parquet.TypeInfo.int64, .{});
    try writer.addColumn("f64", parquet.TypeInfo.double_, .{});
    try writer.addColumn("flag", parquet.TypeInfo.bool_, .{});
    try writer.addColumn("name", parquet.TypeInfo.string, .{});
    try writer.begin();
    for (0..d.i32s.len) |i| {
        try writer.setInt32(0, d.i32s[i]);
        try writer.setInt64(1, d.i64s[i]);
        try writer.setDouble(2, d.f64s[i]);
        try writer.setBool(3, d.bools[i]);
        try writer.setBytes(4, d.strs[i]);
        try writer.addRow();
    }
    try writer.close();
}

// ---------------------------------------------------------------------------
// Reader (timed) and harness
// ---------------------------------------------------------------------------

fn readAll(a: Allocator, io: std.Io, path: []const u8) anyerror!usize {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = try parquet.openFileDynamic(a, file, io, .{});
    defer reader.deinit();
    var it = reader.rowIterator();
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |row| {
        std.mem.doNotOptimizeAway(row.values.len);
        n += 1;
    }
    return n;
}

fn fileSize(io: std.Io, path: []const u8) anyerror!u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    return st.size;
}

fn rowsPerSec(rows: usize, ns: i96) f64 {
    return @as(f64, @floatFromInt(rows)) * 1e9 / @as(f64, @floatFromInt(ns));
}

fn runScenario(gpa: Allocator, io: std.Io, out: *std.Io.Writer, sc: Scenario, rows: usize) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const data = try sc.build(arena.allocator(), rows);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.parquet", .{ bench_dir, sc.name });

    var best_write: i96 = std.math.maxInt(i96);
    var best_read: i96 = std.math.maxInt(i96);
    var read_rows: usize = 0;
    for (0..runs) |_| {
        const w0 = std.Io.Timestamp.now(io, .awake);
        try sc.write(gpa, io, path, &data);
        best_write = @min(best_write, w0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);

        const r0 = std.Io.Timestamp.now(io, .awake);
        read_rows = try readAll(gpa, io, path);
        best_read = @min(best_read, r0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
    }
    if (read_rows != rows) return error.RowCountMismatch;

    const size = try fileSize(io, path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
    try out.print("{s:<14} {d:>9} {d:>10.2} {d:>14.0} {d:>10.2} {d:>14.0} {d:>9.2}\n", .{
        sc.name,
        rows,
        @as(f64, @floatFromInt(best_write)) / 1e6,
        rowsPerSec(rows, best_write),
        @as(f64, @floatFromInt(best_read)) / 1e6,
        rowsPerSec(rows, best_read),
        mb,
    });
    try out.flush();
}

pub fn main(init: std.process.Init) anyerror!void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rows: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else default_rows;

    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout_writer.interface;

    try out.print("scenario        rows    write_ms  write_rows_per_s    read_ms  read_rows_per_s   file_MB\n", .{});
    try out.flush();

    try std.Io.Dir.cwd().createDirPath(io, bench_dir);

    for (scenarios) |sc| try runScenario(gpa, io, out, sc, rows);
}
