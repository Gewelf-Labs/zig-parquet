//! Schema command - displays parquet file schema in tree format

const std = @import("std");
const parquet = @import("parquet");
const helpers = @import("../helpers.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Open the file
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        try stderr.print("Error: Cannot open file '{s}': {}\n", .{ file_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer file.close(io);

    var reader = parquet.openFileDynamic(allocator, file, io, .{}) catch |err| {
        try stderr.print("Error: Cannot read parquet file: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer reader.deinit();

    const schema = reader.getSchema();
    if (schema.len == 0) {
        try stderr.writeAll("Error: Empty schema\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // schema[0] is the root; the rest is a depth-first flattening driven by num_children
    const root = schema[0];
    try stdout.print("{s} ({} columns)\n", .{ root.name, helpers.countLeafColumns(schema) });

    var idx: usize = 1;
    var prefix_buf: [1024]u8 = undefined;
    printChildren(stdout, schema, &idx, root, &prefix_buf, 0) catch |err| {
        try stdout.flush();
        try stderr.print("Error: Malformed schema: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
}

fn printChildren(
    w: *std.Io.Writer,
    schema: []const parquet.format.SchemaElement,
    idx: *usize,
    parent: parquet.format.SchemaElement,
    prefix_buf: []u8,
    prefix_len: usize,
) !void {
    const n = parquet.safe.cast(parent.num_children orelse 0) catch return error.InvalidNumChildren;
    for (0..n) |i| {
        if (idx.* >= schema.len) return error.InvalidNumChildren;
        const elem = schema[idx.*];
        idx.* += 1;
        const is_last = i + 1 == n;

        try w.print("{s}{s}", .{ prefix_buf[0..prefix_len], if (is_last) "└── " else "├── " });
        try printElement(w, elem);

        if (elem.num_children != null) {
            const indent = if (is_last) "    " else "│   ";
            if (prefix_len + indent.len > prefix_buf.len) return error.SchemaTooDeep;
            @memcpy(prefix_buf[prefix_len..][0..indent.len], indent);
            try printChildren(w, schema, idx, elem, prefix_buf, prefix_len + indent.len);
        }
    }
}

fn printElement(w: *std.Io.Writer, elem: parquet.format.SchemaElement) !void {
    const repetition = helpers.repetitionToString(elem.repetition_type);

    if (elem.num_children != null) {
        const CT = parquet.format.ConvertedType;
        const kind = if (elem.converted_type) |ct| switch (ct) {
            CT.LIST => "LIST",
            CT.MAP => "MAP",
            CT.MAP_KEY_VALUE => "MAP_KEY_VALUE",
            else => "GROUP",
        } else "GROUP";
        try w.print("{s}: {s} ({s})\n", .{ elem.name, kind, repetition });
        return;
    }

    const type_name = if (elem.type_) |t| helpers.physicalTypeToString(t) else "UNKNOWN";
    try w.print("{s}: {s}", .{ elem.name, type_name });

    if (elem.logical_type) |lt| {
        var logical_type_buf: [64]u8 = undefined;
        try w.print("/{s}", .{lt.toDetailedString(&logical_type_buf)});
    }

    try w.print(" ({s})", .{repetition});

    if (elem.type_ == .fixed_len_byte_array) {
        if (elem.type_length) |len| {
            try w.print(" [len={}]", .{len});
        }
    }

    try w.writeAll("\n");
}
