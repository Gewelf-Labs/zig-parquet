# Plan: faster read/write paths, one tree for Zig 0.16 and 0.17

Design: `docs/superpowers/specs/2026-10-30-perf-dual-zig-design.md` (read §2, §4.2 and §6 before any task).
Baseline: `bench/BASELINE.md` (repo root).

Phases: **0** owner decision → **1** dual-version compat → **2** read path → **3** write path → **4** docs/CI.
Each phase ends with a verification gate and can be reviewed and merged on its own.

---

## Implementer rules (read fully before your first task)

### R0. Scope

- Do only the task you were given. Edit only the files it names. If a correct fix needs a file that
  is not listed, **stop and ask**.
- Line numbers are approximate (verified on base 38dec45 + 341baeb). Find code by **function name**,
  then confirm the "before" snippet matches exactly. If it does not match, **stop and ask**.
- One task = one commit. Message: `<area>: <what>` (e.g. `compat: replace ** with @splat in src/core`,
  `perf(read): word-at-a-time bit unpack`). For perf tasks, put the bench before/after numbers for the
  target scenario in the commit body.

### R1. Toolchains and commands (Windows, run from the repo root, never `cd` into subdirs)

```
Z16 = C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe     # 0.16.0
Z17 = zig                                                        # 0.17.0 on PATH
```

Once task 1.1 has landed, use these commands. The Makefile picks a separate cache for 0.17
automatically.

```
make test-lib CODECS=zig-only ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe
make test-lib CODECS=zig-only ZIG=zig
make test-cli CODECS=zig-only ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe
make test-cli CODECS=zig-only ZIG=zig
make wasm ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe
make wasm ZIG=zig
make bench ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe     # perf tasks only; machine idle
zig ast-check <file.zig>                                                   # 0.17 parse check of one file
```

Before 1.1 lands, use the subshell form, exactly like this (never a bare `cd`):
`(cd zig-parquet && C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe build test -Dcodecs=zig-only)`
and for 0.17 `(cd zig-parquet && zig build test -Dcodecs=zig-only --cache-dir ../.zig17/cache)`.

- **Always** pass `CODECS=zig-only`. C codec tarballs cannot be fetched on this machine.
- 0.17 must never share `.zig-cache` with 0.16. The Makefile handles this; with raw commands, always
  pass `--cache-dir ../.zig17/cache` (short path; long paths hit Windows MAX_PATH).
- Baseline: 858/858 library tests pass on 0.16 with `zig-only`. "Tests pass" means that same count or
  higher, with no new skips.

### R2. Zig 0.16 API gotchas (from AGENTS.md)

- `std.ArrayList(T)`: init with `.empty`, pass the allocator to every method (`append(gpa, x)`,
  `deinit(gpa)`, `toOwnedSlice(gpa)`). `std.ArrayListUnmanaged(T)` is the same type family.
- I/O goes through `std.Io` (`io` parameter; tests use `std.testing.io`). In-memory writers:
  `std.Io.Writer.Allocating`.
- `arena.reset(.free_all)` / `arena.reset(.retain_capacity)`, never `reset()`.
- Enums from ints: `std.enums.fromInt(E, v) orelse return error.X`.
- Tests use `std.testing.allocator`, which detects leaks and double frees. Never switch a test to
  another allocator to make it pass.

### R3. Dual-version rules (0.16 **and** 0.17 must both compile every line)

| never write | write instead |
|---|---|
| `[_]T{v} ** n`, `.{v} ** n` | `@as([n]T, @splat(v))`, or `var a: [n]T = @splat(v);` |
| `"abc" ** n` | `comptime repeat.bytes("abc", n)` (`src/repeat.zig`) |
| `@cImport` / `@cInclude` | hand-written `const c = struct { extern fn ...; }` |
| `allocator.dupeZ(u8, x)` | `allocator.dupeSentinel(u8, x, 0)` |
| `std.hash.crc.Crc32`, `crc.@"CRC-32/ISO-HDLC"` | `std.hash.Crc32` |
| `b.args` / `run.addPassthruArgs()` in build.zig | `passArgs(b, run)` helper (task 1.2) |
| `@backingInt`, `@fromBackingInt` | `@intFromEnum`, `@enumFromInt` |
| `allocator.print(...)`, `allocator.printSentinel(...)` | `std.fmt.allocPrint(...)`, `std.fmt.allocPrintSentinel(...)` |
| `std.heap.SafeAllocator`, `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator(.{})` |
| `std.meta.fields`, `std.meta.Int`, `std.meta.Tag` (new uses) | explicit types / `switch (T)` |

- **`zig fmt` only with 0.16** (`make fmt ZIG=<Z16>`). 0.17's fmt rewrites builtins to 0.17-only
  spellings. Do not let an editor format with 0.17.
- Do not follow the `zig-0-17` skill or main's 0.17-only code for spellings. Use the table above.
- Version gates (`builtin.zig_version`) are **not** allowed in `src/`. If you hit a 0.16/0.17
  difference not in the table, **stop and ask**.

### R4. Hardening rules (HARDENING.md, non-negotiable)

- No `@intCast` on anything derived from file data or user input. Use `safe.cast`, `safe.castTo`,
  `safe.slice`, `safe.get`.
- `@truncate` only right after a mask or `& 7`-style reduction, with a comment saying why it fits.
- `catch unreachable` only with an inline comment stating the invariant.
- Checked arithmetic (`std.math.add`/`mul`) for sizes from data.
- A fast path either does **one up-front bounds check per page/run** and then indexes freely, or
  **returns null so the existing general path runs**. Never rely on ReleaseFast removing checks.
- For malformed input, the fast path must produce the same error (or the same lenient result) as the
  old code. When unsure, fall back to the old path.

### R5. Perf-task protocol

1. Before editing, run `make bench ZIG=<Z16>` and note your target scenario's numbers.
2. Make the change and run the tests on both toolchains.
3. Run `make bench ZIG=<Z16>` twice and take the best per cell.
4. Acceptance = the stated improvement on the target scenario (±10% noise band), **no scenario more
   than 5% slower**, and `file_MB` unchanged for every scenario (proves identical output size).
5. If the target does not move, **stop and report**. Do not keep the change, and do not try other
   optimizations.

### R6. Stop and ask (post the question, do not guess) when

- a test fails and two honest fix attempts did not fix it;
- the "before" snippet does not match the code;
- a change needs a file the task does not list, or changes a `pub` signature not named in the task;
- a write-side change would alter output bytes (a byte-identity test fails or `file_MB` changes);
- the compiler reports a 0.16/0.17 difference not covered by R3;
- a perf task misses its target or regresses another scenario by more than 5%.

### R7. What NOT to do (whole plan)

- No rewrites of `nested.zig`, `assembleNestedRows` phase 1, the list/map/struct writers, or
  `arrow_batch.zig`.
- No new dependencies, no SIMD intrinsics (`@Vector`), no threads.
- No public API breaks. The only allowed public additions are `Row.values_borrowed` (2.4) and
  `RowIterator.arena` (2.5).
- No default changes (CRC, dictionary, row group size, checksum validation) unless the owner approved
  the decision in design §5.4 (D2-D4).
