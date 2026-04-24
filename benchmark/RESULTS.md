# FixedWidthParsers.jl — Performance Results

**Machine:** Apple Silicon, 8 physical cores, no SMT. Julia 1.12.6, `JULIA_NUM_THREADS=8`.

**Reproduce:** `julia --project --threads=8 benchmark/perf_baseline.jl`

All times are best wall-clock across 5 runs. Throughput is in millions of records per second.

---

## Current throughput (v0.3.0, merged main)

### Narrow schema — 7 fields, 24-byte records

Layout: `carrier:String(2) fnum:Int(4) _skip(1) origin:String(3) dest:String(3) pax:Int(3) revenue:Int(8)`

| Records | Path                       | Time     | Throughput     |
|--------:|----------------------------|---------:|---------------:|
|      1M | runtime columnar ntasks=1  |  42.6 ms |  23.5 M rec/s  |
|      1M | runtime columnar ntasks=4  |  13.0 ms |  76.8 M rec/s  |
|      1M | runtime columnar ntasks=8  |  12.6 ms |  79.6 M rec/s  |
|      1M | `@generated` ntasks=1      |  26.9 ms |  37.2 M rec/s  |
|      1M | `@generated` ntasks=4 *    |  13.4 ms |  74.6 M rec/s  |
|      1M | row-oriented               |  46.1 ms |  21.7 M rec/s  |
|      5M | runtime columnar ntasks=1  | 222.6 ms |  22.5 M rec/s  |
|      5M | runtime columnar ntasks=4  |  64.0 ms |  78.1 M rec/s  |
|      5M | runtime columnar ntasks=8  |  58.8 ms |  85.0 M rec/s  |
|      5M | `@generated` ntasks=8      |  60.3 ms |  83.0 M rec/s  |

<sub>\* `@generated` with `ntasks>1` falls back to the runtime parallel path — see `_parse_file_generated` in `src/materialization.jl`.</sub>

### Wide schema — 50 × `FWInt(4)`, 200-byte records, 500k records

| `ntasks` | Time     | Throughput     | Speedup |
|---------:|---------:|---------------:|--------:|
|        1 | 718.6 ms |  0.70 M rec/s  |   1.00× |
|        2 | 419.7 ms |  1.19 M rec/s  |   1.71× |
|        4 | 233.7 ms |  2.14 M rec/s  |   3.07× |
|        8 | 215.6 ms |  2.32 M rec/s  |   3.33× |

### Date-heavy schemas

| Schema                                                | `ntasks` | Time     | Throughput      |
|-------------------------------------------------------|---------:|---------:|----------------:|
| 3 × `FWDate("yyyymmdd")` + 2 × `FWTime("HHMM")`, 1M   |        1 |  49.7 ms |  20.1 M rec/s   |
| 3 × `FWDate("yyyymmdd")` + 2 × `FWTime("HHMM")`, 1M   |        8 |  12.8 ms |  78.4 M rec/s   |
| 3 × `FWDate("yyyy-mm-dd")`, 500k                      |        1 |  16.6 ms |  30.1 M rec/s   |
| 3 × `FWDate("yyyy-mm-dd")`, 500k                      |        8 |   4.5 ms | 110.2 M rec/s   |
| 3 × `FWDate("dduuuyy")`, 500k                         |        1 |  16.0 ms |  31.3 M rec/s   |
| 3 × `FWDate("dduuuyy")`, 500k                         |        8 |   4.3 ms | 117.6 M rec/s   |

---

## Improvement vs pre-optimization baseline

| Workload                                 | Pre (v0.2.2)    | Post (v0.3.0)   | Speedup   |
|------------------------------------------|----------------:|----------------:|----------:|
| Narrow 1M columnar ntasks=1              |  20.5 M rec/s   |  23.5 M rec/s   |   1.14×   |
| Narrow 1M columnar ntasks=8              |  57.5 M rec/s   |  79.6 M rec/s   |   1.38×   |
| **Row-oriented 1M**                      |   0.5 M rec/s   |  21.7 M rec/s   | **43.0×** |
| 3 × `yyyymmdd` + 2 × `HHMM` 1M, nt=8     |   4.91 M rec/s  |  78.4 M rec/s   |  16.0×    |
| 3 × `yyyy-mm-dd` 500k, nt=8              |   7.46 M rec/s  | 110.2 M rec/s   |  14.8×    |
| 3 × `dduuuyy` 500k, nt=8                 |   ~2 M rec/s    | 117.6 M rec/s   |  ~60×     |

