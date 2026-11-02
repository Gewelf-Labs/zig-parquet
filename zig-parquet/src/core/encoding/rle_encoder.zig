//! RLE/Bit-Packed Hybrid Encoder
//!
//! This encoding is used for:
//! - Definition levels
//! - Repetition levels
//! - Dictionary indices
//!
//! The encoding uses RLE for runs of repeated values and bit-packing for mixed values.
//! This is the inverse of rle.zig's decode function.
//!
//! Reference: https://parquet.apache.org/docs/file-format/data-pages/encodings/#rle

const std = @import("std");
const safe = @import("../safe.zig");
const Optional = @import("../types.zig").Optional;

/// Encode values using RLE/bit-packed hybrid encoding
/// For simplicity, we primarily use RLE runs since definition levels often repeat.
pub fn encode(allocator: std.mem.Allocator, values: []const u32, bit_width: u5) ![]u8 {
    if (values.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    if (bit_width == 0) {
        // All values must be 0, encode as empty
        return try allocator.alloc(u8, 0);
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var i: usize = 0;
    while (i < values.len) {
        // Count consecutive equal values (RLE run)
        var run_len: usize = 1;
        while (i + run_len < values.len and values[i + run_len] == values[i] and run_len < 0x7FFFFFFF) {
            run_len += 1;
        }

        // Use RLE if we have at least 8 values (threshold for efficiency)
        // or if it's the last run
        if (run_len >= 8 or i + run_len == values.len) {
            // Encode as RLE run
            try encodeRleRun(&buffer, allocator, values[i], run_len, bit_width);
            i += run_len;
        } else {
            // Encode as bit-packed run (groups of 8)
            // Find how many values until the next good RLE opportunity
            var pack_count: usize = 0;
            var j = i;
            while (j < values.len) {
                var next_run: usize = 1;
                while (j + next_run < values.len and values[j + next_run] == values[j]) {
                    next_run += 1;
                }
                if (next_run >= 8) break;
                pack_count += next_run;
                j += next_run;
            }

            // Round up to multiple of 8
            pack_count = @min(pack_count, values.len - i);
            const groups = (pack_count + 7) / 8;
            const actual_count = groups * 8;

            try encodeBitPackedRun(&buffer, allocator, values[i..], @min(actual_count, values.len - i), bit_width);
            i += @min(actual_count, values.len - i);
        }
    }

    const result = try buffer.toOwnedSlice(allocator);
    return result;
}

/// Encode an RLE run: (count << 1 | 0) followed by value bytes
fn encodeRleRun(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32, count: usize, bit_width: u5) !void {
    // Write indicator: count << 1 (RLE flag is 0)
    const indicator = count << 1;
    try writeVarInt(buffer, allocator, indicator);

    // Write value using ceil(bit_width / 8) bytes
    const value_bytes = (@as(usize, bit_width) + 7) / 8;
    var v = value;
    for (0..value_bytes) |_| {
        try buffer.append(allocator, @truncate(v));
        v >>= 8;
    }
}

/// Encode a bit-packed run: (num_groups << 1 | 1) followed by packed bytes
fn encodeBitPackedRun(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const u32, count: usize, bit_width: u5) !void {
    // Number of groups of 8 values
    const num_groups = (count + 7) / 8;

    // Write indicator: num_groups << 1 | 1 (bit-packed flag)
    const indicator = (num_groups << 1) | 1;
    try writeVarInt(buffer, allocator, indicator);

    // 8 values of bit_width bits = bit_width bytes per group; padding stays zero.
    const total_bytes = num_groups * @as(usize, bit_width);
    const start_pos = buffer.items.len;
    try buffer.appendNTimes(allocator, 0, total_bytes);
    const out = buffer.items[start_pos..];

    const mask: u64 = (@as(u64, 1) << bit_width) - 1;
    var acc: u64 = 0;
    var acc_bits: u6 = 0; // < 8 at the top of each iteration, so + bit_width (<= 31) < 64
    var pos: usize = 0;
    // Values past values.len (padding up to count) are zero, which `out` already holds.
    for (values[0..@min(count, values.len)]) |v| {
        acc |= (@as(u64, v) & mask) << acc_bits;
        acc_bits += @as(u6, bit_width);
        while (acc_bits >= 8) {
            out[pos] = @truncate(acc); // low byte of acc: exactly the byte being emitted
            pos += 1;
            acc >>= 8;
            acc_bits -= 8;
        }
    }
    if (acc_bits > 0) out[pos] = @truncate(acc); // low byte of acc: the final partial byte
}

/// Write a varint to the buffer
fn writeVarInt(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var v = value;
    while (v >= 0x80) {
        try buffer.append(allocator, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try buffer.append(allocator, @truncate(v));
}

/// Encode definition levels from a bool array (true = present, false = null)
/// This is a convenience wrapper for flat schemas where max_def_level = 1.
fn encodeDefLevels(allocator: std.mem.Allocator, is_defined: []const bool) ![]u8 {
    // Convert bools to u32s (0 or 1)
    const values = try allocator.alloc(u32, is_defined.len);
    defer allocator.free(values);

    for (is_defined, 0..) |defined, i| {
        values[i] = if (defined) 1 else 0;
    }

    // Encode with bit_width 1
    return encode(allocator, values, 1);
}

/// Encode levels (definition or repetition) with a specified max level.
/// For nested types, max_level can be > 1.
/// The bit width is computed from max_level.
fn encodeLevels(allocator: std.mem.Allocator, levels: []const u32, max_level: u8) ![]u8 {
    const bit_width = computeBitWidth(max_level);
    return encode(allocator, levels, bit_width);
}

/// Encode levels with a 4-byte length prefix (for V1 data pages)
pub fn encodeLevelsWithLength(allocator: std.mem.Allocator, levels: []const u32, max_level: u8) ![]u8 {
    const encoded = try encodeLevels(allocator, levels, max_level);
    defer allocator.free(encoded);

    const total = std.math.add(usize, 4, encoded.len) catch return error.OutOfMemory;
    const result = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, result[0..4], try safe.castTo(u32, encoded.len), .little);
    @memcpy(result[4..], encoded);

    return result;
}

/// Compute the bit width needed to encode values up to max_level
fn computeBitWidth(max_level: u8) u5 {
    if (max_level == 0) return 0;
    // log2_int(max_level) for max_level=255 is 7. +1 is 8. Safely fits in u5.
    return safe.castTo(u5, std.math.log2_int(u8, max_level) + 1) catch unreachable; // max_level is u8, so log2 + 1 <= 8, fits u5
}

/// Encode definition levels with a 4-byte length prefix (for V1 data pages)
pub fn encodeDefLevelsWithLength(allocator: std.mem.Allocator, is_defined: []const bool) ![]u8 {
    const encoded = try encodeDefLevels(allocator, is_defined);
    defer allocator.free(encoded);

    const total = std.math.add(usize, 4, encoded.len) catch return error.OutOfMemory;
    const result = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, result[0..4], try safe.castTo(u32, encoded.len), .little);
    @memcpy(result[4..], encoded);

    return result;
}

/// Append V1 definition levels (bit width 1, u32 length prefix) for a flat
/// column straight from its values. Byte-identical to
/// `encodeDefLevelsWithLength` on the matching is-defined slice: same run-splitting rule as `encode`.
pub fn appendDefLevelsWithLength(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const Optional(T)) !void {
    const len_pos = out.items.len;
    try out.appendNTimes(allocator, 0, 4);
    const body_start = out.items.len;
    const n = values.len;
    var i: usize = 0;
    while (i < n) {
        const d = values[i] != .null_value;
        var run_len: usize = 1;
        while (i + run_len < n and (values[i + run_len] != .null_value) == d and run_len < 0x7FFFFFFF) run_len += 1;
        if (run_len >= 8 or i + run_len == n) {
            try writeVarInt(out, allocator, run_len << 1);
            try out.append(allocator, @intFromBool(d));
            i += run_len;
            continue;
        }
        // Bit-pack until the next run of >= 8, exactly like `encode`.
        var pack_count: usize = 0;
        var j = i;
        while (j < n) {
            const dj = values[j] != .null_value;
            var next_run: usize = 1;
            while (j + next_run < n and (values[j + next_run] != .null_value) == dj) next_run += 1;
            if (next_run >= 8) break;
            pack_count += next_run;
            j += next_run;
        }
        const count = @min(((pack_count + 7) / 8) * 8, n - i);
        const groups = (count + 7) / 8;
        try writeVarInt(out, allocator, (groups << 1) | 1);
        const start = out.items.len;
        try out.appendNTimes(allocator, 0, groups);
        for (0..count) |k| {
            if (values[i + k] != .null_value) out.items[start + k / 8] |= @as(u8, 1) << @as(u3, @truncate(k)); // k % 8
        }
        i += count;
    }
    const body_len = try safe.castTo(u32, out.items.len - body_start);
    std.mem.writeInt(u32, out.items[len_pos..][0..4], body_len, .little);
}

/// Encode boolean values using RLE/bit-packed hybrid encoding.
/// This is more efficient than PLAIN bit-packing for data with runs of same values.
pub fn encodeBooleans(allocator: std.mem.Allocator, values: []const bool) ![]u8 {
    // Convert bools to u32s (0 or 1)
    const u32_values = try allocator.alloc(u32, values.len);
    defer allocator.free(u32_values);

    for (values, 0..) |v, i| {
        u32_values[i] = if (v) 1 else 0;
    }

    // Encode with bit_width 1
    return encode(allocator, u32_values, 1);
}

// Tests
test "encode RLE simple run" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Encode 5 repeated values of 3
    const values = [_]u32{ 3, 3, 3, 3, 3 };
    const encoded = try encode(allocator, &values, 8);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decode(allocator, encoded, 8, 5);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u32, &values, decoded);
}

