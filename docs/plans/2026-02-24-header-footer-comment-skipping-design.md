# Header/Footer/Comment Skipping Design

## Goal

Add `skip_header`, `skip_footer`, and `comment` keyword arguments to `parse_file` and `eachrecord` so users can skip non-data records without pre-processing files.

## Constraints

- Comment lines are the same fixed width as data records (preserves arithmetic-offset model)
- Comment detection is a single `UInt8` byte check on the first byte of each record slot
- When no skipping is requested (`skip_header=0, skip_footer=0, comment=nothing`), the existing fast path is used unchanged

## API

```julia
parse_file(path, schema;
    skip_header=0,       # skip first N records
    skip_footer=0,       # skip last N records
    comment=nothing,     # UInt8 — skip records whose first byte matches
    columnar=true, on_error=:strict, ntasks=1)

eachrecord(path, schema;
    skip_header=0,
    skip_footer=0,
    comment=nothing)

# Also works with @fixedwidth types:
parse_file(path, MyType; skip_header=2, comment=UInt8('#'))
```

## Architecture

### Pre-scan phase

A helper `_valid_record_indices(src, skip_header, skip_footer, comment)` produces:
- When no filtering needed: `nothing` (signals "use all records, fast path")
- Otherwise: `Vector{Int}` of valid 1-based record indices

Logic:
1. Start range: `(1 + skip_header):(n - skip_footer)`, clamped so start <= stop
2. If `comment !== nothing`: filter out records whose first byte equals the comment byte
3. Return the index vector (or `nothing` if the full range survives unfiltered)

### Columnar path changes

`_fill_column!` variants gain an overload accepting `indices::Vector{Int}` instead of `record_range::UnitRange{Int}`:
- Output position `j` in `range` maps to source record `indices[j]`
- `col[j]` is written from `record_offset(src, indices[j])`

Parallel partitioning: `_partition_ranges(length(indices), ntasks)` partitions output positions. Each task writes `col[start:stop]` using `indices[start:stop]` for source record lookup.

### Row path changes

Iterate over `indices` instead of `1:n`.

### Iterator path changes

`RecordIterator` stores the valid indices vector. `iterate` uses `indices[state]` to look up the source record position.

### Generated path

When `skip_header=0 && skip_footer=0 && comment===nothing && ntasks <= 1`, the existing `@generated` fast path is used. Otherwise, fall back to the runtime path with indices.

## Error handling

- `skip_header + skip_footer >= n` returns empty result (no error)
- `comment` must be `nothing` or `UInt8`; type error otherwise

## Testing

- Header-only, footer-only, comment-only, all three combined
- Edge cases: skip all records, empty file, no-op defaults
- Parallel + comment interaction
- `@fixedwidth` struct path with skipping
- `eachrecord` with skipping
