//! zig-parquet fuzz harness: one executable, one `runOne` per target (see HARDENING.md "Fuzzing").
//!
//!   zp-fuzz <target> replay <file|dir>...
//!   zp-fuzz <target> run <N|Ns> [--corpus <dir>...] --out <dir> [--seed N] [--max-len N]
//!   zp-fuzz gen-seeds [<corpus-root>]
//!
//! A returned error is a pass; a panic, hang, leak or allocation over the cap is a finding. The
//! same `runOne` backs the std.testing.fuzz tests at the bottom (`zig build fuzz-cov --fuzz=N`,
//! Linux/macOS) and the corpus replay in `zig build test`.
const std = @import("std");
const common = @import("common.zig");
const t_file = @import("t_file.zig");
const t_page = @import("t_page.zig");
const t_encoding = @import("t_encoding.zig");
const t_thrift = @import("t_thrift.zig");
const t_codec = @import("t_codec.zig");

const Allocator = std.mem.Allocator;
pub const Feedback = common.Feedback;

pub const Target = enum { file, @"file-oom", page, encoding, thrift, codec };

/// Seed directories (relative to zig-parquet/), one level each: listInputs does not recurse.
pub const seed_dirs = [_][]const u8{
    "../test-files-wild",                          "../test-files-wild/parquet-testing/data",
    "../test-files-wild/parquet-testing/bad_data", "../test-files-wild/parquet-testing/data/geospatial",
    "../test-files-arrow/basic",                   "../test-files-arrow/compression",
    "../test-files-arrow/edge_cases",              "../test-files-arrow/encodings",
    "../test-files-arrow/interop",                 "../test-files-arrow/logical_types",
    "../test-files-arrow/multipage",               "../test-files-arrow/nested",
    "../test-files-arrow/structure",
};

/// Regression/generated inputs live in `<corpus_root>/<target>/*.bin` (raw, target format).
pub const corpus_root = "fuzz/corpus";

/// Inputs over this size are skipped (replay) or never produced (run).
pub const max_input_len: usize = 64 << 10;
/// Live bytes one input may allocate before it counts as an OOM finding.
pub var alloc_cap: usize = 256 << 20;
/// Print the error return trace of a rejected input (set by single-file replay).
var explain = false;
/// In-memory corpus cap for `run`; past it, new signatures are still counted but not kept.
const max_corpus = 1 << 14;

// ---------------------------------------------------------------------------------------------
// Allocation cap + per-input leak check.

