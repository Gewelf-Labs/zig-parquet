//! CRC-32/ISO-HDLC (same result as std.hash.Crc32), slicing-by-8.
const std = @import("std");

const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @truncate(i); // i < 256
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        t[0][i] = c;
    }
    for (0..256) |i| {
        for (1..8) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

pub fn hash(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        const lo = std.mem.readInt(u32, data[i..][0..4], .little) ^ crc;
        const hi = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        crc = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
    }
    for (data[i..]) |b| crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8);
    return ~crc;
}

test "matches std.hash.Crc32" {
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [2048]u8 = undefined;
    prng.random().bytes(&buf);
    for (0..buf.len) |n| try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), hash(buf[0..n]));
}

test "empty and short inputs match std.hash.Crc32" {
    var prng = std.Random.DefaultPrng.init(7);
    var buf: [16]u8 = undefined;
    prng.random().bytes(&buf);
    try std.testing.expectEqual(std.hash.Crc32.hash(""), hash(""));
    for (1..17) |n| try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), hash(buf[0..n]));
}

test "1 MiB matches std.hash.Crc32" {
    const buf = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(buf);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().bytes(buf);
    try std.testing.expectEqual(std.hash.Crc32.hash(buf), hash(buf));
    try std.testing.expectEqual(std.hash.Crc32.hash(buf[1..]), hash(buf[1..]));
    try std.testing.expectEqual(std.hash.Crc32.hash(buf[3 .. 3 + 1001]), hash(buf[3 .. 3 + 1001]));
}
