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
