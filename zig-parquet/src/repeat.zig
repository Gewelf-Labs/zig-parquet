//! Repeat a byte pattern.
//! Zig 0.17 removed array multiplication (`**`). Single-value fills use `@splat`;
//! multi-byte patterns use this helper. The result is a stable slice of a
//! comptime buffer, so it coerces to `[]const u8`.

fn fill(comptime pattern: []const u8, comptime n: usize) [pattern.len * n]u8 {
    @setEvalBranchQuota(n * 20 + 1000);
    var out: [pattern.len * n]u8 = undefined;
    for (0..n) |i| {
        @memcpy(out[i * pattern.len ..][0..pattern.len], pattern);
    }
    return out;
}

pub fn bytes(comptime pattern: []const u8, comptime n: usize) []const u8 {
    const storage = struct {
        const mem = fill(pattern, n);
    };
    return &storage.mem;
}
