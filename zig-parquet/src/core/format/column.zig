//! Column metadata and column chunk structures

const std = @import("std");
const safe = @import("../safe.zig");
const thrift = @import("../thrift/mod.zig");
const types = @import("types.zig");
const statistics = @import("statistics.zig");

pub const PhysicalType = types.PhysicalType;
pub const Encoding = types.Encoding;
pub const CompressionCodec = types.CompressionCodec;
pub const Statistics = statistics.Statistics;
pub const GeospatialStatistics = statistics.GeospatialStatistics;

fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Column metadata
pub const ColumnMetaData = struct {
    type_: PhysicalType = .int32,
    encodings: []Encoding = &.{},
    path_in_schema: [][]const u8 = &.{},
    codec: CompressionCodec = .uncompressed,
    num_values: i64 = 0,
    total_uncompressed_size: i64 = 0,
    total_compressed_size: i64 = 0,
    data_page_offset: i64 = 0,
    index_page_offset: ?i64 = null,
    dictionary_page_offset: ?i64 = null,
    statistics: ?Statistics = null,
    // Field 17: geospatial_statistics for GEOMETRY/GEOGRAPHY columns
    geospatial_statistics: ?GeospatialStatistics = null,

    const Self = @This();

    /// Free everything parse() allocated. Safe on a partially filled value.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.encodings);
        freePaths(allocator, self.path_in_schema);
        if (self.statistics) |*stats| stats.deinit(allocator);
        if (self.geospatial_statistics) |*geo| geo.deinit(allocator);
        self.* = .{};
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *thrift.CompactReader) !Self {
        var meta = Self{};
        errdefer meta.deinit(allocator);
        const saved_field_id = reader.last_field_id;
        reader.resetFieldTracking();

        while (try reader.readFieldHeader()) |field| {
            switch (field.field_id) {
                1 => meta.type_ = try PhysicalType.fromInt(try reader.readI32()),
                2 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const encodings = try allocator.alloc(Encoding, list_header.size);
                    errdefer allocator.free(encodings);
                    for (encodings) |*slot| {
                        slot.* = try Encoding.fromInt(try reader.readI32());
                    }
                    allocator.free(meta.encodings);
                    meta.encodings = encodings;
                },
                3 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const paths = try allocator.alloc([]const u8, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (paths[0..parsed]) |path| allocator.free(path);
                        allocator.free(paths);
                    }
                    for (paths) |*slot| {
                        slot.* = try allocator.dupe(u8, try reader.readString());
                        parsed += 1;
                    }
                    freePaths(allocator, meta.path_in_schema);
                    meta.path_in_schema = paths;
                },
                4 => meta.codec = try CompressionCodec.fromInt(try reader.readI32()),
                5 => meta.num_values = try reader.readI64(),
                6 => meta.total_uncompressed_size = try reader.readI64(),
                7 => meta.total_compressed_size = try reader.readI64(),
                9 => meta.data_page_offset = try reader.readI64(),
                10 => meta.index_page_offset = try reader.readI64(),
                11 => meta.dictionary_page_offset = try reader.readI64(),
                12 => {
                    const stats = try Statistics.parse(allocator, reader);
                    if (meta.statistics) |*old| old.deinit(allocator);
                    meta.statistics = stats;
                },
                17 => {
                    const geo = try GeospatialStatistics.parse(allocator, reader);
                    if (meta.geospatial_statistics) |*old| old.deinit(allocator);
                    meta.geospatial_statistics = geo;
                },
                else => try reader.skip(field.field_type),
            }
        }

        reader.last_field_id = saved_field_id;
        return meta;
    }

    /// Serialize to Thrift Compact Protocol
    pub fn serialize(self: *const Self, writer: *thrift.CompactWriter) !void {
        const saved = writer.saveFieldId();
        writer.resetFieldTracking();

        try writer.writeFieldHeader(1, .i32);
        try writer.writeI32(@intFromEnum(self.type_));

        try writer.writeFieldHeader(2, .list);
        try writer.writeListHeader(.i32, safe.castTo(u32, self.encodings.len) catch return error.IntegerOverflow);
        for (self.encodings) |enc| {
            try writer.writeI32(@intFromEnum(enc));
        }

        try writer.writeFieldHeader(3, .list);
        try writer.writeListHeader(.binary, safe.castTo(u32, self.path_in_schema.len) catch return error.IntegerOverflow);
        for (self.path_in_schema) |path| {
            try writer.writeString(path);
        }

        try writer.writeFieldHeader(4, .i32);
        try writer.writeI32(@intFromEnum(self.codec));

        try writer.writeFieldHeader(5, .i64);
        try writer.writeI64(self.num_values);

        try writer.writeFieldHeader(6, .i64);
        try writer.writeI64(self.total_uncompressed_size);

        try writer.writeFieldHeader(7, .i64);
        try writer.writeI64(self.total_compressed_size);

        try writer.writeFieldHeader(9, .i64);
        try writer.writeI64(self.data_page_offset);

        if (self.index_page_offset) |v| {
            try writer.writeFieldHeader(10, .i64);
            try writer.writeI64(v);
        }

        if (self.dictionary_page_offset) |v| {
            try writer.writeFieldHeader(11, .i64);
            try writer.writeI64(v);
        }

        if (self.statistics) |*stats| {
            try writer.writeFieldHeader(12, .struct_);
            try stats.serialize(writer);
        }

        if (self.geospatial_statistics) |*geo_stats| {
            try writer.writeFieldHeader(17, .struct_);
            try geo_stats.serialize(writer);
        }

        try writer.writeStructEnd();
        writer.restoreFieldId(saved);
    }
};

