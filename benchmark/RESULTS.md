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

## Change logs

### `madvise(MADV_SEQUENTIAL)` on mmap — 2026-04-23

A/B comparison, same session, best-of-10 per config:

| Config                  | madvise off | madvise on |  Δ      |
|-------------------------|------------:|-----------:|--------:|
| narrow 1M ntasks=1      |    43.94 ms |   43.62 ms |  +0.7 % |
| narrow 1M ntasks=8      |    14.69 ms |   14.81 ms |  -0.8 % |
| narrow 5M ntasks=1      |   225.75 ms |  226.06 ms |  -0.1 % |
| narrow 5M ntasks=8      |    69.23 ms |   66.15 ms |  +4.4 % |
| wide 500k ntasks=1      |   783.05 ms |  769.99 ms |  +1.7 % |
| wide 500k ntasks=8      |   287.62 ms |  276.55 ms |  +3.8 % |

Warm-cache gain is marginal (0–4 %). No regressions; the ~4 % on
multi-threaded configs is probably real prefetch concurrency help.
Cold-cache gain expected but not measurable on this macOS workstation
without `sudo purge` between runs.

**Verdict:** kept. It's three lines for a small but free win with no
downside, and the benefit should be more visible on first-load of large
files (cold cache) which is a common user workload we can't easily
isolate here.

### Fast-path date/time parsers — 2026-04-23

Parameterized `FWDate{FP}` / `FWTime{FP}` / `FWDateTime{FP}` on a fast-path
symbol chosen at construction from the format string. `parse_field`
specializes per symbol with a byte-level parser; unrecognized formats fall
back unchanged. Fast paths covered:

| Format        | Example     | FP symbol         |
|---------------|-------------|-------------------|
| `yyyymmdd`    | `20260224`  | `:yyyymmdd`       |
| `yyyy-mm-dd`  | `2026-02-24`| `:yyyy_mm_dd`     |
| `dduuuyy`     | `10Jan26`   | `:dduuuyy`        |
| `HHMM`        | `0930`      | `:HHMM`           |
| `HHMMSS`      | `093045`    | `:HHMMSS`         |
| `HH:MM`       | `09:30`     | `:HH_MM`          |
| `HH:MM:SS`    | `09:30:45`  | `:HH_MM_SS`       |
| `yyyymmddHHMM` | `202603171430` | `:yyyymmddHHMM` |
| `yyyymmddHHMMSS` | `20260317143045` | `:yyyymmddHHMMSS` |

End-to-end throughput (3 date cols + 2 time cols per record; best of 5):

| Schema                             | Before       | After         | Speedup |
|------------------------------------|-------------:|--------------:|--------:|
| 3×`yyyymmdd` + 2×`HHMM` 1M, nt=1   |   1.31 M r/s |  16.95 M r/s  |  12.9×  |
| 3×`yyyymmdd` + 2×`HHMM` 1M, nt=8   |   4.91 M r/s |  37.58 M r/s  |   7.7×  |
| 3×`yyyy-mm-dd` 500k, nt=1          |   1.87 M r/s |  28.04 M r/s  |  15.0×  |
| 3×`yyyy-mm-dd` 500k, nt=8          |   7.46 M r/s |  53.94 M r/s  |   7.2×  |
| 3×`dduuuyy` 500k, nt=1             |   ~1.6 M r/s |  29.94 M r/s  |  17.7×† |
| 3×`dduuuyy` 500k, nt=8             |          —   |  36.92 M r/s  |    —    |

<sub>† Measured in a same-session A/B that swapped the specialized `parse_field(::FWDate{:dduuuyy}, ...)` with a generic fallback.</sub>

`dduuuyy` was the biggest win because Dates.jl's month-name token
(`u`) is particularly expensive — it does locale-aware substring matching
per record. The fast path does a case-insensitive 3-byte AND-mask
compare against the 12 English abbreviations.

All 876 tests pass (up from 716; 160 new including a 120-iteration
fuzz test vs `Dates.Date(s, fmt)` on yyyymmdd / yyyy-mm-dd / dduuuyy).

## Historical runs

| Date       | Commit    | Notes                                      |
|------------|-----------|--------------------------------------------|
| 2026-04-23 | `4fbcf37` | Initial baseline after perf/parse_string commits. |
| 2026-04-23 | _perf/madvise-sequential_ | `madvise(MADV_SEQUENTIAL)` on mmap.             |
| 2026-04-23 | _perf/fast-date-parsers_  | Fast-path byte-level date/time/datetime parsers. |
