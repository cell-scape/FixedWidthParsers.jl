# Byte-Range Schemas and Schema File Loading Design

## Goal

Add byte-range field specification to `FixedWidthSchema` and a `load_schema` function that reads schema definitions from CSV, JSON, and TOML files.

## Feature 1: Byte-Range Constructor

### API

The existing `FixedWidthSchema` constructor accepts `(width, type)` pairs with auto-computed contiguous offsets. Two new value shapes are added:

```julia
# Existing (unchanged): contiguous width-based
FixedWidthSchema(:carrier => (2, FWString()), :fnum => (4, FWInt()))

# New: range-based (start:end, type)
FixedWidthSchema(:carrier => (1:2, FWString()), :fnum => (3:6, FWInt()))

# New: start + width (start, width, type)
FixedWidthSchema(:carrier => (1, 2, FWString()), :fnum => (3, 4, FWInt()))
```

### Disambiguation

The inner constructor inspects the first pair's value to determine mode:

- `Tuple{Int, Any}` → existing width-based mode (contiguous, no gaps)
- `Tuple{UnitRange{Int}, Any}` → range mode
- `Tuple{Int, Int, Any}` → start+width mode (converted to range internally)

All pairs in a single call must use the same mode. Mixing → `ArgumentError`.

### Range Mode Behavior

- Fields are sorted by start byte
- Gaps between fields get auto-inserted `FWSkip` entries
- Overlapping fields → `ArgumentError`
- `record_width` = end byte of the last field

### Optional `record_width` Keyword

A `record_width` keyword allows extending past the last field (for trailing bytes not covered by any field). When provided:
- Must be ≥ the end byte of the last field
- Trailing gap auto-fills with `FWSkip`

## Feature 2: Schema File Loading

### API

```julia
schema = load_schema("flights.csv")
schema = load_schema("flights.json")   # requires JSON3 loaded
schema = load_schema("flights.toml")
```

Dispatches on file extension. Returns a `FixedWidthSchema` using the range-based constructor.

### Type String Mapping

All formats use the same mapping:

| String | Descriptor |
|--------|-----------|
| `"String"` | `FWString()` |
| `"Int"` | `FWInt()` |
| `"Float64"` | `FWFloat()` |
| `"Skip"` | `FWSkip()` |
| `"Date"` | `FWDate("yyyymmdd")` |
| `"Date(fmt)"` | `FWDate(fmt)` |
| `"FixedPoint(n)"` | `FWFixedPoint(n)` |

Unknown type strings → `ArgumentError`.

### CSV Format

```csv
name,start,end,type
carrier,1,2,String
fnum,3,6,Int
_pad,7,9,Skip
origin,10,12,String
```

- Required columns: `name`, `start`, `end`, `type` (matched by header name, order-independent)
- Extra columns ignored (e.g. `description`, `format`)
- Parsed with basic string splitting — no CSV.jl dependency
- Empty lines and lines starting with `#` skipped

### JSON Format

```json
{
  "fields": [
    {"name": "carrier", "start": 1, "end": 2, "type": "String"},
    {"name": "fnum", "start": 3, "end": 6, "type": "Int"},
    {"name": "origin", "start": 10, "end": 12, "type": "String"}
  ]
}
```

- Requires JSON3.jl as a **package extension** (not a direct dependency)
- `"fields"` is the only required top-level key
- Extra keys at any level ignored

### TOML Format

```toml
[[fields]]
name = "carrier"
start = 1
end = 2
type = "String"

[[fields]]
name = "fnum"
start = 3
end = 6
type = "Int"
```

- Uses stdlib `TOML` — no extra dependency
- `[fields]` is an array of tables

### Dependencies

- CSV parsing: no dependency (basic string splitting)
- TOML parsing: stdlib `TOML`
- JSON parsing: JSON3.jl via **package extension** — `load_schema` for `.json` files is only available when the user has `using JSON3`. Calling it without JSON3 loaded produces an informative error.

## Error Handling

- Overlapping byte ranges → `ArgumentError("fields :carrier and :fnum overlap at bytes 3-4")`
- Unknown type string → `ArgumentError("unknown type string \"Foo\" for field :carrier")`
- Missing required CSV column → `ArgumentError("schema CSV missing required column: start")`
- Malformed JSON/TOML structure → `ArgumentError` with descriptive message
- Unsupported file extension → `ArgumentError("unsupported schema file extension: .xyz")`
- JSON `load_schema` without JSON3 loaded → error directing user to `using JSON3`
- Mixing width-based and range-based pairs → `ArgumentError`
- `record_width` keyword less than last field's end byte → `ArgumentError`

## Testing

- Constructor: range-based, start+width, gap filling, overlap detection, mixing modes error, record_width keyword
- `load_schema` CSV: happy path, extra columns, comments/blank lines, missing columns, unknown types
- `load_schema` TOML: happy path, missing fields
- `load_schema` JSON: happy path (tested via extension)
- Type string parsing: all supported types, parameterized types, unknown types
- Round-trip: load schema from file → parse a fixed-width file → verify correct output