- No "while I'm here" refactors, renames, or comment rewrites in neighboring code.
- No decompression or compressed-codec work: the bench is uncompressed.

### File ownership (who may run in parallel)

Tasks marked **∥** may run at the same time as the other ∥ tasks of the same phase; they touch
disjoint files. Unmarked tasks are sequential in the listed order.

---

## Phase 0: owner decision D0 (blocking)

Choose the base (design §2.3):

- **(a)** Stay on this branch. Do Phase 1 as written below.
- **(b) Recommended:** create a branch from `main`, cherry-pick 341baeb (bench), and do **Appendix B**
  instead of tasks 1.3-1.7. Tasks 1.1, 1.2 and 1.8 still apply. Phases 2-4 are unchanged.

Implementers: do not start Phase 1 until the owner has answered.

---

## Phase 1: dual-version compat (small; unblocks both toolchains)

Until the gate, 0.17 cannot build the whole tree. Per-task acceptance is therefore:
**0.16 tests pass** plus **the 0.17 errors for this task's construct are gone** (checked with
`zig ast-check` for parse errors, or by the compiler output no longer mentioning it).

### Task 1.1 Makefile: `ZIG` variable, per-version cache, fmt guard, bench target

- Files: `Makefile`
- Depends on: none (do it first, alone)
- Change: replace the variable block and recipes as below. Keep `help` and `clean`, and add the new
  variables and target to `help`.

```make
# Toolchain: make <target> ZIG=/path/to/zig   (0.16.x and 0.17.x are supported)
ZIG ?= zig
ZIG_VERSION := $(shell $(ZIG) version)
# Non-0.16 toolchains use their own local cache under <repo>/.zig17 (gitignored).
# $(1) = path from the recipe's working directory back to the repo root.
zcache = $(if $(filter 0.16.%,$(ZIG_VERSION)),,--cache-dir $(1)/.zig17/cache)

lib:       cd $(LIB_DIR) && $(ZIG) build $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)
cli:       cd $(CLI_DIR) && $(ZIG) build $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)
test-lib:  cd $(LIB_DIR) && $(ZIG) build test $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)
test-cli:  cd $(CLI_DIR) && $(ZIG) build test $(call zcache,..) $(CODEC_FLAG) $(OPT_FLAG)
example:   cd $(EXAMPLES_DIR)/$(NAME) && $(ZIG) build $(call zcache,../../..) $(CODEC_FLAG) $(OPT_FLAG)
wasm:      cd $(LIB_DIR) && $(ZIG) build wasm-smoke $(call zcache,..) $(if $(CODECS),$(CODEC_FLAG),-Dcodecs=none)
bench:     cd $(LIB_DIR) && $(ZIG) build bench $(call zcache,..) -Dcodecs=$(or $(CODECS),zig-only) -Doptimize=ReleaseFast
fmt:
	@case "$(ZIG_VERSION)" in 0.16.*) ;; *) echo "make fmt needs Zig 0.16 (0.17 fmt emits 0.17-only builtins): make fmt ZIG=<0.16 zig>"; exit 1;; esac
	$(ZIG) fmt $(LIB_DIR)/src $(LIB_DIR)/build.zig $(LIB_DIR)/bench $(CLI_DIR)/src $(CLI_DIR)/build.zig
```

(Recipes are shown on one line for brevity; keep the existing `.PHONY` + tab-indented style.)
Do **not** add `--prefix`: CLI integration tests run `./zig-out/bin/pqi`.

- Test: `make test-lib CODECS=zig-only ZIG=<Z16>` passes. `make fmt ZIG=zig` prints the refusal and
  exits 1. `make -n test-lib ZIG=zig` shows `--cache-dir ../.zig17/cache`, and
  `make -n test-lib ZIG=<Z16>` shows no `--cache-dir`.
- Acceptance: the above, and `make bench ZIG=<Z16>` reproduces `bench/BASELINE.md` within ±10%.

### Task 1.2 ∥ Build scripts: `passArgs` helper and example `codecs` option

- Files: `zig-parquet/build.zig`, `cli/build.zig`, `zig-parquet/examples/gen-power-grid/build.zig`,
  `zig-parquet/examples/{basic,large_file,wasm_demo}/build.zig`
- Depends on: 1.1
- Change A, in the three files that use `b.args`: replace
  `if (b.args) |args| bench_run.addArgs(args);` (zig-parquet, bench block),
  `if (b.args) |args| { run_cmd.addArgs(args); }` (cli), and
  `if (b.args) |args| { run_read.addArgs(args); }` (gen-power-grid)
  with `passArgs(b, <run var>);`, and append this to the end of each of those files (verified on both
  versions):

```zig
/// Forward `zig build <step> -- args...` on Zig 0.16 (`b.args`) and 0.17 (`addPassthruArgs`).
fn passArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
}
```

- Change B, in examples `basic`, `gen-power-grid`, `large_file` and `wasm_demo` (`wasm_freestanding`
  already has it): add a `codecs` option and forward it, as main 685101e does:

```zig
    const codecs = b.option([]const u8, "codecs", "Compression codecs (default: all). See zig-parquet for values.") orelse "all";
    const parquet_dep = b.dependency("parquet", .{ .target = target, .optimize = optimize, .codecs = codecs });
```

- Test: `(cd zig-parquet && zig build --help --cache-dir ../.zig17/cache)` succeeds (0.17 compiles the
  build script) and the same with Z16 without `--cache-dir`. `make example NAME=basic CODECS=zig-only ZIG=<Z16>` builds.
- Acceptance: both build scripts configure on both versions; 0.16 tests pass.

### Task 1.3 ∥ Copy C bindings and `repeat.zig` from main

- Files: `zig-parquet/src/core/compress/c_{zstd,snappy,lz4,brotli,gzip}.zig`, new `zig-parquet/src/repeat.zig`
- Depends on: 1.1
- Change: these files on main 685101e contain only the binding change, which I reviewed (no 0.17-only
  spellings):

```
git show 685101e:zig-parquet/src/core/compress/c_zstd.zig   > zig-parquet/src/core/compress/c_zstd.zig
git show 685101e:zig-parquet/src/core/compress/c_snappy.zig > zig-parquet/src/core/compress/c_snappy.zig
git show 685101e:zig-parquet/src/core/compress/c_lz4.zig    > zig-parquet/src/core/compress/c_lz4.zig
git show 685101e:zig-parquet/src/core/compress/c_brotli.zig > zig-parquet/src/core/compress/c_brotli.zig
git show 685101e:zig-parquet/src/core/compress/c_gzip.zig   > zig-parquet/src/core/compress/c_gzip.zig
git show 685101e:zig-parquet/src/repeat.zig                 > zig-parquet/src/repeat.zig
```

  Then `git diff -- zig-parquet/src/core/compress/`. Every hunk must be one of: a `@cImport` block
  replaced by `const c = struct {...}`, the `deflateInit2_`/`inflateInit2_` calls (they add
  `zlib_version, @sizeOf(c.z_stream)`), doc-comment wording, or whitespace. Anything else: **stop and ask**.
  Check that line endings did not change (`git diff --stat` should show small counts).