const CountingAllocator = struct {
    parent: Allocator,
    live: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn charge(self: *CountingAllocator, old: usize, new: usize) void {
        if (new > old and self.live + (new - old) > alloc_cap)
            std.debug.panic("fuzz-oom: allocation of {d} bytes with {d} live exceeds cap {d}", .{ new - old, self.live, alloc_cap });
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.charge(0, len);
        const p = self.parent.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.charge(m.len, n);
        if (!self.parent.rawResize(m, a, n, ra)) return false;
        self.live = self.live - m.len + n;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.charge(m.len, n);
        const p = self.parent.rawRemap(m, a, n, ra) orelse return null;
        self.live = self.live - m.len + n;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

/// Runs one input against `target`. Panics (= finding) on leaks, cap overruns and broken
/// invariants; library errors are returned in the feedback.
pub fn runOne(target: Target, parent: Allocator, bytes: []const u8) Feedback {
    var counting: CountingAllocator = .{ .parent = parent };
    const gpa = counting.allocator();
    var fb: Feedback = .{};
    const result = switch (target) {
        .file => t_file.run(gpa, bytes, &fb, false),
        .@"file-oom" => t_file.run(gpa, bytes, &fb, true),
        .page => t_page.run(gpa, bytes, &fb),
        .encoding => t_encoding.run(gpa, bytes, &fb),
        .thrift => t_thrift.run(gpa, bytes, &fb),
        .codec => t_codec.run(gpa, bytes, &fb),
    };
    result catch |e| {
        fb.err = e;
        // Single-file replay: show where the input was rejected (compat-gap triage).
        if (explain) if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    };
    if (counting.live != 0) std.debug.panic("fuzz-leak: {d} bytes still allocated after the input", .{counting.live});
    return fb;
}

// ---------------------------------------------------------------------------------------------
// Seeds.

/// Turns a seed file into an input for `target`, or null if it does not apply.
/// .parquet seeds: file/file-oom take the bytes as they are (file-oom prepends two 0xff bytes =
/// no injected failure); thrift takes the footer (bytes between the 4-byte length and "PAR1")
/// with the prefix `ff ff 00 00` (no failure, which = FileMetaData); others skip.
/// .bin files (fuzz/corpus/<target>/) are already in target format.
/// Valid files that legitimately need more than the 256 MiB live-allocation cap (a decompressed
/// chunk over 2 GiB). They would trip `fuzz-oom` on the seed itself, so they are not seeds.
/// ponytail: name list; replace with reader allocation limits if D5 lands.
const oversized_seeds = [_][]const u8{"large_string_map.brotli.parquet"};

fn adaptSeed(target: Target, name: []const u8, bytes: []const u8, out: Allocator) !?[]const u8 {
    for (oversized_seeds) |skip| if (std.mem.eql(u8, std.fs.path.basename(name), skip)) return null;
    if (std.mem.endsWith(u8, name, ".bin")) return try out.dupe(u8, bytes);
    if (!std.mem.endsWith(u8, name, ".parquet")) return null;
    switch (target) {
        .file => return try out.dupe(u8, bytes),
        .@"file-oom" => return try std.mem.concat(out, u8, &.{ &.{ 0xff, 0xff }, bytes }),
        .thrift => {
            if (bytes.len < 12 or !std.mem.eql(u8, bytes[bytes.len - 4 ..], "PAR1")) return null;
            const flen: usize = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
            if (flen > bytes.len - 12) return null;
            const footer = bytes[bytes.len - 8 - flen ..][0..flen];
            return try std.mem.concat(out, u8, &.{ &.{ 0xff, 0xff, 0x00, 0x00 }, footer });
        },
        .page, .encoding, .codec => return null,
    }
}

pub const SeedFormat = enum { raw, smith_encoded };

/// Every adapted seed for `target`: fuzz/corpus/<target>/*.bin first, then `seed_dirs`. Missing
/// directories and unreadable or oversized files are skipped. `smith_encoded` prefixes each seed
/// with its u32 LE length (the byte stream a single `smith.slice()` consumes).
pub fn loadSeeds(a: Allocator, io: std.Io, target: Target, format: SeedFormat) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    const own_dir = try std.fs.path.join(a, &.{ corpus_root, @tagName(target) });
    listInputs(a, io, own_dir, &paths) catch {};
    for (seed_dirs) |d| listInputs(a, io, d, &paths) catch {};
    var seeds: std.ArrayList([]const u8) = .empty;
    for (paths.items) |path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_input_len)) catch continue;
        const adapted = (try adaptSeed(target, std.fs.path.basename(path), raw, a)) orelse continue;
        if (adapted.len > max_input_len) continue;
        switch (format) {
            .raw => try seeds.append(a, adapted),
            .smith_encoded => {
                const len: u32 = std.math.cast(u32, adapted.len) orelse continue;
                try seeds.append(a, try std.mem.concat(a, u8, &.{ std.mem.asBytes(&std.mem.nativeToLittle(u32, len)), adapted }));
            },
        }
    }
    return seeds.items;
}

// ---------------------------------------------------------------------------------------------
// Mutation engine (libFuzzer-style mutators; corpus grows on new Feedback signatures).

const tokens = [_][]const u8{
    "PAR1",
    "\x15\x00",
    "\x15\x02",
    "\x16\x00",
    "\x19\x1c",
    "\x00",
    &@as([4]u8, @splat(0xff)),
    "\x00\x00\x00\x00",
};
const interesting = [_]u64{ 0, 1, 2, 4, 8, 16, 32, 64, 127, 128, 255, 256, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fffffff, 0x80000000, 0xffffffff, 0x7fffffffffffffff, 0x8000000000000000, std.math.maxInt(u64) };

