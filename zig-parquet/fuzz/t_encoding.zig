//! Fuzz target `encoding` (stub: filled in by its own task).
const std = @import("std");
const common = @import("common.zig");

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    _ = gpa;
    _ = bytes;
    _ = fb;
}