- Test: `zig ast-check` on each of the 6 files (0.17) prints nothing. 0.16 tests pass.
  `C:/.../zig.exe ast-check` on each file prints nothing either.
- Acceptance: the above. Real linkage is proven by the CI `c-only` job (task 4.1).

### Task 1.4 ∥ `**` in library sources → `@splat` / `repeat.bytes`

- Files (every `**` in these): `src/core/compress/{brotli,gzip,lz4,zstd,snappy}.zig`, `src/core/types.zig`,
  `src/core/column_decoder.zig`, `src/core/encoding/delta_binary_packed_encoder.zig`,
  `src/core/page_index_reader.zig`, `src/core/page_range_reader.zig`, `src/core/thrift/compact.zig`,
  `src/api/wasm/freestanding.zig` (all under `zig-parquet/`)
- Depends on: 1.3 (`repeat.zig`)
- Find: `grep -rn " \*\* " zig-parquet/src/core zig-parquet/src/api`
- Change (the same mechanical patterns main used):

```zig
// before                                         // after
var a: [16]u16 = .{0} ** 16;                      var a: [16]u16 = @splat(0);
var h = [_]u32{0} ** 256;                         var h: [256]u32 = @splat(0);
.head = [_]u16{0} ** HASH_SIZE,                   .head = @as([HASH_SIZE]u16, @splat(0)),
Int96.fromBytes([_]u8{0} ** 12)                   Int96.fromBytes(@as([12]u8, @splat(0)))
[_]HandleSlot{.{ .empty = {} }} ** MAX_HANDLES    @as([MAX_HANDLES]HandleSlot, @splat(.{ .empty = {} }))
const original = "abcdefgh" ** 1000;              const original = comptime repeat.bytes("abcdefgh", 1000);
```

  For the string cases, add `const repeat = @import("../../repeat.zig");` at the top of
  `compress/{brotli,lz4,snappy,zstd}.zig`. They are used only in test blocks, but a top-level import
  is fine.
- Test: `zig ast-check` on each touched file (0.17) is clean. 0.16 tests pass.
- Acceptance: `grep -rn " \*\* " zig-parquet/src/core zig-parquet/src/api` returns nothing; tests pass.

### Task 1.5 ∥ `**` in tests

- Files: `zig-parquet/src/tests/{brotli,gzip,lz4,snappy,zstd}_cross_test.zig`, `negative_test.zig`,
  `page_index_test.zig`, `reader_test.zig`, `roundtrip_test.zig`, `interop_pyarrow_test.zig`,
  `writer_logical_test.zig`
- Depends on: 1.3
- Change: same patterns as 1.4, plus `const repeat = @import("../repeat.zig");`. Special shapes:

```zig
&([_]u8{0} ** 16)                 →  &@as([16]u8, @splat(0))
[_]u8{0} ** 15 ++ [_]u8{1}        →  @as([15]u8, @splat(0)) ++ [_]u8{1}
&[_]u8{0} ** 8                    →  &@as([8]u8, @splat(0))
"a]" ** 500,  (array of strings)  →  comptime repeat.bytes("a]", 500),
try zigRoundTrip(a, "AAAA" ** 1000);  →  try zigRoundTrip(a, comptime repeat.bytes("AAAA", 1000));
```

- Test / Acceptance: as 1.4, for `zig-parquet/src/tests`.

### Task 1.6 ∥ `dupeZ` → `dupeSentinel`

- Files: `zig-parquet/src/core/arrow_batch.zig` (47), `src/core/dynamic_writer.zig` (2),
  `src/api/c/handles.zig` (2), `src/api/wasm/handles.zig` (2)
- Depends on: 1.1
- Change: no call has a `)` inside its argument (verified), so a sed is safe:
  `sed -i -E 's/dupeZ\(u8, ([^)]*)\)/dupeSentinel(u8, \1, 0)/g' <the 4 files>`
- Test: `grep -rn dupeZ zig-parquet/src` is empty. 0.16 tests pass.
- Acceptance: the above.

### Task 1.7 ∥ CRC name

- Files: `zig-parquet/src/core/column_writer.zig`, `src/core/dynamic_reader.zig`,
  `src/core/parquet_reader.zig`, `src/tests/checksum_test.zig`
- Depends on: 1.1
- Change: delete each `const crc = std.hash.crc;` and replace `crc.Crc32.hash(` with
  `std.hash.Crc32.hash(`. First check that no other `crc.` use remains in those files.
- Test / Acceptance: `grep -rn "hash.crc" zig-parquet/src` is empty; 0.16 tests pass.

### Task 1.8 Gate 1 (verification)

- Depends on: 1.1-1.7 (or Appendix B)
- Run every R1 command on **both** toolchains: test-lib, test-cli, wasm. Also run
  `make example NAME=wasm_freestanding ZIG=<both>` and `make example NAME=basic CODECS=zig-only ZIG=<both>`.
- Run `make bench` on Z16 **and** on `ZIG=zig`. In `bench/BASELINE.md`, add a `## History` section
  with two tables (write rows/s, read rows/s): rows = scenarios, columns = `baseline`, `P1 (0.16)`,
  `P1 (0.17)`. Later phases append a column.
- Pass criteria: 858/858 on both versions (minus only skips that already exist), CLI tests green on
  both, wasm-smoke green on both, P1 (0.16) bench within ±10% of baseline.
- If anything else fails on 0.17, it is a difference this plan missed: **stop and ask** with the error.

---

## Phase 2: read path (benchmark-guided)

Path under test: `DynamicReader.rowIterator()` → `readRowsInternal` → `readColumnDynamicWithData` →
`column_decoder.*` → row assembly. Expected after Phase 2, vs baseline: int64_plain/f64_plain read
about 3x, int64_nullable about 2.5x, str_* about 2.5x, mixed5 about 3.5x (design §5.4).

### Task 2.1 ∥ R1: word-at-a-time bit unpack + memset RLE fill

- Files: `zig-parquet/src/core/encoding/rle.zig` (`decodeBitPacked`, `decode`)
- Depends on: Gate 1
- Change 1, `decodeBitPacked`: add a fast loop in front of the existing loop, and run the existing
  loop only over the remaining outputs.

```zig
fn decodeBitPacked(data: []const u8, bit_width: u5, output: []u32) !void {
    const mask: u64 = (@as(u64, 1) << bit_width) - 1;
    var bit_pos: usize = 0;
    var i: usize = 0;

    // Fast path: one unaligned 8-byte load per value. A value spans at most
    // 7 (bit offset) + 31 (bit_width) = 38 bits, so it always fits in the word.
    // Runs only while 8 bytes remain; the checked loop below handles the tail.
    if (data.len >= 8) {
        const last_word = data.len - 8;
        while (i < output.len) : (i += 1) {
            const byte_pos = bit_pos >> 3;
            if (byte_pos > last_word) break;
            const word = std.mem.readInt(u64, data[byte_pos..][0..8], .little);
            const shift: u6 = @truncate(bit_pos & 7); // 0..7
            output[i] = @truncate((word >> shift) & mask); // masked to <= 31 bits
            bit_pos += bit_width;
        }
    }

    for (output[i..]) |*out| {
        // ... existing loop body, unchanged (it zero-fills past the end of data) ...
    }
}
```

