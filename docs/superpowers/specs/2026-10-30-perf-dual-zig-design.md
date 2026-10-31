# Design: faster read/write paths, one tree for Zig 0.16 and 0.17

- Date: 2026-10-30
- Status: proposed (needs owner decisions D0-D3 below)
- Branch: `agent/zig-parquet-perf-compat-dc9ccc` (base 38dec45, plus 341baeb "Add bench harness")
- Plan: `docs/superpowers/plans/2026-10-30-perf-dual-zig-plan.md`

## 1. Goals and non-goals

Goals

1. The common read and write paths get much faster, measured by the `zig build bench` scenarios
   (`int64_plain`, `f64_plain`, `int64_nullable`, `str_dict`, `str_unique`, `mixed5`).
   The owner asked for "roughly 10x". Section 5.4 states what is reachable without API changes
   and what each extra step would cost.
2. The single source tree builds and passes tests on Zig 0.16.0 and Zig 0.17.0, with no
   per-version copies of source files.
3. Public API, C ABI, WASM exports and the Arrow bridge keep working. File output stays
   byte-identical unless a decision below explicitly changes it.
4. Every HARDENING.md guarantee still holds. Bounds checks may move from per value to per page
   or per run, but they never disappear.

Non-goals

- No rewrite of nested assembly (`nested.zig`, `assembleNestedRows` phase 1), list/map/struct
  writers, or the Arrow read path.
- No new dependencies, no SIMD intrinsics, no threads.
- No new public types. The only public-surface additions are one defaulted field on `Row` and one
  field on `DynamicReader.RowIterator` (both source-compatible).
- No change of defaults (CRC on write, dictionary on, single row group) without data and an
  owner decision.
- No performance work on compressed pages. The bench is uncompressed, so decompression scratch
  reuse and codec tuning wait until a compressed scenario exists.

## 2. Measured facts

### 2.1 Baseline (from `bench/BASELINE.md`, Zig 0.16.0, ReleaseFast, zig-only, Ryzen 9 7950X, 1M rows)

| scenario | write rows/s | read rows/s | write path exercised | read path exercised |
|---|---|---|---|---|
| int64_plain | 31.7M (31.5 ms) | 16.8M (59.4 ms) | typed `Writer.writeColumnOptional`, required, PLAIN, 1 page, CRC on | `DynamicReader.rowIterator` |
| f64_plain | 32.2M | 18.2M | same as above | same |
| int64_nullable | 37.8M | 17.3M | same, optional, every third value null | same |
| str_dict | 13.6M (73.6 ms) | 12.3M | `DynamicWriter`, optional string, 100 distinct values, dictionary | same |
| str_unique | 3.3M (299.8 ms) | 14.9M | `DynamicWriter`, 1M distinct strings: dictionary attempted, falls back to PLAIN | same |
| mixed5 | 1.8M (564.2 ms) | 5.5M (182.1 ms) | `DynamicWriter`, 5 optional columns (i32, i64, f64 random; bool; string from 1000 values) | same |

The harness (`zig-parquet/bench/main.zig`) opens a new reader per run, so page-fault cost for
fresh memory is inside every read measurement. That matters for section 5.

### 2.2 Zig 0.17 compatibility, verified with the compiler

I copied the tree to a scratch directory, applied the substitutions in section 4.2 mechanically, and
compiled it with both toolchains:

- 0.17: `zig build test -Dcodecs=zig-only` built and ran 852 of 858 tests. The 6 failures were
  caused by the probe itself: it replaced `"abc" ** n` with `"abc"`, so compression-ratio asserts
  failed, and `test-files-wild` was not copied. `zig build wasm-smoke -Dcodecs=zig-only`, the CLI
  build, and `zig build test` for the CLI all passed.
- 0.16: the same patched tree gave the same 852/858 with the same probe-caused failures. Every
  replacement spelling is therefore valid on both versions.
- The bench harness compiles and runs on 0.17.

Only six constructs differ, and each one has a spelling that works on both versions (section 4.2).
The research note's claim that "28 files fail" counts only the first error per file. After those
are fixed, 0.17 also rejects `Allocator.dupeZ` (53 sites) and `std.hash.crc.Crc32` (4 sites).

