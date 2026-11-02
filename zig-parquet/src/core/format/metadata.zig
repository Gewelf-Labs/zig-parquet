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
        freeSchema(allocator, self.schema);
        freeRowGroups(allocator, self.row_groups);
        if (self.key_value_metadata) |kvs| freeKeyValues(allocator, kvs);
        if (self.created_by) |cb| allocator.free(cb);
        self.* = .{};
    }

    // Free helpers shared by deinit and by the replace-on-duplicate-field paths in parse().
    fn freeSchema(allocator: std.mem.Allocator, schema: []SchemaElement) void {
        for (schema) |*elem| elem.deinit(allocator);
        allocator.free(schema);
    }

    fn freeRowGroups(allocator: std.mem.Allocator, row_groups: []RowGroup) void {
        for (row_groups) |*rg| rg.deinit(allocator);
        allocator.free(row_groups);
    }

    fn freeKeyValues(allocator: std.mem.Allocator, kvs: []KeyValue) void {
        for (kvs) |*kv| kv.deinit(allocator);
        allocator.free(kvs);
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
                        for (schema_list[0..parsed]) |*elem| elem.deinit(allocator);
                        allocator.free(schema_list);
                    }
                    for (schema_list) |*slot| {
                        slot.* = try SchemaElement.parse(allocator, reader);
                        parsed += 1;
                    }
                    // A repeated field 2 replaces the earlier list; free it so it does not leak.
                    freeSchema(allocator, meta.schema);
                    meta.schema = schema_list;
                },
                3 => meta.num_rows = try reader.readI64(),
                4 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const row_groups_list = try allocator.alloc(RowGroup, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (row_groups_list[0..parsed]) |*rg| rg.deinit(allocator);
                        allocator.free(row_groups_list);
                    }
                    for (row_groups_list) |*slot| {
                        slot.* = try RowGroup.parse(allocator, reader);
                        parsed += 1;
                    }
                    // A repeated field 4 replaces the earlier list; free it so it does not leak.
                    freeRowGroups(allocator, meta.row_groups);
                    meta.row_groups = row_groups_list;
                },
                5 => {
                    const list_header = try reader.readListHeader();
                    try reader.checkListFits(list_header.size);
                    const kvs = try allocator.alloc(KeyValue, list_header.size);
                    var parsed: usize = 0;
                    errdefer {
                        for (kvs[0..parsed]) |*kv| kv.deinit(allocator);
                        allocator.free(kvs);
                    }
                    for (kvs) |*slot| {
                        slot.* = try KeyValue.parse(allocator, reader);
                        parsed += 1;
                    }
                    // A repeated field 5 replaces the earlier list; free it so it does not leak.
                    if (meta.key_value_metadata) |old| freeKeyValues(allocator, old);
                    meta.key_value_metadata = kvs;
                },
                6 => {
                    const cb = try allocator.dupe(u8, try reader.readString());
                    if (meta.created_by) |old| allocator.free(old);
                    meta.created_by = cb;
                },
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