- Change 2, in `decode`: replace the RLE fill loop with
  `@memset(result[out_idx..][0..values_to_write], value); out_idx += values_to_write;`
  and the trailing `while (out_idx < num_values)` zero fill with `@memset(result[out_idx..], 0);`.
- New tests (bottom of rle.zig):
  1. Round trip for every bit width 1..31 and n in {1,7,8,9,63,64,65,1000}: random values
     `<= (1<<bw)-1` → `@import("rle_encoder.zig").encode` → `decode` → equal.
  2. Truncation, unchanged behavior: `data = {0x05, 1,2,...,12}` (indicator 0x05 = 2 groups = 16 values,
     bit width 8, only 12 payload bytes). `decode(a, &data, 8, 16)` must give `1..12` followed by four `0`.
     Also `data = {0x03, 1,2,3,4}`, n = 8 → `1,2,3,4,0,0,0,0`.
- Test: tests pass on both versions.
- Acceptance: str_dict read +15% or more (dictionary indices, bit width 7); int64_nullable read not slower.

### Task 2.2 ∥ R2: flat PLAIN fixed-width fast path (V1 pages)

- Files: `zig-parquet/src/core/column_decoder.zig`
- Depends on: Gate 1
- Change: add two private functions next to `decodeLevelsForDynamicWithEncoding`:

```zig
/// Fast path for flat PLAIN INT32/INT64/FLOAT/DOUBLE pages: decodes straight into
/// `Value`s with one length check per page. Returns null (caller must use the
/// general path) when levels fail to decode or the page is short, so malformed
/// pages keep their existing errors and lenient behavior.
fn decodeFlatPlainFixed(
    allocator: std.mem.Allocator,
    physical_type: format.PhysicalType,
    value_data: []const u8,
    num_values: usize,
    max_def_level: u8,
    def_level_encoding: format.Encoding,
    rep_level_encoding: format.Encoding,
) !?DynamicDecodeResult {
    const width: usize = switch (physical_type) {
        .int32, .float => 4,
        .int64, .double => 8,
        else => return null,
    };
    const lv = decodeLevelsForDynamicWithEncoding(allocator, value_data, num_values, max_def_level, 0, def_level_encoding, rep_level_encoding) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(lv.def_mask);

    const body = value_data[lv.data_offset..]; // data_offset <= len, checked by the level decoder
    const needed = std.math.mul(usize, lv.non_null_count, width) catch std.math.maxInt(usize);
    if (body.len < needed) {
        if (lv.def_levels) |d| allocator.free(d);
        return null;
    }

    const values = allocator.alloc(Value, num_values) catch |e| {
        if (lv.def_levels) |d| allocator.free(d);
        return e;
    };
    switch (physical_type) {
        .int32 => fillPlainFixed(i32, values, body, lv.def_mask),
        .int64 => fillPlainFixed(i64, values, body, lv.def_mask),
        .float => fillPlainFixed(f32, values, body, lv.def_mask),
        .double => fillPlainFixed(f64, values, body, lv.def_mask),
        else => unreachable, // filtered by the width switch above
    }
    return .{ .values = values, .def_levels = lv.def_levels, .rep_levels = null };
}

fn fillPlainFixed(comptime T: type, out: []Value, body: []const u8, def_mask: []const bool) void {
    const Bits = if (@sizeOf(T) == 4) u32 else u64;
    var off: usize = 0;
    for (def_mask, out) |present, *v| {
        if (!present) {
            v.* = .{ .null_val = {} };
            continue;
        }
        // In bounds: caller checked body.len >= non_null_count * @sizeOf(T).
        const x: T = @bitCast(std.mem.readInt(Bits, body[off..][0..@sizeOf(T)], .little));
        v.* = switch (T) {
            i32 => .{ .int32_val = x },
            i64 => .{ .int64_val = x },
            f32 => .{ .float_val = x },
            f64 => .{ .double_val = x },
            else => @compileError("fillPlainFixed: unsupported " ++ @typeName(T)),
        };
        off += @sizeOf(T);
    }
}
```

  Hook it into `decodeColumnDynamicWithValueEncoding`, right after `const is_dict_encoded = ...;`.
  The condition mirrors exactly when the general path takes `decodeRequiredColumn` (max_def 0) or
  `decodeOptionalColumnWithLevels` (OPTIONAL with max_def 1):

```zig
    const flat_fast_ok = !is_dict_encoded and value_encoding == .plain and max_rep_level == 0 and
        (max_def_level == 0 or (max_def_level == 1 and schema_elem.repetition_type == .optional));
    if (flat_fast_ok) {
        if (try decodeFlatPlainFixed(allocator, physical_type, value_data, num_values, max_def_level, def_level_encoding, rep_level_encoding)) |r| return r;
    }
```

  Do **not** touch `decodeColumnDynamicV2` (our writer emits V1 pages; V2 is already single-pass).
- New tests (bottom of column_decoder.zig), all through `decodeColumnDynamicWithValueEncoding`:
  1. REQUIRED int64, 3 PLAIN values → `int64_val` 1, -2, 3; `def_levels == null`.
  2. OPTIONAL double with levels `[1,0,1]`: page bytes =
     `u32 LE 2` + `{0x03, 0x05}` (bit-packed group, bits 101) + 2 × f64 → values `x, null, y`;
     `def_levels` = `{1,0,1}`.
  3. Short REQUIRED int64: 3 values declared, 16 bytes of data → same result as before the change.
     **Write this test first and run it on the unchanged code** to capture the existing behavior
     (expected: the third value is `.null_val`, because `PlainDecoder.next` returns null). Keep it
     passing after the change.
  4. Short OPTIONAL int32 → `error.EndOfData`, as before (also capture this first).
- Test: tests pass on both versions.
- Acceptance: int64_plain and f64_plain read +25% or more; int64_nullable read +15% or more;
  mixed5 read not slower.

### Task 2.3 R3: adopt first page buffer; skip levels when nothing is nested

- Files: `zig-parquet/src/core/dynamic_reader.zig` (`readColumnDynamic`, `readColumnDynamicWithData`,
  `readRowsInternal` call site, `readRowsFiltered` call site)
- Depends on: Gate 1 (sequential with 2.4 and 2.5, same file)
- Change 1: add a trailing parameter `keep_levels: bool` to `readColumnDynamicWithData` and to
  `readColumnDynamic` (which forwards it). Callers: `readRowsFiltered` passes `false` (it already
  discards levels). `readRowsInternal` passes `any_nested`, computed once after `top_infos`:

```zig
        // Levels are only needed when at least one requested column is nested.
        const any_nested = blk: {
            const infos = top_infos orelse break :blk false;
            for (infos) |info| if (info.is_nested) break :blk true;
            break :blk false;
        };
```

- Change 2: in **both** the V2 and the V1 branch, replace the "Append values (transfer ownership)" +
  "Append levels" block with:

