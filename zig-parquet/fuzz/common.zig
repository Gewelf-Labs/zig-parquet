//! Shared fuzz helpers.
const std = @import("std");

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