fn mutate(rng: std.Random, gpa: Allocator, buf: *std.ArrayList(u8), corpus: []const []const u8, max_len: usize) !void {
    const rounds = 1 + rng.uintLessThan(usize, 5);
    for (0..rounds) |_| {
        const len = buf.items.len;
        switch (rng.uintLessThan(u8, 11)) {
            0 => if (len > 0) { // erase a range
                const at = rng.uintLessThan(usize, len);
                const n = 1 + rng.uintLessThan(usize, @min(len - at, 64));
                buf.replaceRangeAssumeCapacity(at, n, &.{});
            },
            1 => if (len < max_len) { // insert random bytes
                const at = rng.uintAtMost(usize, len);
                var tmp: [16]u8 = undefined;
                const n = 1 + rng.uintLessThan(usize, @min(tmp.len, max_len - len));
                rng.bytes(tmp[0..n]);
                try buf.insertSlice(gpa, at, tmp[0..n]);
            },
            2 => if (len > 0) { // flip a bit
                buf.items[rng.uintLessThan(usize, len)] ^= @as(u8, 1) << rng.int(u3);
            },
            3 => if (len > 0) { // random byte
                buf.items[rng.uintLessThan(usize, len)] = rng.int(u8);
            },
            4, 5 => if (len > 0) { // arithmetic / interesting value at width 1/2/4/8
                const width = @as(usize, 1) << rng.int(u2);
                if (len < width) continue;
                const at = rng.uintAtMost(usize, len - width);
                var v: u64 = 0;
                @memcpy(std.mem.asBytes(&v)[0..width], buf.items[at..][0..width]);
                v = if (rng.boolean())
                    interesting[rng.uintLessThan(usize, interesting.len)]
                else
                    v +% @as(u64, @bitCast(@as(i64, rng.intRangeAtMost(i8, -35, 35))));
                if (rng.boolean()) v = @byteSwap(v) >> @intCast(64 - 8 * width);
                @memcpy(buf.items[at..][0..width], std.mem.asBytes(&v)[0..width]);
            },
            6 => if (len > 1) { // copy a chunk over another place
                const from = rng.uintLessThan(usize, len);
                const to = rng.uintLessThan(usize, len);
                const n = 1 + rng.uintLessThan(usize, @min(len - @max(from, to), 128));
                std.mem.copyForwards(u8, buf.items[to..][0..n], buf.items[from..][0..n]);
            },
            7, 8 => { // dictionary token, overwrite or insert
                const tok = tokens[rng.uintLessThan(usize, tokens.len)];
                const at = rng.uintAtMost(usize, len);
                if (rng.boolean() and at + tok.len <= len) {
                    @memcpy(buf.items[at..][0..tok.len], tok);
                } else if (len + tok.len <= max_len) try buf.insertSlice(gpa, at, tok);
            },
            9 => if (corpus.len > 0) { // splice with another corpus entry
                const other = corpus[rng.uintLessThan(usize, corpus.len)];
                const cut = rng.uintAtMost(usize, len);
                const from = rng.uintAtMost(usize, other.len);
                buf.shrinkRetainingCapacity(cut);
                try buf.appendSlice(gpa, other[from..@min(other.len, from + (max_len - cut))]);
            },
            else => if (len > 0) { // repeat a byte
                const at = rng.uintLessThan(usize, len);
                const n = rng.uintLessThan(usize, @min(64, max_len - @min(max_len, len)) + 1);
                try buf.appendNTimes(gpa, buf.items[at], n);
            },
        }
    }
}

fn hexName(bytes: []const u8) [16]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

// ---------------------------------------------------------------------------------------------
// CLI.

/// Path of the input being replayed, printed by the panic handler so a crash names its file.
var current_path: []const u8 = "";
/// Executions so far; the watchdog calls a hang when it stops moving for `hang_seconds`.
var progress = std.atomic.Value(u64).init(0);
var hang_seconds: u64 = 10;

