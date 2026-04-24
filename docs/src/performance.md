# Performance

This page summarizes measured throughput for FixedWidthParsers.jl v0.3.0.
The full benchmark results and investigation history live in
[`benchmark/RESULTS.md`](https://github.com/cell-scape/FixedWidthParsers.jl/blob/main/benchmark/RESULTS.md)
and can be reproduced via:

```bash
julia --project --threads=8 benchmark/perf_baseline.jl
```

All numbers in this page are best-of-5 wall-clock timings on an Apple
Silicon 8-core machine running Julia 1.12.6 with `JULIA_NUM_THREADS=8`.

## Headline throughput

### Narrow schema (7 fields, 24-byte records)

`carrier:String(2)`, `fnum:Int(4)`, `_skip(1)`, `origin:String(3)`,
`dest:String(3)`, `pax:Int(3)`, `revenue:Int(8)`.

| Records | Path                       | Time    | Throughput      |
|--------:|----------------------------|--------:|----------------:|
| 1M      | runtime columnar `ntasks=1`|  42 ms  | 23.5 M rec/s    |
| 1M      | runtime columnar `ntasks=4`|  13 ms  | 76.8 M rec/s    |
| 1M      | runtime columnar `ntasks=8`|  13 ms  | 79.6 M rec/s    |
| 1M      | `@generated` `ntasks=1`    |  27 ms  | 37.2 M rec/s    |
| 1M      | row-oriented               |  46 ms  | 21.7 M rec/s    |
| 5M      | runtime columnar `ntasks=8`|  59 ms  | 85.0 M rec/s    |

### Date-heavy schemas (with fast-path formats)

| Schema                                                | `ntasks` | Throughput    |
|-------------------------------------------------------|---------:|--------------:|
| 3 × `FWDate("yyyymmdd")` + 2 × `FWTime("HHMM")`, 1M   |        1 |  20.1 M rec/s |
| 3 × `FWDate("yyyymmdd")` + 2 × `FWTime("HHMM")`, 1M   |        8 |  78.4 M rec/s |
| 3 × `FWDate("yyyy-mm-dd")`, 500k                      |        8 | 110.2 M rec/s |
| 3 × `FWDate("dduuuyy")`, 500k                         |        8 | 117.6 M rec/s |

### DuckDB load (to_duckdb)

| Workload                          | `nworkers` | Time    | Throughput    |
|-----------------------------------|-----------:|--------:|--------------:|
| Narrow 1M                         |          1 | 239 ms  |  4.2 M rec/s  |
| Narrow 1M                         |          8 | 104 ms  |  9.6 M rec/s  |
| Dates 1M (3 × yyyymmdd + 2 × HHMM)|          1 |  94 ms  | 10.6 M rec/s  |
| Dates 1M                          |          8 |  77 ms  | 13.0 M rec/s  |

## What made the parser fast

v0.3.0 landed four performance-focused optimizations over v0.2.2. Condensed
from the full change log in `benchmark/RESULTS.md`:

### 1. Row-oriented path rewrite — 43× faster (0.5 → 22 M rec/s)

The `columnar=false` path used `Vector{NamedTuple}` (abstract eltype — every
row heap-boxed) and walked records through `_safe_parse_field`, which did
dynamic dispatch on `f.type::Any` plus a try/catch per field.

The rewrite delegates to the columnar parser (which already specializes per
column via concrete-type function barriers) and transposes the resulting
`StructArray` to a `Vector{NamedTuple{names, Tuple{types...}}}` with a
concrete eltype. Peak memory during parsing is ~2× the returned size — for
huge files users should prefer `columnar = true` regardless.

### 2. Byte-level fast-path date/time parsers — 10–17× on date-heavy schemas

`FWDate{FP}` / `FWTime{FP}` / `FWDateTime{FP}` are parameterized on a
fast-path symbol chosen at construction from the format string.
`parse_field` specializes per symbol with a hand-rolled byte walker;
unrecognized formats fall back to `Dates.DateFormat` at the normal speed.

The biggest single win was `dduuuyy` (e.g. `10Jan26`, 17.7× speedup): Dates.jl's
`u` token does locale-aware substring matching per record, while the fast
path uppercases bytes via an `& 0xDF` mask and compares against the 12
English abbreviations in a branch table.

### 3. DuckDB columnar ingestion — 1.77× on insert phase

The DuckDB extension originally used `DuckDB.Appender` (per-value FFI). It
now uses `register_data_frame + INSERT SELECT` for the sequential path,
crossing the C boundary once per column instead of once per value. The
default `chunk_size` was bumped from 100 000 to 250 000 to amortize per-INSERT
fixed overhead.

### 4. `madvise(MADV_SEQUENTIAL)` on `mmap` — 0–4% on warm cache

A three-line hint to the kernel that the mmap is read sequentially. Marginal
on warm cache; expected to help more on first-read of large files from disk
(cold cache).

## What didn't work (investigated and skipped)

### Parallel columnar shape reshape

Hypothesis: the current per-column parallel shape (N `@sync` barriers × T tasks)
was wasteful, and row-chunk parallelism (one `@sync`, T tasks each filling
all columns) would improve 8-thread efficiency from 44% to ~70%.

Experiment: three shapes, same-session A/B, best of 10. Result: **no shape
dominates.** Differences were within ±5% noise except narrow 5M where the
current shape is clearly best. The current shape is already near-optimal at
this record/column granularity — the bottleneck is inside `_fill_column!`,
not the orchestration around it.

Shipped: four new parallel-path regression tests (wide schema, indexed
variant, `:default` mode, strict-mode line pinpointing) as durable guards
against future shape changes.

## Reproducing

```bash
git clone https://github.com/cell-scape/FixedWidthParsers.jl
cd FixedWidthParsers.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project --threads=8 benchmark/perf_baseline.jl
```

The runner generates 1M- and 5M-record narrow files, a 500k-record wide
file, and three date-heavy files in `/tmp/fwp_bench/` on first run. Files
are preserved across runs.
