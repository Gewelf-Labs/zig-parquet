//! FileMetaData.parse: cleanup on allocation failure and repeated footer lists.

const std = @import("std");
const io = std.testing.io;
const format = @import("../core/format.zig");
const thrift = @import("../core/thrift/mod.zig");

test "FileMetaData.parse frees everything on OOM" {
    const allocator = std.testing.allocator;

    const file = std.Io.Dir.cwd().openFile(io, "../test-files-arrow/basic/basic_types_plain_uncompressed.parquet", .{}) catch |err| {
        std.debug.print("Could not open test file: {}\n", .{err});
        return err;
    };
    defer file.close(io);

    // Footer layout: [metadata][u32 length][PAR1]
    const size = (try file.stat(io)).size;
    var tail: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &tail, size - 8);
    const footer_len = std.mem.readInt(u32, tail[0..4], .little);
    const footer = try allocator.alloc(u8, footer_len);
    defer allocator.free(footer);
    try std.testing.expectEqual(@as(usize, footer_len), try file.readPositionalAll(io, footer, size - 8 - footer_len));

    // Fail each allocation in turn. Every failing run must free what it built;
    // std.testing.allocator reports any leak from the backing allocator.
    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var reader = thrift.CompactReader.init(footer);
        var meta = format.FileMetaData.parse(failing.allocator(), &reader) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        meta.deinit(failing.allocator());
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
    // The first run (fail_index 0) must fail, so the sweep really exercised error paths.
    try std.testing.expect(fail_index > 0);
}

test "FileMetaData.parse frees an earlier schema list when field 2 repeats" {
    const allocator = std.testing.allocator;
    const footer = [_]u8{
        0x29, 0x1C, 0x48, 0x01, 'a', 0x00, // field 2 (schema): list of 1 element named "a"
        0x09, 0x04, 0x1C, 0x00, // field 2 again (long form, zigzag id 2): list of 1 empty element
        0x00, // stop
    };
    var reader = thrift.CompactReader.init(&footer);
    var meta = try format.FileMetaData.parse(allocator, &reader);
    defer meta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), meta.schema.len);
    try std.testing.expectEqualStrings("", meta.schema[0].name);
}
