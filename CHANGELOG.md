# Changelog

All notable changes to FixedWidthParsers.jl are documented here. The project
follows [Semantic Versioning](https://semver.org/) (where "major" is the
second digit during 0.x).

## v0.3.0 — 2026-04-24

Performance-focused release. Big speedups on the row-oriented path and
date-heavy schemas; new in-memory and DuckDB entry points; an API shift
on date/time descriptors.

### Added

- **`parse_string(s, schema; kwargs...)`** and **`parse_bytes(bytes, schema; kwargs...)`**
  for in-memory sources. Both accept the full `parse_file` kwarg set.
- **`parse_file(io::IO, schema; kwargs...)`** overload for pipes, `IOBuffer`,
  `stdin`, and HTTP responses.
- **DuckDB package extension** (`DuckDBExt`) — adds [`to_duckdb(con, name, source, schema; kwargs...)`](@ref)
  which streams fixed-width files into DuckDB tables with bounded memory.
  Supports `nworkers` for parallel concurrent inserts. Activates when both
  `DuckDB.jl` and `DBInterface.jl` are loaded.
- **Byte-level fast-path parsers** for common date/time formats. When the
  format string matches one of the recognized patterns, `parse_field`
  dispatches to a hand-rolled byte walker that skips the `DateFormat`
  interpreter entirely. Fast paths:
  - `FWDate`: `yyyymmdd`, `yyyy-mm-dd`, `dduuuyy`
  - `FWTime`: `HHMM`, `HHMMSS`, `HH:MM`, `HH:MM:SS`
  - `FWDateTime`: `yyyymmddHHMM`, `yyyymmddHHMMSS`
  Measured 10–17× faster on date-heavy schemas. `dduuuyy` (e.g. "10Jan26")
  is the largest win — Dates.jl's `u` token does locale-aware substring
  matching per record, while the fast path uses a case-insensitive AND-mask
  branch table over the 12 English abbreviations.
- **`madvise(MADV_SEQUENTIAL)`** hint on `mmap` (Unix only). Marginal on
  warm cache, expected to help more on cold first-read of large files.
- **Additional parallel-path regression tests** covering wide schemas, the
  indexed variant (skip_header/footer/comment), `:default` mode under
  parallelism, and strict-mode line pinpointing.
- **Fast-path tests** with a 120-iteration fuzz comparing byte-level results
  against `Dates.Date(s, fmt)` across year/month/day grids.
- **Tutorial material** (`docs/src/tutorials/`): Quick Start, Handling Real
  Data, Streaming to DuckDB.
- **User Guide, DuckDB Extension, Performance** pages split out in the
  Documenter site.
- **`benchmark/perf_baseline.jl`** — reproducible focused runner used to
  generate the numbers in `benchmark/RESULTS.md`.

### Changed

- **`FWDate` / `FWTime` / `FWDateTime` are now parameterized** on a
  fast-path symbol (e.g. `FWDate{:yyyymmdd}`). The `UnionAll` `FWDate`
  still matches all parameterizations in method dispatch, so existing code
  that accepts `fw::FWDate` or accesses `.format_string` / `.default` /
  `.transform` continues to work unchanged. This is the v0.2→v0.3 API
  shift that motivates the minor-version bump.
- **Row-oriented path is 43× faster** (0.5 → 22 M rec/s on a narrow 7-field
  schema). The `columnar=false` result type changes from
  `Vector{NamedTuple}` (abstract) to `Vector{NamedTuple{names, Tuple{types...}}}`
  (concrete eltype). Peak memory during parsing is now ~2× the returned
  size since we parse columnar then transpose.
- **Default `to_duckdb` `chunk_size` is 250 000** (previously 100 000 in
  the Appender-based prototype). DuckDB's INSERT has ~20 ms fixed cost
  per call; 250k is the measured sweet spot on narrow schemas.
- **DuckDB sequential ingestion path uses `register_data_frame + INSERT`**
  (columnar C FFI, 1.77× faster than the Appender row-wise path).
  `nworkers > 1` uses per-worker `Appender`s because DuckDB.jl's
  `registered_objects` Dict is not thread-safe.

### Fixed

- **`_parse_int_bytes` rejects malformed integers.** Previously walked
  bytes setting `neg = true` on any `'-'` byte, so `"1-23"` silently parsed
  as `-123`, `"++5"` as `5`, `"1 2"` as `12`. Now accepts only
  `[spaces] [+/-]? digit+ [spaces]`; anything else throws `ArgumentError`.
- **`parse_record` returns owned string values.** Previously propagated
  `StringView` into the caller's buffer, which dangled if the buffer was
  closed or mutated. `parse_record` / `eachrecord` now copy into
  `InlineString` / `String` (same treatment the columnar path gives).
- **Zero-copy date/time parsing** — `FWDate/FWTime/FWDateTime` pass the
  `StringView` directly to `Dates.Date(str, fmt)` instead of allocating a
  heap `String` copy per record. Measured 48 bytes/record saved on a date
  column. (This applies to non-fast-path formats too; fast paths avoid
  `Dates` entirely.)

### Internal

- Parallel columnar shape investigated (per-column vs row-chunk vs flat);
  no shape dominates, current shape kept. See the
  [Performance](docs/src/performance.md) page for the full experiment.

### Test count

716 → 4301 across the perf branches, and now 4314+ with the DuckDB
extension tests (the expansion is largely from `@testset for nt in (1,2,4,8)`
loops in the parallel test files — many assertions per testset).

## v0.2.2 — 2026-04-23

Pre-optimization baseline referenced from the v0.3.0 changelog. Included
bundled aviation schemas, multi-record parsing, column selection,
parallel columnar via `ntasks`, JSON schema loading via extension, and
initial `parse_file` / `eachrecord` / `parse_record` entry points.

---

_Contributions and issue reports welcome at_
<https://github.com/cell-scape/FixedWidthParsers.jl>.
