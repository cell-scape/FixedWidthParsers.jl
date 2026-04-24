# PREV_SESSION.md

Handoff notes for the next Claude session. Update this file at the end of
every session and commit it. Read it at the start of every session.

---

## Release state

- **Current version:** `v0.3.1` (tag `v0.3.1` at commit `195ffe1`).
- **Latest commit on `main`:** `234bfc3` — adds this session-handoff
  infrastructure (`PREV_SESSION.md` + `CLAUDE.md` protocol). Post-tag,
  non-functional; no release needed for it.
- **Not registered** in Julia's General registry. The user has said this is
  mostly an internal package and may move off public GitHub; registration is
  deferred. Consumers install via `Pkg.add(url = "…", rev = "v0.3.1")`.
- **Last release adds:** DuckDB package extension + comprehensive docs
  overhaul. See `CHANGELOG.md` for the full entry.

## Conventions established (honor these unless the user says otherwise)

1. **TDD.** Write a failing test, run it to confirm it fails, then implement.
   This comes from `CLAUDE.md` and has been followed for every commit this
   session.
2. **No `Co-Authored-By` lines in commits.** Saved in the user's auto-memory
   (`feedback_no_coauthor.md`).
3. **One logical change per branch**, `--no-ff` merges to `main`, clean up
   local + remote branches after merge. Branch names follow
   `perf/<thing>`, `feat/<thing>`, `docs/<thing>`.
4. **Document perf changes in `benchmark/RESULTS.md`.** Every shipped perf
   change has a dated change-log entry with A/B numbers; shape investigations
   that didn't ship got documented under "Investigations".
5. **Benchmark in same session when numbers matter.** Session-to-session
   variance dwarfed the madvise effect in one measurement — an in-process
   A/B swap via `@eval` was the honest way to compare.
6. **Small prose commits over trailing summaries.** The user explicitly
   doesn't want repeated narration of what a diff already shows.

## Where things live

```
src/
  FixedWidthParsers.jl     Module entry, includes + exports
  types.jl                 Descriptors (FWString/FWInt/.../FWDate{FP})
                           + parse_field methods, including fast-path
                           date/time byte parsers
  schema.jl                FixedWidthSchema + @fixedwidth macro + show
  io.jl                    MmapSource, ChunkedSource, detect_newline,
                           _advise_sequential (MADV_SEQUENTIAL)
  parsing.jl               parse_record (row-path primitive)
  iteration.jl             eachrecord / RecordIterator + Tables.jl
  materialization.jl       parse_file + _parse_columnar(_indexed),
                           _parse_rows(_indexed) (delegates to columnar
                           + _transpose_to_rows), @generated path,
                           InlineString fast paths, _coerce, _julia_type
  schema_io.jl             load_schema (CSV/TOML; JSON via ext)
  multi_record.jl          MultiRecordSchema + parse_file dispatch
  bundled_schemas.jl       SSIM_SCHEMA, AIRCRAFT_SCHEMA, etc.

ext/
  DuckDBExt.jl             to_duckdb (weakdeps: DuckDB + DBInterface).
                           Sequential path uses register_data_frame +
                           INSERT; parallel path (nworkers > 1) uses
                           per-worker Appenders (DuckDB.jl's
                           registered_objects Dict is not thread-safe).
  JSON3Ext.jl              load_schema(*.json) via JSON3.

test/
  runtests.jl              Runs all test_*.jl files in order.
  test_duckdb_ext.jl       DuckDB integration tests; 39 tests (runs only
                           when DuckDB is loaded via extras/test target).
  test_parse_string.jl     parse_string / parse_bytes / parse_file(io).
  (others match src/ modules)

benchmark/
  RESULTS.md               Post-optimization throughput tables +
                           change logs + investigations. Read this for
                           perf context.
  perf_baseline.jl         Reproducible runner; writes files to
                           /tmp/fwp_bench/. Run with --threads=8.
  benchmarks.jl            Original BenchmarkTools suite (slower; use
                           perf_baseline.jl for iteration).

docs/
  make.jl                  Documenter entry; loads DuckDB + DBInterface
                           so DuckDBExt docstrings resolve.
  src/                     index.md + tutorials/{quickstart,real_data,
                           duckdb}.md + guide.md + duckdb.md +
                           performance.md + api.md.
```