### 2.3 The branch is behind `main`

`main` contains 685101e "Port to Zig 0.17.0" and three later commits. That port is 0.17-only. It
uses `@backingInt`/`@fromBackingInt` (27 sites), `Allocator.print`/`printSentinel` (about 17 sites),
`std.hash.crc.@"CRC-32/ISO-HDLC"`, and `addPassthruArgs`. On 0.16 it fails with 29 first-layer errors,
which I verified by compiling main's tree with 0.16. It already contains hand-written `extern`
blocks for the five C wrappers and `src/repeat.zig`, and this plan reuses both. The divergence in
the hot files is mostly outside the functions this design touches: in `column_writer.zig` main
changed the `writeColumnChunkFromValues*` (nested) paths, and `dynamic_reader.zig` differs by 7
lines.

**D0 (owner, blocking Phase 1):** choose the base.

- **(a) Stay on this branch.** Phase 1 is the forward list in section 4.2. Merging main later
  conflicts in `column_decoder.zig`, `dynamic_writer.zig`, `arrow_batch.zig` and the compress files,
  and main's 0.17-only spellings must then be converted anyway.
- **(b) Rebase onto main first (recommended).** Cherry-pick 341baeb onto main, then Phase 1 is the
  inverse list: replace main's 0.17-only spellings with the shared ones. That is about 50 mechanical
  edits, listed in plan Appendix B. Phases 2-4 are unchanged; the tasks name functions, so line
  numbers may drift.

## 3. Principles

1. Choose the smallest diff that captures the win. Each task is a local change inside one or two
   functions.
2. Measure before and after every perf task with the bench. A task that does not move its target
   scenario is reverted, not kept "for later".
3. Keep output byte-identical. Every write-side task has a unit test that compares new bytes with
   the old code path's bytes.
4. Use one spelling for both Zig versions. A version gate is the last resort, and today none is
   needed in `src/`.

## 4. Part A: one tree for Zig 0.16 and 0.17

### 4.1 Decision: no `compat.zig`

The brief suggested a small comptime-gated `src/core/compat.zig`. The compiler probe shows it would
be empty: every construct that differs has a spelling both versions accept. An empty abstraction is
pure cost, so none is added. Rules:

- In `src/`: write only spellings from the "use" column below. If a future difference has no common
  spelling, add `src/compat.zig` with one `if (builtin.zig_version.minor >= 17)` gated declaration
  per item, plus a test, and record it in AGENTS.md. Until then the file does not exist.
- In `build.zig` files, which cannot import `src/`: a 6-line `passArgs` helper using
  `@hasDecl(std.Build.Step.Run, "addPassthruArgs")` is copied into each build script that forwards
  args. Three copies of 6 lines are cheaper than a shared build module.

### 4.2 The difference table (verified)

| construct | 0.16 | 0.17 | use (valid on both) | sites (this branch) |
|---|---|---|---|---|
| array repetition `x ** n` | ok | **removed** (parse error) | `@splat(v)` with a known array type, e.g. `var a: [16]u8 = @splat(0);` or `@as([16]u8, @splat(0))` | 93 lines / 23 files |
| string repetition `"ab" ** n` | ok | **removed** | `comptime repeat.bytes("ab", n)` from `src/repeat.zig` (copied verbatim from main 685101e, verified on both) | ~35 lines, tests and compress test blocks |
| `@cImport` / `@cInclude` | ok (deprecated) | **removed** | `const c = struct { extern fn ...; const K = ...; };`, copied verbatim from main 685101e for all 5 `c_*.zig` files | 5 files |
| `Allocator.dupeZ(u8, x)` | ok | **removed** | `allocator.dupeSentinel(u8, x, 0)` | 53 sites / 4 files |
| `std.hash.crc.Crc32` | ok | **renamed** (`crc.@"CRC-32/ISO-HDLC"`) | `std.hash.Crc32` | 4 files |
| `b.args` in build.zig | ok | **removed** (`Run.addPassthruArgs`) | `passArgs(b, run)` helper (`@hasDecl` gate) | 3 build.zig |
| `@intFromEnum`, `@enumFromInt`, `std.fmt.allocPrint`, `@bitCast` floats, `std.heap.DebugAllocator`, `std.meta.eql`, `std.meta.isError`, `builtin.cpu`, `std.fmt.FormatOptions` | ok | ok (compiled in probe) | unchanged; do **not** "modernize" to `@backingInt`/`allocator.print`, which are 0.17-only | n/a |
| `std.meta.fields`, `@backingInt`, `@fromBackingInt`, `Allocator.print`, `std.heap.SafeAllocator`, `addPassthruArgs` | absent or ok | ok | **forbidden**, not available on both | 0 here; present on main |