```zig
                // Take ownership of the page's values. The first page's buffer becomes
                // the chunk buffer, so single-page chunks are never copied.
                if (all_values.capacity == 0) {
                    all_values = .fromOwnedSlice(page_result.values);
                } else {
                    try all_values.appendSlice(self.allocator, page_result.values);
                    self.allocator.free(page_result.values);
                }
                page_result.values = &.{};

                // Levels are only consumed by nested assembly.
                if (page_result.def_levels) |dl| {
                    if (keep_levels) try all_def_levels.appendSlice(self.allocator, dl);
                    self.allocator.free(dl);
                }
                if (page_result.rep_levels) |rl| {
                    if (keep_levels) try all_rep_levels.appendSlice(self.allocator, rl);
                    self.allocator.free(rl);
                }
```

- Test: tests pass on both versions, especially `nested_test`, `list_test`, `map_test`,
  `struct_test` and `page_index_test`, which exercise `keep_levels = true` and the filtered path.
- Acceptance: int64_plain read +10% or more and mixed5 read +10% or more vs the 2.2 result.

### Task 2.4 R4: flat rows for non-nested reads; move instead of clone

- Files: `zig-parquet/src/core/value.zig` (`Row`), `zig-parquet/src/core/dynamic_reader.zig`
  (`readRowsInternal`, `assembleFlatRows`, `readRowsFiltered` call, `readAllRows`, `readRowsProjected`)
- Depends on: 2.3
- Change 1, `value.zig` `Row`: add the field and honor it in `deinit`.

```zig
    /// When true, `values` is part of a block owned by the producer (e.g. a
    /// `RowIterator` arena) and is not freed by `deinit`.
    values_borrowed: bool = false,
    ...
    pub fn deinit(self: Row) void {
        const opts: Value.DeinitOptions = .{ .skip_bytes = self.bytes_borrowed };
        for (self.values) |v| v.deinitWithOptions(self.allocator, opts);
        if (!self.values_borrowed) self.allocator.free(self.values);
    }
```

  First check that nothing else frees `row.values` directly:
  `grep -rn "\.values)" zig-parquet/src cli/src | grep free`. Only `Row.deinit` may.
- Change 2: `readRowsInternal` gets a trailing parameter `rows_arena: ?*std.heap.ArenaAllocator`.
  `readAllRows` and `readRowsProjected` pass `null`. Replace the final assembly with:

```zig
        // Without nested columns every top-level column is exactly one leaf at the
        // same index (leaf_start == top index), so the flat assembler applies.
        if (is_flat or !any_nested) {
            return self.assembleFlatRows(num_rows, num_leaf_columns, column_values, col_indices, rows_arena);
        }
        return self.assembleNestedRows(...unchanged...);
```

- Change 3: replace `assembleFlatRows` with the version below (signature gains `rows_arena`;
  `readRowsFiltered` passes `null`), plus the helper at file level:

```zig
    fn assembleFlatRows(
        self: *Self,
        num_rows: usize,
        num_columns: usize,
        column_values: [][]Value,
        projected_col_indices: ?[]const usize,
        rows_arena: ?*std.heap.ArenaAllocator,
    ) ![]Row {
        // ... keep the existing output_indices block unchanged ...
        const num_output_cols = output_indices.len;
        const rows = try self.allocator.alloc(Row, num_rows);
        errdefer self.allocator.free(rows);

        // Flat values are scalars or byte slices owned by the reader's bytes arena
        // (bytes_arena_allocator is set for the whole read), so cells are moved, not
        // cloned. The caller's `column_values` cleanup then frees only the arrays.
        if (rows_arena) |arena| {
            const cells = std.math.mul(usize, num_rows, num_output_cols) catch return error.OutOfMemory;
            const block = try arena.allocator().alloc(Value, cells);
            for (rows, 0..) |*row, r| {
                const vals = block[r * num_output_cols ..][0..num_output_cols];
                fillFlatRow(vals, column_values, output_indices, r);
                row.* = .{ .values = vals, .allocator = self.allocator, .bytes_borrowed = true, .values_borrowed = true };
            }
            return rows;
        }

        var rows_initialized: usize = 0;
        errdefer for (rows[0..rows_initialized]) |row| row.deinit();
        for (rows, 0..) |*row, r| {
            const vals = try self.allocator.alloc(Value, num_output_cols);
            fillFlatRow(vals, column_values, output_indices, r);
            row.* = .{ .values = vals, .allocator = self.allocator, .bytes_borrowed = true };
            rows_initialized += 1;
        }
        return rows;
    }

fn fillFlatRow(dst: []Value, column_values: []const []Value, output_indices: []const usize, row: usize) void {
    for (output_indices, dst) |col_idx, *d| {
        const col = column_values[col_idx];
        d.* = if (row < col.len) col[row] else .{ .null_val = {} };
    }
}
```

  `cloneValue` stays (assembleNestedRows still uses it). Do not change `assembleNestedRows`.
- Test: tests pass on both versions, including the C ABI tests (`c_abi_test.zig`), which go through
  `readAllRows`. `std.testing.allocator` will flag any double free or leak; if it does, **stop and
  ask** rather than adding clones back piecemeal.
- Acceptance: mixed5 read +40% or more; str_dict and str_unique read +20% or more vs the 2.3 result.

### Task 2.5 R5: `RowIterator` value block in an iterator arena

- Files: `zig-parquet/src/core/dynamic_reader.zig` (`RowIterator`, `rowIterator`, `rowIteratorProjected`),
  `zig-parquet/src/tests/roundtrip_test.zig` (one new test)
- Depends on: 2.4
- Change:

```zig
    pub const RowIterator = struct {
        // ... existing fields ...
        /// Backs the value slices of `current_rows` (flat reads). Reset when the
        /// iterator moves past a row group; freed by `deinit`.
        arena: std.heap.ArenaAllocator,

        // in next():   const rows = try self.reader.readRowsInternal(self.current_rg, self.col_indices, &self.arena);
        pub fn deinit(self: *RowIterator) void {
            self.freeCurrentRows();
            self.arena.deinit();
        }

        fn freeCurrentRows(self: *RowIterator) void {
            if (self.current_rows) |rows| {
                for (rows) |row| row.deinit();
                self.reader.allocator.free(rows);
                self.current_rows = null;
            }
            _ = self.arena.reset(.retain_capacity);
        }
    };
    // rowIterator() and rowIteratorProjected(): add `.arena = std.heap.ArenaAllocator.init(self.allocator),`
```

  Check that nobody builds a `RowIterator` literal elsewhere
  (`grep -rn "RowIterator{" zig-parquet/src cli/src` returns nothing) and that every `rowIterator()`
  caller calls `deinit()` (cli `cat.zig` and `head.zig` do).
- New test (next to the existing multi-row-group iterator test in roundtrip_test.zig, ~line 4130):
  DynamicWriter with an `int64` column and a `string` column, `setRowGroupSize(10)`, 25 rows
  (`i`, `"s{i}"`). Iterate with `rowIterator()`; for each row assert both columns equal the expected
  values; count = 25. This exercises an arena reset at each of the 2 boundaries.
- Test: tests pass on both versions.
- Acceptance: int64_plain read ≥ 2.5x baseline cumulative (≥ 42M rows/s); every read scenario ≥ 2x baseline.

### Task 2.6 (conditional) R6: flat PLAIN BYTE_ARRAY fast path

