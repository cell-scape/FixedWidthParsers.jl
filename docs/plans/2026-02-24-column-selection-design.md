# Column Selection Design

## Goal

Add `select` and `exclude` keyword arguments to `parse_file` and `eachrecord` so users can parse only a subset of columns without modifying the schema.

## API

```julia
# Include only these columns
parse_file(path, schema; select=[:carrier, :origin])

# Exclude these columns
parse_file(path, schema; exclude=[:_pad, :revenue])

# Both → ArgumentError
parse_file(path, schema; select=[:carrier], exclude=[:origin])

# Unknown column → ArgumentError
parse_file(path, schema; select=[:nonexistent])
```

Same keywords on `eachrecord` (file + IO) and `@fixedwidth` dispatch.

## Architecture

A helper `_apply_column_selection(schema, select, exclude)` returns a new `FixedWidthSchema` where excluded fields are converted to `FWSkip`. This reuses the existing skip machinery — no changes to inner loop code.

- `select` provided → keep only named fields, convert all others to `FWSkip`
- `exclude` provided → convert named fields to `FWSkip`, keep the rest
- Both `nothing` → return original schema unchanged (fast path)
- Both provided → `ArgumentError`
- Unknown column name → `ArgumentError`

Record width is preserved (byte offsets unchanged). Excluded fields simply aren't parsed or stored.

## Where Applied

- `parse_file` — filter schema before calling parsing functions
- `eachrecord` — filter schema before constructing `RecordIterator`
- `@fixedwidth` dispatch — filter schema before calling `_parse_file_generated`

## Testing

- `select` with subset of columns
- `exclude` with subset
- Error when both provided
- Error for unknown column name
- Works with `eachrecord`, `@fixedwidth`, parallel, row-oriented
- Interaction with existing `FWSkip` fields in schema
