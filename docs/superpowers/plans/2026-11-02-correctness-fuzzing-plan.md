# Plan: correctness testing and fuzzing for zig-parquet

Research: `docs/previous-art/parquet-fuzzing-and-correctness.md` (read "Oracle hierarchy",
"Mutation strategies" and "Gaps and recommended research programme" before any task).
Template code ([github.com/Gewelf-Labs/zarrow](https://github.com/Gewelf-Labs/zarrow); local checkout `C:/Users/cable/Documents/dev/zarrow`): `fuzz/fuzz.zig` and `docs/fuzzing.md` at zarrow
commit e93f5c3. This is the same owner's Arrow library; its harness is dual 0.16/0.17 and CI-proven.
Phase 1 ports its shape, with the targets changed to Parquet ones.

Phases: **1** byte-level fuzz harness (safety oracle, all OSes) → **2** schema-aware round trip and
metamorphic reader/writer cross product → **3** cross-engine differential → **4** depth: ledger,
structure-aware mutation, 32-bit replay. Phases are ordered by bug-finding value per unit of effort.
Each phase ends with a gate and can be reviewed and merged on its own. Phase 1 needs no owner
decision. Decisions D1-D6 (at the end) block only the tasks that name them.

---

## Facts established (2026-11-02, this worktree, branch head 04555de)

| # | Fact | Evidence |
|---|---|---|
| F1 | No fuzz targets exist yet. | `grep -rn "testing.fuzz\|--fuzz"` over `*.zig`, the Makefile and the workflows finds nothing. |
| F2 | Baseline: **919/919** library tests pass on 0.16 (`zig-only`, Windows). The source has 923 `test "` declarations; the 4-test gap is declarations not compiled into the zig-only test binary (not investigated). | `(cd zig-parquet && <Z16> build test -Dcodecs=zig-only --summary all)` → `919/919 tests passed`. |
| F3 | OOM sweeps exist: `checkAllAllocationFailures` (column_decoder.zig:3120) and hand-rolled `FailingAllocator` loops (nested.zig:744, footer_parse_test.zig:31/74, roundtrip_test.zig:4829). | grep |
| F4 | `std.testing.fuzz(context, testOne(ctx, *Smith), .{ .corpus })` has the **same signature on 0.16.0 and 0.17.0**. `Smith`'s internals differ between versions, but its public methods are the same. | `lib/std/testing.zig` (0.16 l.1220-1233, 0.17 l.1250-1263); a diff of `pub fn` names in `testing/Smith.zig` is empty. |
| F5 | Under a plain `zig build test`, a fuzz test runs once per `.corpus` entry and once on empty input. This works on **Windows with both versions**. | `lib/compiler/test_runner.zig` `fuzz()` (0.16 l.526-626). Scratch probe `fzwin/t.zig`: 0.16 and 0.17 both print "2 fuzz tests found", all pass. 0.17 on Windows needs a short `--cache-dir` (MAX_PATH). |
| F6 | `--fuzz` is **not implemented on Windows** (both versions), nor on 32-bit hosts. The fuzzer object formats are ELF and Mach-O only, so it runs on Linux and macOS. | 0.16 `build_runner.zig:836`, 0.17 `Maker.zig:2572` and `Maker/WebServer.zig:278` ("--fuzz not yet implemented for windows"). `fuzzer.zig:185` supports `.elf` and `.macho`. |
| F7 | **0.16 Debug fuzz builds do not compile.** `test_runner.zig:566` passes `*builtin.StackTrace` to `writeStackTrace`. ReleaseSafe works. 0.17 fixed this (`writeErrorReturnTrace`, test_runner.zig:587). | WSL probe `~/fzprobe-zp`: `zig build test --fuzz=300K` on Debug gives "expected type '*const debug.StackTrace'". `-Doptimize=ReleaseSafe` runs (300K runs in about 20 s on a trivial target). |
| F8 | `--fuzz=N` is an **iteration limit per fuzz test** (K/M/G suffixes). When a crash is found, the build **still exits 0**. The crashing input goes to `<cache>/f/crash` as the Smith byte stream: for a target that does one `smith.slice()`, that is a u32 LE length followed by the input bytes. Panics are caught and saved too. | WSL probe: an error-return finding and an OOB-panic finding both printed "input saved to '.zig-cache/f/crash'"; `echo $?` was `0`. `xxd crash` = `0a000000 41424336...`. `fuzzer.zig` `select()`: `t.limit` is per test. |
| F9 | Zig's fuzzer is weak at magic values. A 3-byte `"ABC"` comparison took about 500K executions. Good seeds matter more than the engine. | WSL probe (rs3.log). |
| F10 | The fuzz test runner resets `std.testing.allocator` for each input and exits 1 on a leak. Library code never logs (`std.log`), so "error logs detected" cannot cause false findings. | test_runner.zig `test_one`; `grep -rn std.log zig-parquet/src` is empty. |
| F11 | Zig exposes only `-ffuzz`, which is tied to Zig's own runtime: there is no `trace-pc-guard` flag, and Zig code gets no ASan or MSan. A libFuzzer or AFL++ bridge would be an unverified spike, and OSS-Fuzz has no Zig language support. | `zig build-lib --help` lists only `-ffuzz` and `-fsanitize-c`/`-thread`. `std.Build.Module` has only `fuzz: ?bool`. |
| F12 | Linux is available: WSL Ubuntu 24.04, 32 cores, 30 GB RAM, Zig 0.16 at `~/zig16/zig`, with rsync, make and python3. Neither a Zig 0.17 Linux toolchain nor valgrind is installed. | `wsl.exe -e bash -lc ...` |
| F13 | CI: GitHub Actions. The `zig-parquet` and `pqi` jobs run on ubuntu-latest **and macos-latest** × Zig 0.16/0.17, with default codecs `all` (Zig and C, so the `*_cross_test.zig` Zig↔C codec tests run). There are also `c-codecs` (c-only), `fmt` (0.16) and `interop` (pytest) jobs. `Gewelf-Labs/zig-parquet` is **public**, a fork of `akeating/zig-parquet`. | `.github/workflows/test.yml`; `gh repo view`. |
| F14 | Engines available locally: cargo 1.98.1, node 24.18.1, bun 1.3.14, uv 0.11.32 (Python 3.15rc1), duckdb CLI 1.5.5. **No JVM** (no `java`, no `mvn`, nothing under Program Files). | `--version` checks. |
| F15 | `apache/parquet-testing` is **already vendored** as a snapshot from the initial commit (2026-02-26): `test-files-wild/parquet-testing/{data,bad_data,variant,shredded_variant}`, 447 tracked files. `pqi validate` checks it against `expected-failures.txt`. 285 of the 307 `.parquet` files under `test-files-wild` and `test-files-arrow` are ≤ 64 KiB (about 1 MB total), which makes them a ready seed corpus. | `git ls-files`, `find -size -65k`. |
| F16 | The DynamicWriter writes **V1 pages only**, encodings PLAIN, RLE_DICTIONARY, RLE (bool), DELTA_BINARY_PACKED (int32/64, always block 128 with 4 mini-blocks) and BYTE_STREAM_SPLIT (int32/64/float/double). The page index is opt-in (`write_page_index` field) and CRC is on by default. **No bloom filters, no encryption.** Readers support V1 and V2 and all 8 encodings. | dynamic_writer.zig `validateEncodingForType`, `delta_binary_packed_encoder.zig:29-31`, README; `grep -ri bloom\|encrypt` finds only page-filter comments. |
| F17 | `parquet.internals` exports column_decoder, every encoder/decoder, thrift, compress and format, so a fuzz module that imports `parquet` (as `bench/` does) reaches every target without touching `src/`. `openBufferDynamic(allocator, bytes, options)` is the in-memory entry point. | lib.zig l.150-187. |
| F18 | `pqi cat --json` is **lossy**: fixed-bytes output is printable-or-hex by heuristic, non-UTF-8 bytes are written raw, logical types are not applied, and map keys are stringified. It cannot be the differential oracle as it is. | cli/src/commands/cat.zig `writeJsonValue`. |
| F19 | `bench/js` checks only `rows` and the sum of column 0 for 6 fixed scenarios. `parquet-wasm` is arrow-rs compiled to WASM, so it is the same family as arrow-rs. `bench/rust` pins `parquet = 60.1.0` with arrow. | bench/js/src/bench.js `checkResult`; bench/rust/Cargo.toml. |
| F20 | `AllocationLimits` (max dictionary, page and string size) exists in `parquet_reader.zig`, but `DynamicReader` does not use it. | `grep AllocationLimits dynamic_reader.zig` is empty. |

Could not verify here: `--fuzz` on 0.17 for Linux and on macOS (both are supported by the source; zarrow's
docs say 0.17 Debug works). Executions per second for the Parquet targets (budgets below are first
guesses, calibrated in task 1.9). Whether any external writer emits DELTA blocks with large
mini-blocks, or V2 pages with `is_compressed = false`. A local build with C codecs (4 of 5 C packages
are in `zig-parquet/zig-pkg`; zstd is missing).

---

## Ground-truth bug benchmark: the bugs fixed on this branch, and which layer catches them

| Bug (fix commit) | Symptom | Layer that catches it | Phase |
|---|---|---|---|
| RLE/bit-pack byte count in `u5` for bit widths 25-31 (fixed inside cfd392e) | Debug panic; wrong byte count in ReleaseFast | `page` and `encoding` targets: the fuzzer picks the bit width, the safety oracle sees the panic. An exhaustive width sweep found it originally. | 1 |
| Union slot set from a failing `try`, so the OOM errdefer freed undefined bytes (5d4ad3f) | GPF on Linux only, masked on Windows | `file-oom` (fail index chosen by the fuzzer) **on Linux**: the WSL or CI nightly lane. The existing OOM sweep caught it on Linux CI only, which is why the Linux lane is required. | 1 |
| FLBA dictionary page with BIT_PACKED levels, out of bounds (e6dc68a) | panic | `page` target: the recipe picks FLBA + dictionary + BIT_PACKED level encoding directly. `file` reaches it more slowly, through page-header mutation. | 1 |
| Geo CRS leak on failed or repeated LogicalType parse (a81dcb3) | leak | `thrift` target: per-input leak check plus repeated-field mutations, seeded from `parquet-testing/data/geospatial` footers. | 1 |
| Footer-parser OOM leaks (885b5e0, c7c344e) | leak | `thrift` target with OOM injection: the existing sweep, generalised to every seed footer. | 1 |
| `list<struct>` writer wrote `num_children` = field count; visible only when another column follows (9cdfe67) | valid-looking file that fails to read back | `roundtrip` target (multi-column random schemas) and the exhaustive option sweep schema set (2.3). A reader in phase 3 would also reject the file. This is a feature-combination bug, the arrow-rs #10747 class. | 2 |
| DELTA_BINARY_PACKED value-count cap rejected valid files with large mini-blocks (9ffc53a, found by an external review) | valid file rejected | `spec` target: an independent reference encoder over **every legal** block/mini-block size (2.4). Byte fuzzing cannot find it, because a rejection counts as a pass, and the writer round trip cannot find it, because our encoder only emits 128/4. | 2 |
| V2 page with `is_compressed = false` in a compressed chunk gave dangling zero-copy slices (25d3c36) | wrong bytes, no crash | Needs that page shape **plus** a value oracle. Byte fuzzing finds nothing, because every reader mode agrees on the same garbage. Caught by a semantics-preserving rewrite (decompress the V2 page, set the flag) compared with the original (4.2), or by the Arrow-path vs DynamicReader comparison (2.6) on such a seed. | 4 (2 partial) |

Task 1.10 replays this table for real: it re-injects each bug in a scratch worktree and records time-to-detection.

---

## Implementer rules (read fully before your first task)

### R0. Scope

- Do only the task you were given and edit only the files it names. If a correct change needs another
  file, **stop and ask**.
- Line numbers are approximate (base 04555de). Find code by function name.
- One task = one commit, message `<area>: <what>` (`fuzz: page target`, `ci: fuzz smoke job`).
- Library bugs found while building a harness are **not fixed in the harness task**. Follow R5.

### R1. Toolchains and commands (Windows, from the repo root; never `cd` into subdirs)

```
Z16 = C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe     # 0.16.0
Z17 = zig                                                        # 0.17.0 on PATH
make test-lib CODECS=zig-only ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe
make test-lib CODECS=zig-only ZIG=zig
make fmt ZIG=C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe   # then `git diff --stat` must show only your files
zig ast-check <file.zig>                                             # 0.17 parse check of one file
```

Targets added by this plan (task 1.1): `make fuzz-run TARGET=<t> [SECONDS=60] [SEED=n]`,
`make fuzz-replay TARGET=<t> FILES=<path>`, `make fuzz-cov [N=200K]` (Linux/macOS only).

Linux (WSL), for `fuzz-cov`, the `file-oom` lane and anything that "crashed only on Linux":

```
wsl.exe -e bash -lc 'rsync -a --delete --exclude .zig-cache --exclude zig-out --exclude .zig17 --exclude node_modules --exclude target /mnt/c/Users/cable/Documents/dev/zig-parquet/.claude/worktrees/zig-parquet-perf-compat-dc9ccc/ ~/zp/ && cd ~/zp && make fuzz-cov ZIG=$HOME/zig16/zig N=200K'
```

Copy trees to `~/zp`, never `/tmp`. WSL has only Zig 0.16, so 0.17 Linux runs happen in CI.

- Always pass `CODECS=zig-only` locally (the `fuzz-*` targets default to it). C codecs instrumented
  by `--fuzz` do not link (zarrow build.zig:147 learned this), so a `--fuzz` build **must** be
  zig-only.
- "Tests pass" means 919/919 or higher on both versions, plus the new fuzz tests, with no new skips.

### R2. Zig API gotchas (0.16 and 0.17)

- `std.ArrayList(T)`: `.empty`, and pass the allocator to every method. In-memory output goes to
  `std.Io.Writer.Allocating`.
- Files: `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`, `openDir(io, p, .{ .iterate = true })`,
  `it.next(io)`. Copy the exact calls from zarrow `fuzz/fuzz.zig` `listInputs` and `replay`; they compile on both versions.
- `std.testing.allocator` and `std.testing.io` are compile errors outside tests. Harness functions
  take `gpa: Allocator` and `io: std.Io`, and only `test` blocks pass the testing ones.
  `std.testing.FailingAllocator` is fine in the exe.
- Executable entry: `pub fn main(init: std.process.Init) !void` (`init.gpa`, `init.io`, `init.arena`,
  `init.minimal.args.toSlice(arena)`).

### R3. Dual-version rules

Use the AGENTS.md table (`@splat`, never `**`; `std.fmt.allocPrint`; `@intFromEnum`/`@enumFromInt`;
`std.heap.DebugAllocator(.{})`; no new `std.meta.fields`/`Int`/`Tag`; `std.meta.stringToEnum` is
fine). No `builtin.zig_version` gates. `make fmt` only with Z16. **Every task proves both versions
the same way:** `make test-lib CODECS=zig-only` with Z16 and with Z17 (the corpus replay is part of
`test`), plus the task's own `make fuzz-run ... ZIG=<both>` line for exe changes.

### R4. Hardening rules apply to harness code too

The harness parses untrusted bytes just as the library does. Never `@intCast` input-derived values;
use `Input.below(n)`, `% n` or `safe.castTo`. Every slice of input goes through `Input.rest()` or a
bounds check. A harness panic is reported as a library bug, so the harness itself must never panic
on input.

### R5. When a target finds something

1. Save the input. The `run` loop leaves it in `zig-parquet/.fuzz-out/<target>/current.bin`;
   `fuzz-cov` leaves it in `<cache>/f/crash` (strip the first 4 bytes: `tail -c +5 crash > input.bin`).
2. Minimize it: `python zig-parquet/fuzz/minimize.py <target> input.bin out.bin` (task 1.8).
3. Report target, kind (panic message / `fuzz-leak` / `fuzz-oom` / `fuzz-hang` / `mismatch`), the first
   `src/` stack frame, and the minimized file. **Do not fix the library in the same task.**
4. Fix tasks (separate, owner-approved) follow zarrow `docs/fuzzing.md` "Fix it": fix at the trust
   boundary in the shared function. Never loosen validation, catch a panic or special-case the input.
   Then promote the input as a regression (R8).
5. If the input is a *valid* Parquet file (another engine reads it) and zig-parquet rejects it, that is a
   compatibility gap, not a fuzz bug. Add it to `test-files-wild/` with a line in
   `expected-failures.txt` and open an issue.

### R6. Stop and ask when

- a test fails and two honest fix attempts did not fix it;
- a change needs a file the task does not list, or a `src/` change (Phase 1-3 tasks touch `src/` only
  where named);
- the compiler shows a 0.16/0.17 difference that R3 does not cover;
- a target produces more than 3 distinct findings in its first 5 minutes (likely a harness bug).

### R7. What NOT to do (whole plan)

- No new Zig dependencies, no fuzzing frameworks, no Python packages beyond `duckdb` (D6).
- No public API changes. Phase 1-3 add nothing to `src/` except task 2.4's internal encoder parameter.
- No changes to library defaults (checksums, dictionary, page size) to make a target pass.
- No rewrites of zarrow code "to be nicer". Port it, rename it, change only what Parquet needs.

### R8. Regression promotion: where findings live (permanent)

| Finding | Lives in | Name | Expected behaviour recorded in |
|---|---|---|---|
| Crash, leak, hang or OOM on some input (any byte target) | `zig-parquet/fuzz/corpus/<target>/` | `regress-<yyyymmdd>-<area>-<slug>.bin` (minimized raw input, not Smith-encoded) | one line in `zig-parquet/fuzz/corpus/expected.txt`: `<target>/<file> ok \| error.<Name> \| error` |
| Wrong values from a valid file | `zig-parquet/src/tests/<area>_test.zig` | `test "regress: <slug>"` that builds the minimized case in code; or a ≤ 4 KiB file in `fuzz/corpus/file/` plus an exact-row assertion | the test itself |
| Writer bug (round trip or interop) | `zig-parquet/src/tests/writer_*_test.zig` | `test "regress: <slug>"`: write the minimized Case, read it back, compare | the test |
| Another engine's bug (xdiff) | `test-files-arrow/xdiff-known.txt` | `<file> <engine> <reason/upstream link>` | that line |

`zig build test` replays every corpus file on every CI lane and both Zig versions, and asserts the
`expected.txt` outcome exactly. Pinning the error name catches error-class drift as well as crashes.

---

## Phase 1: byte-level harness, safety oracle (about 3-4 Haiku-days)

Goal: every untrusted-input surface gets a target. On every input, the oracle checks that there is
no panic, no leak (per-input count), no live allocation over 256 MiB and no hang over 10 s, and
that every reader mode agrees when they all succeed. Seeds: the 285 existing small files. Drivers:
(a) a seeded mutation loop that works on every OS, including Windows; (b) `std.testing.fuzz`
coverage-guided on Linux/macOS; (c) corpus replay inside `zig build test`. One `runOne(target, gpa, bytes)` backs all three.

Layout (new files only under `zig-parquet/fuzz/`):

```
zig-parquet/fuzz/fuzz.zig        CLI (run/replay/gen-seeds), CountingAllocator, runOne, mutate, std.testing.fuzz tests
zig-parquet/fuzz/common.zig      Input (decision stream), Feedback, valuesEqual, freeRows
zig-parquet/fuzz/t_file.zig      target file / file-oom
zig-parquet/fuzz/t_page.zig      target page
zig-parquet/fuzz/t_encoding.zig  target encoding
zig-parquet/fuzz/t_thrift.zig    target thrift
zig-parquet/fuzz/t_codec.zig     target codec
zig-parquet/fuzz/corpus/<target>/*.bin, corpus/expected.txt
zig-parquet/fuzz/minimize.py     stdlib-only byte minimizer (subprocess per candidate)
```

### Task 1.1 Scaffold: build steps, Makefile, CLI driver, stub targets

- Files: `zig-parquet/build.zig`, `Makefile`, `.gitignore`, `.github/workflows/test.yml` (fmt step
  only), new `zig-parquet/fuzz/{fuzz.zig,common.zig,t_file.zig,t_page.zig,t_encoding.zig,t_thrift.zig,t_codec.zig}`,
  new `zig-parquet/fuzz/corpus/expected.txt`
- Depends on: none (do it first, alone)
- **Model: Sonnet** (port and adapt about 500 lines across two versions)
- build.zig: insert after the bench block:

```zig
    // Fuzzing (HARDENING.md "Fuzzing"): harness exe + std.testing.fuzz tests, one runOne per target.
    {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("fuzz/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        });
        fuzz_mod.addImport("parquet", parquet_mod);
        fuzz_mod.addImport("build_options", build_options.createModule());
        const fuzz_exe = b.addExecutable(.{ .name = "zp-fuzz", .root_module = fuzz_mod });
        const fuzz_run = b.addRunArtifact(fuzz_exe);
        passArgs(b, fuzz_run);
        b.step("fuzz", "Fuzz harness: zig build fuzz -- <target> run|replay|gen-seeds ...").dependOn(&fuzz_run.step);
        b.step("fuzz-install", "Install zig-out/bin/zp-fuzz (used by fuzz/minimize.py)").dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);

        const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
        const fuzz_tests_run = b.addRunArtifact(fuzz_tests);
        fuzz_tests_run.step.dependOn(&check_test_files.step);
        test_step.dependOn(&fuzz_tests_run.step); // corpus replay + expected.txt on every `zig build test`
        b.step("fuzz-cov", "Coverage-guided: zig build fuzz-cov --fuzz=N -Dcodecs=zig-only (Linux/macOS)").dependOn(&fuzz_tests_run.step);
    }
```

- Makefile (keep `.PHONY` + tab style; add the three to `help`; add `$(LIB_DIR)/fuzz` to the `fmt` line):

```make
FUZZ_CACHE = $(if $(filter 0.16.%,$(ZIG_VERSION)),$(LIB_DIR)/.zig-cache,.zig17/cache)

fuzz-run:
	@test -n "$(TARGET)" || { echo "usage: make fuzz-run TARGET=<target> [SECONDS=60] [SEED=n] [OPT=ReleaseSafe]"; exit 1; }
	cd $(LIB_DIR) && $(ZIG) build fuzz $(call zcache,..) -Dcodecs=$(or $(CODECS),zig-only) -Doptimize=$(or $(OPT),ReleaseSafe) -- $(TARGET) run $(or $(SECONDS),60)s --out .fuzz-out/$(TARGET) $(if $(SEED),--seed $(SEED))

fuzz-replay:
	@test -n "$(TARGET)" -a -n "$(FILES)" || { echo "usage: make fuzz-replay TARGET=<target> FILES=<file|dir>"; exit 1; }
	cd $(LIB_DIR) && $(ZIG) build fuzz $(call zcache,..) -Dcodecs=$(or $(CODECS),zig-only) -- $(TARGET) replay $(FILES)

# Zig's coverage-guided fuzzer. Linux/macOS only. 0.16 needs ReleaseSafe (Debug -ffuzz does not compile).
# `zig build --fuzz=N` exits 0 even on a crash, so check for the saved input.
fuzz-cov:
	rm -f $(FUZZ_CACHE)/f/crash
	cd $(LIB_DIR) && $(ZIG) build fuzz-cov $(call zcache,..) -Dcodecs=zig-only -Doptimize=$(or $(OPT),ReleaseSafe) --fuzz=$(or $(N),200K)
	@if test -e $(FUZZ_CACHE)/f/crash; then mkdir -p $(LIB_DIR)/.fuzz-out; tail -c +5 $(FUZZ_CACHE)/f/crash > $(LIB_DIR)/.fuzz-out/cov-crash.bin; echo "fuzz-cov: finding saved to $(LIB_DIR)/.fuzz-out/cov-crash.bin"; exit 1; fi
```

- `.gitignore`: add `.fuzz-out/`. `test.yml` `fmt` job: append `zig-parquet/fuzz` to the `zig fmt --check` list.
- `fuzz.zig`: port zarrow `fuzz/fuzz.zig` as follows:
  - Copy l.69-137 (`CountingAllocator`, `runOne`) with zarrow's `Feedback` replaced by `common.Feedback`.
  - Copy l.700-778 (`tokens`, `interesting`, `mutate`). Use these tokens:
    `"PAR1"`, `"\x15\x00"`, `"\x15\x02"`, `"\x16\x00"`, `"\x19\x1c"`, `"\x00"` (Thrift stop),
    `@as([4]u8, @splat(0xff))`, `"\x00\x00\x00\x00"`.
  - Copy l.780-991 (`hexName`, `watchdog`, `panic`, `usage`, `main`, `listInputs`, `replay`, `run`).
  - In `listInputs`, skip names that do not end in `.parquet` or `.bin`.
  - Copy l.1069-1080 (Smith glue).
  - `max_input_len = 64 << 10`.
  - `run` without `--corpus` uses `fuzz/corpus/<target>` plus `seed_dirs` (below), each passed through `adaptSeed`.
  - Leave out zarrow's `genSeeds`/`transcode`/compute/array/c-abi code.

```zig
pub const Target = enum { file, @"file-oom", page, encoding, thrift, codec };

/// Seed directories (relative to zig-parquet/), one level each: listInputs does not recurse.
pub const seed_dirs = [_][]const u8{
    "../test-files-wild",                         "../test-files-wild/parquet-testing/data",
    "../test-files-wild/parquet-testing/bad_data", "../test-files-wild/parquet-testing/data/geospatial",
    "../test-files-arrow/basic",                  "../test-files-arrow/compression",
    "../test-files-arrow/edge_cases",             "../test-files-arrow/encodings",
    "../test-files-arrow/interop",                "../test-files-arrow/logical_types",
    "../test-files-arrow/multipage",              "../test-files-arrow/nested",
    "../test-files-arrow/structure",
};

/// Turns a seed file into an input for `target`, or null if it does not apply.
/// .parquet seeds: file/file-oom take the bytes as they are (file-oom prepends two 0xff bytes =
/// no injected failure); thrift takes the footer (bytes between the 4-byte length and "PAR1"); others skip.
/// .bin files from fuzz/corpus/<target>/ are already in target format.
fn adaptSeed(target: Target, name: []const u8, bytes: []const u8, out: Allocator) !?[]const u8
```

  Tests at the bottom, one per target:

```zig
fn fuzzTarget(target: Target) !void {
    // Seeds live for the whole process (the fuzzer may keep them): page_allocator, never freed.
    // ponytail: process-lifetime seeds, a few MB.
    const seeds = try loadSeeds(std.heap.page_allocator, std.testing.io, target, .smith_encoded);
    try std.testing.fuzz(target, fuzzOne, .{ .corpus = seeds });
}
test "fuzz file" { try fuzzTarget(.file); }
// ... one per Target ...
test "fuzz corpus expectations" { /* parse fuzz/corpus/expected.txt, runOne each, compare outcome exactly */ }
```

  `loadSeeds(.smith_encoded)` returns each adapted seed as `u32 LE len ++ bytes` (F8 format).
- `common.zig`:

```zig
//! Shared fuzz helpers.
const std = @import("std");

/// Fuzz decisions read from the input. Exhausted input yields zeros, so a shorter
/// input is always a smaller case: truncating is our shrinker.
pub const Input = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn byte(in: *Input) u8 {
        if (in.pos >= in.bytes.len) return 0;
        defer in.pos += 1;
        return in.bytes[in.pos];
    }
    /// In [0, n); 0 when n == 0.
    pub fn below(in: *Input, n: usize) usize {
        if (n == 0) return 0;
        return (@as(usize, in.byte()) | @as(usize, in.byte()) << 8) % n;
    }
    /// Little-endian, zero-padded past the end.
    pub fn int(in: *Input, comptime T: type) T {
        var buf: [@sizeOf(T)]u8 = @splat(0);
        for (&buf) |*b| b.* = in.byte();
        return std.mem.readInt(T, &buf, .little);
    }
    pub fn rest(in: *Input) []const u8 {
        const r = in.bytes[@min(in.pos, in.bytes.len)..];
        in.pos = in.bytes.len;
        return r;
    }
};

/// What one execution looked like; a new `sig` grows the run loop's corpus.
pub const Feedback = struct {
    err: ?anyerror = null,
    rows: u64 = 0,
    detail: u64 = 0, // target-specific bits (encodings seen, reader modes that succeeded, ...)

    pub fn sig(f: Feedback) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (f.err) |e| @errorName(e) else "ok");
        h.update(std.mem.asBytes(&@min(f.rows, 8)));
        h.update(std.mem.asBytes(&f.detail));
        return h.final();
    }
};
```

- Each `t_*.zig` stub: `pub fn run(gpa: std.mem.Allocator, bytes: []const u8, fb: *common.Feedback) !void { _ = gpa; _ = bytes; _ = fb; }`
  (`t_file.run` takes an extra `oom: bool`).
- `expected.txt`: a header comment with the format from R8 and no entries.
- Test: `make test-lib CODECS=zig-only` on both versions (6 fuzz tests + expectations pass).
  `make fuzz-run TARGET=file SECONDS=5 ZIG=<both>` prints "done, N execs".
  `make fuzz-replay TARGET=file FILES=../test-files-wild ZIG=zig` prints "replayed".
  WSL: `make fuzz-cov ZIG=$HOME/zig16/zig N=1K` exits 0 and prints the FUZZING REPORT.
- Acceptance: the above, plus `make fmt ZIG=<Z16>` produces no diff and `git status` shows no `.fuzz-out` files.

### Task 1.2 ∥ `file` / `file-oom` target: whole-file read, metamorphic across reader modes

- Files: `zig-parquet/fuzz/t_file.zig`, `zig-parquet/fuzz/common.zig` (add `valuesEqual`, `freeRows`)
- Depends on: 1.1
- Change: for `oom`, the first 2 bytes choose `fail_index = int(u16)` (`0xffff` = never fail). Wrap
  `gpa` in `std.testing.FailingAllocator.init(gpa, .{ .fail_index = ... })`; the rest of the bytes are the
  file. Then:
  1. `var r = parquet.openBufferDynamic(a, file, .{ .checksum = .{ .validate_page_checksum = (hash(file) & 7) == 0 } }) catch |e| return e;`
     then `defer r.deinit()`.
  2. Reference: for each row group `rg < min(getNumRowGroups(), 16)`, `readAllRows(rg)`. Stop at 4096 rows in
     total (keep the read bounded). An error ends the target with that error.
  3. Each of these must produce rows **equal to the reference** whenever it succeeds without error:
     `rowIterator()`, `rowIteratorStreaming()`, and `readRowsProjected(rg, cols)`, where `cols` is
     the subset given by the bits of `hash(file)` over the top-level column count. The projected rows
     are compared with the matching columns of the reference.
     A mode that errors where the reference succeeded is a mismatch **only for OOM-free runs**
     (`!oom`); with `oom` set, any mode may hit the injected failure.
  4. A mismatch calls `std.debug.panic("fuzz-mismatch: {s} rg {d} row {d} col {d}", ...)`.
  5. `fb.rows` = reference row count; `fb.detail` = bit set of modes that succeeded.
- `valuesEqual(a: Value, b: Value) bool`: deep equality over all 11 `Value` variants. Floats compare by
  bit pattern, except that any NaN equals any NaN. Slices compare by content. Map entries and
  struct fields compare in order, and field names must match.
  `freeRows(gpa, rows)`: `for (rows) |row| row.deinit(); gpa.free(rows);` (the pattern from roundtrip_test.zig:97-101).
- Test: both versions pass. `make fuzz-run TARGET=file SECONDS=60` and `TARGET=file-oom SECONDS=60` on Windows; no
  finding is expected, but if there is one, follow R5. Add a unit test in `common.zig` for `valuesEqual` (NaN, -0.0,
  nested list vs struct, different field names).
- Acceptance: the corpus replay in `zig build test` exercises all ≤ 64 KiB seeds through every mode with
  no mismatch, and the whole fuzz test binary adds ≤ 30 s to `make test-lib` in Debug (if it adds more, report the
  number; do not drop seeds silently). Note the execs per second printed by `run` in the commit body.

### Task 1.3 ∥ `page` target: one page through the column decoder

- Files: `zig-parquet/fuzz/t_page.zig`
- Depends on: 1.1
- Change: decode the recipe below with `common.Input`, then call
  `parquet.internals.column_decoder.decodeColumnDynamicWithValueEncoding` (V1) or
  `decodeColumnDynamicV2` (V2) with `gpa`. On success: `fb.rows = result.values.len`, then `result.deinit(gpa)`.
  Every dictionary built is `deinit`ed. Recipe (byte offsets are `Input` reads in order):

```
physical   = [boolean,int32,int64,int96,float,double,byte_array,fixed_len_byte_array][below(8)]
type_len   = 1 + below(32)                        (FLBA only; also sets schema_elem.type_length)
value_enc  = [plain,plain_dictionary,rle,bit_packed,delta_binary_packed,delta_length_byte_array,
              delta_byte_array,rle_dictionary,byte_stream_split][below(9)]
flags      = byte(): bit0 def enc bit_packed (else rle), bit1 rep enc bit_packed, bit2 V2, bit3 dictionary
max_def    = below(4);  max_rep = below(3);  num_values = below(4097)
if dictionary: dict_count = below(257); dict_len = below(4097); dict bytes = next dict_len bytes;
               build the dictionary that matches `physical` with its `fromPlain(gpa, dict, dict_count)`
               (FixedByteArrayDictionary also takes type_len); a build error ends the target with that error
if V2:      rep_len = below(1025); def_len = below(1025); rep, def = next bytes; values = rest()
else:       page data = rest()
schema_elem = .{ .type_ = physical, .type_length = (FLBA) type_len, .repetition_type = if max_def>0 .optional else .required, .name = "c" }
```

- No enum conversion from raw input ints: the arrays above are indexed by `below(n)`, so every chosen value is a valid enum.
- Test: both versions pass. `make fuzz-run TARGET=page SECONDS=60`. Add `gen-seeds` support: write
  `fuzz/corpus/page/gen-<type>-<enc>.bin` recipes whose page data comes from the library's own encoders
  (`plain_encoder`, `rle_encoder`, `delta_*_encoder`, `byte_stream_split_encoder`) for 16 values of each
  supported (type, encoding) pair. Commit them (≤ 100 files, ≤ 64 KiB total).
- Acceptance: as above; with the u5 widening removed locally (1.10 recipe), `run` finds the panic within 60 s.
  Check this once and record the time in the commit body. Do not commit the injection.

### Task 1.4 ∥ `encoding` target: encoder → decoder round trips + raw decoder bytes

- Files: `zig-parquet/fuzz/t_encoding.zig`
- Depends on: 1.1
- Change: `mode = below(2)`.
  - mode 0 (round trip): `kind = below(7)` picks one of RLE/bit-packed hybrid (bit width `below(32)`,
    values masked to the width), DELTA_BINARY_PACKED i32/i64, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY,
    BYTE_STREAM_SPLIT f32/f64, or PLAIN byte arrays. It generates `below(2049)` values from `Input` (byte
    arrays: `below(33)` lengths with bytes from the input), encodes with `parquet.internals.encoding.*_encoder`,
    decodes with the matching decoder, and checks equality. A **mismatch or a decoder error on encoder
    output** is a panic: `std.debug.panic("fuzz-mismatch: encoding {s}", ...)`.
  - mode 1 (raw): read `const bw: u5 = @truncate(in.below(32)); // below(32) < 32` and `n = below(4097)`, then pass
    `rest()` to each decoder (`rle.decode(gpa, data, bw, n)`,
    `delta_binary_packed.decodeInt32/64`, `delta_length_byte_array`, `delta_byte_array`, `byte_stream_split`).
    Errors are passes.
- Check the exact encoder/decoder signatures in `src/core/encoding/*.zig` before writing calls. If one
  needs a parameter not described here, **stop and ask**.
- Test / Acceptance: both versions pass; `make fuzz-run TARGET=encoding SECONDS=60` has no findings (or an R5 report).

### Task 1.5 ∥ `thrift` target: footer and page-header parsing with OOM injection

- Files: `zig-parquet/fuzz/t_thrift.zig`
- Depends on: 1.1
- Change: `fail = int(u16)` (`0xffff` = no failure) and `which = below(4)`. Wrap gpa in a FailingAllocator. Parse
  `rest()` with `thrift.CompactReader.init(rest)` as `which` selects: 0 `format.FileMetaData`, 1
  `format.PageHeader`, 2 `format.ColumnIndex`, 3 `format.OffsetIndex`. Check the names in
  `src/core/format/{metadata,page,page_index}.zig`. On success, `deinit` with the same allocator.
  `adaptSeed` gives footers with `which = 0` (prefix `ff ff 00 00`).
- This generalises footer_parse_test.zig's sweep to every seed footer and to mutated footers.
- Test / Acceptance: both versions pass; `make fuzz-run TARGET=thrift SECONDS=60`. Reverse-applying a81dcb3's
  `logical_types.zig` hunk locally (`git show a81dcb3 -- zig-parquet/src/core/format/logical_types.zig | git apply -R`)
  is found as `fuzz-leak` within 5 minutes. Record the time, then `git checkout -- zig-parquet/src/core/format/logical_types.zig`.

### Task 1.6 ∥ `codec` target: the five pure-Zig decompressors

- Files: `zig-parquet/fuzz/t_codec.zig`
- Depends on: 1.1
- Change: `codec = [snappy,gzip,brotli,lz4_raw,zstd][below(5)]`, `hint = below(1 << 20)`, then
  `parquet.internals.compress.decompress(gpa, rest(), codec, hint)`; free on success. A second mode (`below(2) == 1`)
  compresses `rest()` with `compress.compress`, decompresses with the true length and compares (round
  trip); a mismatch is a panic.
- `gen-seeds` writes `fuzz/corpus/codec/gen-<codec>-<n>.bin` by compressing 4 fixed buffers (1 KiB zeros, 1 KiB
  ASCII text, 1 KiB random from `DefaultPrng.init(1)`, a 16 KiB repeating 7-byte pattern filled in a loop) with each codec.
- Test / Acceptance: both versions pass; `make fuzz-run TARGET=codec SECONDS=120`. These are large hand-written
  decoders (brotli, zstd, gzip), so this is the highest-risk memory-safety surface. Report any finding by R5.

### Task 1.7 Corpus replay assertions and the regression convention

- Files: `zig-parquet/fuzz/fuzz.zig` (the `test "fuzz corpus expectations"` body), `zig-parquet/HARDENING.md`
  (new section "Fuzzing and regressions": R5, R8, commands, budgets; about 60 lines, link the plan)
- Depends on: 1.2-1.6
- Change: the expectations test reads `fuzz/corpus/expected.txt` (skip `#` and blank lines). Each line is
  `<target>/<file> <outcome>`. It runs `runOne` and asserts: `ok` → no error; `error` → some error;
  `error.X` → exactly `X`. It must also fail if a `regress-*` file in the corpus has **no** line (a missing
  expectation is an error).
- Test: add one deliberate entry pointing at a committed tiny input (`fuzz/corpus/thrift/regress-20261102-empty-footer.bin`,
  4 bytes `ff ff 00 00` → `error`) and check that `zig build test` passes. Edit the line to `ok`, check that it fails,
  then revert the edit.
- Acceptance: both versions pass; HARDENING.md section written.

### Task 1.8 ∥ Minimizer

- Files: new `zig-parquet/fuzz/minimize.py` (stdlib only, under 80 lines)
- Depends on: 1.1
- Change: `python zig-parquet/fuzz/minimize.py <target> <in> <out> [--exe zig-parquet/zig-out/bin/zp-fuzz]`.
  Run `<exe> <target> replay <in>` once and record the "signature": the exit code and the first line containing
  `panic`, `fuzz-` or `error:`. Then a ddmin-lite loop: for `chunk` in `len/2, len/4, …, 1`, try deleting
  each `chunk`-sized range and keep it if the signature is unchanged; then try zeroing single bytes. Each
  candidate is written to a temp file in the same dir as `<out>` and run in a subprocess with a 20 s timeout.
  Print the before/after sizes. Build the exe first with `make` target `fuzz-install` (add a one-line Makefile
  recipe `fuzz-install: cd $(LIB_DIR) && $(ZIG) build fuzz-install $(call zcache,..) -Dcodecs=zig-only`).
- Test: make a fake finding by temporarily adding `if (bytes.len > 10 and bytes[3] == 'Z') @panic("probe")` to
  `t_codec.run`, minimize a 2 KiB input containing it, and check the output is ≤ 11 bytes. Revert the probe.
- Acceptance: the above. (The Makefile edit is the only shared file; do it after 1.1 lands.)

### Task 1.9 CI: PR smoke job and nightly campaign

- Files: `.github/workflows/test.yml` (new job `fuzz-smoke`), new `.github/workflows/fuzz-nightly.yml`
- Depends on: 1.2-1.8; D3 for the schedule
- `fuzz-smoke` (every PR, ubuntu-latest, Zig 0.17.0, `timeout-minutes: 15`): generate test files (the
  existing two steps), then

```yaml
      - name: Mutation smoke, 30 s per target (ReleaseSafe)
        run: |
          for t in file file-oom page encoding thrift codec; do
            make fuzz-run TARGET=$t SECONDS=30 SEED=${{ github.run_id }} || { echo "::error::fuzz finding in $t (seed ${{ github.run_id }})"; exit 1; }
          done
      - name: Coverage-guided smoke (informational)
        continue-on-error: true
        run: make fuzz-cov N=50K
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: fuzz-smoke-findings
          path: zig-parquet/.fuzz-out
```

- `fuzz-nightly.yml`: `schedule: cron "0 3 * * *"` plus `workflow_dispatch` (input `seconds`, default 600). A
  matrix over the 6 targets, each `make fuzz-run TARGET=<t> SECONDS=<seconds> SEED=${{ github.run_id }}`
  (`timeout-minutes: 20`, upload `.fuzz-out/<t>` always). Two informational jobs (`continue-on-error: true`) run
  `make fuzz-cov N=2M`, one with setup-zig `0.17.0` and one with `0.16.0` (the recipe already uses ReleaseSafe).
- Budgets: PR fuzz job about 5-7 min (3 min mutation + build + about 1-2 min coverage smoke). Nightly about 6 × 10 +
  2 × 15 ≈ **90 runner-min/night**, free on a public repo (F13). Long campaigns stay local:
  `make fuzz-run TARGET=file SECONDS=3600` (Windows) or the WSL `fuzz-cov N=50M` line from R1.
- Calibrate: after the first green nightly, put the exec/s per target in HARDENING.md. If any PR target does
  under 200 execs in its 30 s, report it and do not raise the budget.
- Acceptance: both workflows run green on a pushed branch (the owner pushes; implementers do not).

### Task 1.10 Ground-truth bug benchmark (Phase 1 part)

- Files: `zig-parquet/HARDENING.md` (table "Fuzz benchmark: time to find known bugs")
- Depends on: 1.2-1.8
- **Model: Sonnet** (manual re-injection, judging what "found" means)
- Work in a scratch worktree: `git worktree add C:/Users/cable/AppData/Local/Temp/zpbb HEAD`. Run every
  command there; never touch the main tree. For each bug, inject it, run the target with seeds 1-3 for at
  most 300 s each, record the median time-to-finding (or "not found in 300 s"), then `git -C <wt> checkout -- .`
  Injections:
  - u5 overflow: in `src/core/encoding/rle.zig`, change `(@as(usize, bit_width) + 7) / 8` back to `(bit_width + 7) / 8`
    and `(@as(usize, bit_offset) + bit_width + 7) / 8` to `(bit_offset + bit_width + 7) / 8`. Targets: page, encoding.
    The default ReleaseSafe keeps overflow checks, so it traps like Debug. Record the mode used.
  - union slot (5d4ad3f): `git show 5d4ad3f -- zig-parquet/src/core | git apply -R`. Target file-oom, **in WSL**
    (`rsync` the scratch worktree to `~/zpbb`), plus once on Windows to confirm "masked on Windows".
  - FLBA levels (e6dc68a): `git show e6dc68a -- zig-parquet/src/core | git apply -R`. Targets: page, file.
  - geo crs (a81dcb3) and RowGroup parse leak (`git show c7c344e -- zig-parquet/src/core/format/row_group.zig | git apply -R`). Target: thrift.
  - V2 dangling (25d3c36): in `readColumnChunkData` call site of `dynamic_reader.zig`, re-add
    `const chunk_alloc = if (meta.codec == .uncompressed) page_alloc else self.allocator;` and read/free the chunk with
    it. Target: file. **Expected: not found** (see the benchmark table); record it anyway.
  - list<struct> (9cdfe67) and DELTA cap (9ffc53a): reverse-apply; targets: file. **Expected: not found in Phase 1**;
    these are the Phase 2 acceptance cases (tasks 2.2, 2.4).
- Acceptance: a table with one row per bug (target, mode, OS, seeds, median time or not-found), committed in HARDENING.md.
  `git worktree remove` the scratch tree.

### Task 1.11 Gate 1

- Both versions: `make test-lib CODECS=zig-only` (919 + fuzz tests), `make test-cli CODECS=zig-only`, `make wasm`.
  `make fuzz-run` 60 s per target on Windows (0.16 and 0.17). WSL `make fuzz-cov ZIG=$HOME/zig16/zig N=200K` and
  `make fuzz-run TARGET=file-oom SECONDS=300`.
- Pass: no unexpected findings (each finding is reported by R5 and has an owner decision). The benchmark table
  shows u5, FLBA, geo-crs, row-group leak and union-slot (Linux) **found**. CI fuzz-smoke is green.

---

## Phase 2: schema-aware generation, round trip, metamorphic cross product (about 4-5 days)

Goal: catch the bugs that live in valid files and feature combinations (list<struct>, DELTA cap), which byte
fuzzing cannot see. The oracle is the generated Case itself: what was written must be read back, in every reader
mode, under every writer option.

### Task 2.1 Case generator

- Files: new `zig-parquet/fuzz/case.zig`
- Depends on: Gate 1
- **Model: Sonnet or Opus**
- Change: `pub fn generate(in: *common.Input, arena: Allocator) !Case`, where `Case = { columns: []ColumnSpec, rows: [][]Value, opts: WriterOpts }`.
  - Columns: `1 + below(6)`. A leaf type comes from the TypeInfo presets (dynamic_writer.zig l.79-125: bool_, int32,
    int64, float_, double_, bytes, string, date, uuid, json, enum_, bson, float16, interval, timestamp_*, time_*,
    int8…uint64, `forDecimal(p, s)` with p in {5, 18, 30}, `fixedBytes(1 + below(16))`), optional with
    probability 1/2. Nesting (`below(4) == 0`, depth ≤ 3): list, struct (1-3 fields), map (key: string or int32).
    Build the nodes with `allocSchemaNode`/`allocSchemaFields` and add them with `addColumnNested`.
    **Bias:** put a nested column before at least one other column in half of the cases (the 9cdfe67 shape).
  - Rows: `below(5)` picks a count in {0, 1, 7, 100, 1000+below(1000)}. Null density per column in {0, 5%, 50%, 100%}.
    Values are biased to boundaries: min/max ints, 0, -0.0, NaN, ±inf, empty strings and lists, 1-byte and 4 KiB strings,
    runs of equal values (so dictionary and RLE engage), and long single-null or single-value gaps.
  - Values are built in **the reader's representation** (what `readAllRows` returns for that TypeInfo). Find it by
    reading `dynamic_reader_test.zig` and `roundtrip_test.zig` for each preset before writing the generator. If a type's
    read-back form differs from its write form, record the mapping in a comment table at the top of `case.zig`.
  - WriterOpts: codec per column from {uncompressed, snappy, gzip, lz4_raw, zstd, brotli}; `use_dictionary`; encoding
    per column from the types `validateEncodingForType` allows; `max_page_size` in {64, 1024, 8192, default};
    `setRowGroupSize` in {1, 7, 1000, default}; page checksum on/off; `write_page_index` on/off; and
    `setDictionarySizeLimit` in {16, default}.
  - `pub fn write(case, gpa) ![]u8` uses `createBufferDynamic` → `addColumn`/`addColumnNested` → `begin` → per row
    `setValue` → `addRow` → `close` → `toOwnedSlice`.
- Test: a unit test generates 200 cases from seeds 0..199 (random bytes from `std.Random.DefaultPrng.init(seed)`, 4 KiB each)
  and writes each without error. Writer errors on generated input are generator bugs: fix the generator, not the writer.
- Acceptance: both versions pass; the test takes under 10 s in Debug.

### Task 2.2 `roundtrip` target: every reader mode against the Case

- Files: new `zig-parquet/fuzz/t_roundtrip.zig`; `fuzz.zig` (add `.roundtrip` to `Target`, dispatch and test; `adaptSeed` returns null)
- Depends on: 2.1
- Change: generate → write → `openBufferDynamic` (checksum validation on when the case wrote checksums) → check:
  1. `readAllRows` over all row groups == `case.rows` (`valuesEqual`), and `getTotalNumRows()` == the row count.
  2. `rowIterator`, `rowIteratorStreaming`: same rows.
  3. `readRowsProjected` and `rowIteratorStreamingProjected` with a projection drawn from the Input: the projected columns of `case.rows`.
  4. If the schema is flat and `write_page_index` is on: `readRowsFiltered(rg, &.{})` == that row group's rows. Then
     pick one int64 or int32 column and a range predicate (`ColumnFilter`, see `page_filter.zig`). Every case row
     matching the predicate must appear in the result, in order (pushdown may keep extra rows, never drop one).
  5. Writer metamorphic: rewrite the same rows with `opts` toggled in one dimension (dictionary, or codec, or page size)
     and check (1) again.
  Any failure: `std.debug.panic("fuzz-mismatch: roundtrip {s}", ...)`; a write error on a valid Case is also a panic.
- Run 300 cases (seeds 0..299) in a plain `test "roundtrip cases"` so every `zig build test` covers them, within ≤ 15 s Debug.
- Acceptance: both versions pass. In a scratch worktree, `git show 9cdfe67 -- zig-parquet/src/core/writer.zig | git apply -R`
  is caught by `make fuzz-run TARGET=roundtrip SECONDS=120`. Add the result to the HARDENING.md benchmark table.

### Task 2.3 ∥ Exhaustive writer-option sweep over fixed schemas

- Files: new `zig-parquet/src/tests/option_sweep_test.zig`, `zig-parquet/src/tests/mod.zig` (one import line)
- Depends on: Gate 1 (independent of 2.1)
- Change: 3 fixed schemas: (a) one optional column of every flat preset; (b) `list<struct<a:int32,b:string>>` **followed
  by** `int64` and `string`; (c) `map<string,int64>` then `list<list<int32>>`. Fixed 50 rows per schema with nulls every 3rd
  row. Full cross product: codec {6} × dictionary {on, off} × page size {64, default} × checksum {on, off} × page index {on, off}
  = 96 combinations per schema. Each is written, read with `readAllRows`, and compared with the input rows. Encodings stay
  at the defaults; the generator covers those.
- This is the research note's cross product made exhaustive where the space is small.
- Acceptance: both versions pass; runtime ≤ 10 s Debug; reverse-applying 9cdfe67 makes it fail (check, then revert).

### Task 2.4 ∥ `spec` target: spec-legal streams our writer never emits (reader acceptance oracle)

- Files: new `zig-parquet/fuzz/t_spec.zig`; `fuzz.zig` (Target `.spec`); `zig-parquet/src/core/encoding/delta_binary_packed_encoder.zig`
  (only to add `pub fn encodeWithParams`; the existing functions call it with 128/4, and their byte output is unchanged)
- Depends on: Gate 1
- **Model: Sonnet** (format detail)
- Change: an independent reference **only where the library has no parameter**; otherwise parameterise the library encoder:
  - DELTA_BINARY_PACKED: `block_size = 128 * (1 + below(32))`, `mini_blocks` = a divisor of `block_size / 32` chosen by
    `below`. Encode with `encodeWithParams`; the reader must return exactly the values (`decodeInt32/64`). Include the
    all-equal case (bit width 0) and the 2049-zero case from 9ffc53a's test.
  - RLE/bit-packed hybrid: a test-local writer (about 40 lines in `t_spec.zig`, following the spec's grammar) that splits the
    value stream into random RLE and bit-packed runs (bit-packed groups padded to 8 values), bit width `below(32)`. `rle.decode` == values.
  - BYTE_STREAM_SPLIT for FLBA widths 1..16 (the reader supports FLBA; the writer does not).
  - V2 data page assembly: level bytes RLE **without** a length prefix, plus PLAIN values → `decodeColumnDynamicV2` == values,
    for optional and repeated columns (max_rep 1).
  A rejection or a wrong value is a panic (`fuzz-reject-valid` / `fuzz-mismatch`).
- Acceptance: both versions pass; existing golden-byte tests still pass (the encoder's default output is unchanged).
  Reverse-applying 9ffc53a in a scratch worktree is caught within 60 s; add it to the benchmark table.

### Task 2.5 ∥ Writer-option ledger assertion

- Files: `zig-parquet/fuzz/t_roundtrip.zig`, `zig-parquet/fuzz/case.zig`
- Depends on: 2.2
- Change: `case.zig` counts the cells of the "written" column of the coverage matrix (below) it produced. The
  `roundtrip cases` test asserts that every **required** cell is non-zero after its 300 cases, and prints the table
  with `std.debug.print` only when an assertion fails.
- Acceptance: both versions pass; deleting a dimension from the generator (try it locally) fails the test.

### Task 2.6 `arrow` target: Arrow C Data bridge and C ABI stream, structurally validated

- Files: new `zig-parquet/fuzz/t_arrow.zig`, new `zig-parquet/fuzz/arrow_check.zig`; `fuzz.zig` (Target `.arrow`)
- Depends on: 1.2
- **Model: Sonnet or Opus**
- Change: for file bytes:
  (a) `readRowGroupAsArrow(gpa, reader.getSource(), reader.metadata, rg, null)` and with a projection;
  (b) through the C ABI, calling the Zig functions directly: `zp_reader_open_memory` → `zp_reader_get_stream` →
      `get_schema`/`get_next` until end → `release`, checking error codes via `zp_reader_error_code`.
  `arrow_check.validate(schema, array)` is a minimal ValidateFull equivalent: `length ≥ 0`;
  `null_count ≤ length`; the validity bitmap is long enough; offsets are monotone and within the data
  buffer (utf8/binary/list/map); child lengths match the format string (`+l`, `+s`, `+m`, `w:N`);
  `release` is non-null exactly once. When the DynamicReader path also succeeds, the Arrow values must
  equal the DynamicReader rows column by column (convert Arrow → `Value` in `arrow_check.zig`).
- Acceptance: both versions pass; 10 min `run` on Windows without unexplained findings. Construct the V2 seed from
  the 25d3c36 regression test (copy its builder into `gen-seeds` as `fuzz/corpus/file/gen-v2-uncompressed-in-snappy.bin`),
  inject 25d3c36 in a scratch tree, and record whether `arrow` catches it.

### Task 2.7 Gate 2

- The Gate 1 commands, plus `make fuzz-run` 120 s each for roundtrip, spec and arrow on both versions, and the WSL
  `fuzz-cov`. The benchmark table now shows list<struct> and DELTA cap **found**. CI: add `roundtrip spec arrow` to the
  smoke and nightly target lists (edit 1.9's loops).

---

## Phase 3: cross-engine differential (about 3-4 days; D1, D6)

Goal: interoperability correctness in both directions. Readers: zig-parquet, PyArrow (Arrow C++), DuckDB (independent C++)
and arrow-rs (independent Rust). Parquity's "no privileged oracle" rule applies: any engine that disagrees with the others
is reported, including zig-parquet. Files under test: `test-files-wild`, `test-files-arrow`, plus N files generated by
the Phase 2 generator (zig as the writer).

Canonical row form (all engines must emit this exactly; JSON Lines, one object per row, keys = top-level columns in schema order):

| Parquet leaf (physical / logical) | canonical JSON value |
|---|---|
| null at any level | `null` (a null list ≠ an empty list `[]`) |
| BOOLEAN | `true` / `false` |
| INT32, INT64 (any INT/DATE/TIME/TIMESTAMP annotation) | decimal **string** of the *physical signed* value (`"-5"`). Unsigned annotations are shown as their signed bit pattern. |
| FLOAT, DOUBLE | `"f32:xxxxxxxx"` / `"f64:xxxxxxxxxxxxxxxx"` hex of the bits; every NaN → `"nan"` |
| DECIMAL (any physical) | `"dec:<unscaled integer>"` |
| INT96 | `"i96:<24 hex>"` of the 12 stored bytes |
| BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY (all other logical types: STRING, ENUM, JSON, BSON, UUID, FLOAT16, INTERVAL, GEOMETRY, GEOGRAPHY) | `"hex:<lowercase hex>"` |
| LIST | array |
| MAP | array of `[key, value]` pairs, in file order |
| STRUCT | object, fields in schema order |

### Task 3.1 `dump` subcommand (zig-parquet side)

- Files: `zig-parquet/fuzz/fuzz.zig` (subcommand `dump <file>` to stdout), `zig-parquet/fuzz/common.zig` (`writeCanonical`)
- Depends on: Gate 1
- Change: open with `openFileDynamic`, iterate with `rowIteratorStreaming`, and emit the canonical form. The leaf logical
  type comes from `getColumnLogicalType` (decimal and the physical type come from `getLeafSchemaElement`). Unit tests cover one
  value of each row of the table.
- Acceptance: both versions pass; `(cd zig-parquet && zig build fuzz -Dcodecs=zig-only --cache-dir ../.zig17/cache -- dump ../test-files-arrow/interop/nested.parquet)`
  prints JSONL (subshell form only, never a bare `cd`).

### Task 3.2 `xdiff.py`: PyArrow and DuckDB normalizers, pairwise comparison

- Files: new `test-files-arrow/xdiff.py`, new `test-files-arrow/xdiff-known.txt`, `test-files-arrow/pyproject.toml` +
  `uv.lock` (dependency group `xdiff = ["duckdb>=1.5"]`, D6)
- Depends on: 3.1
- **Model: Sonnet or Opus** (type mapping)
- Change: `uv run --group xdiff python xdiff.py [--zp <zp-fuzz exe>] [--rs <dump-ipc exe>] <file|dir>...`. For each
  `.parquet` file:
  - zig: `zp-fuzz dump`.
  - pyarrow: `pq.read_table`, normalized **using the Parquet schema** (`pq.ParquetFile(f).schema`: physical type, logical
    type, type_length), not the Arrow type. Convert back to physical: date32 → days, time/timestamp → int in the
    file's unit (`.cast(pa.int64())` after unit checks), decimal → unscaled int, INT96 timestamp → 12 bytes
    (julian day + nanos-of-day), float16 → 2 LE bytes, str → utf-8 bytes.
  - duckdb: `duckdb.sql("select * from read_parquet(?)").arrow()` (or `.fetch_arrow_table()`), then the same normalizer
    plus DuckDB-specific reverse mappings (UUID type → 16 bytes, INTERVAL → 12 bytes, JSON → bytes). A type DuckDB cannot
    express is reported as `unsupported`, not as a disagreement.
  Each engine runs in a subprocess with a 30 s timeout (the CVE-2023-47248 lesson: treat oracles as untrusted).
  Report: per file, the set of engines that **agree**, then each disagreeing engine with its first differing
  row/column, `error:<msg>` for engines that failed, and whether the file is listed in `xdiff-known.txt`. Exit 1 on
  any unlisted disagreement. Also print a summary count.
- Acceptance: running it over `test-files-arrow` passes or lists only triaged entries. Over `test-files-wild`, every
  disagreement is either fixed (R5), listed in `xdiff-known.txt` with a reason, or reported to the owner.

### Task 3.3 ∥ arrow-rs reader: Arrow IPC dumper in the existing bench crate

- Files: `bench/rust/Cargo.toml` (add `arrow-ipc = "60.1.0"`), new `bench/rust/src/bin/dump_ipc.rs`, `Cargo.lock`
- Depends on: none (∥ with 3.1)
- Change: `dump_ipc <in.parquet> <out.arrow>` uses `ParquetRecordBatchReaderBuilder` (batch size 1024) → `FileWriter`.
  `xdiff.py --rs` runs it and reads the IPC file with `pyarrow.ipc.open_file`, then applies the same normalizer. Exit code
  1 with the error message on read failure.
- Acceptance: `(cd bench/rust && cargo build --release --bin dump_ipc)` succeeds (subshell form, as `make bench-rust` does);
  xdiff over `test-files-arrow` with `--rs` gives no new disagreements.

### Task 3.4 Writer interop: generated files through every reader

- Files: `zig-parquet/fuzz/fuzz.zig` (subcommand `gen-cases <dir> <n> [--seed s]` writes `case-<seed>.parquet`; covers
  Phase 2 options incl. `write_page_index`), `.github/workflows/fuzz-nightly.yml` (job `xdiff`)
- Depends on: 2.1, 3.2, 3.3
- Change: the nightly job writes 300 cases, then `uv run --group xdiff python test-files-arrow/xdiff.py --rs ... <dir>
  ../test-files-wild ../test-files-arrow` (about 5-10 min). Any disagreement on a zig-written file is a zig **writer** bug
  until proven otherwise; promote it per R8 as a `writer_*_test.zig` regression.
- Acceptance: one green nightly; the job uploads the report as an artifact and writes the summary to `$GITHUB_STEP_SUMMARY`.

### Task 3.5 ∥ `codec-diff` target: Zig vs C codecs (Linux CI only)

- Files: new `zig-parquet/fuzz/t_codec_diff.zig`; `fuzz.zig` (Target `.@"codec-diff"`)
- Depends on: 1.6
- Change: requires both implementations (`build_options.enable_zig_<c> and build_options.enable_<c>`), otherwise return.
  Decompress `rest()` with both; if both succeed, the outputs must be equal. If exactly one succeeds, report `fuzz-codec-disagree`
  (a separate triage class; a known-difference list goes in the file's header comment). Also Zig compress → C decompress == input.
- CI: a nightly job on ubuntu with `make fuzz-run TARGET=codec-diff CODECS=all SECONDS=600` (never `fuzz-cov`: R1).
- Acceptance: compiles to a no-op with `zig-only` on both versions; the nightly job runs.

### Task 3.6 Gate 3

- xdiff over wild + arrow + 300 generated files: zero unlisted disagreements. Every `xdiff-known.txt` line has a reason.
  Nightly is green for 3 consecutive nights.

---

## Phase 4: depth (pick by ledger evidence; each task is independent)

### Task 4.1 ∥ Semantic-coverage ledger over files

- Files: `zig-parquet/fuzz/fuzz.zig` (subcommand `ledger <dir>...`), `zig-parquet/fuzz/common.zig`
- Change: for each file, read the footer and, per column chunk, the first page header (`format.PageHeader.parse` at
  `dictionary_page_offset` / `data_page_offset`). Count the matrix cells below for "read seeds", including V1/V2 page type,
  CRC present, and dictionary page present. Print a Markdown table. Nightly appends it to `$GITHUB_STEP_SUMMARY`.
- Acceptance: running on `test-files-wild` lists every required "read" cell; empty required cells become seed-generation
  work for task 4.4.

### Task 4.2 Structure-aware, semantics-preserving rewrites (`rewrite` target)

- **Model: Opus**
- Files: new `zig-parquet/fuzz/t_rewrite.zig`, `fuzz.zig`
- Change: parse the footer and the page headers of a valid seed, then apply one rewrite that keeps the logical rows unchanged:
  re-compress a page with another codec; V2 page → `is_compressed = false` with the decompressed payload; split a
  PLAIN page in two; drop or recompute CRCs; reorder key-value metadata. Re-serialize with `thrift/compact_writer.zig`,
  fix offsets and the footer length. Oracle: rows(rewritten) == rows(original) in every reader mode. This targets the
  25d3c36 class directly.
- Acceptance: the injected 25d3c36 bug is found; added to the benchmark table.

### Task 4.3 ∥ 32-bit replay: the corpus on wasm32-wasi

- Files: `zig-parquet/build.zig` (step `fuzz-wasi`: a wasm32-wasi build of `fuzz.zig` with `-Dcodecs=zig-only`), new `zig-parquet/fuzz/wasi-replay.mjs`
- Change: `node wasi-replay.mjs zp-fuzz.wasm <target> replay <dir>` runs the `replay` subcommand under `node:wasi` with the
  seed dirs pre-opened. This catches `usize` = u32 overflow paths (sizes × counts) that 64-bit runs never hit.
- Acceptance: the replay of all targets' corpora passes on wasm32; added to nightly.

### Task 4.4 ∥ Seed generation from PyArrow for shapes the writer cannot produce

- Files: `test-files-arrow/generate.py` (new `seeds/` group: `data_page_version="2.0"` × {snappy, zstd, none},
  `column_encoding` DELTA_* and BYTE_STREAM_SPLIT for FLBA, `data_page_size=64`, `use_dictionary` per column), `.gitignore` (if outputs are not committed)
- Change: ≤ 64 KiB each; add `../test-files-arrow/seeds` to `seed_dirs`.
- Acceptance: the ledger shows the V2 and FLBA-BSS cells filled.

### Task 4.5 (optional) Port zarrow's supervisor and triage report

- Only if nightly findings need dedup across runs: port `tools/fuzz.py` and `tools/fuzz_triage.py` from zarrow into
  `zig-parquet/fuzz/`. Skipped until then: the CI artifact plus R5 is enough at the current scale.

---

## Semantic-coverage matrix (zig-parquet's real feature set)

"Written" = the DynamicWriter can produce the cell (the Phase 2 generator must hit it; this is asserted in 2.5). "Read" = seeds
must contain it (ledger 4.1). **R** = required cell, - = not applicable (the feature does not exist in zig-parquet).

| Dimension | Values | Written | Read | Measured by |
|---|---|---|---|---|
| Physical type | BOOLEAN, INT32, INT64, INT96, FLOAT, DOUBLE, BYTE_ARRAY, FLBA | R except INT96 | R all | case counters; ledger |
| Logical type | none, STRING, ENUM, JSON, BSON, UUID, DATE, TIME ms/us/ns, TIMESTAMP ms/us/ns (utc and local), DECIMAL on int32/int64/FLBA/BYTE_ARRAY, INT 8/16/32/64 signed and unsigned, FLOAT16, INTERVAL, GEOMETRY, GEOGRAPHY | R (presets) | R | case counters; ledger |
| Value encoding × physical | PLAIN all; RLE_DICTIONARY / PLAIN_DICTIONARY all but bool; RLE bool; DELTA_BINARY_PACKED int32/64; DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY byte arrays; BYTE_STREAM_SPLIT int32/int64/float/double (+FLBA read) | R for the writer's set (F16) | R all | case counters; ledger; `page`/`spec` targets for the rest |
| Level encoding | RLE, BIT_PACKED (deprecated, read only) | RLE | R both | ledger; `page` recipe |
| Page version | V1, V2 (incl. `is_compressed = false`) | V1 only | R both | ledger; `spec` (V2 page) and `rewrite` (V2 flag) |
| Codec × dictionary | {none, snappy, gzip, lz4_raw, zstd, brotli} × {dict, no dict}; LZ4 (hadoop) and LZO rejected by design | R | R | case counters; ledger |
| Repetition × nesting depth | required/optional/repeated × depth 0-3; list, struct, map; nested **followed by** another column | R | R | case counters |
| Null pattern | 0%, 5%, 50%, 100%, single null, long runs | R | - | case counters |
| Row group / page shape | 1 vs many row groups; tiny pages (64 B); page boundary inside a list; dictionary fallback (size limit) | R | R | case counters; ledger (page counts from the offset index) |
| Page index | absent / present; `readRowsFiltered` with empty and range filters | R | R | case counters |
| Checksums | written on/off × validated on/off × corrupt | R (on/off) | R (two corrupt files in wild) | case counters; `file` target bit |
| Reader mode | readAllRows, rowIterator, rowIteratorStreaming, projected (both), readRowsFiltered, Arrow bridge, C ABI stream | - | R | `Feedback.detail` bits in file/roundtrip/arrow |
| Not applicable | bloom filters, encryption, async reader, row-selection policies, VARIANT (parquet-testing `variant/`, not supported) | - | - | excluded by design |

Code coverage is coarse and complementary: the `--fuzz=N` report prints `Coverage: x/y` PCs per target, and nightly records it.
No line-coverage tool is adopted (kcov would work on Linux; add it only if the ledger and the PC counts disagree).

---

## What we are adopting from the research, and what we are not

Adopted: the layered oracle hierarchy (safety → structural via `arrow_check` → semantic round trip → cross-engine → metamorphic
reader modes); separate small targets rather than one giant one; good seeds over engine sophistication (F9); the shared corpus as a
baseline, with minimized findings promoted forever (R8); a Case-based generator with "no privileged oracle" (Parquity's ideas,
without the tool); feature cross-products (2.2, 2.3); a semantic-coverage ledger checked by a test (2.5); a ground-truth benchmark of
real bugs (1.10); resource exhaustion as its own finding class (`fuzz-oom` at 256 MiB live and `fuzz-hang` at 10 s, triaged
separately; wiring `AllocationLimits` into `DynamicReaderOptions` is decision D5); oracles run as untrusted subprocesses.

Not adopted, and why:
- **OSS-Fuzz / libFuzzer / AFL++ / Honggfuzz**: no Zig language support; Zig has only `-ffuzz` for its own runtime; there is no ASan
  for Zig code (F11). The bridge would be an unverified spike with low payoff. Zig safety checks (Debug/ReleaseSafe), plus
  DebugAllocator leak and double-free detection and 0xaa poisoning, are our sanitizer. (D2)
- **FormatFuzzer, FuzzBerg, Parquity as tools**: they belong to C++ or Python ecosystems and would be a heavy integration.
  We take their ideas instead (4.2 is our structure-aware mutator, built on our own Thrift writer).
- **proptest-style shrinking**: replaced by the byte decision stream, where truncating or zeroing bytes yields a smaller Case, and by `minimize.py`.
- **Pairwise / t-wise generators**: exhaustive where the space is small (2.3), random plus a ledger elsewhere. Add pairwise only if the ledger shows persistent holes.
- **20-30 repetition statistical engine benchmark**: overkill here; the ground-truth table uses 3 seeds per bug.
- **Encryption, bloom-filter, async and row-selection-policy dimensions**: zig-parquet has none of them (F16).
- **hyparquet as an oracle**: it converts logical types to JS values (Number, BigInt, Date), which loses exactness for some types, so it would need a third normalizer. `bench/js` keeps its checksum interop matrix as a sanity check. parquet-wasm is arrow-rs (F19), so it adds no independence.
- **Typed `Writer` in the generator**: its types are comptime and cannot be generated at runtime; it shares `column_writer` and schema generation with DynamicWriter, which 2.2 and 2.3 cover. Existing typed tests stay.
- **valgrind**: not installed (F12); consider it for the Linux `file-oom` lane only if a Linux-only crash class recurs.

---

## Decisions for the user

| # | Decision | Blocks | Recommendation |
|---|---|---|---|
| D1 | Add parquet-java (JVM) as a fourth reader | 3.x (optional task) | **Not now.** Phase 3 already has three independent families (Arrow C++, DuckDB, arrow-rs). Revisit after Gate 3 as a **CI-only** nightly job (`actions/setup-java`, no local JVM) that reads **zig-written files only**, because parquet-mr consumers (Spark, Trino) are where page-index interop bugs showed up (the research note's zero-rows issue) and zig writes page indexes. |
| D2 | Apply to OSS-Fuzz | none | **No.** No Zig support; acceptance favours widely deployed projects; the in-house nightly gives the same signal for this codebase. |
| D3 | Scheduled CI minutes | 1.9 nightly | **Decided 2026-11-02 by the owner: no automatic CI fuzzing.** No schedule and no PR fuzz job. `.github/workflows/fuzz.yml` is `workflow_dispatch` only (default 60 s per target, coverage-guided jobs off). Campaigns run locally. |
| D4 | Vendor `apache/parquet-testing` | none | It **is already vendored** as a Feb 2026 snapshot (F15). Keep the snapshot (no submodule). Refresh it **once** now to pick up newer `bad_data/` reproducers, re-run `make validate-wild`, and update `expected-failures.txt`. |
| D5 | Reader resource limits (wire `AllocationLimits` into `DynamicReaderOptions`) | none | **Defer** until `fuzz-oom` findings cluster. Small legal files can expand enormously (an RLE run of 2^31 nulls), so a cap is an API decision, not a bug fix. |
| D6 | Add `duckdb` to the `test-files-arrow` uv project (dependency group `xdiff`) | 3.2 | **Yes.** It is the only independent C++ reader available here without a JVM; a group keeps the default `uv run` unchanged. |

---

## Appendix: file map

| task | files |
|---|---|
| 1.1 | zig-parquet/build.zig, Makefile, .gitignore, .github/workflows/test.yml (fmt), zig-parquet/fuzz/{fuzz,common,t_file,t_page,t_encoding,t_thrift,t_codec}.zig, fuzz/corpus/expected.txt |
| 1.2 | fuzz/t_file.zig, fuzz/common.zig |
| 1.3 | fuzz/t_page.zig (+ fuzz/corpus/page/gen-*) |
| 1.4 | fuzz/t_encoding.zig |
| 1.5 | fuzz/t_thrift.zig |
| 1.6 | fuzz/t_codec.zig (+ fuzz/corpus/codec/gen-*) |
| 1.7 | fuzz/fuzz.zig, zig-parquet/HARDENING.md, fuzz/corpus/thrift/regress-20261102-empty-footer.bin |
| 1.8 | fuzz/minimize.py, Makefile (fuzz-install) |
| 1.9 | .github/workflows/test.yml, .github/workflows/fuzz-nightly.yml |
| 1.10 | zig-parquet/HARDENING.md |
| 2.1-2.2, 2.5 | fuzz/case.zig, fuzz/t_roundtrip.zig, fuzz/fuzz.zig |
| 2.3 | src/tests/option_sweep_test.zig, src/tests/mod.zig |
| 2.4 | fuzz/t_spec.zig, fuzz/fuzz.zig, src/core/encoding/delta_binary_packed_encoder.zig |
| 2.6 | fuzz/t_arrow.zig, fuzz/arrow_check.zig, fuzz/fuzz.zig |
| 3.1 | fuzz/fuzz.zig, fuzz/common.zig |
| 3.2 | test-files-arrow/{xdiff.py,xdiff-known.txt,pyproject.toml,uv.lock} |
| 3.3 | bench/rust/{Cargo.toml,Cargo.lock,src/bin/dump_ipc.rs} |
| 3.4 | fuzz/fuzz.zig, .github/workflows/fuzz-nightly.yml |
| 3.5 | fuzz/t_codec_diff.zig, fuzz/fuzz.zig |
| 4.x | see each task |

Parallel tasks (∥) touch disjoint files, **except** that each new target edits `fuzz.zig`'s `Target` enum, dispatch and test list;
1.1 adds every Phase 1 target up front so that 1.2-1.6 do not touch `fuzz.zig`. Phase 2-3 tasks that add a target do it in
their own commit, sequentially.