test "encode RLE mixed values" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Mix of values
    const values = [_]u32{ 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2 };
    const encoded = try encode(allocator, &values, 8);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decode(allocator, encoded, 8, 16);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u32, &values, decoded);
}

test "encode definition levels" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Mix of defined and null values
    const is_defined = [_]bool{ true, true, true, false, true };
    const encoded = try encodeDefLevels(allocator, &is_defined);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decodeDefLevels(allocator, encoded, 1, 5);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(bool, &is_defined, decoded);
}

test "encode definition levels with length prefix" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    const is_defined = [_]bool{ true, false, true };
    const encoded = try encodeDefLevelsWithLength(allocator, &is_defined);
    defer allocator.free(encoded);

    // First 4 bytes are length
    const len = std.mem.readInt(u32, encoded[0..4], .little);
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(len + 4, encoded.len);

    // Decode the RLE portion
    const decoded = try rle.decodeDefLevels(allocator, encoded[4..], 1, 3);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(bool, &is_defined, decoded);
}

test "encode bit-packed values" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Values that don't repeat enough for RLE
    const values = [_]u32{ 0, 1, 0, 1, 0, 1, 0, 1 };
    const encoded = try encode(allocator, &values, 1);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decode(allocator, encoded, 1, 8);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u32, &values, decoded);
}

