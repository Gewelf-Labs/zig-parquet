//! Fuzz target `page`: one data page through the column decoder (V1 or V2, optional dictionary).
//! Recipe (every `below(n)` is a 2-byte LE read; `byte()` is one byte):
//!   physical  = physicals[below(8)]          type_len = 1 + below(32)   (FLBA only)
//!   value_enc = value_encodings[below(9)]    flags    = byte()
//!     bit0 def levels bit_packed (else rle)  bit1 rep levels bit_packed  bit2 V2  bit3 dictionary
//!   max_def = below(4)  max_rep = below(3)  num_values = below(4097)
//!   dictionary: dict_count = below(257), dict_len = below(4097), dict = take(dict_len)
//!   V2:  rep_len = below(1025), def_len = below(1025), rep = take(rep_len), def = take(def_len), values = rest()
//!   V1:  page = rest()   (levels are length-prefixed inside the page)
const std = @import("std");
const parquet = @import("parquet");
const common = @import("common.zig");

const column_decoder = parquet.internals.column_decoder;
const dictionary = parquet.internals.encoding.dictionary;
const format = parquet.format;
const enc = parquet.internals.encoding;

const Allocator = std.mem.Allocator;

// Index of each enum = the value the recipe's `below(n)` must produce to select it.
const physicals = [_]format.PhysicalType{ .boolean, .int32, .int64, .int96, .float, .double, .byte_array, .fixed_len_byte_array };
const value_encodings = [_]format.Encoding{ .plain, .plain_dictionary, .rle, .bit_packed, .delta_binary_packed, .delta_length_byte_array, .delta_byte_array, .rle_dictionary, .byte_stream_split };

/// Consumes exactly `n` bytes (or the rest) as a slice. Never panics.
fn take(in: *common.Input, n: usize) []const u8 {
    const start = @min(in.pos, in.bytes.len);
    const end = @min(start + n, in.bytes.len);
    in.pos = end;
    return in.bytes[start..end];
}

/// Dictionaries built from the recipe. Each is owned here and freed by `deinit`.
const Dicts = struct {
    string: ?dictionary.StringDictionary = null,
    int32: ?dictionary.Int32Dictionary = null,
    int64: ?dictionary.Int64Dictionary = null,
    float32: ?dictionary.Float32Dictionary = null,
    float64: ?dictionary.Float64Dictionary = null,
    int96: ?dictionary.Int96Dictionary = null,
    fixed: ?dictionary.FixedByteArrayDictionary = null,

    fn build(self: *Dicts, gpa: Allocator, physical: format.PhysicalType, data: []const u8, count: usize, type_len: usize) !void {
        switch (physical) {
            .boolean => {}, // no dictionary for BOOLEAN
            .byte_array => self.string = try dictionary.StringDictionary.fromPlain(gpa, data, count),
            .int32 => self.int32 = try dictionary.Int32Dictionary.fromPlain(gpa, data, count),
            .int64 => self.int64 = try dictionary.Int64Dictionary.fromPlain(gpa, data, count),
            .float => self.float32 = try dictionary.Float32Dictionary.fromPlain(gpa, data, count),
            .double => self.float64 = try dictionary.Float64Dictionary.fromPlain(gpa, data, count),
            .int96 => self.int96 = try dictionary.Int96Dictionary.fromPlain(gpa, data, count),
            .fixed_len_byte_array => self.fixed = try dictionary.FixedByteArrayDictionary.fromPlain(gpa, data, count, type_len),
        }
    }

    fn deinit(self: *Dicts) void {
        if (self.string) |*d| d.deinit();
        if (self.int32) |*d| d.deinit();
        if (self.int64) |*d| d.deinit();
        if (self.float32) |*d| d.deinit();
        if (self.float64) |*d| d.deinit();
        if (self.int96) |*d| d.deinit();
        if (self.fixed) |*d| d.deinit();
    }

    const Refs = struct {
        string: ?*dictionary.StringDictionary,
        int32: ?*dictionary.Int32Dictionary,
        int64: ?*dictionary.Int64Dictionary,
        float32: ?*dictionary.Float32Dictionary,
        float64: ?*dictionary.Float64Dictionary,
        int96: ?*dictionary.Int96Dictionary,
        fixed: ?*dictionary.FixedByteArrayDictionary,
    };

    fn refs(self: *Dicts) Refs {
        return .{
            .string = if (self.string) |*d| d else null,
            .int32 = if (self.int32) |*d| d else null,
            .int64 = if (self.int64) |*d| d else null,
            .float32 = if (self.float32) |*d| d else null,
            .float64 = if (self.float64) |*d| d else null,
            .int96 = if (self.int96) |*d| d else null,
            .fixed = if (self.fixed) |*d| d else null,
        };
    }
};

