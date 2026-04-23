# FixedWidthParsers.jl — Advanced Features Development Log

## Overview

This log documents the design and implementation of 7 advanced features for FixedWidthParsers.jl, a Julia package for parsing fixed-width text files. The work was carried out across multiple sessions using subagent-driven development with two-stage code reviews (spec compliance + code quality) after each task.

**Starting point:** 388 tests passing, with core parsing (FWString, FWInt, FWFloat, FWDate, FWFixedPoint, FWSkip), columnar/row-oriented materialization, `@generated` compile-time specialization, lazy iteration, parallel parsing, schema loading from JSON/TOML, and column selection.

**End state:** 523 tests passing, 7 new features, 7 new test files, 1 new source file, significant modifications to types.jl, materialization.jl, and schema.jl.

---

## Phase 1: Brainstorming & Design

### Process

We explored the codebase thoroughly — reading every source file, test file, and understanding the architecture before proposing features. The key architectural patterns we identified:

- **Function-barrier pattern** in materialization.jl: `_fill_column!` dispatches on the concrete descriptor type, so Julia specializes the inner loop with zero dynamic dispatch.
- **`@generated` path** for `@fixedwidth` macro types: emits a single-pass loop with all field offsets, widths, and descriptor constructors baked as compile-time constants.
- **Three error modes**: `:strict` (throw ParseError), `:lenient` (return missing), and the soon-to-be-added `:default`.
- **InlineString optimization**: `_inline_from_buf` constructs stack-allocated strings directly from buffer bytes via `Base.bitcast`, avoiding all heap allocation for strings up to 31 bytes.

### Feature Selection

We evaluated ~10 candidate features and selected 7, ordered bottom-up so each builds on the previous:

1. **FWBool** — new descriptor type
2. **Custom Pad** — extend existing numeric descriptors
3. **Default Values** — new error mode affecting all descriptors
4. **Post-Parse Transforms** — new field on all descriptors
5. **Schema Visualization** — display methods
6. **Multi-Record Types** — new schema type
7. **@generated Polish** — test coverage for compile-time path

**Key design decision:** Features 1-4 are layered — each adds a field to all descriptor structs. We chose to add fields incrementally (one task at a time) rather than all at once, to keep each diff reviewable and testable.

**Design doc:** `docs/plans/2026-02-24-advanced-features-design.md`
**Implementation plan:** `docs/plans/2026-02-24-advanced-features-plan.md`

---

## Phase 2: Implementation

### Task 1: FWBool Descriptor

**Commits:** `9a0ef66`, `0b44a19`
**Tests added:** 25 (test/test_bool.jl)

**What we built:**
- `FWBool` struct with `true_val::String`, `false_val::String`, `default::Union{Bool, Nothing}`
- `parse_field(::FWBool, ...)` with zero-allocation byte-level comparison
- Schema integration: `_parse_type_string("Bool")`, `_type_to_descriptor(::Type{Bool})`, `@fixedwidth` macro support
- `@generated` path branch for FWBool

**Key insight — zero-alloc string comparison:**
The initial implementation used `strip(StringView(...))` which allocated on every call. The code review caught this and we replaced it with direct byte-level comparison using `ncodeunits`/`codeunit`:

```julia
# Instead of allocating a StringView and stripping it:
tv = fw.true_val
if trimlen == ncodeunits(tv)
    match = true
    @inbounds for k in 1:trimlen
        if buf[first + k - 1] != codeunit(tv, k); match = false; break; end
    end
    match && return true
end
```

This pattern compares the buffer bytes directly against the string's code units without any allocation — critical for a hot-path function called millions of times.

**Code review finding — missing @generated branch:**
The initial implementation forgot to add FWBool to the `@generated` function `_parse_columnar_generated`. Without it, FWBool fields would fall through to the generic `else` branch, losing the compile-time specialization advantage. Fixed in the quality pass.

---

### Task 2: Custom Pad on FWInt and FWFloat

**Commits:** `9ff8157`, `814b000`
**Tests added:** 11 (test/test_custom_pad.jl)

**What we built:**
- Added `pad::Char` field to FWInt and FWFloat (default `' '`)
- Non-space pad handling: creates a temporary buffer replacing pad bytes with spaces, then delegates to existing `_parse_int_bytes`/`_parse_float_bytes`
- `all_pad` early return: fields like `"0000"` with `pad='0'` return `0` / `0.0` instead of erroring

**Key insight — pad replacement strategy:**
Rather than modifying the core parsers to understand pad characters, we chose a simpler approach: replace pad bytes with spaces in a temp buffer, then reuse the existing space-aware parsers. This keeps the hot-path parsers unchanged and only adds overhead when `pad != ' '`:

```julia
if fw.pad != ' '
    pad_byte = UInt8(fw.pad)
    tbuf = Vector{UInt8}(undef, len)
    all_pad = true
    @inbounds for i in 1:len
        b = buf[pos + i - 1]
        if b == pad_byte
            tbuf[i] = 0x20  # replace with space
        else
            tbuf[i] = b
            all_pad = false
        end
    end
    all_pad && return 0  # "0000" with pad='0' → 0
    return _parse_int_bytes(tbuf, 1, len)
end
return _parse_int_bytes(buf, pos, len)  # default pad=' ', no copy needed
```