test "encode levels with max_level > 1" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Definition levels for nested type: 0 = null list, 1 = empty list, 2 = element present
    const levels = [_]u32{ 2, 2, 1, 0, 2, 2, 2 };
    const max_level: u8 = 2;
    const encoded = try encodeLevels(allocator, &levels, max_level);
    defer allocator.free(encoded);

    // Decode and verify
    const bit_width = computeBitWidth(max_level);
    const decoded = try rle.decode(allocator, encoded, bit_width, 7);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u32, &levels, decoded);
}

test "encode levels with length prefix" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    const levels = [_]u32{ 3, 3, 2, 1, 0, 3 };
    const max_level: u8 = 3;
    const encoded = try encodeLevelsWithLength(allocator, &levels, max_level);
    defer allocator.free(encoded);

    // First 4 bytes are length
    const len = std.mem.readInt(u32, encoded[0..4], .little);
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(len + 4, encoded.len);

    // Decode the RLE portion
    const bit_width = computeBitWidth(max_level);
    const decoded = try rle.decode(allocator, encoded[4..], bit_width, 6);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u32, &levels, decoded);
}

test "encode booleans" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // Mix of true/false values
    const values = [_]bool{ true, true, true, false, false, true };
    const encoded = try encodeBooleans(allocator, &values);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decode(allocator, encoded, 1, 6);
    defer allocator.free(decoded);

    // Check decoded values match originals
    try std.testing.expectEqual(@as(u32, 1), decoded[0]);
    try std.testing.expectEqual(@as(u32, 1), decoded[1]);
    try std.testing.expectEqual(@as(u32, 1), decoded[2]);
    try std.testing.expectEqual(@as(u32, 0), decoded[3]);
    try std.testing.expectEqual(@as(u32, 0), decoded[4]);
    try std.testing.expectEqual(@as(u32, 1), decoded[5]);
}

test "encode booleans with runs" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // 10 trues followed by 10 falses - should use RLE efficiently
    var values: [20]bool = undefined;
    for (0..10) |i| values[i] = true;
    for (10..20) |i| values[i] = false;

    const encoded = try encodeBooleans(allocator, &values);
    defer allocator.free(encoded);

    // Decode and verify
    const decoded = try rle.decode(allocator, encoded, 1, 20);
    defer allocator.free(decoded);

    for (0..10) |i| {
        try std.testing.expectEqual(@as(u32, 1), decoded[i]);
    }
    for (10..20) |i| {
        try std.testing.expectEqual(@as(u32, 0), decoded[i]);
    }
}

