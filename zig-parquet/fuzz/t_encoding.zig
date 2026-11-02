//! Fuzz target `encoding`: encoder -> decoder round trips (mode 0) and raw bytes into each decoder (mode 1).
const std = @import("std");
const parquet = @import("parquet");
const common = @import("common.zig");

const enc = parquet.internals.encoding;

const max_values = 2048;
const max_str_len = 32;
const max_raw_values = 4096;

const Mode = enum(u64) { round_trip = 0, raw = 1 };
const Kind = enum(u64) { rle = 0, dbp32, dbp64, dlba, dba, bss, plain };

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    var in: common.Input = .{ .bytes = bytes };
    if (in.below(2) == 0) {
        fb.detail = @intFromEnum(Mode.round_trip) << 8;
        roundTrip(gpa, &in, fb);
    } else {
        fb.detail = @intFromEnum(Mode.raw) << 8;
        raw(gpa, &in, fb);
    }
}

/// Mode 0: encode generated values, decode the output, compare. Any mismatch or error is a finding.
fn roundTrip(gpa: std.mem.Allocator, in: *common.Input, fb: *common.Feedback) void {
    const kind: Kind = @enumFromInt(in.below(7));
    const n = in.below(max_values + 1);
    fb.rows = n;
    fb.detail |= @intFromEnum(kind);
    switch (kind) {
        .rle => {
            const bw: u5 = @truncate(in.below(32)); // below(32) < 32
            const vals = genLevels(gpa, in, n, bw) catch return;
            defer gpa.free(vals);
            const name = "rle";
            const bytes = enc.rle_encoder.encode(gpa, vals, bw) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            const got = enc.rle.decode(gpa, bytes, bw, n) catch |e| fail(name, "decoder", e);
            defer gpa.free(got);
            if (!std.mem.eql(u32, got, vals)) mismatch(name);
        },
        .dbp32 => {
            const vals = genInts(i32, u32, gpa, in, n) catch return;
            defer gpa.free(vals);
            const name = "delta_binary_packed_i32";
            const bytes = enc.delta_binary_packed_encoder.encodeInt32(gpa, vals) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            const got = enc.delta_binary_packed.decodeInt32(gpa, bytes) catch |e| fail(name, "decoder", e);
            defer gpa.free(got);
            if (!std.mem.eql(i32, got, vals)) mismatch(name);
        },
        .dbp64 => {
            const vals = genInts(i64, u64, gpa, in, n) catch return;
            defer gpa.free(vals);
            const name = "delta_binary_packed_i64";
            const bytes = enc.delta_binary_packed_encoder.encodeInt64(gpa, vals) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            const got = enc.delta_binary_packed.decodeInt64(gpa, bytes) catch |e| fail(name, "decoder", e);
            defer gpa.free(got);
            if (!std.mem.eql(i64, got, vals)) mismatch(name);
        },
        .dlba => {
            const strs = genStrings(gpa, in, n) catch return;
            defer strs.deinit(gpa);
            const name = "delta_length_byte_array";
            const bytes = enc.delta_length_byte_array_encoder.encode(gpa, strs.items) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            var got = enc.delta_length_byte_array.decode(gpa, bytes) catch |e| fail(name, "decoder", e);
            defer got.deinit();
            if (!sameStrings(got.values, strs.items)) mismatch(name);
        },
        .dba => {
            const strs = genStrings(gpa, in, n) catch return;
            defer strs.deinit(gpa);
            const name = "delta_byte_array";
            const bytes = enc.delta_byte_array_encoder.encode(gpa, strs.items) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            var got = enc.delta_byte_array.decode(gpa, bytes) catch |e| fail(name, "decoder", e);
            defer got.deinit();
            if (!sameStrings(got.values, strs.items)) mismatch(name);
        },
        .bss => {
            // One input bit picks f32 or f64; values are raw bit patterns (NaN payloads, -0.0 included).
            if (in.byte() & 1 == 0) {
                const vals = gpa.alloc(f32, n) catch return;
                defer gpa.free(vals);
                for (vals) |*v| v.* = @bitCast(in.int(u32));
                const name = "byte_stream_split_f32";
                const bytes = enc.byte_stream_split_encoder.encodeFloat32(gpa, vals) catch |e| fail(name, "encoder", e);
                defer gpa.free(bytes);
                const got = enc.byte_stream_split.decodeFloat32Alloc(gpa, bytes, n) catch |e| fail(name, "decoder", e);
                defer gpa.free(got);
                if (!sameBits(f32, got, vals)) mismatch(name);
            } else {
                const vals = gpa.alloc(f64, n) catch return;
                defer gpa.free(vals);
                for (vals) |*v| v.* = @bitCast(in.int(u64));
                const name = "byte_stream_split_f64";
                const bytes = enc.byte_stream_split_encoder.encodeFloat64(gpa, vals) catch |e| fail(name, "encoder", e);
                defer gpa.free(bytes);
                const got = enc.byte_stream_split.decodeFloat64Alloc(gpa, bytes, n) catch |e| fail(name, "decoder", e);
                defer gpa.free(got);
                if (!sameBits(f64, got, vals)) mismatch(name);
            }
        },
        .plain => {
            const strs = genStrings(gpa, in, n) catch return;
            defer strs.deinit(gpa);
            const name = "plain_byte_array";
            const bytes = enc.plain_encoder.encodeByteArrays(gpa, strs.items) catch |e| fail(name, "encoder", e);
            defer gpa.free(bytes);
            var dec = enc.plain.PlainDecoder([]const u8).init(bytes, n);
            for (strs.items) |want| {
                const got = dec.next() orelse mismatch(name);
                if (!std.mem.eql(u8, got, want)) mismatch(name);
            }
            if (dec.next() != null) mismatch(name);
        },
    }
}

