# FixedWidthParsers.jl — Performance Baseline

Baseline measurements taken 2026-04-23 against `main` at commit `4fbcf37`.

**Machine:** Apple Silicon, 8 physical cores, no SMT. Julia 1.12.6, `JULIA_NUM_THREADS=8`.

**Reproduce:** `julia --project --threads=8 benchmark/perf_baseline.jl`

---

## Narrow-schema throughput (7 fields, 24-byte records)

Layout: `carrier:String(2) fnum:Int(4) _skip(1) origin:String(3) dest:String(3) pax:Int(3) revenue:Int(8)`.

Each cell shows best wall time across 5 runs and the implied record throughput.

| Records | Path                          | Time     | Throughput      | vs ntasks=1 |
|--------:|-------------------------------|---------:|----------------:|------------:|
|      1M | runtime columnar ntasks=1     |  48.7 ms |   20.5 M rec/s  |       1.00× |
|      1M | runtime columnar ntasks=2     |  31.0 ms |   32.3 M rec/s  |       1.57× |
|      1M | runtime columnar ntasks=4     |  22.4 ms |   44.7 M rec/s  |       2.18× |
|      1M | runtime columnar ntasks=8     |  17.4 ms |   57.5 M rec/s  |       2.80× |
|      1M | `@generated` ntasks=1         |  30.5 ms |   32.8 M rec/s  |       1.60× |
|      1M | `@generated` ntasks=4 *       |  22.8 ms |   43.8 M rec/s  |       2.14× |
|      1M | row-oriented (`columnar=false`) | 1983.6 ms |   0.5 M rec/s |       0.02× |
|      5M | runtime columnar ntasks=1     | 276.1 ms |   18.1 M rec/s  |       1.00× |
|      5M | runtime columnar ntasks=4     |  90.9 ms |   55.0 M rec/s  |       3.04× |
|      5M | runtime columnar ntasks=8     |  76.9 ms |   65.0 M rec/s  |       3.59× |
|      5M | `@generated` ntasks=1         | 143.2 ms |   34.9 M rec/s  |       1.00× |
|      5M | `@generated` ntasks=4         |  96.2 ms |   52.0 M rec/s  |       1.49× |
|      5M | `@generated` ntasks=8         |  73.7 ms |   67.9 M rec/s  |       1.94× |

<sub>\* When `ntasks>1`, the `@generated` path falls back to the runtime parallel path — see `_parse_file_generated` in `src/materialization.jl`.</sub>

---

## Wide-schema parallel scaling (50 fields, 500k records)

Layout: 50 × `FWInt(4)`, 200-byte records. Stresses the per-column parallel shape where column work is small relative to task-spawn overhead.

| `ntasks` | Time     | Throughput      | Speedup |
|---------:|---------:|----------------:|--------:|
|        1 | 730.9 ms |   0.68 M rec/s  |   1.00× |
|        2 | 408.9 ms |   1.22 M rec/s  |   1.79× |
|        4 | 241.6 ms |   2.07 M rec/s  |   3.03× |
|        8 | 207.4 ms |   2.41 M rec/s  |   3.53× |

8-thread efficiency on the wide schema: **44 %** (3.53× of 8.0×). Per-field throughput is ~3× lower on the wide schema (34 M parses/sec) than on the narrow one (102 M parses/sec), which matches the expected cost of the current per-column task shape — each column's inner loop is too short to amortize `@sync @spawn` overhead.

---

## Where the cycles go (profile, sampled)

### Row-oriented path — the anomaly (40× slower than columnar)

Sampled hot frames when parsing 1M records as `Vector{NamedTuple}`:

| Count | Self | Frame |
|------:|-----:|-------|
|   702 |   70 | `Base.ntuple` — per-record field tuple construction |
|   385 |  208 | `_parse_rows` inner loop |
|   282 |  266 | `_coerce(::FWString, width, v)` — per-field InlineString allocation |
|   267 |    6 | `_parse_rows` ntuple closure |
|   184 |  132 | `_safe_parse_field` — dynamic dispatch + try/catch per field |
|   177 |  177 | `Base.NamedTuple` construction |

**Diagnosis.** The row path uses `Vector{NamedTuple}` (abstract eltype), and inside its inner loop `_safe_parse_field` wraps every field parse in a try/catch with dynamic dispatch on `f.type::Any`. The columnar path avoids both by pre-allocating typed column vectors and function-barriering on concrete descriptor types.

### Columnar path — no obvious hot spot

Sampled hot frames for 5 × 1M columnar parses:

| Count | Frame |
|------:|-------|
|   162 | `_parse_columnar` outer scheduling |
|   117 | `_fill_column!` dispatch |
|    62 | `_fill_column_strict!` — actual fill loop |
|    62 | `parse_field` — field parsers |

Time is dominated by the actual parse work. No wasteful work to remove at this granularity.

---

## Recommendations, ranked by expected impact

| # | Change                                              | Expected win                          | Risk/cost                          |
|---|-----------------------------------------------------|---------------------------------------|------------------------------------|
| 1 | **Fix row-oriented path** (typed `Vector{NT}`, specialized inner loop, drop try/catch in hot path) | **20–40× faster rows** (0.5 → ~15 M rec/s) | Medium. ~50 LOC. Touches `_parse_rows` + `_parse_rows_indexed`. |
| 2 | **Reshape parallel columnar** to row-chunk parallelism (each task fills all columns for its row range) | **1.8–2× on wide schemas**; narrow schema stays flat | Medium-high. ~150 LOC. Needs re-validation of strict/lenient/default. |
| 3 | **Custom fast-path date parsers** (`yyyymmdd`, `HHMM`, `yyyy-mm-dd`) | **~30 % on date-heavy schemas** | Low. ~40 LOC, isolated to `types.jl`. |
| 4 | `madvise(MADV_SEQUENTIAL)` on mmap | Cold-cache only, 10–20 % on first parse of large files | Trivial (3 LOC). |

Row-oriented fix (#1) is the clear top priority — it's the largest absolute gap and the fix is the most isolated. #2 has the highest ceiling for wide-schema users. #3 and #4 are nice-to-haves.

---

## Investigations

### Parallel columnar shape — 2026-04-23

Hypothesis: the current per-column shape (`for col; @sync for r; @spawn
fill; end; end` → N barriers, N×T spawns) is wasteful on wide schemas,
and inverting to row-chunk parallelism (one `@sync`, T tasks each
filling all columns) would improve 8-thread efficiency from 44 % to
~70 % on wide workloads.

Experiment: three shapes, same-session A/B, best of 10:

| Shape                                     | Description                              |
|-------------------------------------------|------------------------------------------|
| OLD (current)                             | `for col` outside; `@sync` + T spawns per column. N barriers, N×T tasks. |
| NEW (row-chunk)                           | One `@sync`; T tasks each loop `for col` filling all columns for its row slice. 1 barrier, T tasks. |
| FLAT                                      | One `@sync`; flatten `col × range` into a single loop. 1 barrier, N×T tasks. |

Results (best time in ★):

| Config                        | OLD              | NEW (row-chunk)  | FLAT             |
|-------------------------------|------------------|------------------|------------------|
| narrow 1M ntasks=2            |  22.31 ms        |  22.21 ms        |  22.21 ms ★      |
| narrow 1M ntasks=4            |  11.79 ms        |  12.11 ms        |  11.69 ms ★      |
| narrow 1M ntasks=8            |  10.09 ms        |  10.09 ms        |  10.04 ms ★      |
| narrow 5M ntasks=8            |  50.84 ms ★      |  60.62 ms        |  57.55 ms        |
| wide 500k ntasks=2            | 417.23 ms        | 408.86 ms ★      | 413.88 ms        |
| wide 500k ntasks=4            | 211.16 ms ★      | 215.03 ms        | 212.69 ms        |
| wide 500k ntasks=8            | 202.99 ms        | 197.22 ms        | 192.75 ms ★      |

Verdict: **no shape dominates.** Differences are within ±5 % noise except
narrow 5M ntasks=8 where the current shape is clearly best (+15 % over
row-chunk). The hypothesis that the per-column shape is wasteful is
wrong at this schema size; the current shape is already near-optimal.

Decision: **keep the existing per-column shape**, but ship the new
correctness regression tests (wide-schema parallel, indexed variant,
default mode under parallel, strict-mode line pinpointing) as durable
guards that outlast any future shape changes.

Further speedups on parallel columnar would likely need a different
lever: batch-parse multiple adjacent records per call (SIMD-friendly),
or adaptive partitioning when records have variable sizes. Both out of
scope here.

## Historical runs

| Date       | Commit    | Notes                                      |
|------------|-----------|--------------------------------------------|
| 2026-04-23 | `4fbcf37` | Initial baseline after perf/parse_string commits. |
| 2026-04-23 | _perf/parallel-row-chunks_ | Investigated 3 parallel shapes; no clear winner — current shape kept. New parallel regression tests added. |