- Only if str_unique read is below 35M rows/s after 2.5. Otherwise skip and note "skipped, target met".
- Files: `zig-parquet/src/core/column_decoder.zig`
- Approach: in `decodeFlatPlainFixed`'s style, handle `.byte_array` (only when the schema has no
  decimal logical type, so `isDecimalIntColumn` stays false). Pass 1 walks the length prefixes over
  the non-null count and returns null on any overrun, with no allocation. Pass 2 allocates the
  `Value[]` and fills `.bytes_val = try value_mod.dupeBytes(allocator, slice)`. The validating pass
  is why no partial-failure cleanup is needed. Same 4-test pattern as 2.2.
- Acceptance: str_unique read +20% or more.

### Task 2.7 (owner decision D1 only) lazy `RowIterator`

- Do **not** start without written owner approval of D1 (design §5.4).
- Sketch: add `pub fn rowIteratorStreaming(self: *Self) StreamingRowIterator` (new type; the old
  iterator is untouched). It keeps the per-row-group `column_values` and one `row_values: []Value`
  buffer, and `next()` fills `row_values` for the cursor (`fillFlatRow`) and returns `*const Row`,
  valid until the next `next()`. Nested schemas fall back to `readRowsInternal`. The bench gets a
  `--streaming` flag. Expected read: about 3x beyond 2.5.

### Task 2.8 Gate 2

- All R1 test commands on both toolchains. `make validate-wild CODECS=zig-only ZIG=<Z16>`: the failure
  list must equal the one recorded before Phase 2 (run it once on the Gate-1 commit first).
- Bench on Z16, twice, and append column `P2` to both History tables.
- Pass: tests green on both versions; every read scenario ≥ 2x baseline; no write scenario more than 5% slower.

---

## Phase 3: write path (benchmark-guided)

Paths under test: typed `Writer.writeColumnOptional` → `column_writer.writeColumnChunkOptionalWithEncoding`
→ `page_writer.writeDataPageOptionalWithEncoding` (int64_plain, f64_plain, int64_nullable), and
`DynamicWriter.flush` → `writeColumnChunk(ByteArray)DictOptionalWithPathArray` (str_dict, str_unique, mixed5).

**Golden rule: output bytes must not change.** Every task below has a byte-identity check.

### Task 3.1 ∥ W1: accumulator bit packing

- Files: `zig-parquet/src/core/encoding/rle_encoder.zig` (`encodeBitPackedRun`; delete `writeBits` once unused)
- Depends on: Gate 2
- Change: replace the body after the indicator write:

```zig
    // 8 values of bit_width bits = bit_width bytes per group; padding stays zero.
    const total_bytes = num_groups * @as(usize, bit_width);
    const start_pos = buffer.items.len;
    try buffer.appendNTimes(allocator, 0, total_bytes);
    const out = buffer.items[start_pos..];

    const mask: u64 = (@as(u64, 1) << bit_width) - 1;
    var acc: u64 = 0;
    var acc_bits: u6 = 0; // < 8 at the top of each iteration, so + bit_width (<= 31) < 64
    var pos: usize = 0;
    for (values[0..@min(count, values.len)]) |v| {
        acc |= (@as(u64, v) & mask) << acc_bits;
        acc_bits += bit_width;
        while (acc_bits >= 8) {
            out[pos] = @truncate(acc); // low byte
            pos += 1;
            acc >>= 8;
            acc_bits -= 8;
        }
    }
    if (acc_bits > 0) out[pos] = @truncate(acc);
```

  Run `grep -n writeBits zig-parquet/src -r` before deleting `writeBits`.
- New test: round trip through `rle.decode` for bit widths 1..31, counts {1, 8, 9, 100, 1000}
  (the decoder is now fast, so this also cross-checks 2.1).
- Acceptance: tests pass on both versions; str_dict write +10% or more (indices at bit width 7);
  `file_MB` unchanged.

### Task 3.2 W2: `appendDefLevelsWithLength`

- Files: `zig-parquet/src/core/encoding/rle_encoder.zig` (new pub fn + test)
- Depends on: 3.1 (same file)
- Change: add `const Optional = @import("../types.zig").Optional;` and:

```zig
/// Append V1 definition levels (bit width 1, u32 length prefix) for a flat
/// column straight from its values. Byte-identical to
/// `encodeDefLevelsWithLength` on the matching is-defined slice: same run-splitting rule as `encode`.
pub fn appendDefLevelsWithLength(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const Optional(T)) !void {
    const len_pos = out.items.len;
    try out.appendNTimes(allocator, 0, 4);
    const body_start = out.items.len;
    const n = values.len;
    var i: usize = 0;
    while (i < n) {
        const d = values[i] != .null_value;
        var run_len: usize = 1;
        while (i + run_len < n and (values[i + run_len] != .null_value) == d and run_len < 0x7FFFFFFF) run_len += 1;
        if (run_len >= 8 or i + run_len == n) {
            try writeVarInt(out, allocator, run_len << 1);
            try out.append(allocator, @intFromBool(d));
            i += run_len;
            continue;
        }
        // Bit-pack until the next run of >= 8, exactly like `encode`.
        var pack_count: usize = 0;
        var j = i;
        while (j < n) {
            const dj = values[j] != .null_value;
            var next_run: usize = 1;
            while (j + next_run < n and (values[j + next_run] != .null_value) == dj) next_run += 1;
            if (next_run >= 8) break;
            pack_count += next_run;
            j += next_run;
        }
        const count = @min(((pack_count + 7) / 8) * 8, n - i);
        const groups = (count + 7) / 8;
        try writeVarInt(out, allocator, (groups << 1) | 1);
        const start = out.items.len;
        try out.appendNTimes(allocator, 0, groups);
        for (0..count) |k| {
            if (values[i + k] != .null_value) out.items[start + k / 8] |= @as(u8, 1) << @as(u3, @truncate(k)); // k % 8
        }
        i += count;
    }
    const body_len = try safe.castTo(u32, out.items.len - body_start);
    std.mem.writeInt(u32, out.items[len_pos..][0..4], body_len, .little);
}
```

- New test, byte identity: for n in {0,1,7,8,9,15,16,17,100,1000} and null rates {0%, 5%, 33%, 50%,
  95%, 100%} plus the bench pattern (`i % 3 == 2` is null): build `[]Optional(i64)` and the matching
  `[]bool`, then assert `appendDefLevelsWithLength` output == `encodeDefLevelsWithLength(bool slice)`.
- Acceptance: test passes on both versions (no bench change expected yet).

### Task 3.3 W3: PLAIN page fast path (fixed width, bool, byte arrays)

- Files: `zig-parquet/src/core/page_writer.zig` (`writeDataPageOptionalWithEncoding`,
  `writeDataPageByteArrayOptionalWithEncoding`, new private fns, tests)
- Depends on: 3.2
- Change 1: first line of `writeDataPageOptionalWithEncoding`:
  `if (encoding == .plain and (T == i32 or T == i64 or T == f32 or T == f64 or T == bool)) return writePlainPageOptional(allocator, T, values, is_optional);`