Notes:

- The zlib wrapper calls `deflateInit2_`/`inflateInit2_` with `"1.3.1"` and `@sizeOf(z_stream)`
  because `deflateInit2`/`inflateInit2` are C macros. `z_stream` uses `c_ulong`, which gives the
  correct LLP64 layout on Windows. main's file already does both.
- `wasm_demo/src/main.zig` uses `std.heap.GeneralPurposeAllocator`, which exists in neither std.
  CI is green, so the default `zig build` step probably never analyzes that exe. Leave it unless the
  compiler complains on either version (it is not a dual-version issue).

### 4.3 zig fmt policy

`zig fmt` from 0.17 rewrites builtins into 0.17-only spellings (`@backingInt`), which breaks 0.16.
Therefore:

- `zig fmt` runs only with 0.16. `make fmt` refuses to run when `$(ZIG) version` is not `0.16.*`.
- Editors and LSPs must use the 0.16 `zig` for formatting. AGENTS.md states this.
- An optional CI `zig fmt --check` job runs with 0.16 only.

### 4.4 Toolchains, caches, Makefile

- Toolchains on this machine: 0.16 is `C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe`;
  0.17 is `zig` on PATH. CI uses `mlugg/setup-zig` with a version matrix.
- The Makefile gains `ZIG ?= zig`. When `$(ZIG) version` is not 0.16.x, every recipe adds
  `--cache-dir <repo>/.zig17/cache` (already gitignored), so the two compilers never share a local
  cache. `--prefix` is not changed: the CLI integration tests run `./zig-out/bin/pqi`, and with a
  prefix they fail (verified). Overwriting `zig-out/` between versions is harmless.
