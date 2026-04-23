# Parallel Columnar Parsing Design

## Goal

Add multi-threaded columnar parsing to `parse_file` via an `ntasks` keyword argument. Records are partitioned across Julia tasks, each writing to disjoint slices of shared pre-allocated column vectors. Zero extra allocation, no merge step.

## API

```julia
# Runtime schema
sa = parse_file("big.dat", schema; ntasks=4)

# @fixedwidth macro schema
sa = parse_file("big.dat", FlightRecord; ntasks=Threads.nthreads())

# Default: single-threaded (backwards-compatible)
sa = parse_file("big.dat", schema)  # ntasks=1
```

- `ntasks` defaults to `1` (current behavior, no threading overhead)
- Applies only to `columnar=true` mode; ignored for row-oriented parsing
- Clamped: `ntasks = min(ntasks, n)` to avoid empty tasks

## Algorithm

```
parse_file(path, schema; ntasks=4, columnar=true)
  |
  +-- Open MmapSource, compute n = record_count
  +-- Pre-allocate column vectors (same as today)
  +-- Partition 1:n into ntasks contiguous ranges
  |     e.g., [1:250K, 250K+1:500K, 500K+1:750K, 750K+1:1M]
  |
  +-- For each column (function-barrier):
  |     @sync for range in chunk_ranges
  |         Threads.@spawn _fill_column_range!(col, descriptor, ..., range)
  |     end
  |
  +-- Wrap columns in StructArray, return
```

### Why This Works Without Locks

1. **Mmap buffer is read-only** -- all tasks read from the same memory-mapped buffer
2. **Disjoint write regions** -- task k writes only to `col[range_k]`, no overlap
3. **Deterministic offsets** -- `record_offset(src, i) = (i-1) * stride + 1` is pure arithmetic

### Threading Model

- `Threads.@spawn` for task-based parallelism (scheduled on available OS threads)
- `@sync` ensures all tasks complete before returning the StructArray
- When `ntasks=1`, bypass `@spawn` entirely (zero overhead path)

## Error Handling

### Strict Mode

Each spawned task wraps its fill loop in try/catch. On parse failure:
1. Task re-scans its range to locate the exact failing record
2. Throws `ParseError` with correct absolute line number
3. `@sync` propagates the first error to the caller

### Lenient Mode

Each task independently catches per-field errors and assigns `missing`. No coordination needed between tasks. Warning messages include correct absolute line numbers.

## Scope

### Changes

| File | Change |
|------|--------|
| `src/materialization.jl` | Add `ntasks` kwarg to `parse_file`, partition + spawn in `_parse_columnar`, range-based column fill |
| `src/materialization.jl` | Range-based partitioning in `_parse_columnar_generated` |
| `test/test_materialization.jl` | Parallel correctness tests (ntasks=1 vs 2 vs 4, error handling) |
| `benchmark/benchmarks.jl` | Parallel benchmarks (1M records, varying ntasks) |

### Unchanged

- Row-oriented parsing (`columnar=false`) -- single-threaded
- `eachrecord` iteration -- single-threaded, lazy
- IO layer (`io.jl`) -- untouched
- Schema/types -- untouched
- All existing tests -- pass without modification

## Key Design Decisions

1. **Default `ntasks=1`** -- opt-in parallelism, no surprise thread usage
2. **Shared vectors, not chunk-and-merge** -- `record_offset` is pure, so tasks write directly to final storage
3. **Column-major outer loop** -- function barrier per column preserved; tasks partition records within each column
4. **No `@threads` macro** -- `@spawn` gives better composability and doesn't conflict with nested parallelism