pub fn run(gpa: Allocator, bytes: []const u8, fb: *common.Feedback) !void {
    var in: common.Input = .{ .bytes = bytes };
    const physical = physicals[in.below(physicals.len)];
    const type_len = 1 + in.below(32);
    const value_enc = value_encodings[in.below(value_encodings.len)];
    const flags = in.byte();
    const max_def: u8 = @truncate(in.below(4)); // < 4 by construction
    const max_rep: u8 = @truncate(in.below(3)); // < 3 by construction
    const num_values = in.below(4097);
    const def_enc: format.Encoding = if (flags & 0x01 != 0) .bit_packed else .rle;
    const rep_enc: format.Encoding = if (flags & 0x02 != 0) .bit_packed else .rle;
    const is_v2 = flags & 0x04 != 0;
    const uses_dict = flags & 0x08 != 0;

    var dicts: Dicts = .{};
    defer dicts.deinit();
    if (uses_dict) {
        const dict_count = in.below(257);
        const dict_len = in.below(4097);
        try dicts.build(gpa, physical, take(&in, dict_len), dict_count, type_len);
    }
    const r = dicts.refs();

    const schema: format.SchemaElement = .{
        .type_ = physical,
        .type_length = if (physical == .fixed_len_byte_array) @as(i32, @intCast(type_len)) else null, // 1..32 by construction
        .repetition_type = if (max_def > 0) .optional else .required,
        .name = "c",
    };

    if (is_v2) {
        // V2 levels are always RLE without a length prefix, so bits 0-1 of flags do not apply.
        const rep_len = in.below(1025);
        const def_len = in.below(1025);
        const rep = take(&in, rep_len);
        const def = take(&in, def_len);
        const values = in.rest();
        var result = try column_decoder.decodeColumnDynamicV2(gpa, schema, rep, def, values, num_values, max_def, max_rep, uses_dict, r.string, r.int32, r.int64, r.float32, r.float64, r.fixed, r.int96, value_enc);
        defer result.deinit(gpa);
        fb.rows = result.values.len;
    } else {
        const page = in.rest();
        var result = try column_decoder.decodeColumnDynamicWithValueEncoding(gpa, schema, page, num_values, max_def, max_rep, uses_dict, r.string, r.int32, r.int64, r.float32, r.float64, r.fixed, r.int96, def_enc, rep_enc, value_enc);
        defer result.deinit(gpa);
        fb.rows = result.values.len;
    }
}

// ---------------------------------------------------------------------------------------------
// gen-seeds: recipes whose page data comes from the library's own encoders.

const Pair = struct { p: format.PhysicalType, e: format.Encoding };

/// (type, encoding) pairs the decoder supports, each written as a V1 and a V2 recipe.
const seed_pairs = [_]Pair{
    .{ .p = .boolean, .e = .plain },
    .{ .p = .boolean, .e = .rle },
    .{ .p = .int32, .e = .plain },
    .{ .p = .int32, .e = .rle_dictionary },
    .{ .p = .int32, .e = .delta_binary_packed },
    .{ .p = .int32, .e = .byte_stream_split },
    .{ .p = .int64, .e = .plain },
    .{ .p = .int64, .e = .rle_dictionary },
    .{ .p = .int64, .e = .delta_binary_packed },
    .{ .p = .int64, .e = .byte_stream_split },
    .{ .p = .int96, .e = .plain },
    .{ .p = .int96, .e = .rle_dictionary },
    .{ .p = .float, .e = .plain },
    .{ .p = .float, .e = .rle_dictionary },
    .{ .p = .float, .e = .byte_stream_split },
    .{ .p = .double, .e = .plain },
    .{ .p = .double, .e = .rle_dictionary },
    .{ .p = .double, .e = .byte_stream_split },
    .{ .p = .byte_array, .e = .plain },
    .{ .p = .byte_array, .e = .rle_dictionary },
    .{ .p = .byte_array, .e = .delta_length_byte_array },
    .{ .p = .byte_array, .e = .delta_byte_array },
    .{ .p = .fixed_len_byte_array, .e = .plain },
    .{ .p = .fixed_len_byte_array, .e = .rle_dictionary },
    .{ .p = .fixed_len_byte_array, .e = .byte_stream_split },
};