**Code review finding — FWFloat missing `all_pad`:**
FWInt had the `all_pad && return 0` early return, but FWFloat didn't. All-pad FWFloat fields (e.g., `"00000000"` with `pad='0'`) would try to parse an all-spaces string as a float and error. Fixed by adding the same `all_pad` tracking to FWFloat.

---

### Task 3: Default Values (:default error mode)

**Commits:** `7b0d411`
**Tests added:** 19 (test/test_defaults.jl)

**What we built:**
- Added `default` field to all 6 descriptor types
- New `:default` error mode: blank fields use configured defaults, malformed non-blank fields throw ParseError
- `_is_blank(buf, pos, len, pad_byte)` — checks if all bytes equal the pad character
- `_pad_byte(descriptor)` and `_get_default(descriptor)` accessor helpers
- Dedicated fill functions: `_fill_column_default!`, `_fill_string_column_default!`, and indexed variants
- Updated `_safe_parse_field` for row-oriented `:default` path
- Column type for `:default` is `Vector{T}` (no `Missing` union needed)

**Key insight — `:default` vs `:lenient`:**
`:default` mode sits between `:strict` and `:lenient` in strictness. It's the "production" mode where you know what blank fields mean (substitute a default) but still want to catch genuinely malformed data:

| Mode | Blank field | Malformed field | Column type |
|------|-------------|-----------------|-------------|
| `:strict` | ParseError | ParseError | `Vector{T}` |
| `:default` | Use default | ParseError | `Vector{T}` |
| `:lenient` | `missing` | `missing` | `Vector{Union{T, Missing}}` |

**Key insight — `@generated` path bypass:**
The `@generated` path bypasses `:default` mode entirely (routes to runtime). This avoids generating complex blank-detection + default-substitution logic at compile time. Since `:default` mode is the "careful" mode, the slight performance loss from runtime dispatch is acceptable.

---

### Task 4: Post-Parse Transforms

**Commits:** `37a2d56`, `dbb03c2`
**Tests added:** 15 (test/test_transforms.jl)

**What we built:**
- Added `transform::Union{Function, Nothing}` to all 6 descriptor types
- `_get_transform(descriptor)` and `_julia_type_with_transform(desc, width)` helpers
- `_has_transforms(schema)` — checks if any field has a transform
- Transform applied after `parse_field` + `_coerce` in all fill functions
- Transform applied to default values in `:default` mode
- Transform NOT applied to `missing` in `:lenient` mode
- Transform errors treated as parse errors (strict: ParseError, lenient: missing)
- Column type becomes `Vector{Any}` when transform is set
- FWString InlineString fast path falls back to generic path when transform is set
- `@generated` path bypasses when any field has a transform

**Key insight — column type as `Any`:**
When a transform is set, we can't know the output type at schema time (`FWInt(transform=string)` returns `String`, not `Int`). The column becomes `Vector{Any}`. This is the correct trade-off: transforms sacrifice type-specialization for flexibility.

**Critical bug found in review — silent failure in rescan:**
Both reviewers independently found the same bug: in `_fill_column_default!`, if a transform throws on a default value, the rescan path silently skipped blank+default records instead of re-invoking the transform to attribute the error. The fix adds transform re-invocation in the rescan:

```julia
# Before (bug): blank with default → skip silently
# After (fix):
elseif xform !== nothing
    try
        xform(_coerce(descriptor, width, dflt))
    catch e
        raw = collect(buf[field_pos:field_pos+width-1])
        throw(ParseError(i, col_range, raw, _julia_type(descriptor),
            "Failed to apply transform to default for field :$(name): ..."))
    end
end
```

This bug would have been very hard to find in production — a transform that throws on certain default values would silently produce a partially-filled column with `undef` data.

---

### Task 5: Schema Visualization

**Commit:** `65239a6`
**Tests added:** 31 (test/test_schema_show.jl)

**What we built:**
- `_descriptor_string(desc)` — formats each descriptor showing only non-default parameters
- `Base.show(io, schema)` — compact: `FixedWidthSchema(12 bytes, 4 fields, 3 output)`
- `Base.show(io, MIME"text/plain", schema)` — aligned table with Bytes, Width, Name, Type columns

**Key insight — showing only non-default parameters:**
Each descriptor type has different "interesting" parameters. FWString's default pad is `' '`, so `FWString()` displays as just `"FWString"` while `FWString(pad='0')` shows the pad. FWFixedPoint always shows its `decimals` parameter since it's mandatory. Transforms append `+transform` rather than showing the function object. This makes REPL output clean and scannable:

```
FixedWidthSchema (12 bytes, 4 fields, 3 output)
 Bytes  Width  Name     Type
   1:2      2  carrier  FWString
   3:6      4  fnum     FWInt
  7:9       3  _skip    FWSkip
 10:12      3  origin   FWString
```

