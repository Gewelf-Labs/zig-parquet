# zig-parquet vs other Parquet libraries

Two comparisons on the six scenarios of `zig-parquet/bench/main.zig`, 1,000,000 rows,
uncompressed, numeric columns PLAIN, string columns dictionary-encoded (falling back to PLAIN
when the dictionary gets large). Each phase is the best of 3 runs; lower ms is better.

Machine: AMD Ryzen 9 7950X, Windows 11, 2026-11-01. Light background load (~20% CPU); treat
differences under ~10% as noise.

## Native: zig-parquet vs Rust `parquet` crate

```bash
make bench ZIG=<zig 0.16>    # zig-parquet, ReleaseFast
make bench-rust              # bench/rust: parquet 60.1.0, release + LTO, target-cpu=native
```

Both write a file, then read it back twice through two APIs. Zig's `read` is
`rowIterator()`, and Rust's `read_rows` is the `RowIter` row API: both build row objects.
Zig's `read_stream` is `rowIteratorStreaming()`, and Rust's `read_arrow` is
`ParquetRecordBatchReader`: each library's fastest reader. Zig writes numeric scenarios with
its typed column writer and string/mixed scenarios row by row with `DynamicWriter`. Rust writes
one Arrow `RecordBatch` with `ArrowWriter`.

| scenario | write Zig | write Rust | row read Zig | row read Rust | fast read Zig | fast read Rust | MB Zig / Rust |
|---|---:|---:|---:|---:|---:|---:|---:|
| int64_plain | 9.1 | 8.3 | 28.3 | 88.9 | 8.9 | 2.1 | 7.63 / 7.63 |
| f64_plain | 9.6 | 7.7 | 25.3 | 89.7 | 8.0 | 2.1 | 7.63 / 7.63 |
| int64_nullable | 7.5 | 8.5 | 25.8 | 94.8 | 8.6 | 3.0 | 5.21 / 5.21 |
| str_dict | 56.8 | 18.3 | 31.1 | 159.7 | 14.8 | 4.3 | 0.84 / 0.84 |
| str_unique | 67.2 | 21.5 | 36.0 | 165.8 | 16.8 | 7.4 | 13.25 / 13.41 |
| mixed5 | 201.4 | 43.1 | 102.7 | 485.9 | 44.2 | 12.4 | 20.40 / 20.42 |

- **Numeric writes are within 25% of each other.** String and mixed writes are 3-5x slower in Zig. Zig's
  string path goes through the row-at-a-time `DynamicWriter`, and Rust writes whole columns.
- **Row-object reads: Zig is 3-5x faster** than parquet-rs's row API.
- **Fastest reads: Rust's Arrow reader is 2.3-4.2x faster** than Zig's streaming row iterator.
  Arrow decodes into columnar buffers. Zig's fastest public reader still assembles rows.
- Files are the same size within 1.2%.

## WASM: zig-parquet vs JS Parquet libraries

```bash
make bench-js-browsers    # Chrome, then Firefox (Playwright)
make bench-js-workerd     # workerd (Cloudflare Workers runtime, local)
```

- **zig-parquet**: `zpbench.wasm`, wasm32-freestanding, ReleaseFast, about 1.1 MB (`make bench-wasm`).
- **hyparquet** 1.32.0 (read) with **hyparquet-writer** 0.18.0: pure JS.
- **parquet-wasm** 0.9.0 with **apache-arrow** 21.2.0: arrow-rs compiled to WASM.

Write is canonical JS data to Parquet bytes, including every conversion the library needs:
Arrow tables, UTF-8 encoding, and copies into and out of WASM memory. Read is file bytes to a
column-0 checksum, decoding all columns. Every reader read every writer's files in all three
runtimes (interop matrix all ok). Details and caveats are in `bench/js/README.md`.

**Read caveat:** zig-parquet keeps decoded rows in WASM memory and gives JS column 0 as a
typed-array view. parquet-wasm copies every column to JS as Arrow, and hyparquet builds JS arrays
and strings for every column. Part of zig-parquet's read lead is that it creates no JS values for
the other columns.

### Chrome 156 (V8)

| scenario | write zig | write hyparquet | write parquet-wasm | read zig | read hyparquet | read parquet-wasm |
|---|---:|---:|---:|---:|---:|---:|
| int64_plain | 12.7 | 88.2 | 9.9 | 4.9 | 12.0 | 21.8 |
| f64_plain | 12.6 | 42.1 | 9.9 | 4.6 | 8.4 | 16.3 |
| int64_nullable | 13.5 | 56.8 | 14.8 | 5.5 | 19.3 | 17.3 |
| str_dict | 95.9 | 144.0 | 364.6 | 7.5 | 43.4 | 20.3 |
| str_unique | 75.3 | 989.1 | 411.3 | 16.3 | 500.7 | 19.9 |
| mixed5 | 237.1 | 390.7 | 382.3 | 21.6 | 120.8 | 75.9 |

### Firefox 157 (SpiderMonkey, Playwright build)

| scenario | write zig | write hyparquet | write parquet-wasm | read zig | read hyparquet | read parquet-wasm |
|---|---:|---:|---:|---:|---:|---:|
| int64_plain | 15.8 | 78.4 | 10.9 | 5.7 | 14.3 | 23.4 |
| f64_plain | 15.3 | 43.4 | 7.2 | 5.7 | 6.3 | 16.0 |
| int64_nullable | 17.7 | 62.9 | 19.3 | 7.3 | 22.9 | 20.3 |
| str_dict | 88.3 | 130.0 | 267.8 | 9.8 | 37.9 | 24.7 |
| str_unique | 86.3 | 267.2 | 240.0 | 21.6 | 210.1 | 25.5 |
| mixed5 | 200.5 | 406.0 | 290.5 | 21.8 | 94.1 | 46.4 |

### workerd 2026-11-01 (V8; 1 ms timer resolution)

| scenario | write zig | write hyparquet | write parquet-wasm | read zig | read hyparquet | read parquet-wasm |
|---|---:|---:|---:|---:|---:|---:|
| int64_plain | 15 | 76 | 7 | 5 | 16 | 28 |
| f64_plain | 15 | 48 | 8 | 5 | 7 | 18 |
| int64_nullable | 14 | 58 | 15 | 7 | 23 | 20 |
| str_dict | 94 | 120 | 196 | 10 | 38 | 18 |
| str_unique | 79 | 605 | 180 | 21 | 176 | 21 |
| mixed5 | 220 | 380 | 233 | 26 | 135 | 46 |

- **Reads: zig-parquet is fastest or tied in every runtime and scenario**: 1.1-31x over hyparquet
  and 1-5.6x over parquet-wasm. The read caveat above applies.
- **Non-null numeric writes: parquet-wasm is fastest**, 1.3-2.1x ahead of zig-parquet. For nullable
  int64, zig-parquet is slightly ahead. hyparquet-writer is 3-7x behind zig-parquet.
- **String and mixed writes: zig-parquet is fastest**, 1.3-13x ahead, except workerd mixed5,
  where it is within 6% of parquet-wasm.
- workerd's clock was not frozen locally: a 200 ms busy loop measured 200 ms. Deployed Workers
  may freeze timers during CPU work.
- zig-parquet in WASM takes 1.4-2.4x its native time for numeric writes and 1.1-1.7x for string
  and mixed writes, including the JS-side copies.