fn watchdog(io: std.Io) void {
    var last = progress.load(.monotonic);
    var still: u64 = 0;
    while (true) {
        io.sleep(.fromNanoseconds(1_000_000_000), .awake) catch return;
        const now = progress.load(.monotonic);
        still = if (now == last) still + 1 else 0;
        last = now;
        if (still >= hang_seconds) {
            std.debug.print("fuzz-hang: one input ran for over {d}s: {s}\n", .{ hang_seconds, if (current_path.len > 0) current_path else "<out>/current.bin" });
            std.process.exit(77);
        }
    }
}
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ra: ?usize) noreturn {
        if (current_path.len > 0) std.debug.print("fuzz: crashing input: {s}\n", .{current_path});
        std.debug.defaultPanic(msg, ra);
    }
}.f);

fn usage() noreturn {
    std.debug.print(
        \\usage: zp-fuzz <target> replay <file|dir>...
        \\       zp-fuzz <target> run <iters|secs s> [--corpus <dir>...] --out <dir> [--seed N] [--max-len N] [--alloc-cap N] [--timeout S]
        \\       zp-fuzz gen-seeds [<corpus-root>]
        \\targets: file file-oom page encoding thrift codec
        \\
    , .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--timeout") and i + 1 < argv.len) {
            i += 1;
            hang_seconds = std.fmt.parseInt(u64, argv[i], 10) catch usage();
        } else try args.append(arena, argv[i]);
    }
    if (args.items.len < 2) usage();
    if (std.mem.eql(u8, args.items[1], "gen-seeds")) return genSeeds(gpa, io, if (args.items.len > 2) args.items[2] else corpus_root);
    if (args.items.len < 3) usage();
    const target = std.meta.stringToEnum(Target, args.items[1]) orelse usage();
    (try std.Thread.spawn(.{}, watchdog, .{io})).detach();
    if (std.mem.eql(u8, args.items[2], "replay")) return replay(gpa, io, target, args.items[3..]);
    if (std.mem.eql(u8, args.items[2], "run")) return run(gpa, io, target, args.items[3..]);
    usage();
}

/// Files directly under `path` (or `path` itself), sorted for a stable order. In directories only
/// `.parquet` and `.bin` files count.
fn listInputs(a: Allocator, io: std.Io, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => return out.append(a, path),
        else => return e,
    };
    defer dir.close(io);
    const start = out.items.len;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".parquet") and !std.mem.endsWith(u8, entry.name, ".bin")) continue;
        try out.append(a, try std.fs.path.join(a, &.{ path, entry.name }));
    }
    std.mem.sort([]const u8, out.items[start..], {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
}

fn replay(gpa: Allocator, io: std.Io, target: Target, paths: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    for (paths) |p| try listInputs(a, io, p, &files);
    var ok: usize = 0;
    var errors: usize = 0;
    var skipped: usize = 0;
    explain = files.items.len == 1;
    for (files.items) |path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input_len)) catch |e| {
            std.debug.print("skip {s}: {s}\n", .{ path, @errorName(e) });
            skipped += 1;
            continue;
        };
        defer gpa.free(raw);
        // .parquet files are adapted like seeds; .bin files are already target format.
        const bytes = (try adaptSeed(target, std.fs.path.basename(path), raw, a)) orelse {
            skipped += 1;
            continue;
        };
        current_path = path;
        const fb = runOne(target, gpa, bytes);
        _ = progress.fetchAdd(1, .monotonic);
        current_path = "";
        if (fb.err != null) errors += 1 else ok += 1;
        if (files.items.len == 1) std.debug.print("{s}: {s}, {d} rows\n", .{ path, if (fb.err) |e| @errorName(e) else "ok", fb.rows });
    }
    std.debug.print("{s}: replayed {d} inputs ({d} ok, {d} rejected, {d} skipped), no crash\n", .{ @tagName(target), ok + errors, ok, errors, skipped });
}