---

### Task 6: Multi-Record Types

**Commits:** `a5fc88c`, `ab0f144`
**Tests added:** 21 (test/test_multi_record.jl)

**What we built:**
- `MultiRecordSchema` struct with discriminator range, schema mappings, record width
- Constructor with validation (empty range, no pairs, duplicates, width constraints)
- `parse_file(path, ms::MultiRecordSchema; ...)` — two-pass: classify by discriminator, then parse each group
- `MultiRecordIterator` + `eachrecord(path, ms; ...)` — lazy iterator with `_type::Symbol` field
- Returns `Dict{Symbol, StructArray}` mapping each record type to its parsed data

**Key insight — two-pass architecture:**
Pass 1 reads only the discriminator bytes to classify every record into groups. Pass 2 calls `_parse_columnar_indexed` on each group's indices with its specific schema. This reuses the existing indexed columnar parser without modification — the multi-record logic is purely a classification layer on top.

**Critical fix — resource safety:**
The code review found that `MmapSource` wasn't closed if an exception occurred during classification or parsing (e.g., unknown discriminator in the middle of a file, or a ParseError during group parsing). Wrapped the entire body in `try-finally`:

```julia
src = MmapSource(path, ms.record_width)
try
    # ... classification and parsing ...
    return result
finally
    close(src)
end
```

---

### Task 7: @generated Specialization Polish

**Commit:** `9f17a94`
**Tests added:** 8 (test/test_generated.jl)

**What we built:**
Test coverage verifying the `@generated` compile-time path produces identical results to the runtime path:
- FWBool in `@fixedwidth` structs
- Generated vs runtime path equivalence (100-record comparison)
- Lenient mode in generated path

**Key insight — the @generated path was already correct:**
Tasks 1-2 had already added FWBool and custom pad branches to `_parse_columnar_generated`. Tasks 3-4 had already added bypass conditions for `:default` mode and transforms. This task was purely about adding explicit test coverage to verify the generated path, which is easy to break since it's code-generating code.

---

## Architecture Summary

### Descriptor struct evolution

Each descriptor went through 3 additive changes across Tasks 1-4:

```
Task 1: FWBool(true_val, false_val)
Task 2: FWInt(pad), FWFloat(pad)
Task 3: All descriptors += default field
Task 4: All descriptors += transform field
```

Final struct layout (using FWInt as example):
```julia
struct FWInt
    pad::Char                          # Task 2
    default::Union{Int, Nothing}       # Task 3
    transform::Union{Function, Nothing} # Task 4
end
```

### Fill function matrix

The materialization layer has a matrix of fill functions:

|  | Strict | Lenient | Default |
|--|--------|---------|---------|
| **Direct** | `_fill_column_strict!` | `_fill_column_lenient!` | `_fill_column_default!` |
| **Indexed** | `_fill_column_indexed_strict!` | `_fill_column_indexed_lenient!` | `_fill_column_indexed_default!` |
| **FWString direct** | `_fill_string_column!` | `_fill_string_column!` | `_fill_string_column_default!` |
| **FWString indexed** | `_fill_string_column_indexed!` | `_fill_string_column_indexed!` | `_fill_string_column_indexed_default!` |

Each fill function was updated in Task 4 to apply transforms. FWString specializations fall back to the generic path when transforms are set (since InlineString construction can't anticipate the transform's output type).

### @generated path bypass conditions

The compile-time `_parse_columnar_generated` is used only when ALL conditions are met:
- No record filtering (skip_header, skip_footer, comment)
- Single-threaded (`ntasks <= 1`)
- No column selection (`select`/`exclude`)
- Not `:default` mode
- No transforms on any field

Otherwise, parsing routes through the runtime path which handles all features.

---

## Review Process

Each task went through two-stage review:

1. **Spec compliance review** — verifies every requirement is implemented, nothing missing, nothing extra
2. **Code quality review** — checks for bugs, performance issues, edge cases, consistency

Notable bugs caught by reviews:
- FWBool `parse_field` allocating via `strip(StringView(...))` (Task 1)
- Missing FWBool branch in `@generated` function (Task 1)
- FWFloat missing `all_pad` early return (Task 2)
- Transform error on default value silently swallowed in rescan (Task 4)
- MmapSource resource leak in MultiRecordSchema parse_file (Task 6)

---

## Statistics

| Metric | Before | After |
|--------|--------|-------|
| Tests | 388 | 523 |
| Source files | 7 | 8 |
| Test files | 12 | 19 |
| Descriptor types | 6 | 7 |
| Error modes | 2 | 3 |
| Schema types | 1 | 2 |

**New source file:** `src/multi_record.jl`

**New test files:** `test_bool.jl`, `test_custom_pad.jl`, `test_defaults.jl`, `test_transforms.jl`, `test_schema_show.jl`, `test_multi_record.jl`, `test_generated.jl`
