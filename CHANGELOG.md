# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Data corruption fixes
- **The pure-Zig gzip encoder wrote invalid deflate streams for ordinary data** (since v0.1.6, including v0.2.0). Its Huffman tree builder clamped codes deeper than the length limit, producing an oversubscribed prefix code, so neither zig-parquet nor zlib could read the page back. In tests, 33 of 128 realistic page payloads (timestamps, skewed bytes, text, 8 KiB to 1 MiB) were affected. **GZIP-compressed files written by zig-parquet v0.1.6 to v0.2.0 may contain unreadable pages; rewrite them with this version.** Files written with other codecs, or with the C gzip codec (`c-gzip`), are not affected.
- **DELTA_BINARY_PACKED INT64 reads returned wrong values without an error** when a block's `first_value` or `min_delta` had a magnitude of 2^62 or more, such as random 64-bit IDs. The zigzag decode used an arithmetic shift, so such values came back off by 2^63 (2^62 read as -2^62). This affects files from any writer. Re-read affected data with this version.

### Performance
- Streaming row iterator: `DynamicReader.rowIteratorStreaming()` and `rowIteratorStreamingProjected()` return a `StreamingRowIterator` that reuses one row buffer. Contract: the row and its byte slices are valid until the next `next()` or `deinit()`. Memory is bounded by one row group. If loading a row group fails, the next `next()` retries that row group.
- Zero-copy byte arrays on flat reads: PLAIN and dictionary BYTE_ARRAY values (V1 and V2) are slices of the page buffer instead of per-value copies.
- Flat PLAIN fast path for INT32, INT64, FLOAT and DOUBLE pages.
- Word-at-a-time bit unpacking for RLE and bit-packed runs; RLE fill uses memset.
- Flat row assembly without clones: non-nested reads move decoded values into rows, and `rowIterator()` keeps its value block in an iterator arena.
- Write: PLAIN data pages built in one buffer with definition levels written in place; dictionary data pages built in one buffer; accumulator bit packing; dictionary size limit checked inside the loop; statistics computed after the dictionary decision.
- Slicing-by-8 CRC-32 for page checksums on write and on checksum-verified reads.

Benchmark, ReleaseFast, zig-only codecs, 1,000,000 rows, Zig 0.16.0, Ryzen 9 7950X (±10%; see `bench/BASELINE.md`). Speedup over the baseline:

| scenario | write | read (rowIterator) | read_stream vs baseline read |
|---|---:|---:|---:|
| int64_plain | 3.8x | 2.5x | 8.5x |
| f64_plain | 3.5x | 2.4x | 7.7x |
| int64_nullable | 3.8x | 2.4x | 7.8x |
| str_dict | 1.4x | 2.8x | 6.2x |
| str_unique | 4.8x | 2.1x | 4.1x |
| mixed5 | 2.7x | 1.7x | 3.9x |

Output bytes are unchanged: file sizes match the baseline in every scenario, and golden-byte tests cover the changed write paths.

### Added
- Fuzz harness (`zig-parquet/fuzz/`): six targets (file, file-oom, page, encoding, thrift, codec) with a mutation loop that runs on every OS, Zig's coverage-guided fuzzer on Linux/macOS, corpus replay in `zig build test`, a minimizer and a regression convention. `make fuzz-run`, `make fuzz-replay`, `make fuzz-cov`. A manual-only GitHub workflow (`fuzz.yml`) runs it in CI on demand.
- `Row.values_borrowed` flag (default `false`) for rows whose value block is owned by the producer.
- `StreamingRowIterator` is exported from the package root.
- `make bench` target (zig-only, ReleaseFast; `ROWS=<n>` sets the row count).
- Comparison benchmarks: `make bench-rust` (Rust `parquet` crate) and `make bench-js-browsers` / `make bench-js-workerd` (zig-parquet WASM vs hyparquet and parquet-wasm in Chrome, Firefox and workerd). Results in `bench/COMPARE.md`.
- `ZIG=<path>` on any Makefile target selects the Zig toolchain.