## What each recent branch did (read CHANGELOG for details)

- `perf/madvise-sequential` — `madvise(MADV_SEQUENTIAL)` on mmap. 0–4%, marginal.
- `perf/fast-date-parsers` — byte-level fast paths for 9 common date/time
  formats (yyyymmdd, yyyy-mm-dd, dduuuyy, HHMM, etc.). 10–17× on
  date-heavy schemas. **This is the v0.2→v0.3 API shift:** `FWDate` /
  `FWTime` / `FWDateTime` are now parameterized on a fast-path symbol
  (`FWDate{:yyyymmdd}`, etc.). The UnionAll `FWDate` still dispatches
  everywhere.
- `perf/fast-row-parse` — `columnar=false` rewritten as columnar + transpose.
  **43× faster** (0.5 → 22 M rec/s). Peak memory during parsing is ~2×
  the returned size.
- `perf/parallel-row-chunks` — investigation only. Three parallel shapes
  measured; no winner. Current shape kept, four new regression tests
  shipped.
- `feat/duckdb-extension` — DuckDB package extension with `to_duckdb`.
  Two iterations: initially row-wise Appender, then switched to columnar
  `register_data_frame + INSERT` (1.77× on sequential), then added
  `nworkers` kwarg for parallel loads (2.3× at 8 workers on narrow 1M).
- `docs/overhaul` — tutorials, split guide, DuckDB/performance pages,
  `CHANGELOG.md`.

## Open but not pursued (with rationale)

- **Registry publication.** Deferred; package is internal. If the user
  changes their mind, see the session thread for the full walkthrough.
- **Further parallel columnar tuning.** Investigated and concluded that
  the current shape is near-optimal at our record/column granularity.
  Further gains would require a different lever (SIMD batching, adaptive
  partitioning). Don't rehash without a new hypothesis.
- **Mutex-guarded `register_data_frame` in the DuckDB parallel path.**
  Considered and rejected — would need to protect reads too (DuckDB's
  INSERT scans the Dict), which serializes the INSERT and defeats
  parallelism. Per-worker Appender is the right shape.
- **Appender vs register_data_frame sequential tradeoff is already
  resolved**: `register_data_frame` is 1.77× faster single-threaded at
  chunk_size=250k, which is why the extension uses it for `nworkers=1`.
- **Sequential row-chunk-parallel investigation artifacts**
  (`/tmp/fwp_ab*.jl`, `/tmp/fwp_duckdb_*.jl`) are gone — they were
  throwaway probes. Redo from scratch if needed.

## Common commands

```bash
# Full test suite (add --threads=8 for the parallel tests)
JULIA_NUM_THREADS=8 julia --project --threads=8 -e 'using Pkg; Pkg.test()'

# Single test file
julia --project -e 'using Test, FixedWidthParsers, Dates, StructArrays
                     include("test/test_types.jl")'

# Benchmarks
JULIA_NUM_THREADS=8 julia --project --threads=8 benchmark/perf_baseline.jl

# Build docs
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
# Output: docs/build/index.html

# Sanity: count tests
JULIA_NUM_THREADS=8 julia --project --threads=8 -e 'using Pkg; Pkg.test()' | tail -3
# Expect: "Pass  Total" around 4314 as of v0.3.1.
```

## Handoff notes from this session (2026-04-24)

- Clean release point at `v0.3.1`. No in-progress work.
- `main` is the only branch on origin — all perf/feat/docs branches merged
  and deleted after release.
- 4314 tests pass as of `195ffe1` (run with `--threads=8`).
- `docs/build/` is gitignored and builds cleanly with no Documenter
  warnings or broken refs.
- `docs/plans/` and `docs/superpowers/` are archaeology — don't treat as
  current spec.
- This session-handoff protocol is itself brand new (commit `234bfc3`).
  You're the first session reading `PREV_SESSION.md`. Rewriting this file
  to fit the *current* session's shape is encouraged — don't preserve
  content just because it was here.
- User preferences observed this session: concise and technical;
  data-driven with same-session A/B for small perf deltas; dislikes
  trailing summaries that duplicate the diff; values honest "we tried X
  and it didn't help" writeups over optimistic hand-waving.
