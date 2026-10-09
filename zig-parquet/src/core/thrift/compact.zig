//! Thrift Compact Protocol decoder
//!
//! The Compact Protocol is a binary protocol that uses variable-length encoding
//! for integers and packs field headers efficiently.

const std = @import("std");
const safe = @import("../safe.zig");

/// Thrift type codes used in Compact Protocol
pub const Type = enum(u4) {
    stop = 0,
    bool_true = 1,
    bool_false = 2,
    i8 = 3,
    i16 = 4,
    i32 = 5,
    i64 = 6,
    double = 7,
    binary = 8, // Also used for strings
    list = 9,
    set = 10,
    map = 11,
    struct_ = 12,
    // uuid = 13, // Not used in Parquet
};

pub const FieldHeader = struct {
    field_id: i16,
    field_type: Type,
};

pub const ListHeader = struct {
    element_type: Type,
    size: u32,
};

/// A reader for Thrift Compact Protocol encoded data
pub const CompactReader = struct {
    data: []const u8,
    pos: usize = 0,
    last_field_id: i16 = 0,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{ .data = data };
    }

    /// Read a single byte
    pub fn readByte(self: *Self) !u8 {
        if (self.pos >= self.data.len) return error.EndOfData;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Read N bytes
    fn readBytes(self: *Self, n: usize) ![]const u8 {
        // pos <= data.len is an invariant of this reader.
        if (n > self.data.len - self.pos) return error.EndOfData;
        const bytes = try safe.slice(self.data, self.pos, n);
        self.pos += n;
        return bytes;
    }

    /// Read an unsigned variable-length integer (varint)
    pub fn readVarInt(self: *Self) !u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7F) << @as(u6, std.math.cast(u6, shift) orelse return error.VarIntTooLong);
            if (b & 0x80 == 0) break;
            shift += 7;
            if (shift >= 64) return error.VarIntTooLong;
        }
        return result;
    }

    /// Decode a zigzag-encoded signed integer
    fn zigzagDecode(n: u64) i64 {
        return @bitCast((n >> 1) ^ -%@as(u64, n & 1));
    }

    /// Read a signed 16-bit integer (zigzag + varint)
    pub fn readI16(self: *Self) !i16 {
        const v = try self.readVarInt();
        const decoded = zigzagDecode(v);
        if (decoded < std.math.minInt(i16) or decoded > std.math.maxInt(i16)) {
            return error.IntegerOverflow;
        }
        return safe.castTo(i16, decoded) catch return error.IntegerOverflow;
    }

    /// Read a signed 32-bit integer (zigzag + varint)
    pub fn readI32(self: *Self) !i32 {
        const v = try self.readVarInt();
        const decoded = zigzagDecode(v);
        if (decoded < std.math.minInt(i32) or decoded > std.math.maxInt(i32)) {
            return error.IntegerOverflow;
        }
        return safe.castTo(i32, decoded) catch return error.IntegerOverflow;
    }

    /// Read a signed 64-bit integer (zigzag + varint)
    pub fn readI64(self: *Self) !i64 {
        const v = try self.readVarInt();
        return zigzagDecode(v);
    }

    /// Read an 8-byte double
    pub fn readDouble(self: *Self) !f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// Read a length-prefixed binary blob
    pub fn readBinary(self: *Self) ![]const u8 {
        return try self.readBytes(try self.readLength());
    }

    /// Read a varint length, rejecting anything past the remaining buffer before
    /// narrowing to usize (so 32-bit targets report EndOfData, not overflow).
    fn readLength(self: *Self) !usize {
        const len = try self.readVarInt();
        if (len > self.data.len - self.pos) return error.EndOfData;
        return safe.castTo(usize, len) catch unreachable; // len <= remaining bytes, which fits in usize
    }

    /// Read a length-prefixed string (same as binary but semantically UTF-8)
    pub fn readString(self: *Self) ![]const u8 {
        return self.readBinary();
    }

    /// Read a field header, returns null when STOP field is encountered
    pub fn readFieldHeader(self: *Self) !?FieldHeader {
        const b = try self.readByte();

        // STOP field
        if (b == 0) return null;

        // Mask to 4 bits: value 0-15 always fits in u4
        const type_id: u4 = @truncate(b & 0x0F);
        const field_type = std.enums.fromInt(Type, type_id) orelse return error.InvalidFieldType;

        // Delta encoding: high nibble contains field ID delta
        const delta: u4 = @truncate((b >> 4) & 0x0F);
        var field_id: i16 = undefined;

        if (delta != 0) {
            field_id = std.math.add(i16, self.last_field_id, @as(i16, delta)) catch return error.IntegerOverflow;
        } else {
            // Full field ID follows
            field_id = try self.readI16();
        }

        self.last_field_id = field_id;
        return .{ .field_id = field_id, .field_type = field_type };
    }

    /// Read a list header
    pub fn readListHeader(self: *Self) !ListHeader {
        const b = try self.readByte();

        // Mask to 4 bits: value 0-15 always fits in u4
        const size_nibble: u4 = @truncate((b >> 4) & 0x0F);
        const type_nibble: u4 = @truncate(b & 0x0F);
        const element_type = std.enums.fromInt(Type, type_nibble) orelse return error.InvalidListType;

        var size: u32 = undefined;
        if (size_nibble == 0x0F) {
            // Size is in following varint
            const s = try self.readVarInt();
            if (s > std.math.maxInt(u32)) return error.ListTooLong;
            size = safe.castTo(u32, s) catch return error.IntegerOverflow;
        } else {
            size = size_nibble;
        }

        return .{ .element_type = element_type, .size = size };
    }

    /// Reset field ID tracking (call when entering a new struct)
    pub fn resetFieldTracking(self: *Self) void {
        self.last_field_id = 0;
    }

    /// Reject a list whose element count exceeds the bytes left: every element
    /// costs at least one byte on the wire.
    pub fn checkListFits(self: *const Self, size: u32) !void {
        if (@as(usize, size) > self.data.len - self.pos) return error.ListTooLong;
    }

    const max_skip_depth: u8 = 64;

    /// Skip a value of the given type
    pub fn skip(self: *Self, t: Type) !void {
        return self.skipDepth(t, 0, false);
    }

    fn skipDepth(self: *Self, t: Type, depth: u8, in_container: bool) !void {
        if (depth >= max_skip_depth) return error.NestingTooDeep;
        switch (t) {
            .stop => {},
            .bool_true, .bool_false => {
                // A bool field header carries the value. Inside a container each bool is one byte.
                if (in_container) _ = try self.readByte();
            },
            .i8 => _ = try self.readByte(),
            .i16, .i32, .i64 => _ = try self.readVarInt(),
            .double => _ = try self.readBytes(8),
            .binary => {
                _ = try self.readBytes(try self.readLength());
            },
            .list, .set => {
                const header = try self.readListHeader();
                // pos <= data.len is an invariant of this reader.
                if (@as(usize, header.size) > self.data.len - self.pos) return error.EndOfData;
                for (0..header.size) |_| {
                    try self.skipDepth(header.element_type, depth + 1, true);
                }
            },
            .map => {
                const size = try self.readVarInt();
                if (size == 0) return;
                const types = try self.readByte();
                const key_type = std.enums.fromInt(Type, @as(u4, @truncate((types >> 4) & 0x0F))) orelse return error.InvalidMapType;
                const val_type = std.enums.fromInt(Type, @as(u4, @truncate(types & 0x0F))) orelse return error.InvalidMapType;
                const n = safe.castTo(usize, size) catch return error.ListTooLong;
                // pos <= data.len is an invariant of this reader.
                if (n > self.data.len - self.pos) return error.EndOfData;
                for (0..n) |_| {
                    try self.skipDepth(key_type, depth + 1, true);
                    try self.skipDepth(val_type, depth + 1, true);
                }
            },
            .struct_ => {
                const saved_field_id = self.last_field_id;
                self.resetFieldTracking();
                while (try self.readFieldHeader()) |field| {
                    try self.skipDepth(field.field_type, depth + 1, false);
                }
                self.last_field_id = saved_field_id;
            },
        }
    }

    /// Get remaining unread data
    pub fn remaining(self: *Self) []const u8 {
        return self.data[self.pos..];
    }

    /// Check if at end of data
    pub fn isAtEnd(self: *Self) bool {
        return self.pos >= self.data.len;
    }
};

