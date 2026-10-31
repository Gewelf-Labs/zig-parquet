# zig-parquet baseline benchmark

- Date: 2026-10-30
- Zig: 0.16.0 (`C:/Users/cable/tools/zig-x86_64-windows-0.16.0/zig.exe`)
- Build: `zig build bench -Dcodecs=zig-only -Doptimize=ReleaseFast` (default 1,000,000 rows)
- Codecs: zig-only (no compression, uncompressed pages)
- OS: Windows 11 Pro 10.0.26300
- CPU: AMD Ryzen 9 7950X 16-Core Processor
- Method: each phase run 3 times, best time reported. Write time covers file create, write, and close. Read time covers open, footer parse, and iterating all rows with DynamicReader.rowIterator. Input data is generated before timing.

## Results

```
scenario        rows    write_ms  write_rows_per_s    read_ms  read_rows_per_s   file_MB
int64_plain      1000000      31.50       31746838      59.37       16843410      7.63
f64_plain        1000000      31.05       32208712      55.07       18159828      7.63
int64_nullable   1000000      26.46       37794466      57.66       17344008      5.21
str_dict         1000000      73.63       13581255      81.49       12271444      0.84
str_unique       1000000     299.78        3335815      67.18       14884718     13.25
mixed5           1000000     564.23        1772336     182.14        5490189     20.40
```

## History

Phase 1 (dual-version compat). Values are rows/s, best of 3 runs per cell, ReleaseFast, zig-only codecs,
1,000,000 rows. The machine was NOT idle during these runs (background CPU load 70-95%), so run-to-run
spread is large (up to ~2x on some cells). Read the P1 columns as indicative, not as a pass/fail against
the ±10% band. The baseline row's code is the pre-rebase tree (0.16 only); P1 columns use main's code
with the Phase 1 compat changes.

### write rows/s

| scenario | baseline | P1 (0.16) | P1 (0.17) |
|---|---:|---:|---:|
| int64_plain | 31,746,838 | 34,022,400 | 34,577,549 |
| f64_plain | 32,208,712 | 27,865,632 | 35,900,197 |
| int64_nullable | 37,794,466 | 30,639,508 | 40,657,679 |
| str_dict | 13,581,255 | 11,151,318 | 14,731,771 |
| str_unique | 3,335,815 | 2,260,448 | 3,090,853 |
| mixed5 | 1,772,336 | 1,382,703 | 2,024,260 |

### read rows/s

| scenario | baseline | P1 (0.16) | P1 (0.17) |
|---|---:|---:|---:|
| int64_plain | 16,843,410 | 14,316,003 | 17,849,174 |
| f64_plain | 18,159,828 | 15,419,487 | 18,710,509 |
| int64_nullable | 17,344,008 | 14,846,950 | 16,502,876 |
| str_dict | 12,271,444 | 10,585,214 | 12,591,017 |
| str_unique | 14,884,718 | 10,756,713 | 14,410,842 |
| mixed5 | 5,490,189 | 5,073,574 | 4,861,038 |

## Notes

- From commit 0ed9219 the bench prints two more columns, `read_stream_ms` and
  `read_stream_rows_per_s`: the same read done with `DynamicReader.rowIteratorStreaming()` (one
  reused row, valid until the next `next()`). `read_ms` / `read_rows_per_s` still use
  `rowIterator()` and remain the compatibility number compared in the tables above. The streaming
  read runs right after the `rowIterator()` read in each of the 3 runs, and its best time is
  reported. Its rows/s are not comparable to the history tables' read column.