### Changed
- Zig 0.16.0 and 0.17.0 are both supported from one tree, and CI tests both.
- `make fmt` requires a Zig 0.16 toolchain (0.17's `zig fmt` emits 0.17-only builtins).
- `pqi cat` and `pqi head` use the streaming row iterator.
- C codec dependencies are lazy: zig-only builds no longer fetch the C codec archives.

### Fixed
- DELTA_BINARY_PACKED: deltas now wrap at the column's type width as the spec requires. INT32 columns with consecutive values more than 2^31 apart were written with a delta the reader rejected, and INT64 extremes panicked the encoder. The decoder also misread 58- to 63-bit-wide values at unaligned offsets. INT32 files whose `min_delta` needs more than 32 bits, as older zig-parquet wrote them, now decode correctly.
- Brotli decompression read code-length bits past the end of truncated input (integer overflow); malformed prefix codes are now rejected as in RFC 7932.
- Gzip decompression panicked on some truncated streams under Zig 0.16 (a sign error in std 0.16's inflate, fixed in 0.17); it now returns `error.DecompressionError` on both versions.
- Leaks on malformed footers: repeated `ColumnIndex`/`OffsetIndex` fields and partially parsed page headers are freed.
- `DynamicReader.deinit`, and the C and WASM reader handles, leaked schema logical-type payloads such as a GEOGRAPHY `crs`. They now free the whole footer.
- Leaks when a page fails to decode part-way: def/rep levels and byte values already copied are freed. Also fixed a leak when an allocation fails while a nested column result is assembled.
- Untrusted counts could ask for huge allocations: a page claiming more values than its column chunk, a column chunk past the end of the file, a row group whose `num_rows` exceeds the values actually decoded, and a dictionary with more entries than its page can hold. Each now returns an error before allocating.
- List and map columns with fewer repetition levels than definition levels panicked; they now return `error.InvalidRepetitionLevels`.
- Bit unpacking overflowed `u5` for bit widths 25-31: the byte count was computed in `u5`. This panicked in Debug builds and gave a wrong byte count in ReleaseFast. Fixed by computing in `usize`.
- Overflow-checked level and bit-pack sizes: `bitPackedSize` returns `error.Overflow`, and V2 level cursor checks are overflow-safe.
- Out-of-memory leaks: footer parsers (`ColumnChunk`, `Statistics`, `RowGroup`, `SchemaElement`, `KeyValue`, `FileMetaData`) free partial allocations; nested assembly frees the partial list item and struct field; dynamic decoders free def/rep levels and page results.
- FIXED_LEN_BYTE_ARRAY dictionary pages with BIT_PACKED levels longer than the page panicked; they now return `error.EndOfData`.
- Repeated footer lists (schema, row groups, key/value metadata) leaked the earlier value; they are now freed before replacement.
- `DynamicWriter` (and any `SchemaNode`-built schema) wrote `num_children = <struct field count>` on the repeated `list` group of a `list<struct>` column. Files with such a column followed by other columns failed to read back with `error.InvalidSchema`. The group now has one child, the `element` group.
- GEOMETRY / GEOGRAPHY logical types leaked the `crs` string when parsing failed after it was read, or when the field repeated. `LogicalType.deinit` frees it.
- Byte-array decoders initialized `Optional` slots in place from a fallible copy: on an allocation failure the slot already carried the `.value` tag with an undefined payload, and the cleanup path freed garbage (crashed on Linux). The copy is now made before the slot is written.

## [0.2.0] - 2026-04-07

### Changed
- **Pure Zig compression is now the default.** All five codecs (zstd, gzip, snappy, lz4, brotli) use pure Zig implementations out of the box. C/C++ backends are opt-in via `-Dcodecs=c-only` or individual `c-<codec>` tokens.
- `-Dcodecs=` token rename: Zig codecs are now plain `zstd`, `snappy`, `gzip`, `lz4`, `brotli`; C codecs are `c-zstd`, `c-snappy`, `c-gzip`, `c-lz4`, `c-brotli`
- Removed `-Dprefer-zig` build flag — Zig always wins when compiled in
- Dissolved `compress.experimental` namespace — Zig codec modules are now top-level
- Renamed `stable` codec preset to `c-only`
- Renamed codec source files: `zig_*.zig` → `*.zig`, `*.zig` (C) → `c_*.zig`

### Fixed
- All five Zig decompressors now treat `uncompressed_size` as a capacity hint only; actual decompressed bytes are returned regardless of hint value. Fixes decompression of files with bogus metadata hints (e.g. `large_string_map.brotli.parquet`)
- Brotli decompressor converted to `ArrayListUnmanaged` output — no longer pre-allocates to hint size
- Fixed pre-existing double-free in lz4 decompressor (errdefer + explicit free)
- Fixed `large_file` example: column count check compared physical schema leaves against logical columns (incorrect for nested types)

### Added
- Pure Zig LZ4 raw block codec with cross-implementation testing
- Pure Zig Brotli codec: full RFC 7932 decompressor + quality-0 compressor, with cross-implementation testing
- SortingColumn support: parse, serialize, and expose in writer API
- C→Zig direction added to all five codec cross-implementation round-trip tests
- Oversized hint test added to all five Zig decompressors

## [0.1.6] - 2026-04-04

### Added
- Experimental pure Zig gzip codec (`zig-gzip`) with full deflate encoder and cross-implementation testing
- Level-9 deflate encoder with LZ77 compression, Huffman tree building, and RLE tree descriptor encoding
- Concatenated gzip member support in the zig_gzip decompressor
- `-Dprefer-zig` build flag to select Zig codec implementations over C when both are available
- Cross-impl tests for concatenated gzip streams (C↔Zig interoperability)

### Changed
- Codec presets split: `all` includes experimental Zig implementations; `stable` for production use

## [0.1.5] - 2026-04-02

### Added
- Dual codec system: stable C/C++ implementations alongside experimental pure Zig compressors
- Experimental pure Zig zstd compressor (level 1, raw literals, predefined FSE tables)
- Experimental pure Zig snappy compressor and decompressor (full block format)
- `-Dcodecs=zig-zstd`, `-Dcodecs=zig-snappy`, `-Dcodecs=zig-only` build options
- `compress.experimental` API namespace for Zig codec implementations
- Cross-implementation test suites validating C↔Zig interoperability for zstd and snappy
- Write-path targeted tests for Zig zstd compressor (literals header boundaries, sequence count encoding, large LL/ML codes, large offsets, mixed block types, rep[0] gaps)
- COMPRESSION.md with codec details, build sizes, and API documentation

### Changed
- Stable C/C++ codecs remain default; dispatch falls back to Zig when stable is unavailable
- `supports_zstd` / `supports_snappy` build flags now cover both implementations

## [0.1.4] - 2026-03-28

### Changed
- Replace `-Dno_compression` with per-codec `-Dcodecs=` build option — enable any combination of zstd, snappy, gzip, lz4, brotli (default: all)

### Fixed
- Fix key-only map regression: fall back to list (Arrow C++ approach)

### Added
- Add validate-wild step to CI pipeline

## [0.1.3] - 2026-03-27

### Fixed
- Fix varint panic on malicious Thrift data in compact reader
- Fix errdefer undefined behavior and add checked arithmetic in core encodings
- Fix critical findings across multiple code review rounds (arrow_batch, column_decoder, column_writer, dynamic_reader, dynamic_writer)
- Remove dead branch in DictHashContext hash function

### Added
- Arrow write round-trip tests for arrow_batch hardening

## [0.1.2] - 2026-03-26

### Added
- REQUIRED column support in DynamicWriter via `TypeInfo.asRequired()` — non-nullable schema, write-time validation, no definition levels on disk

### Fixed
- Fix release script to update `zig fetch` URL in README for new versions

### Changed
- Document interop/ directory and missing subdirectories in test-files-arrow README

## [0.1.1] - 2026-03-25

### Added
- Test file pre-check in `zig build test` — fails early with a clear message instead of 52 FileNotFound errors

### Fixed
- Deduplicate `safeTypeLength` between column_decoder and dynamic_reader
- Fix incorrect file paths in AGENTS.md
- Document all pqi commands in README (count, column, rowgroups, size)
- Fix README feature claims: complete logical types list, clarify DataPage V2 and hardening

### Changed
- Reorder README features to lead with core capabilities
- Clean up CONTRIBUTING.md section ordering

## [0.1.0] - 2026-03-23

Initial release.

### Added
- Full read/write support for all Parquet physical types
- All standard encodings: PLAIN, RLE, DICTIONARY, DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, BYTE_STREAM_SPLIT
- Nested types: LIST, MAP, STRUCT with arbitrary nesting depth
- Logical types: STRING, DATE, TIME, TIMESTAMP, DECIMAL, UUID, INT, FLOAT16, ENUM, JSON, BSON, INTERVAL, GEOMETRY, GEOGRAPHY
- Compression: zstd, gzip, snappy, lz4_raw, brotli
- DataPage V1 and V2 read support; write uses V1
- Runtime DynamicWriter and DynamicReader for schema-agnostic row I/O
- Column statistics (min/max/null_count)
- Page-level CRC32 checksums (written by default, validated on read)
- Key-value metadata read/write
- Column projection on DynamicReader
- Streaming RowIterator with C ABI support
- C ABI with Arrow C Data Interface (ArrowSchema, ArrowArray, ArrowArrayStream)
- WASM targets: wasm32-wasi (with compression) and wasm32-freestanding (no compression)
- `pqi` CLI: schema, head, cat, count, stats, rowgroups, size, column, validate
- Buffer, file, and callback I/O transports
- Hardening: safe casting, bounds checking, no `@intCast` on external data
- 219/219 pass rate on supported Apache parquet-testing files

[0.1.7]: https://github.com/akeating/zig-parquet/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/akeating/zig-parquet/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/akeating/zig-parquet/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/akeating/zig-parquet/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/akeating/zig-parquet/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/akeating/zig-parquet/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/akeating/zig-parquet/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/akeating/zig-parquet/releases/tag/v0.1.0