fn run(gpa: Allocator, io: std.Io, target: Target, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (args.len < 1) usage();
    const budget = args[0];
    const by_time = std.mem.endsWith(u8, budget, "s");
    const limit = std.fmt.parseInt(u64, if (by_time) budget[0 .. budget.len - 1] else budget, 10) catch usage();
    var out_dir: ?[]const u8 = null;
    var seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .real).toNanoseconds())));
    var max_len: usize = max_input_len;
    var corpus_paths: std.ArrayList([]const u8) = .empty;
    var explicit_corpus = false;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--corpus")) {
            explicit_corpus = true;
            listInputs(a, io, v, &corpus_paths) catch |e| std.debug.print("corpus {s}: {s}\n", .{ v, @errorName(e) });
        } else if (std.mem.eql(u8, args[i], "--out")) {
            out_dir = v;
        } else if (std.mem.eql(u8, args[i], "--seed")) {
            seed = std.fmt.parseInt(u64, v, 10) catch usage();
        } else if (std.mem.eql(u8, args[i], "--max-len")) {
            max_len = @min(std.fmt.parseInt(usize, v, 10) catch usage(), max_input_len);
        } else if (std.mem.eql(u8, args[i], "--alloc-cap")) {
            alloc_cap = std.fmt.parseInt(usize, v, 10) catch usage();
        } else usage();
    }
    const out = out_dir orelse usage();
    const cwd = std.Io.Dir.cwd();
    const grow_dir = try std.fs.path.join(a, &.{ out, "corpus" });
    try cwd.createDirPath(io, grow_dir);
    try listInputs(a, io, grow_dir, &corpus_paths);
    const current = try cwd.createFile(io, try std.fs.path.join(a, &.{ out, "current.bin" }), .{ .truncate = true });
    defer current.close(io);
    var out_handle = try cwd.openDir(io, out, .{});
    defer out_handle.close(io);

    // Seeds: explicit --corpus dirs, else fuzz/corpus/<target> plus seed_dirs (adapted); then
    // what earlier runs grew into <out>/corpus. Inputs that crashed before (<out>/skip/<hash>) are skipped.
    var inputs: std.ArrayList([]const u8) = .empty;
    if (!explicit_corpus) try inputs.appendSlice(a, try loadSeeds(a, io, target, .raw));
    for (corpus_paths.items) |path| {
        const bytes = cwd.readFileAlloc(io, path, a, .limited(max_len)) catch continue;
        try inputs.append(a, bytes);
    }
    var corpus: std.ArrayList([]const u8) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (inputs.items) |bytes| {
        if (bytes.len > max_len) continue;
        const hex = hexName(bytes);
        const crash_name = try std.fmt.allocPrint(a, "skip/{s}", .{&hex});
        if (out_handle.statFile(io, crash_name, .{})) |_| {
            std.debug.print("skipping known crasher {s}\n", .{&hex});
            continue;
        } else |_| {}
        try current.writePositionalAll(io, bytes, 0);
        try current.setLength(io, bytes.len);
        const fb = runOne(target, gpa, bytes);
        _ = progress.fetchAdd(1, .monotonic);
        try seen.put(a, fb.sig(), {});
        try corpus.append(a, bytes);
    }
    if (corpus.items.len == 0) try corpus.append(a, "");
    std.debug.print("{s}: seed {d}, {d} corpus inputs, {d} signatures\n", .{ @tagName(target), seed, corpus.items.len, seen.count() });

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake);
    var iters: u64 = 0;
    while (true) : (iters += 1) {
        if (iters % 256 == 0) {
            const elapsed: u64 = std.math.cast(u64, start.durationTo(std.Io.Timestamp.now(io, .awake)).toSeconds()) orelse 0;
            if ((by_time and elapsed >= limit) or (!by_time and iters >= limit)) break;
            if (iters % (1 << 14) == 0 and iters > 0)
                std.debug.print("#{d} {d}s corpus {d} signatures {d}\n", .{ iters, elapsed, corpus.items.len, seen.count() });
        } else if (!by_time and iters >= limit) break;

        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, corpus.items[rng.uintLessThan(usize, corpus.items.len)]);
        try mutate(rng, gpa, &buf, corpus.items, max_len);
        try current.writePositionalAll(io, buf.items, 0);
        try current.setLength(io, buf.items.len);
        const fb = runOne(target, gpa, buf.items);
        _ = progress.fetchAdd(1, .monotonic);
        const gop = try seen.getOrPut(a, fb.sig());
        // ponytail: fixed corpus cap; signature-based growth has no coverage to prune with.
        if (gop.found_existing or corpus.items.len >= max_corpus) continue;
        const copy = try a.dupe(u8, buf.items);
        try corpus.append(a, copy);
        const hex = hexName(copy);
        const name = try std.fmt.allocPrint(a, "{s}.bin", .{&hex});
        var dir = try cwd.openDir(io, grow_dir, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = name, .data = copy });
    }
    std.debug.print("{s}: done, {d} execs, corpus {d}, {d} signatures\n", .{ @tagName(target), iters, corpus.items.len, seen.count() });
}

