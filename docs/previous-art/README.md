# Previous art

Projects, tools, papers and write-ups that already explore what zig-parquet does. Read these
before designing a feature or a test programme, so we reuse what others learned instead of
rediscovering it.

| Document | Covers | Used by |
|---|---|---|
| [parquet-fuzzing-and-correctness.md](parquet-fuzzing-and-correctness.md) | Fuzzing and correctness testing of Parquet in Arrow C++, arrow-rs and the wider ecosystem: OSS-Fuzz, corpora, CVEs, differential and metamorphic testing, semantic coverage | [Correctness and fuzzing plan](../superpowers/plans/2026-11-02-correctness-fuzzing-plan.md) |
| [Gewelf-Labs/zarrow](https://github.com/Gewelf-Labs/zarrow) `fuzz/fuzz.zig`, `docs/fuzzing.md` | A Zig fuzz harness that builds on Zig 0.16 and 0.17: one target function shared by a seeded mutation loop, `std.testing.fuzz` and corpus replay | Template for Phase 1 of the plan |

## Adding an entry

- One file per topic, named for the topic rather than the source.
- Start with a short note giving when it was collected and anything removed or changed.
- Add a row above, and link it from the plan or spec that relies on it.
