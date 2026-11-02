//! Fuzz targets `file` / `file-oom` (stub: filled in by its own task).
const std = @import("std");
const common = @import("common.zig");

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback, oom: bool) !void {
    _ = gpa;
    _ = bytes;
    _ = fb;
    _ = oom;
}
