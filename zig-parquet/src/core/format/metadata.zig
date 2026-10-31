//! File metadata - the root structure in the Parquet footer

const std = @import("std");
const safe = @import("../safe.zig");
const thrift = @import("../thrift/mod.zig");
const schema_mod = @import("schema.zig");
const row_group_mod = @import("row_group.zig");

pub const SchemaElement = schema_mod.SchemaElement;
pub const RowGroup = row_group_mod.RowGroup;
pub const KeyValue = row_group_mod.KeyValue;

/// File metadata - the root structure in the footer
pub const FileMetaData = struct {
    version: i32 = 0,
    schema: []SchemaElement = &.{},
    num_rows: i64 = 0,
    row_groups: []RowGroup = &.{},
    key_value_metadata: ?[]KeyValue = null,
    created_by: ?[]const u8 = null,

    const Self = @This();

    /// Free everything parse() allocated. Fields still at their defaults are skipped,
    /// so this is safe on a partially filled value. Leaves `self` empty.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.schema) |*elem| freeSchemaElement(allocator, elem);
        allocator.free(self.schema);
        for (self.row_groups) |*rg| freeRowGroup(allocator, rg);
        allocator.free(self.row_groups);
        if (self.key_value_metadata) |kvs| {
            for (kvs) |*kv| freeKeyValue(allocator, kv);
            allocator.free(kvs);
        }
        if (self.created_by) |cb| allocator.free(cb);
        self.* = .{};
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *thrift.CompactReader) !Self {
        var meta = Self{};
        // Frees whatever has been assigned to `meta` so far if a later field fails.
        errdefer meta.deinit(allocator);
        reader.resetFieldTracking();

        while (try reader.readFieldHeader()) |field| {
            switch (field.field_id) {
                1 => meta.version = try reader.readI32(),
                2 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const schema_list = try allocator.alloc(SchemaElement, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (schema_list[0..parsed]) |*elem| freeSchemaElement(allocator, elem);
                        allocator.free(schema_list);
                    }
                    for (schema_list) |*slot| {
                        slot.* = try SchemaElement.parse(allocator, reader);
                        parsed += 1;
                    }
                    meta.schema = schema_list;
                },
                3 => meta.num_rows = try reader.readI64(),
                4 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const row_groups_list = try allocator.alloc(RowGroup, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (row_groups_list[0..parsed]) |*rg| freeRowGroup(allocator, rg);
                        allocator.free(row_groups_list);
                    }
                    for (row_groups_list) |*slot| {
                        slot.* = try RowGroup.parse(allocator, reader);
                        parsed += 1;
                    }
                    meta.row_groups = row_groups_list;
                },
                5 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const kvs = try allocator.alloc(KeyValue, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (kvs[0..parsed]) |*kv| freeKeyValue(allocator, kv);
                        allocator.free(kvs);
                    }
                    for (kvs) |*slot| {
                        slot.* = try KeyValue.parse(allocator, reader);
                        parsed += 1;
                    }
                    meta.key_value_metadata = kvs;
                },
                6 => meta.created_by = try allocator.dupe(u8, try reader.readString()),
                else => try reader.skip(field.field_type),
            }
        }

        return meta;
    }

    /// Serialize to Thrift Compact Protocol
    pub fn serialize(self: *const Self, writer: *thrift.CompactWriter) !void {
        writer.resetFieldTracking();

        try writer.writeFieldHeader(1, .i32);
        try writer.writeI32(self.version);

        try writer.writeFieldHeader(2, .list);
        try writer.writeListHeader(.struct_, safe.castTo(u32, self.schema.len) catch return error.IntegerOverflow);
        for (self.schema) |*elem| {
            try elem.serialize(writer);
        }

        try writer.writeFieldHeader(3, .i64);
        try writer.writeI64(self.num_rows);

        try writer.writeFieldHeader(4, .list);
        try writer.writeListHeader(.struct_, safe.castTo(u32, self.row_groups.len) catch return error.IntegerOverflow);
        for (self.row_groups) |*rg| {
            try rg.serialize(writer);
        }

        if (self.key_value_metadata) |kvs| {
            try writer.writeFieldHeader(5, .list);
            try writer.writeListHeader(.struct_, safe.castTo(u32, kvs.len) catch return error.IntegerOverflow);
            for (kvs) |*kv| {
                try kv.serialize(writer);
            }
        }

        if (self.created_by) |cb| {
            try writer.writeFieldHeader(6, .binary);
            try writer.writeString(cb);
        }

        try writer.writeStructEnd();
    }
};

// Element-level frees used by FileMetaData.deinit and the partial-parse errdefers.
// Each mirrors the allocations made by the matching parse(); see DynamicReader.deinit.

fn freeSchemaElement(allocator: std.mem.Allocator, elem: *SchemaElement) void {
    if (elem.name.len > 0) allocator.free(elem.name);
    if (elem.logical_type) |lt| switch (lt) {
        .geometry => |g| if (g.crs) |crs| allocator.free(crs),
        .geography => |g| if (g.crs) |crs| allocator.free(crs),
        else => {},
    };
    elem.* = .{};
}

fn freeColumnChunk(allocator: std.mem.Allocator, col: *row_group_mod.ColumnChunk) void {
    if (col.file_path) |fp| allocator.free(fp);
    if (col.meta_data) |*md| {
        allocator.free(md.encodings);
        for (md.path_in_schema) |path| allocator.free(path);
        allocator.free(md.path_in_schema);
        if (md.statistics) |*stats| stats.deinit(allocator);
        if (md.geospatial_statistics) |*geo| geo.deinit(allocator);
    }
    col.* = .{};
}

fn freeRowGroup(allocator: std.mem.Allocator, rg: *RowGroup) void {
    for (rg.columns) |*col| freeColumnChunk(allocator, col);
    allocator.free(rg.columns);
    if (rg.sorting_columns) |sc| allocator.free(sc);
    rg.* = .{};
}

fn freeKeyValue(allocator: std.mem.Allocator, kv: *KeyValue) void {
    if (kv.key.len > 0) allocator.free(kv.key);
    if (kv.value) |v| allocator.free(v);
    kv.* = .{};
}