test "computeBitWidth" {
    try std.testing.expectEqual(@as(u5, 0), computeBitWidth(0));
    try std.testing.expectEqual(@as(u5, 1), computeBitWidth(1));
    try std.testing.expectEqual(@as(u5, 2), computeBitWidth(2));
    try std.testing.expectEqual(@as(u5, 2), computeBitWidth(3));
    try std.testing.expectEqual(@as(u5, 3), computeBitWidth(4));
    try std.testing.expectEqual(@as(u5, 3), computeBitWidth(7));
}

/// Reference LSB-first unpacker, independent of rle.zig's decoder.
fn unpackRef(bytes: []const u8, bit_width: u5, out: []u32) void {
    var bit: usize = 0;
    for (out) |*o| {
        var v: u32 = 0;
        for (0..bit_width) |b| {
            const pos = bit + b;
            const bit_in: u32 = (bytes[pos / 8] >> @as(u3, @truncate(pos % 8))) & 1; // % 8 fits u3
            const sh = safe.castTo(u5, b) catch unreachable; // b < bit_width <= 31
            v |= bit_in << sh;
        }
        o.* = v;
        bit += bit_width;
    }
}

test "bit-packed run round trips for widths 1..31" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    const counts = [_]usize{ 1, 8, 9, 100, 1000 };
    var prng = std.Random.DefaultPrng.init(0x3131);
    const random = prng.random();
    for (1..32) |bw_int| {
        const bw = safe.castTo(u5, bw_int) catch unreachable; // 1..31 fits u5
        const max_val: u32 = (@as(u32, 1) << bw) - 1;
        for (counts) |count| {
            const values = try allocator.alloc(u32, count);
            defer allocator.free(values);
            for (values) |*v| v.* = random.int(u32) & max_val;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try encodeBitPackedRun(&buf, allocator, values, count, bw);

            // Skip the varint run header, then unpack the whole groups of 8.
            var hdr: usize = 0;
            while ((buf.items[hdr] & 0x80) != 0) hdr += 1;
            hdr += 1;
            const padded = (count + 7) / 8 * 8;
            const got = try allocator.alloc(u32, padded);
            defer allocator.free(got);
            unpackRef(buf.items[hdr..], bw, got);
            try std.testing.expectEqualSlices(u32, values, got[0..count]);
            for (got[count..]) |z| try std.testing.expectEqual(@as(u32, 0), z);

            // Cross-check against the real decoder (fast path + checked tail).
            const decoded = try rle.decode(allocator, buf.items, bw, count);
            defer allocator.free(decoded);
            try std.testing.expectEqualSlices(u32, values, decoded);
        }
    }
}

test "bit-packed run pads short input with zeros" {
    const allocator = std.testing.allocator;
    const rle = @import("rle.zig");

    // count (8) exceeds values.len (5): the tail of the group must encode as 0
    const values = [_]u32{ 5, 1, 7, 2, 6 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try encodeBitPackedRun(&buf, allocator, &values, 8, 3);

    const decoded = try rle.decode(allocator, buf.items, 3, 8);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u32, &.{ 5, 1, 7, 2, 6, 0, 0, 0 }, decoded);
}

test "appendDefLevelsWithLength is byte-identical to encodeDefLevelsWithLength" {
    const allocator = std.testing.allocator;
    const sizes = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 100, 1000 };
    const rates = [_]u32{ 0, 5, 33, 50, 95, 100 }; // percent null
    var prng = std.Random.DefaultPrng.init(0x3232);
    const random = prng.random();

    for (sizes) |n| {
        // Random null rates, plus the bench pattern (every third value null).
        for (0..rates.len + 1) |case| {
            const opt = try allocator.alloc(Optional(i64), n);
            defer allocator.free(opt);
            const is_def = try allocator.alloc(bool, n);
            defer allocator.free(is_def);
            for (opt, is_def, 0..) |*o, *d, i| {
                const is_null = if (case < rates.len)
                    random.uintLessThan(u32, 100) < rates[case]
                else
                    i % 3 == 2;
                d.* = !is_null;
                o.* = if (is_null) .null_value else .{ .value = @as(i64, @intCast(i)) };
            }

            // Pre-existing bytes must be kept: the helper appends.
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try out.append(allocator, 0xAB);
            try appendDefLevelsWithLength(i64, &out, allocator, opt);

            const want = try encodeDefLevelsWithLength(allocator, is_def);
            defer allocator.free(want);
            try std.testing.expectEqual(@as(u8, 0xAB), out.items[0]);
            try std.testing.expectEqualSlices(u8, want, out.items[1..]);
        }
    }
}
