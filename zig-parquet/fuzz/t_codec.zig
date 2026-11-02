//! Fuzz target `codec`: the five pure-Zig decompressors, and compress -> decompress round trips.
//!
//! Input: mode = below(2), codec = below(5), hint = below(1 << 20), then rest() is the data.
//!   mode 0: decompress(data) with `hint` as the claimed uncompressed size. A rejection is a pass.
//!   mode 1: compress(data), decompress with the true length, compare. Any mismatch, or a
//!           rejection of our own output, is a finding (panic).
const std = @import("std");
const parquet = @import("parquet");
const common = @import("common.zig");

const compress = parquet.internals.compress;
const Codec = parquet.CompressionCodec;

/// Index = the value `Input.below(5)` returns for that codec.
const codecs = [_]Codec{ .snappy, .gzip, .brotli, .lz4_raw, .zstd };

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    var in: common.Input = .{ .bytes = bytes };
    const round_trip = in.below(2) == 1;
    const idx = in.below(codecs.len);
    const codec = codecs[idx];
    const hint = in.below(1 << 20);
    const data = in.rest();
    fb.detail = idx * 2 + @intFromBool(round_trip);

    if (round_trip) {
        const packed_bytes = try compress.compress(gpa, data, codec);
        defer gpa.free(packed_bytes);
        const out = compress.decompress(gpa, packed_bytes, codec, data.len) catch |e|
            std.debug.panic("fuzz-mismatch: codec {s}: decompress rejected our own output: {s}", .{ @tagName(codec), @errorName(e) });
        defer gpa.free(out);
        if (!std.mem.eql(u8, out, data))
            std.debug.panic("fuzz-mismatch: codec {s}: round trip of {d} bytes changed the data", .{ @tagName(codec), data.len });
        fb.rows = out.len;
    } else {
        const out = try compress.decompress(gpa, data, codec, hint);
        defer gpa.free(out);
        fb.rows = out.len;
    }
}

/// The 4 fixed source buffers, one per `gen-<codec>-<n>.bin`.
fn sourceBuffer(n: usize, buf: []u8) []const u8 {
    switch (n) {
        0 => @memset(buf, 0),
        1 => {
            const text = "The quick brown fox jumps over the lazy dog, 0123456789. ";
            for (buf, 0..) |*b, i| b.* = text[(i + i / 7) % text.len];
        },
        2 => {
            var prng = std.Random.DefaultPrng.init(1);
            prng.random().bytes(buf);
        },
        else => {
            const pattern = "pattern";
            for (buf, 0..) |*b, i| b.* = pattern[i % pattern.len];
        },
    }
    return buf;
}

/// `gen-seeds`: writes generated seeds into `dir` (fuzz/corpus/<target>).
/// Each seed is in target format: mode 0, the codec's index, the true length as the hint, then
/// the codec's compressed output of one source buffer.
pub fn genSeeds(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    var src: [16 << 10]u8 = undefined;
    for (codecs, 0..) |codec, idx| {
        for (0..4) |n| {
            // Sizes: 1 KiB for buffers 0-2, 16 KiB for buffer 3.
            const len: usize = if (n == 3) 16 << 10 else 1 << 10;
            const source = sourceBuffer(n, src[0..len]);
            const packed_bytes = try compress.compress(gpa, source, codec);
            defer gpa.free(packed_bytes);

            var seed: std.ArrayList(u8) = .empty;
            defer seed.deinit(gpa);
            // Each prefix field is a u16 LE: below(n) of a value < n is the value itself, and the
            // hint (< 1 << 20) is the value itself too.
            for ([_]u16{ 0, @intCast(idx), @intCast(len) }) |field| {
                try seed.append(gpa, @truncate(field));
                try seed.append(gpa, @truncate(field >> 8));
            }
            try seed.appendSlice(gpa, packed_bytes);

            const path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "gen-{s}-{d}.bin", .{ @tagName(codec), n }) });
            try cwd.writeFile(io, .{ .sub_path = path, .data = seed.items });
        }
    }
}
