# JavaScript benchmark: zig-parquet (WASM) vs hyparquet vs parquet-wasm

Compares three Parquet libraries running inside JS engines on the six scenarios of
`zig-parquet/bench/main.zig`:

- **zig-parquet**: compiled to a freestanding `zpbench.wasm` (`make bench-wasm`).
- **hyparquet** (read) + **hyparquet-writer** (write): pure JS.
- **parquet-wasm** (arrow-rs compiled to WASM) with **apache-arrow** for tables.

Runtimes: Chrome and Firefox (Playwright drives the installed builds), and workerd (Cloudflare Workers runtime, local `workerd serve`).

## Run

From the repo root:

```sh
make bench-js-browsers ROWS=1000000   # Chrome, then Firefox
make bench-js-workerd  ROWS=1000000   # workerd
```

Or from `bench/js/` after `npm ci`:

```sh
node run-browsers.mjs 10000
node run-workerd.mjs 10000
```

`ZPBENCH_WASM` overrides the zig wasm path (default `../../zig-parquet/zig-out/bin/zpbench.wasm`).
Browser results are also written to `dist/results-browsers.json`; `FORMAT=json node run-workerd.mjs` prints workerd results as JSON.

## What is measured

- **Interop** (1000 rows, untimed): every library writes every scenario and reads every other library's output. Printed as a matrix.
- **write** = canonical JS data to a Parquet `Uint8Array`. Includes all conversion the library needs (Arrow table construction, UTF-8 encoding, copying into WASM memory, copying the result out).
- **read** = `Uint8Array` to `{rows, sum}`. Every library decodes all columns. The checksum is computed in JS over column 0 (int64 → Number, double/int32 → value, string → UTF-8 byte length, null → 0), summed in row order. A mismatch is `ERR`.
- Best of 3 runs per phase. `file_MB` is in MiB.
- **Read output is not the same shape for every library.** zig-parquet decodes every column into rows inside WASM memory and hands JS column 0 as a `Float64Array` view. parquet-wasm copies every column out to JS as Arrow IPC. hyparquet builds JS arrays (and JS strings) for every column. zig-parquet's read lead is partly that it never creates JS values for the other columns or for string contents.
- Writer settings: no compression everywhere. Numerics use PLAIN encoding (no dictionary). Strings use each library's dictionary default (dictionary on, falling back to plain when it does not help).

Scenarios (see `src/gen.js`): `int64_plain`, `f64_plain`, `int64_nullable`, `str_dict`, `str_unique`, `mixed5`. Data is generated with splitmix64 (seed 42) outside the timed region.

## Caveats

- Data differs from the native bench's data (it uses a different PRNG), so compare across libraries here, not against native numbers.
- hyparquet-writer decides dictionaries with a size heuristic (no on/off switch for strings). parquet-wasm dictionary is set globally: on for string scenarios, off for numerics, and on for `name` in `mixed5`.
- Required vs optional columns follow the native bench: `int64_plain` and `f64_plain` are required, everything else is optional.
- Arrow nullability is set explicitly. apache-arrow's `vectorFromArray` uses generated code (`new Function`), which workerd forbids, so nullable/string/bool Arrow buffers are assembled directly.
- hyparquet's default row-group and statistics settings are used. parquet-wasm and zig-parquet use their defaults too. Row-group layouts may differ between libraries.
- Strings: hyparquet's checksum uses an exact UTF-8 length loop on the decoded JS string. parquet-wasm uses Arrow's value offsets directly.
- workerd timers have 1 ms resolution, so small phases read as 0.00 or 1.00. Full-size runs are unaffected.
- Browser timing uses `performance.now()`. Firefox runs with COOP/COEP to get finer timers.
- workerd timing: a 200 ms busy loop advanced `performance.now()` by exactly 200 ms under local `workerd serve`, so the clock is not frozen here and phases are timed in-worker. Resolution is 1 ms. `workerd` output starts with a clock probe line. Deployed Workers may freeze the clock during CPU work, which this method would not detect. If that happens, each phase needs its own request and a baseline subtraction.
- workerd runs the whole benchmark in one request and streams progress lines, then the table. Streaming keeps response headers from timing out on long runs.
