# FixedWidthParsers.jl Performance Optimization — Design Document

**Date:** 2026-02-24
**Status:** Approved

## Problem

Current throughput: ~24 MB/s (columnar), target: >500 MB/s.

Profiling shows **~26 allocations per record** with the bottleneck in orchestration, not field parsing:

| Component | Allocs/10K records | Notes |
|-----------|-------------------|-------|
| `parse_field(FWInt)` | ~0 | Already fast |
| `parse_field(FWString)` | 0 | Zero-copy StringView |
| `String(sv)` coercion | 30K (3/record) | One per string field |
| `parse_record` | 279K (28/record) | Symbol[]/Any[] + push! + Tuple() |
| `_parse_columnar` | 257K (26/record) | Dynamic dispatch via Any-typed fields |

## Root Causes

1. **`parse_record` builds `Symbol[]` and `Any[]` vectors every call** — 2 heap allocs + boxing + dynamic dispatch
2. **`FieldSpec.type::Any`** forces dynamic dispatch on every `parse_field` call in the inner loop
3. **`String(StringView(...))`** allocates a new heap String for every string field
4. **`Parsers.xparse`** has overhead for delimiter/quote handling we don't need

## Optimizations

### 1. Hand-written `_parse_int_bytes` (replace Parsers.xparse for ints)

Zero-allocation integer parser that walks bytes directly:

```julia
@inline function _parse_int_bytes(buf, pos, len)
    val = 0; neg = false
    @inbounds for i in pos:pos+len-1
        b = buf[i]
        if b == 0x2d  # '-'
            neg = true
        elseif b >= 0x30 && b <= 0x39
            val = val * 10 + Int(b - 0x30)
        end  # skip spaces/other
    end
    return neg ? -val : val
end
```

Also `_parse_float_bytes` using similar approach or keep Parsers.xparse for floats (less common).

### 2. InlineStrings for short string fields

Add `InlineStrings.jl` dependency. Map field width to inline string type:

| Width | Type | Size |
|-------|------|------|
| 1-3 | String3 | 4 bytes inline |
| 4-7 | String7 | 8 bytes inline |
| 8-15 | String15 | 16 bytes inline |
| 16-31 | String31 | 32 bytes inline |
| 32+ | String | heap allocated |

Inline strings are stored directly in arrays (no pointer indirection, no GC).

`_julia_type(fw::FWString)` returns the appropriate InlineString type based on `fw` being paired with a width (or we add width to FWString).

### 3. Function-barrier columnar loop (runtime schemas)

Replace the single loop over `ns_fields::Vector{FieldSpec}` with per-column function barriers:

```julia
function _fill_column!(col, descriptor, buf, src, n, width, offset)
    @inbounds for i in 1:n
        pos = record_offset(src, i) + offset - 1
        col[i] = parse_field(descriptor, buf, pos, width)
    end
end
```

Called once per field — Julia specializes each call on the concrete descriptor type. No dynamic dispatch inside the inner loop.

### 4. `@generated` columnar parse for static schemas

When `T` is a `@fixedwidth` struct, generate the entire parse:

```julia
@generated function _parse_columnar_static(::Type{T}, src, buf, n) where T
    s = schema(T)
    # Emit: column allocations with exact types
    # Emit: single loop body with constant offsets
    # Return: StructArray
end
```

### 5. Fix parse_record allocations

For runtime schemas, pre-compute the field names tuple once (stored in schema), and use a function-barrier approach:

```julia
function parse_record(schema::FixedWidthSchema, buf, pos)
    values = _parse_values(schema, buf, pos)  # returns Tuple via recursion or @generated
    return NamedTuple{schema._output_names}(values)
end
```

For static schemas (`@fixedwidth`), the `@generated` version emits direct NamedTuple construction.

## Non-Goals

- Thread parallelism (future — separate PR)
- SIMD (future)
- Changing the public API

## Expected Results

| Optimization | Est. allocs eliminated/record | Notes |
|-------------|------------------------------|-------|
| InlineStrings | 3 | String heap allocs → 0 |
| Function barriers | ~20 | No more Any boxing |
| _parse_int_bytes | ~2 | Parsers.xparse overhead |
| Fix parse_record | ~28 (for iteration path) | Symbol[]/Any[] gone |
| **Total** | **~25 of 26** | Target: <3 allocs/record |

Target throughput: >200 MB/s (conservative), >500 MB/s stretch goal.