The biggest user-visible wins are the row-oriented path and date-heavy schemas. Columnar int parsing was already well-tuned; the parallel-scaling improvements there come mostly from session-to-session variance and secondary-order effects.

---

## Pre-optimization baseline (v0.2.2, commit `4fbcf37`)

Kept for archaeology and to calibrate future regressions.

### Narrow schema

| Records | Path                          | Time     | Throughput      |
|--------:|-------------------------------|---------:|----------------:|
|      1M | runtime columnar ntasks=1     |  48.7 ms |   20.5 M rec/s  |
|      1M | runtime columnar ntasks=8     |  17.4 ms |   57.5 M rec/s  |
|      1M | `@generated` ntasks=1         |  30.5 ms |   32.8 M rec/s  |
|      1M | row-oriented                  | 1983.6 ms |   0.5 M rec/s  |
|      5M | runtime columnar ntasks=8     |  76.9 ms |   65.0 M rec/s  |

### Wide-schema parallel scaling

| `ntasks` | Time     | Throughput      | Speedup |
|---------:|---------:|----------------:|--------:|
|        1 | 730.9 ms |   0.68 M rec/s  |   1.00× |
|        8 | 207.4 ms |   2.41 M rec/s  |   3.53× |

### Profile hot spots (pre-optimization)

**Row-oriented path — the 40× anomaly.** Sampled hot frames parsing 1M records:

| Count | Self | Frame |
|------:|-----:|-------|
|   702 |   70 | `Base.ntuple` — per-record field tuple construction |
|   385 |  208 | `_parse_rows` inner loop |
|   282 |  266 | `_coerce(::FWString, width, v)` — per-field InlineString allocation |
|   184 |  132 | `_safe_parse_field` — dynamic dispatch + try/catch per field |
|   177 |  177 | `Base.NamedTuple` construction |

Diagnosis: `Vector{NamedTuple}` with abstract eltype boxed every row, and `_safe_parse_field` dispatched dynamically on `f.type::Any`. Fixed by delegating to the columnar path and transposing — see change log below.

**Columnar path — dominated by actual parse work.** No obvious hot spot to remove.

---

## Optimizations shipped in v0.3.0

### 1. Row-oriented path rewrite (43× speedup)

The `columnar=false` path previously returned `Vector{NamedTuple}` with abstract eltype — every row heap-boxed — and walked records through `_safe_parse_field`, which did dynamic dispatch on `f.type::Any` plus a try/catch per field.

Rewrite: `_parse_rows` and `_parse_rows_indexed` now delegate to the columnar path (which already specializes per column via concrete-type function barriers) and transpose the resulting `StructArray` to a `Vector{NamedTuple{names, Tuple{types...}}}` with a **concrete** eltype.

| Path                        | Before         | After         | Speedup |
|-----------------------------|---------------:|--------------:|--------:|
| row-oriented 1M records     |   1983.6 ms    |    44.8 ms    |  44.3×  |
|                             |    0.5 M rec/s |  22.3 M rec/s |         |
| row vs columnar ratio       |        ~40×    |       1.05×   |         |

Tradeoff: peak memory during parsing is ~2× the returned size. For huge files users should prefer `columnar=true` regardless.

### 2. Fast-path date/time parsers (10–17× on date-heavy schemas)

Parameterized `FWDate{FP}` / `FWTime{FP}` / `FWDateTime{FP}` on a fast-path symbol chosen at construction from the format string. `parse_field` specializes per symbol with a byte-level parser; unrecognized formats fall back unchanged.