/// `gen-seeds [root]`: each target that can synthesize seeds from the library's own encoders
/// writes them under <root>/<target>/. Add a target here when its task adds a `genSeeds`.
fn genSeeds(gpa: Allocator, io: std.Io, root: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const page_dir = try std.fs.path.join(a, &.{ root, "page" });
    try cwd.createDirPath(io, page_dir);
    try t_page.genSeeds(gpa, io, page_dir);
    const codec_dir = try std.fs.path.join(a, &.{ root, "codec" });
    try cwd.createDirPath(io, codec_dir);
    try t_codec.genSeeds(gpa, io, codec_dir);
}

// ---------------------------------------------------------------------------------------------
// std.testing.fuzz entry points: `zig build fuzz-cov --fuzz=N` (coverage-guided, Linux/macOS).
// Under plain `zig build test` each runs once per seed and on empty input.

fn fuzzOne(target: Target, smith: *std.testing.Smith) anyerror!void {
    const S = struct {
        var buf: [max_input_len]u8 = undefined;
    };
    const n = smith.slice(&S.buf);
    _ = runOne(target, std.testing.allocator, S.buf[0..n]);
}

fn fuzzTarget(target: Target) !void {
    // Seeds live for the whole process (the fuzzer may keep them): page_allocator, never freed.
    // ponytail: process-lifetime seeds, a few MB.
    const seeds = try loadSeeds(std.heap.page_allocator, std.testing.io, target, .smith_encoded);
    try std.testing.fuzz(target, fuzzOne, .{ .corpus = seeds });
}

test "fuzz file" {
    try fuzzTarget(.file);
}

test "fuzz file-oom" {
    try fuzzTarget(.@"file-oom");
}

test "fuzz page" {
    try fuzzTarget(.page);
}

test "fuzz encoding" {
    try fuzzTarget(.encoding);
}

test "fuzz thrift" {
    try fuzzTarget(.thrift);
}

test "fuzz codec" {
    try fuzzTarget(.codec);
}

// Every line of corpus/expected.txt names a raw input and the exact outcome `runOne` must give.
test "fuzz corpus expectations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, corpus_root ++ "/expected.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const path = fields.next() orelse continue;
        const want = fields.next() orelse return error.BadExpectation;
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.BadExpectation;
        const target = std.meta.stringToEnum(Target, path[0..slash]) orelse return error.BadExpectation;
        const full = try std.fs.path.join(gpa, &.{ corpus_root, path });
        defer gpa.free(full);
        const bytes = try cwd.readFileAlloc(io, full, gpa, .limited(max_input_len));
        defer gpa.free(bytes);
        const fb = runOne(target, gpa, bytes);
        const ok = if (std.mem.eql(u8, want, "ok"))
            fb.err == null
        else if (std.mem.eql(u8, want, "error"))
            fb.err != null
        else if (std.mem.startsWith(u8, want, "error."))
            if (fb.err) |e| std.mem.eql(u8, @errorName(e), want["error.".len..]) else false
        else
            return error.BadExpectation;
        if (!ok) {
            std.debug.print("expected.txt: {s}: wanted {s}, got {s}\n", .{ path, want, if (fb.err) |e| @errorName(e) else "ok" });
            return error.UnexpectedOutcome;
        }
    }
}