```zig
/// PLAIN page built in one buffer: [u32 len + def levels] (optional only), then
/// the non-null values. Byte-identical to the general path.
fn writePlainPageOptional(allocator: std.mem.Allocator, comptime T: type, values: []const Optional(T), is_optional: bool) PageWriteError!DataPageResult {
    var non_null: usize = 0;
    for (values) |v| {
        if (v != .null_value) non_null += 1;
    }
    if (!is_optional and non_null != values.len) return error.NullInRequiredColumn;

    const value_bytes = if (T == bool) (non_null + 7) / 8 else std.math.mul(usize, non_null, @sizeOf(T)) catch return error.IntegerOverflow;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, value_bytes + values.len / 4 + 16);
    if (is_optional) try rle_encoder.appendDefLevelsWithLength(T, &out, allocator, values);

    const start = out.items.len;
    try out.appendNTimes(allocator, 0, value_bytes); // zeroed: bool packing ORs bits in
    const dst = out.items[start..];
    var k: usize = 0;
    for (values) |v| switch (v) {
        .null_value => {},
        .value => |x| {
            if (T == bool) {
                if (x) dst[k / 8] |= @as(u8, 1) << @as(u3, @truncate(k)); // k % 8
            } else {
                const Bits = if (@sizeOf(T) == 4) u32 else u64;
                std.mem.writeInt(Bits, dst[k * @sizeOf(T) ..][0..@sizeOf(T)], @bitCast(x), .little);
            }
            k += 1;
        },
    };
    return .{ .data = try out.toOwnedSlice(allocator), .num_values = values.len, .num_non_null = non_null };
}
```

- Change 2: in `writeDataPageByteArrayOptionalWithEncoding`, when `encoding == .plain`, use the same
  shape. Count pass: `non_null`, `payload += 4 + len` (checked add; overflow → `error.OutOfMemory`,
  as `plain_encoder.encodeByteArrays` does), and a `too_large` flag for `len > maxInt(i32)`. **Error
  precedence must match the old code**: first `NullInRequiredColumn`, then `ValueTooLarge`. Then levels,
  then for each value `u32 LE len` + bytes. Leave other encodings on the existing path.
- New tests, byte identity (in page_writer.zig): for n in {0,1,7,8,9,100,1000}, null rate
  {0,5,33,100}%, `is_optional` in {true, false} (false only with 0% nulls), compare against the old
  general path built by hand: split into `non_null` + `is_defined`, then
  `writeDataPageTypedWithEncoding(allocator, T, non_null, is_defined, is_optional, .plain)`. Do this
  for T = i64, f32, bool. For byte arrays, compare against `encodeByteArraysWithEncoding` +
  `combineDefLevelsAndValues` (optional) or the plain bytes (required). Compare `data`, `num_values`
  and `num_non_null`.
- Acceptance: int64_plain and f64_plain write +50% or more; int64_nullable write +60% or more;
  str_unique write +10% or more; `file_MB` unchanged everywhere.

### Task 3.4 ∥ W4: dictionary in-loop limit, `getOrPut`, statistics after the decision

- Files: `zig-parquet/src/core/column_writer.zig` (`writeColumnChunkDictOptionalWithPathArray`,
  `writeColumnChunkByteArrayDictOptionalWithPathArray`)
- Depends on: Gate 2 (∥ with 3.1-3.3 and 3.6; sequential before 3.5)
- Change, typed function. Remove the "Compute statistics" block at the top and the post-loop
  "Check dictionary size limit" block. Rewrite the build loop:

```zig
    var idx: usize = 0;
    for (values) |v| {
        if (v != .null_value) {
            const gop = unique_map.getOrPut(v.value) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = try safe.castTo(u32, dict_values.items.len);
                dict_values.append(allocator, v.value) catch return error.OutOfMemory;
                // The dictionary only grows, so its first excess is the same decision
                // the old post-loop check made: fall back now instead of hashing on.
                if (dictionary_size_limit) |limit| {
                    if (dict_values.items.len * @sizeOf(T) > limit) {
                        return writeColumnChunkOptionalWithPathArray(T, allocator, output, path_in_schema, values, is_optional, start_offset, codec, write_page_checksum);
                    }
                }
            }
            indices[idx] = gop.value_ptr.*;
            idx += 1;
            // ...existing cardinality-threshold block, minus its two `stats` lines...
        }
    }

    const dict_size = dict_values.items.len;

    // Statistics are only needed once the dictionary is kept (fallbacks compute their own).
    var stats_builder = statistics.StatisticsBuilder(T){};
    stats_builder.updateOptional(values);
    const stats = stats_builder.build(allocator) catch return error.OutOfMemory;
    errdefer if (stats) |s| freeStatistics(allocator, s);
```

  Byte-array function: same shape with `std.StringHashMap` `getOrPut(val)`, keeping the
  `val.len > maxInt(i32)` check **before** `getOrPut`, `dict_bytes += 4 + val.len` on insert and
  `if (dict_bytes > limit)` fallback. Statistics (`ByteArrayStatisticsBuilder`) move below the loop
  in the same way.
- Test: tests pass on both versions (`writer_basic_test`, `roundtrip_test` dictionary and fallback cases).
- Acceptance: str_unique write ≥ 3x baseline (≥ 10M rows/s); mixed5 write ≥ 2x baseline;
  str_dict not slower; `file_MB` unchanged.

### Task 3.5 W5: dictionary data pages built in one buffer

- Files: `zig-parquet/src/core/column_writer.zig` (page loops of the same two functions)
- Depends on: 3.2, 3.4
- Change: in each data-page loop, replace the `data_page_uncompressed = if (is_optional) blk: {...} else blk: {...}`
  expression and its `defer allocator.free(data_page_uncompressed)` with:

```zig
        // [def levels (optional only)][bit width][indices], built in one buffer.
        var page_buf: std.ArrayList(u8) = .empty;
        defer page_buf.deinit(allocator);
        if (is_optional) try rle_encoder.appendDefLevelsWithLength(T, &page_buf, allocator, page_values);
        page_buf.append(allocator, bit_width) catch return error.OutOfMemory;
        page_buf.appendSlice(allocator, rle_data) catch return error.OutOfMemory;
        const data_page_uncompressed = page_buf.items;
```

  (In the byte-array function `T` is `[]const u8`.)
- Acceptance: str_dict write +15% or more; mixed5 write +10% or more; `file_MB` unchanged.

### Task 3.6 ∥ W6: byte-array statistics without a copy per new extreme

- Files: `zig-parquet/src/core/statistics.zig` (`ByteArrayStatisticsBuilder.update`, `.updateOptional`)
- Depends on: Gate 2
- Change (same pattern for `update`):

```zig
    pub fn updateOptional(self: *Self, values: []const Optional([]const u8)) !void {
        var lo: ?[]const u8 = null;
        var hi: ?[]const u8 = null;
        for (values) |v| switch (v) {
            .null_value => self.null_count += 1,
            .value => |val| {
                if (lo == null or std.mem.order(u8, val, lo.?) == .lt) lo = val;
                if (hi == null or std.mem.order(u8, val, hi.?) == .gt) hi = val;
            },
        };
        // At most two owned copies per call instead of one per new extreme.
        if (lo) |l| try self.updateValue(l);
        if (hi) |h| try self.updateValue(h);
    }
```