| Format           | Example              | FP symbol           |
|------------------|----------------------|---------------------|
| `yyyymmdd`       | `20260224`           | `:yyyymmdd`         |
| `yyyy-mm-dd`     | `2026-02-24`         | `:yyyy_mm_dd`       |
| `dduuuyy`        | `10Jan26`            | `:dduuuyy`          |
| `HHMM`           | `0930`               | `:HHMM`             |
| `HHMMSS`         | `093045`             | `:HHMMSS`           |
| `HH:MM`          | `09:30`              | `:HH_MM`            |
| `HH:MM:SS`       | `09:30:45`           | `:HH_MM_SS`         |
| `yyyymmddHHMM`   | `202603171430`       | `:yyyymmddHHMM`     |
| `yyyymmddHHMMSS` | `20260317143045`     | `:yyyymmddHHMMSS`   |

`dduuuyy` was the biggest win (17.7×) because Dates.jl's month-name token (`u`) does locale-aware substring matching per record. The fast path does a case-insensitive 3-byte AND-mask compare against the 12 English abbreviations.

Backward compatible: `FWDate` / `FWTime` / `FWDateTime` remain valid as `UnionAll` types in dispatch, so existing code that does `fw::FWDate` or accesses `.format_string` / `.default` / `.transform` keeps working and picks up the fast path automatically. **This is the v0.2→v0.3 API change — the types are now parametric.**

### 3. `madvise(MADV_SEQUENTIAL)` on mmap (0–4 % marginal)

Tells the kernel to aggressively prefetch pages and drop them after we pass. Same-session A/B, best of 10:

| Config                  | madvise off | madvise on |  Δ      |
|-------------------------|------------:|-----------:|--------:|
| narrow 1M ntasks=8      |    14.69 ms |   14.81 ms |  −0.8 % |
| narrow 5M ntasks=8      |    69.23 ms |   66.15 ms |  +4.4 % |
| wide 500k ntasks=8      |   287.62 ms |  276.55 ms |  +3.8 % |

Kept. Three lines of code, no regressions; cold-cache benefit expected but not measurable on macOS without `sudo purge`.

### 4. Parallel columnar shape — investigation (no change shipped)

Hypothesis: the per-column parallel shape (N `@sync` barriers × T tasks) was wasteful on wide schemas, and row-chunk parallelism (one `@sync`, T tasks each filling all columns) would improve 8-thread efficiency from 44 % to ~70 %.

Experiment: same-session A/B across three candidate shapes, best of 10:

| Config                        | OLD (current)    | NEW (row-chunk)  | FLAT (1 barrier) |
|-------------------------------|-----------------:|-----------------:|-----------------:|
| narrow 1M ntasks=8            |  10.09 ms        |  10.09 ms        |  10.04 ms ★      |
| narrow 5M ntasks=8            |  50.84 ms ★      |  60.62 ms        |  57.55 ms        |
| wide 500k ntasks=2            | 417.23 ms        | 408.86 ms ★      | 413.88 ms        |
| wide 500k ntasks=4            | 211.16 ms ★      | 215.03 ms        | 212.69 ms        |
| wide 500k ntasks=8            | 202.99 ms        | 197.22 ms        | 192.75 ms ★      |

No shape dominates. Differences are within ±5 % noise except narrow 5M where the current shape is clearly best (+15 %).

**Decision:** keep the existing per-column shape. Shipped: four new parallel-path regression tests (wide-schema correctness, indexed variant, `:default` mode, strict-mode line pinpointing) as durable guards against future shape changes.

Further speedups would need a different lever: batch-parse multiple adjacent records per call (SIMD-friendly), or adaptive partitioning for variable-size records. Out of scope for v0.3.

---

## Historical runs

| Date       | Commit      | Notes                                                                                                 |
|------------|-------------|-------------------------------------------------------------------------------------------------------|
| 2026-04-23 | `4fbcf37`   | Pre-optimization baseline.                                                                            |
| 2026-04-23 | `dd889f9`   | Merged `perf/madvise-sequential` — kernel sequential-access hint on mmap.                             |
| 2026-04-23 | `b4de76e`   | Merged `perf/fast-date-parsers` — byte-level fast paths for yyyymmdd / HHMM / dduuuyy / etc.          |
| 2026-04-23 | `aa2c96c`   | Merged `perf/fast-row-parse` — row-oriented path rewritten as columnar + transpose (43×).             |
| 2026-04-23 | `9615d28`   | Merged `perf/parallel-row-chunks` — parallel shape investigation; no code change; regression tests.  |