const n_seed = 16; // values per seed
const flba_len = 4; // FIXED_LEN_BYTE_ARRAY width used by seeds

fn indexOf(comptime T: type, list: []const T, v: T) usize {
    for (list, 0..) |x, i| if (x == v) return i;
    unreachable; // every caller passes a member of `list`
}

fn put2(a: Allocator, out: *std.ArrayList(u8), v: usize) !void {
    const b: [2]u8 = .{ @truncate(v), @truncate(v >> 8) };
    try out.appendSlice(a, &b);
}

/// The 16 values of a pair, as the typed slices the library encoders take.
const Samples = struct {
    bools: [n_seed]bool = undefined,
    i32s: [n_seed]i32 = undefined,
    i64s: [n_seed]i64 = undefined,
    f32s: [n_seed]f32 = undefined,
    f64s: [n_seed]f64 = undefined,
    strs: [n_seed][]const u8 = undefined,
    fixed: [n_seed][flba_len]u8 = undefined,
    int96: [n_seed * 12]u8 = undefined,

    fn init(a: Allocator) !Samples {
        var s: Samples = .{};
        for (0..n_seed) |i| {
            s.bools[i] = i % 3 == 0;
            s.i32s[i] = @as(i32, @intCast(i)) * 37 - 200; // i < 16 by construction
            s.i64s[i] = @as(i64, @intCast(i)) * 1_000_000_007 - 5;
            s.f32s[i] = @as(f32, @floatFromInt(i)) * 1.5 - 3;
            s.f64s[i] = @as(f64, @floatFromInt(i)) * -0.25 + 100;
            s.strs[i] = try std.fmt.allocPrint(a, "value-{d:0>2}", .{i});
            s.fixed[i] = .{ @truncate(i), @truncate(i * 3), @truncate(i * 5 + 1), @truncate(0xf0 + i) };
        }
        for (&s.int96, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
        return s;
    }
};

/// PLAIN encoding of all 16 values (for BOOLEAN: bit-packed).
fn plainBytes(a: Allocator, s: *const Samples, p: format.PhysicalType) ![]u8 {
    return switch (p) {
        .boolean => enc.plain_encoder.encodeBooleans(a, &s.bools),
        .int32 => enc.plain_encoder.encodeInt32(a, &s.i32s),
        .int64 => enc.plain_encoder.encodeInt64(a, &s.i64s),
        .int96 => a.dupe(u8, &s.int96),
        .float => enc.plain_encoder.encodeFloat(a, &s.f32s),
        .double => enc.plain_encoder.encodeDouble(a, &s.f64s),
        .byte_array => enc.plain_encoder.encodeByteArrays(a, &s.strs),
        .fixed_len_byte_array => enc.plain_encoder.encodeFixedByteArrays(a, try fixedSlices(a, s), flba_len),
    };
}

fn fixedSlices(a: Allocator, s: *const Samples) ![]const []const u8 {
    const out = try a.alloc([]const u8, n_seed);
    for (out, 0..) |*o, i| o.* = &s.fixed[i];
    return out;
}

/// Page value bytes for a non-PLAIN, non-dictionary encoding.
fn encodedBytes(a: Allocator, s: *const Samples, p: format.PhysicalType, e: format.Encoding) ![]u8 {
    return switch (e) {
        .rle => enc.rle_encoder.encodeBooleans(a, &s.bools),
        .delta_binary_packed => switch (p) {
            .int32 => enc.delta_binary_packed_encoder.encodeInt32(a, &s.i32s),
            .int64 => enc.delta_binary_packed_encoder.encodeInt64(a, &s.i64s),
            else => unreachable, // not a seed pair
        },
        .delta_length_byte_array => enc.delta_length_byte_array_encoder.encode(a, &s.strs),
        .delta_byte_array => enc.delta_byte_array_encoder.encode(a, &s.strs),
        .byte_stream_split => switch (p) {
            .int32 => enc.byte_stream_split_encoder.encodeInt32(a, &s.i32s),
            .int64 => enc.byte_stream_split_encoder.encodeInt64(a, &s.i64s),
            .float => enc.byte_stream_split_encoder.encodeFloat32(a, &s.f32s),
            .double => enc.byte_stream_split_encoder.encodeFloat64(a, &s.f64s),
            .fixed_len_byte_array => enc.byte_stream_split_encoder.encodeFixedByteArray(a, try fixedSlices(a, s), flba_len),
            else => unreachable, // not a seed pair
        },
        else => unreachable, // plain and dictionary are handled by the caller
    };
}

/// One recipe for (p, e) with V1 or V2 layout. All 16 values are defined (max_def = 1).
fn buildSeed(a: Allocator, p: format.PhysicalType, e: format.Encoding, v2: bool) ![]u8 {
    var s = try Samples.init(a);
    var out: std.ArrayList(u8) = .empty;
    const dict = e == .rle_dictionary;

    try put2(a, &out, indexOf(format.PhysicalType, &physicals, p));
    try put2(a, &out, flba_len - 1);
    try put2(a, &out, indexOf(format.Encoding, &value_encodings, e));
    try out.append(a, (if (v2) @as(u8, 0x04) else 0) | (if (dict) @as(u8, 0x08) else 0));
    try put2(a, &out, 1); // max_def
    try put2(a, &out, 0); // max_rep
    try put2(a, &out, n_seed); // num_values

    const plain = try plainBytes(a, &s, p);
    var values: []const u8 = undefined;
    if (dict) {
        // Dictionary = the 16 distinct values in PLAIN form; page = [bit_width] + RLE indices 0..15.
        try put2(a, &out, n_seed); // dict_count
        try put2(a, &out, plain.len); // dict_len
        try out.appendSlice(a, plain);
        var idx: [n_seed]u32 = undefined;
        for (&idx, 0..) |*x, i| x.* = @intCast(i);
        const rle = try enc.rle_encoder.encode(a, &idx, 4);
        const hdr = [_]u8{4};
        values = try std.mem.concat(a, u8, &.{ &hdr, rle });
    } else if (e == .plain) {
        values = plain;
    } else {
        values = try encodedBytes(a, &s, p, e);
    }

    var defs: [n_seed]u32 = @splat(1);
    if (v2) {
        const def_bytes = try enc.rle_encoder.encode(a, &defs, 1);
        try put2(a, &out, 0); // rep_len
        try put2(a, &out, def_bytes.len);
        try out.appendSlice(a, def_bytes);
    } else {
        try out.appendSlice(a, try enc.rle_encoder.encodeLevelsWithLength(a, &defs, 1));
    }
    try out.appendSlice(a, values);
    return out.items;
}

pub fn genSeeds(gpa: Allocator, io: std.Io, dir: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out_dir = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer out_dir.close(io);
    for (seed_pairs) |pair| {
        for ([_]bool{ false, true }) |v2| {
            // V2 BYTE_STREAM_SPLIT is not wired for FIXED_LEN_BYTE_ARRAY (UnsupportedEncoding); V1 is.
            if (v2 and pair.p == .fixed_len_byte_array and pair.e == .byte_stream_split) continue;
            const bytes = try buildSeed(a, pair.p, pair.e, v2);
            const name = try std.fmt.allocPrint(a, "gen-{s}-{s}{s}.bin", .{ @tagName(pair.p), @tagName(pair.e), if (v2) "-v2" else "" });
            try out_dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        }
    }
}