// Tests
test "varint decoding" {
    // Test value: 300 = 0b100101100 encoded as 0xAC 0x02
    var reader = CompactReader.init(&[_]u8{ 0xAC, 0x02 });
    const v = try reader.readVarInt();
    try std.testing.expectEqual(@as(u64, 300), v);
}

test "zigzag decoding" {
    // 0 -> 0, 1 -> -1, 2 -> 1, 3 -> -2, 4 -> 2
    try std.testing.expectEqual(@as(i64, 0), CompactReader.zigzagDecode(0));
    try std.testing.expectEqual(@as(i64, -1), CompactReader.zigzagDecode(1));
    try std.testing.expectEqual(@as(i64, 1), CompactReader.zigzagDecode(2));
    try std.testing.expectEqual(@as(i64, -2), CompactReader.zigzagDecode(3));
    try std.testing.expectEqual(@as(i64, 2), CompactReader.zigzagDecode(4));
}

test "field header with delta" {
    // Field with delta=1 and type=i32 (5): byte = 0x15
    var reader = CompactReader.init(&[_]u8{0x15});
    const field = try reader.readFieldHeader();
    try std.testing.expect(field != null);
    try std.testing.expectEqual(@as(i16, 1), field.?.field_id);
    try std.testing.expectEqual(Type.i32, field.?.field_type);
}

test "stop field" {
    var reader = CompactReader.init(&[_]u8{0x00});
    const field = try reader.readFieldHeader();
    try std.testing.expect(field == null);
}

test "malicious varint returns error instead of panicking" {
    // 11 bytes all with continuation bit set — would overflow u6 shift without the fix
    const bad_varint = @as([11]u8, @splat(0x80));
    var reader = CompactReader.init(&bad_varint);
    try std.testing.expectError(error.VarIntTooLong, reader.readVarInt());
}

test "map skip rejects invalid type nibble" {
    var reader = CompactReader.init(&[_]u8{ 0x01, 0xFF });
    try std.testing.expectError(error.InvalidMapType, reader.skip(.map));
}

test "readBinary rejects length past the buffer" {
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var reader = CompactReader.init(&bad);
    try std.testing.expectError(error.EndOfData, reader.readBinary());
}

test "field id delta overflow returns error" {
    const bytes = [_]u8{ 0x05, 0xFE, 0xFF, 0x03, 0x15 };
    var reader = CompactReader.init(&bytes);
    const first = try reader.readFieldHeader();
    try std.testing.expect(first != null);
    try std.testing.expectError(error.IntegerOverflow, reader.readFieldHeader());
}

test "skip rejects deeply nested structs" {
    const nested = @as([100]u8, @splat(0x1C));
    var reader = CompactReader.init(&nested);
    try std.testing.expectError(error.NestingTooDeep, reader.skip(.struct_));
}

test "skip rejects huge bool list" {
    const bytes = [_]u8{ 0xF1, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    var reader = CompactReader.init(&bytes);
    try std.testing.expectError(error.EndOfData, reader.skip(.list));
}
