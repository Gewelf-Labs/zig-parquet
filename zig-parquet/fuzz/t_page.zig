//! Fuzz target `page` (stub: filled in by its own task).
const std = @import("std");
const common = @import("common.zig");

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    _ = gpa;
    _ = bytes;
    _ = fb;
}

/// `gen-seeds`: writes generated seeds into `dir` (fuzz/corpus/<target>).
pub fn genSeeds(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    _ = gpa;
    _ = io;
    _ = dir;
}
