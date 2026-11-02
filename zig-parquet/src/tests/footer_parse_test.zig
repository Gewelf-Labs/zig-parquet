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

test "LogicalType.parse frees geo crs on OOM" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x0C, 0x22, // field 17 GEOMETRY (long form, zigzag id 17): struct
        0x18, 0x09, 'E', 'P', 'S', 'G', ':', '4', '3', '2', '6', // field 1 crs: binary "EPSG:4326"
        0x00, // end GeometryType
        0x00, // end LogicalType
    };

    // Fail each allocation in turn; std.testing.allocator catches any leak on the failing runs.
    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var reader = thrift.CompactReader.init(&data);
        const parsed = format.LogicalType.parse(failing.allocator(), &reader) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        var lt = parsed orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("EPSG:4326", lt.geometry.crs.?);
        lt.deinit(failing.allocator());
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(fail_index > 0);
}

test "LogicalType.parse frees the earlier geo crs when field 1 repeats" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x0C, 0x22, // field 17 GEOMETRY: struct
        0x18, 0x09, 'E', 'P', 'S', 'G', ':', '4', '3', '2', '6', // field 1 crs "EPSG:4326"
        0x08, 0x02, 0x09, 'E', 'P', 'S', 'G', ':', '3', '8', '5', '7', // field 1 again (long form): "EPSG:3857"
        0x00, // end GeometryType
        0x00, // end LogicalType
    };
    var reader = thrift.CompactReader.init(&data);
    var lt = (try format.LogicalType.parse(allocator, &reader)) orelse return error.TestUnexpectedResult;
    defer lt.deinit(allocator);
    try std.testing.expectEqualStrings("EPSG:3857", lt.geometry.crs.?);
}

test "ColumnIndex.parse frees everything on OOM" {
    const allocator = std.testing.allocator;
    // Fields 1 (null_pages), 2 (min), 3 (max), 5 (null_counts); every one allocates.
    const data = [_]u8{
        0x19, 0x12, 0x02, // field 1: list<bool> of 1 element, false
        0x19, 0x18, 0x02, 'a', 'a', // field 2: list<binary> of 1 element "aa"
        0x19, 0x18, 0x02, 'b', 'b', // field 3: list<binary> of 1 element "bb"
        0x29, 0x16, 0x02, // field 5: list<i64> of 1 element, 1
        0x00, // stop
    };

    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var reader = thrift.CompactReader.init(&data);
        var ci = format.page_index.ColumnIndex.parse(failing.allocator(), &reader) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        ci.deinit(failing.allocator());
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(fail_index > 0);
}

test "ColumnIndex.parse frees the earlier lists when a field repeats" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x29, 0x18, 0x02, 'a', 'a', // field 2: list<binary> "aa"
        0x09, 0x04, 0x18, 0x02, 'b', 'b', // field 2 again (long form): "bb"
        0x39, 0x16, 0x02, // field 5: list<i64> [1]
        0x09, 0x0A, 0x16, 0x04, // field 5 again (long form): [2]
        0x00, // stop
    };
    var reader = thrift.CompactReader.init(&data);
    var ci = try format.page_index.ColumnIndex.parse(allocator, &reader);
    defer ci.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ci.min_values.len);
    try std.testing.expectEqualStrings("bb", ci.min_values[0]);
    try std.testing.expectEqual(@as(i64, 2), ci.null_counts.?[0]);
}

test "OffsetIndex.parse frees everything on OOM" {
    const allocator = std.testing.allocator;
    // Field 1 (page_locations, one struct) and field 2 (unencoded byte counts).
    const data = [_]u8{
        0x19, 0x1C, 0x16, 0x64, 0x00, // field 1: list<PageLocation> of 1, offset 50
        0x19, 0x16, 0x06, // field 2: list<i64> of 1 element, 3
        0x00, // stop
    };

    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var reader = thrift.CompactReader.init(&data);
        var oi = format.page_index.OffsetIndex.parse(failing.allocator(), &reader) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        oi.deinit(failing.allocator());
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(fail_index > 0);
}

test "OffsetIndex.parse frees the earlier page locations when field 1 repeats" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x19, 0x1C, 0x16, 0x64, 0x00, // field 1: list of 1 PageLocation, offset 50
        0x09, 0x02, 0x1C, 0x00, // field 1 again (long form): list of 1 empty PageLocation
        0x00, // stop
    };
    var reader = thrift.CompactReader.init(&data);
    var oi = try format.page_index.OffsetIndex.parse(allocator, &reader);
    defer oi.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), oi.page_locations.len);
    try std.testing.expectEqual(@as(i64, 0), oi.page_locations[0].offset);
}

test "PageHeader.parse frees partial headers on OOM" {
    const allocator = std.testing.allocator;
    // Field 5: DataPageHeader with statistics (max "x"); field 8: DataPageHeaderV2 with statistics (max "y").
    const data = [_]u8{
        0x5C, 0x5C, 0x18, 0x01, 'x', 0x00, 0x00, // field 5: DataPageHeader { statistics { max "x" } }
        0x3C, 0x8C, 0x18, 0x01, 'y', 0x00, 0x00, // field 8: DataPageHeaderV2 { statistics { max "y" } }
        0x00, // stop
    };

    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var reader = thrift.CompactReader.init(&data);
        var header = format.PageHeader.parse(failing.allocator(), &reader) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        header.deinit(failing.allocator());
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(fail_index > 0);
}

test "PageHeader.parse frees the earlier data page header when field 5 repeats" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x5C, 0x5C, 0x18, 0x01, 'x', 0x00, 0x00, // field 5: DataPageHeader { statistics { max "x" } }
        0x0C, 0x0A, 0x5C, 0x18, 0x01, 'x', 0x00, 0x00, // field 5 again (long form): same shape
        0x00, // stop
    };
    var reader = thrift.CompactReader.init(&data);
    var header = try format.PageHeader.parse(allocator, &reader);
    defer header.deinit(allocator);

    const stats = header.data_page_header.?.statistics.?;
    try std.testing.expectEqualStrings("x", stats.max.?);
}