/// Mode 1: raw input bytes into every decoder. Errors are passes; a panic or leak is the finding.
/// `detail` bit i is set when decoder i succeeded, so new decoder paths grow the corpus.
fn raw(gpa: std.mem.Allocator, in: *common.Input, fb: *common.Feedback) void {
    const bw: u5 = @truncate(in.below(32)); // below(32) < 32
    const n = in.below(max_raw_values + 1);
    const data = in.rest();
    fb.rows = n;

    if (enc.rle.decode(gpa, data, bw, n)) |v| {
        gpa.free(v);
        fb.detail |= 1 << 0;
    } else |e| fb.err = e;

    if (enc.delta_binary_packed.decodeInt32(gpa, data)) |v| {
        gpa.free(v);
        fb.detail |= 1 << 1;
    } else |e| fb.err = e;

    if (enc.delta_binary_packed.decodeInt64(gpa, data)) |v| {
        gpa.free(v);
        fb.detail |= 1 << 2;
    } else |e| fb.err = e;

    if (enc.delta_length_byte_array.decode(gpa, data)) |r| {
        var res = r;
        res.deinit();
        fb.detail |= 1 << 3;
    } else |e| fb.err = e;

    if (enc.delta_byte_array.decode(gpa, data)) |r| {
        var res = r;
        res.deinit();
        fb.detail |= 1 << 4;
    } else |e| fb.err = e;

    if (enc.byte_stream_split.decodeFloat32Alloc(gpa, data, n)) |v| {
        gpa.free(v);
        fb.detail |= 1 << 5;
    } else |e| fb.err = e;

    if (enc.byte_stream_split.decodeFloat64Alloc(gpa, data, n)) |v| {
        gpa.free(v);
        fb.detail |= 1 << 6;
    } else |e| fb.err = e;
}

// ---------------------------------------------------------------------------------------------
// Generators. Values come only from `in`; exhausted input yields zeros.

/// RLE levels of `bw` bits. Repeats the previous value often so RLE runs and bit-packed groups both occur.
fn genLevels(gpa: std.mem.Allocator, in: *common.Input, n: usize, bw: u5) ![]u32 {
    const mask: u32 = (@as(u32, 1) << bw) -% 1;
    const out = try gpa.alloc(u32, n);
    var prev: u32 = 0;
    for (out, 0..) |*v, i| {
        v.* = if (i > 0 and in.byte() < 160) prev else in.int(u32) & mask;
        prev = v.*;
    }
    return out;
}

/// Delta-friendly integers: a random start, then steps of random magnitude (wrapping, so the full
/// range of T is reachable). Occasional restarts give new blocks and new min-deltas.
fn genInts(comptime T: type, comptime U: type, gpa: std.mem.Allocator, in: *common.Input, n: usize) ![]T {
    const out = try gpa.alloc(T, n);
    var prev: T = 0;
    for (out, 0..) |*v, i| {
        if (i == 0 or in.byte() < 16) {
            v.* = in.int(T);
        } else {
            const sh: std.math.Log2Int(U) = @truncate(in.below(@bitSizeOf(U))); // below(bits) < bits
            var d: T = @bitCast(in.int(U) >> sh);
            if (in.byte() & 1 == 1) d = 0 -% d;
            v.* = prev +% d;
        }
        prev = v.*;
    }
    return out;
}

/// Byte arrays of 0..32 bytes, taken from `in`. All values share one backing buffer.
const Strings = struct {
    items: [][]const u8,
    backing: []u8,

    fn deinit(s: Strings, gpa: std.mem.Allocator) void {
        gpa.free(s.items);
        gpa.free(s.backing);
    }
};

fn genStrings(gpa: std.mem.Allocator, in: *common.Input, n: usize) !Strings {
    const backing = try gpa.alloc(u8, n * max_str_len);
    errdefer gpa.free(backing);
    const items = try gpa.alloc([]const u8, n);
    errdefer gpa.free(items);
    var off: usize = 0;
    for (items) |*s| {
        const len = in.below(max_str_len + 1);
        for (backing[off..][0..len]) |*b| b.* = in.byte();
        s.* = backing[off..][0..len];
        off += len;
    }
    return .{ .items = items, .backing = backing };
}

// ---------------------------------------------------------------------------------------------
// Comparison and failure helpers.

fn sameStrings(got: []const []const u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (got, want) |g, w| if (!std.mem.eql(u8, g, w)) return false;
    return true;
}

/// Compares float slices by bit pattern (NaN payloads and -0.0 must survive exactly).
fn sameBits(comptime F: type, got: []const F, want: []const F) bool {
    if (got.len != want.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(got), std.mem.sliceAsBytes(want));
}

fn mismatch(name: []const u8) noreturn {
    std.debug.panic("fuzz-mismatch: encoding {s} (values differ)", .{name});
}

fn fail(name: []const u8, stage: []const u8, err: anyerror) noreturn {
    std.debug.panic("fuzz-mismatch: encoding {s} ({s} error: {s})", .{ name, stage, @errorName(err) });
}
