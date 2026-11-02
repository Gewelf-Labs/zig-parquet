//! Fuzz target `thrift`: footer and page-header parsing with OOM injection.
//!
//! Input: `fail` u16 LE (0xffff = no injected failure), `which` below(4), then the Thrift bytes.
//! `which`: 0 FileMetaData, 1 PageHeader, 2 ColumnIndex, 3 OffsetIndex.
const std = @import("std");
const parquet = @import("parquet");
const common = @import("common.zig");

const format = parquet.format;
const thrift = parquet.internals.thrift;

const no_failure: u16 = 0xffff;

pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    var in: common.Input = .{ .bytes = bytes };
    const fail = in.int(u16);
    const which = in.below(4);
    fb.detail = which;

    var failing = std.testing.FailingAllocator.init(gpa, .{
        .fail_index = if (fail == no_failure) std.math.maxInt(usize) else fail,
    });
    const a = failing.allocator();
    var reader = thrift.CompactReader.init(in.rest());
    switch (which) {
        0 => {
            var v = try format.FileMetaData.parse(a, &reader);
            v.deinit(a);
        },
        1 => {
            var v = try format.PageHeader.parse(a, &reader);
            v.deinit(a);
        },
        2 => {
            var v = try format.page_index.ColumnIndex.parse(a, &reader);
            v.deinit(a);
        },
        else => {
            var v = try format.page_index.OffsetIndex.parse(a, &reader);
            v.deinit(a);
        },
    }
}