- Keep the 0.17 cache path short. A deep `--cache-dir` hit Windows MAX_PATH ("configurer.exe
  FileNotFound") in the probe.
- `wasm`, `cli`, `test-cli` and `example` forward `CODECS`, as main's Makefile already does, so
  `CODECS=zig-only` works offline. C codec tarballs cannot be fetched on this machine.
- `make bench` = `zig build bench -Dcodecs=$(CODECS or zig-only) -Doptimize=ReleaseFast`.
- C wrappers cannot be built locally because the tarballs cannot be fetched. Local proof is parse
  only (`zig ast-check`). Real proof is a CI job running `zig build test -Dcodecs=c-only` on both
  versions.

### 4.5 CI and pins

- `test.yml`: matrix `zig: [0.16.0, 0.17.0]` × `os` for the `zig-parquet` and `pqi` jobs, plus one
  `c-codecs` job (ubuntu, both versions, `-Dcodecs=c-only`).
- `release.yml`: same matrix for the test job. Release artifacts are built with 0.16 (the fmt
  toolchain) unless the owner prefers 0.17.
- `mise.toml` stays on `0.16.0`, since it is the fmt toolchain. A comment points to the 0.17
  command line.
- `build.zig.zon` (library and CLI): `.minimum_zig_version = "0.16.0"`.

## 5. Part B: performance

### 5.1 Where the time goes (code-level, verified by reading the code)

Read: `rowIterator` → `readRowsInternal` → per leaf `readColumnDynamicWithData` → per page
`column_decoder.decode*` → row assembly.

1. **Every file read goes through the nested assembler.** `is_flat` is `schema[0].num_children == 0`,
   which is false for every normal file. So `readRowsInternal` (dynamic_reader.zig ~666) calls
   `assembleNestedRows` even when no column is nested. Its phase 2 does, per row,
   `allocator.alloc(Value, ncols)` plus `cloneValue` per cell, and strings are copied again into the
   arena. For 1M rows that is 1M small allocations, 1M frees, and up to 5M clones (mixed5).
2. **Three full-size arrays per page plus one per chunk.** `decodeColumnWithLevels` fills
   `Optional(T)[]` (16 B/value), `decodeDynamic*` converts it to `Value[]` (24 B/value), and
   `readColumnDynamicWithData` `appendSlice`s that into `all_values`, which is a third copy with
   growth reallocations. With the `Row[]` (40 B/row) on top, int64_plain touches about 140 MB of
   fresh memory per run. On Windows the page faults alone cost several ms.
3. **Levels are built for flat columns and then thrown away.** A `u32` def-level array, a `bool`
   mask, and per-chunk `all_def_levels` accumulation are kept even though only nested assembly reads
   them.
4. **Bit unpacking runs one value at a time** (`rle.zig` `decodeBitPacked`): a div, a checked cast,
   and up to 5 checked byte loads per value. RLE runs fill one `u32` per iteration. This hits
   dictionary indices (str_dict, mixed5 name) and bit-packed def levels (int64_nullable).

Write (typed `Writer`, the first three scenarios): `writeColumnChunkOptionalWithEncoding` →
`page_writer.writeDataPageOptionalWithEncoding`:

5. **Four to five transient full-size buffers per page.** Two unreserved ArrayLists (`is_defined`,
   `non_null`), `encodePlain` output, then either `allocator.dupe` (required) or
   `combineDefLevelsAndValues` (optional), which builds `bool` → `u32` → RLE buffer → length-prefixed
   copy → final copy.
6. **Bit packing writes one bit chunk at a time** (`rle_encoder.writeBits`, with a checked cast per
   chunk). int64_nullable's 110110... pattern is entirely bit-packed.
7. **Page CRC32** is byte-at-a-time table CRC in both std versions, about 5 ms per 8 MB. It is a
   fixed floor once 5 and 6 are fixed.

Write (`DynamicWriter`, the last three scenarios):

8. **The dictionary limit is checked after hashing the whole column.**
   `writeColumnChunk(ByteArray)DictOptionalWithPathArray` inserts every distinct value (1M for
   str_unique; about 1M each for mixed5's i32, i64 and f64), then compares against the 1 MiB limit,
   then falls back to PLAIN. Statistics are computed before the attempt and again in the fallback.
   This is most of str_unique's 300 ms and mixed5's 564 ms.
9. **Byte-array statistics duplicate every new extreme.** That is minor, but the fix is trivial.

### 5.2 Read-path changes

| id | change | where | why it is safe |
|---|---|---|---|
| R1 | Word-at-a-time bit unpack: one unaligned `u64` load per value while 8 bytes remain, otherwise the existing byte-wise loop for the tail. RLE fill uses `@memset`. | `encoding/rle.zig` `decodeBitPacked`, `decode` | Bounds check per value becomes "8 bytes remain" per value with no slicing past the end. Truncated input still zero-fills exactly as before, through the untouched tail loop. |
| R2 | Flat PLAIN fixed-width fast path (INT32/INT64/FLOAT/DOUBLE, `max_rep == 0`, `max_def <= 1`, not dictionary): decode levels with the existing helper, check `non_null * width <= len` once, write `Value`s directly. | `column_decoder.zig` new `decodeFlatPlainFixed`, hooked in `decodeColumnDynamicWithValueEncoding` | One check per page. If the page is short or level decoding fails, return null and let the existing general decoder run, so error and null semantics stay identical, including the lenient "short required page yields nulls" behavior. |
| R3 | Adopt the first page's `Value[]` as the chunk buffer (`fromOwnedSlice`) instead of copying it into `all_values`. Skip def/rep accumulation when the read has no nested column. | `dynamic_reader.zig` `readColumnDynamicWithData` (+ `keep_levels` param) | Ownership transfer only. Levels are still produced, and still accumulated whenever any nested column is read. |
| R4 | Route non-nested reads to `assembleFlatRows` and move cells instead of `cloneValue`. | `dynamic_reader.zig` `readRowsInternal`, `assembleFlatRows` | Flat `Value`s hold only scalars or arena-owned bytes. The `column_values` defer runs while `bytes_arena_allocator` is set, so it never frees bytes, and flat values have no containers. Moving is therefore equivalent to cloning without the copy. |
| R5 | Row value slices for `rowIterator` come from one block in an iterator-owned arena, which is reset when the iterator crosses a row group. `Row` gains `values_borrowed: bool = false`, and `Row.deinit` skips `free(values)` when it is set. `readAllRows` keeps per-row allocation (no lifetime change for C/WASM callers). | `value.zig` `Row`, `dynamic_reader.zig` `RowIterator` | The documented iterator contract ("valid until the next call to next() that crosses a row group boundary") already covers it. Byte payloads stay in the reader arena with unchanged lifetime. |
| R6 (conditional) | PLAIN BYTE_ARRAY flat fast path: one validation pass, then one copy pass. | `column_decoder.zig` | Only if str_unique read misses its target after R5. |

### 5.3 Write-path changes

| id | change | where | identity proof |
|---|---|---|---|
| W1 | 64-bit accumulator bit packing (fixes 6). | `rle_encoder.zig` `encodeBitPackedRun` | Packing is canonical (LSB-first); round-trip test for bit widths 1..31. |
| W2 | `appendDefLevelsWithLength(T, out, values)`: V1 def levels (bit width 1) written straight from `[]Optional(T)` into the page buffer, a port of `encode`'s run-splitting rule. | `rle_encoder.zig` (new pub fn) | Test: equal to `encodeDefLevelsWithLength` on random and edge patterns. |
| W3 | PLAIN page fast path: fixed width plus bool, then byte arrays, each built in one ArrayList (count pass, levels, values). | `page_writer.zig` `writeDataPageOptionalWithEncoding`, `writeDataPageByteArrayOptionalWithEncoding` | Test: equal to `writeDataPageTypedWithEncoding` (old path) on random inputs. Error precedence is preserved. |
| W4 | Dictionary: `getOrPut`, check the limit inside the loop (the dictionary only grows, so the first excess equals the final excess), compute statistics only after the dictionary is kept. | `column_writer.zig` `writeColumnChunkDictOptionalWithPathArray`, `writeColumnChunkByteArrayDictOptionalWithPathArray` | Same fallback decision, so same bytes. Existing dictionary and fallback tests. |
| W5 | Dictionary data pages: def levels via W2, then bit_width, then indices into one buffer. | same two functions, page loop | Same bytes. Existing tests plus W2's test. |
| W6 | Byte-array statistics: find extremes by borrowed slice, then make at most 2 owned copies per update call. | `statistics.zig` `ByteArrayStatisticsBuilder.update{,Optional}` | Same min/max. Existing statistics tests. |
| W7 (measure first) | Slicing-by-8 CRC-32 (ISO-HDLC, same polynomial as `std.hash.Crc32`), about 35 lines, used by the 3 `computePageCrc` helpers. Default stays on. | new `src/core/crc32.zig` | Test: equal to `std.hash.Crc32.hash` on random lengths 0..2000 and 1 MiB. Done only if the CRC share of int64_plain write is 20% or more after W1-W6. |

Considered and rejected, because the data says no:

- A buffered `WriteTargetWriter` or reusing `CompactWriter`: one page per chunk in every scenario
  means 2 writes and 1 header per column.
- Decompression scratch reuse: the bench is uncompressed.
- Pre-sizing hash maps: it trades memory for low-cardinality columns.

### 5.4 Expected results and the honest ceiling

These are estimates from allocation counts and memory traffic, not a profile. Each task's acceptance
criterion in the plan is the measured gain for its own scenario.

| scenario | write now → expected | read now → expected | dominant remaining cost |
|---|---|---|---|
| int64_plain | 31.7M → ≥90M rows/s (≈3x; ≈4.5x with W7) | 16.8M → ≥50M (≈3x) | write: CRC plus file I/O; read: `Row[]` (40 B/row) plus page faults |
| f64_plain | 32.2M → ≥90M | 18.2M → ≥50M | same |
| int64_nullable | 37.8M → ≥100M | 17.3M → ≥45M | same |
| str_dict | 13.6M → ≥25M (≈2x) | 12.3M → ≥35M | write: one `StringHashMap` lookup per value |
| str_unique | 3.3M → ≥20M (≈6x) | 14.9M → ≥35M | write: about 70k hashes before abort, plus 13 MB CRC |
| mixed5 | 1.8M → ≥7M (≈4x) | 5.5M → ≥20M (≈4x) | write: about 520k hashes before aborts plus 1M string lookups |

Geometric mean is about 3.5x. The owner's ~10x is reachable only by changing behavior or contracts.
These are the decisions:

- **D1: lazy `RowIterator` (read about 3x beyond R5).** Assemble each row on `next()` into one
  reused `Row` and value buffer, so there is no `Row[]` and no value block. The cost is narrowing the
  contract from "valid until next() crosses a row group" to "valid until the next call to next()".
  Callers in this repo (`pqi cat`/`head`, bench) already use rows one at a time. External users
  holding row pointers would break silently, so this needs a CHANGELOG "breaking" note or a new
  `rowIteratorStreaming()` method (new API). A plan sketch is in task 2.7.
- **D2: CRC on write.** W7 is the non-breaking option. Defaulting `write_page_checksum` to false (the
  Arrow C++/pyarrow default; parquet-mr defaults on) would save another ~10-15% on plain writes, but
  it changes file bytes.
- **D3: dictionary heuristics.** A default `dictionary_cardinality_threshold` (for example 0.5,
  checked after 1024 values) would skip most of mixed5's and str_unique's remaining hashing. It
  changes which columns are dictionary-encoded, so output bytes differ.
- **D4 (memory, not speed):** `DynamicWriter` buffers the whole file as 24 B `Value`s until
  `close()` (`row_group_row_limit = null`). A default limit (for example 1M rows) bounds memory but
  changes file layout.

## 6. Hardening invariants (all tasks)

- No `@intCast` on data. Use `safe.cast` / `safe.castTo`. `@truncate` is allowed only right after
  masking or `% 8`-style reduction, with an inline comment.
- Every fast path is guarded by one up-front length check with a correct error, or by a "fall back
  to the general path" return. It never relies on ReleaseFast's missing bounds checks.
- Allocation sizes derived from file data use checked `std.math.mul`/`add`. New buffers are sized
  from `rg.num_rows`/`num_values`, which existing code already trusts to the same degree; nothing
  is sized from a larger untrusted value.
- `catch unreachable` only with an invariant comment.
- Fallback paths must reproduce the old error for malformed input. The negative tests and
  `make validate-wild` (where test files exist) are the oracle.

## 7. Risks

1. **Base divergence (D0).** Doing the work on a stale base means a painful merge in the same files.
   Mitigation: decide D0 before Phase 1.
2. **Lifetime regressions from moved values (R4, R5).** A missed owner causes a double free or a use
   after free. Mitigation: `std.testing.allocator` leak and double-free detection in the 858 tests,
   C/WASM handle tests, and a dedicated multi-row-group iterator test.
3. **Silent output change on the write side.** Mitigation: byte-identity unit tests (W2, W3), plus a
   bench `file_MB` check per scenario.
4. **Targets below 10x.** This is stated up front (5.4) with the decisions that unlock more. Haiku
   implementers do not invent extra optimizations: a miss is reported, not improvised.
5. **0.17-only spellings creeping back** through `zig fmt` (0.17), copy-paste from main, or the
   zig-0-17 skill. Mitigation: the fmt guard, the CI matrix, and the forbidden list in AGENTS.md.
6. **C codecs unverifiable locally.** Mitigation: a CI `c-only` job on both versions before merge.
7. **Bench noise on Windows** (±10%). Mitigation: best of 3 runs, rerun twice, and compare only
   changes above 10% unless a task targets a smaller one.