/// Column chunk
pub const ColumnChunk = struct {
    file_path: ?[]const u8 = null,
    file_offset: i64 = 0,
    meta_data: ?ColumnMetaData = null,
    // Page index locators (set after row groups are flushed, before the footer).
    offset_index_offset: ?i64 = null,
    offset_index_length: ?i32 = null,
    column_index_offset: ?i64 = null,
    column_index_length: ?i32 = null,

    const Self = @This();

    /// Free everything parse() allocated. Safe on a partially filled value.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.file_path) |fp| allocator.free(fp);
        if (self.meta_data) |*md| md.deinit(allocator);
        self.* = .{};
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *thrift.CompactReader) !Self {
        var chunk = Self{};
        errdefer chunk.deinit(allocator);
        const saved_field_id = reader.last_field_id;
        reader.resetFieldTracking();

        while (try reader.readFieldHeader()) |field| {
            switch (field.field_id) {
                1 => {
                    const path = try allocator.dupe(u8, try reader.readString());
                    if (chunk.file_path) |old| allocator.free(old);
                    chunk.file_path = path;
                },
                2 => chunk.file_offset = try reader.readI64(),
                3 => {
                    const md = try ColumnMetaData.parse(allocator, reader);
                    if (chunk.meta_data) |*old| old.deinit(allocator);
                    chunk.meta_data = md;
                },
                4 => chunk.offset_index_offset = try reader.readI64(),
                5 => chunk.offset_index_length = try reader.readI32(),
                6 => chunk.column_index_offset = try reader.readI64(),
                7 => chunk.column_index_length = try reader.readI32(),
                else => try reader.skip(field.field_type),
            }
        }

        reader.last_field_id = saved_field_id;
        return chunk;
    }

    /// Serialize to Thrift Compact Protocol
    pub fn serialize(self: *const Self, writer: *thrift.CompactWriter) !void {
        const saved = writer.saveFieldId();
        writer.resetFieldTracking();

        if (self.file_path) |fp| {
            try writer.writeFieldHeader(1, .binary);
            try writer.writeString(fp);
        }

        try writer.writeFieldHeader(2, .i64);
        try writer.writeI64(self.file_offset);

        if (self.meta_data) |*md| {
            try writer.writeFieldHeader(3, .struct_);
            try md.serialize(writer);
        }

        if (self.offset_index_offset) |v| {
            try writer.writeFieldHeader(4, .i64);
            try writer.writeI64(v);
        }
        if (self.offset_index_length) |v| {
            try writer.writeFieldHeader(5, .i32);
            try writer.writeI32(v);
        }
        if (self.column_index_offset) |v| {
            try writer.writeFieldHeader(6, .i64);
            try writer.writeI64(v);
        }
        if (self.column_index_length) |v| {
            try writer.writeFieldHeader(7, .i32);
            try writer.writeI32(v);
        }

        try writer.writeStructEnd();
        writer.restoreFieldId(saved);
    }
};