- Test: tests pass on both versions (statistics tests, page-index tests that read min/max).
- Acceptance: no regression; str_unique write not slower (gain is small and expected to be within noise).

### Task 3.7 W7: measure CRC, then (conditionally) slicing-by-8

- Files (if implemented): new `zig-parquet/src/core/crc32.zig`; the `computePageCrc` bodies in
  `column_writer.zig`, `dynamic_reader.zig`, `parquet_reader.zig`
- Depends on: 3.3-3.6
- Step 1, measure: temporarily change `column_writer.computePageCrc` to `return 0;`, run the bench,
  and revert with `git checkout -- zig-parquet/src/core/column_writer.zig`. CRC share = (ms with
  CRC − ms without) / ms with CRC, for int64_plain write. If below 20%, stop: record the number in
  BASELINE.md notes and skip step 2.
- Step 2, implement:

```zig
//! CRC-32/ISO-HDLC (same result as std.hash.Crc32), slicing-by-8.
const std = @import("std");

const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @truncate(i); // i < 256
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        t[0][i] = c;
    }
    for (0..256) |i| {
        for (1..8) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

pub fn hash(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        const lo = std.mem.readInt(u32, data[i..][0..4], .little) ^ crc;
        const hi = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        crc = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
    }
    for (data[i..]) |b| crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8);
    return ~crc;
}

test "matches std.hash.Crc32" {
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [2048]u8 = undefined;
    prng.random().bytes(&buf);
    for (0..buf.len) |n| try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), hash(buf[0..n]));
}
```

  Then in the three `computePageCrc` helpers use `crc32.hash(data)`. Add a 1 MiB comparison too
  (allocate with `std.testing.allocator`).
- Acceptance: int64_plain and f64_plain write +20% or more; `file_MB` unchanged (the CRC value must be
  identical, which the reader-side checksum tests also prove).

### Task 3.8 Gate 3

- All R1 test commands on both toolchains; `make validate-wild` failure list unchanged.
- Bench on Z16, twice, and append column `P3` to both tables.
- Pass: tests green on both versions; `file_MB` identical to baseline for all 6 scenarios; write
  targets (design §5.4) met or the miss is explained in BASELINE.md notes; no read scenario more than
  5% slower than P2.

---

## Phase 4: docs, CI, pins

### Task 4.1 ∥ CI matrix

- Files: `.github/workflows/test.yml`, `.github/workflows/release.yml`
- Change: in `zig-parquet` and `pqi` jobs add `zig: [0.16.0, 0.17.0]` to the matrix and use
  `version: ${{ matrix.zig }}`. Add job `c-codecs`: ubuntu, matrix zig [0.16.0, 0.17.0], step
  `zig build test -Dcodecs=c-only` in `zig-parquet`. This is the first real proof of task 1.3's
  extern declarations. Optional job `fmt`: zig 0.16.0, `zig fmt --check zig-parquet/src cli/src zig-parquet/build.zig cli/build.zig`.
  Add it only if `make fmt ZIG=<Z16>` produces no diff on this branch.
- Acceptance: CI green on a pushed branch (the owner pushes; implementers do not push).

### Task 4.2 ∥ Docs and pins

- Files: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `zig-parquet/HARDENING.md`,
  `zig-parquet/build.zig.zon`, `cli/build.zig.zon`, `mise.toml`
- Change:
  - AGENTS.md: "Zig 0.16.0 and 0.17.0". Add a section **"Dual-version rules"** = R3's table + the fmt
    rule + `make ... ZIG=` usage. Add `make bench` to the command list.
  - README/CONTRIBUTING: the supported versions line.
  - CHANGELOG: perf summary (baseline → P3 table), `Row.values_borrowed`, `RowIterator.arena`,
    dual-version support.
  - HARDENING.md: a short "Fast paths" section listing 2.1, 2.2, 3.3 and where their bounds checks live
    (per page/run) and their fallbacks.
  - `.minimum_zig_version = "0.16.0"` in both zon files. `mise.toml` stays `0.16.0` with a comment
    `# fmt toolchain; 0.17 is also supported (see AGENTS.md)`.
- Acceptance: docs only; tests untouched.

### Task 4.3 Gate 4 (final)

- Full R1 matrix on both toolchains; bench on Z16 **and** `ZIG=zig`; append `P4 (0.16)` and
  `P4 (0.17)` columns. Summarize the speedup per scenario at the top of BASELINE.md.

---

## Appendix A: Phase 1 file map (this branch)

| task | files |
|---|---|
| 1.1 | Makefile |
| 1.2 | zig-parquet/build.zig, cli/build.zig, examples/{basic,gen-power-grid,large_file,wasm_demo}/build.zig |
| 1.3 | src/core/compress/c_*.zig (5), src/repeat.zig (new) |
| 1.4 | src/core/compress/{brotli,gzip,lz4,zstd,snappy}.zig, src/core/{types,column_decoder,page_index_reader,page_range_reader}.zig, src/core/encoding/delta_binary_packed_encoder.zig, src/core/thrift/compact.zig, src/api/wasm/freestanding.zig |
| 1.5 | src/tests/{brotli,gzip,lz4,snappy,zstd}_cross_test.zig, negative_test, page_index_test, reader_test, roundtrip_test, interop_pyarrow_test, writer_logical_test |
| 1.6 | src/core/arrow_batch.zig, src/core/dynamic_writer.zig, src/api/{c,wasm}/handles.zig |
| 1.7 | src/core/{column_writer,dynamic_reader,parquet_reader}.zig, src/tests/checksum_test.zig |

## Appendix B: Phase 1 if D0 = (b), rebased onto main

main (685101e and later) is 0.17-only. Verified by compiling main with 0.16: 29 first-layer errors.
Replace tasks 1.3-1.7 with the tasks below (each ∥, split by file as in Appendix A), then do 1.8:

- B1 `@backingInt(x)` → `@intFromEnum(x)` (18 sites); `@fromBackingInt(x)` → `@enumFromInt(x)` (9 sites;
  keep the result type annotation that main relies on). `git grep -n "BackingInt" -- zig-parquet cli`.
- B2 `allocator.print(fmt, args)` → `std.fmt.allocPrint(allocator, fmt, args)`;
  `allocator.printSentinel(fmt, args, 0)` → `std.fmt.allocPrintSentinel(allocator, fmt, args, 0)`
  (`arrow_batch.zig:28`, `tests/multipage_test.zig`, others: `git grep -nE "\.print(Sentinel)?\(" -- zig-parquet/src cli/src`
  and change only the calls whose receiver is an `Allocator`).
- B3 `std.hash.crc.@"CRC-32/ISO-HDLC"` → `std.hash.Crc32` (column_writer, dynamic_reader, parquet_reader, checksum_test).
- B4 build scripts: `run.addPassthruArgs()` → `passArgs(b, run)` (task 1.2 helper); all `build.zig.zon`
  `.minimum_zig_version = "0.17.0"` → `"0.16.0"`; any `std.heap.SafeAllocator` in code → `std.heap.DebugAllocator(.{})`.
- B5 compile with 0.16, fix the next layer using **only** R3 spellings, and **stop and ask** on anything else.
- Keep main's `c_*.zig` and `repeat.zig` as they are (already dual-compatible).
