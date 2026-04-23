# Advanced Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add FWBool, custom numeric pad, default values, post-parse transforms, schema visualization, multi-record types, and @generated specialization to FixedWidthParsers.jl.

**Architecture:** Seven features layered bottom-up. Each feature builds on the previous: FWBool adds a new type, custom pad extends numerics, default/transform add fields to all descriptors and new fill-path logic, schema show overrides display, multi-record adds a new schema type, and @generated polishes the compile-time path. All features follow the existing function-barrier pattern in materialization.jl.

**Tech Stack:** Julia 1.10+, StructArrays, InlineStrings, Dates, Mmap, Tables.jl

---

### Task 1: FWBool Descriptor

Add `FWBool` type with configurable true/false values, `parse_field`, type mappings, and macro support.

**Files:**
- Modify: `src/types.jl` — add FWBool struct + parse_field
- Modify: `src/materialization.jl` — add _julia_type(::FWBool)
- Modify: `src/schema.jl` — add _parse_type_string("Bool"), _type_to_descriptor(::Type{Bool}), @fixedwidth Bool support
- Modify: `src/FixedWidthParsers.jl` — add FWBool to exports
- Create: `test/test_bool.jl` — FWBool tests
- Modify: `test/runtests.jl` — include test_bool.jl

**Step 1: Write the failing tests**

Create `test/test_bool.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field, _parse_type_string, _type_to_descriptor

@testset "FWBool" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "default Y/N" begin
        desc = FWBool()
        @test parse_field(desc, to_buf("Y"), 1, 1) === true
        @test parse_field(desc, to_buf("N"), 1, 1) === false
    end

    @testset "custom true/false values" begin
        desc = FWBool(true_val="T", false_val="F")
        @test parse_field(desc, to_buf("T"), 1, 1) === true
        @test parse_field(desc, to_buf("F"), 1, 1) === false
    end

    @testset "multi-char values" begin
        desc = FWBool(true_val="YES", false_val="NO ")
        @test parse_field(desc, to_buf("YES"), 1, 3) === true
        @test parse_field(desc, to_buf("NO "), 1, 3) === false
    end

    @testset "whitespace stripping" begin
        desc = FWBool()
        @test parse_field(desc, to_buf("Y  "), 1, 3) === true
        @test parse_field(desc, to_buf(" N "), 1, 3) === false
        @test parse_field(desc, to_buf("  Y"), 1, 3) === true
    end

    @testset "mismatch throws" begin
        desc = FWBool()
        @test_throws ArgumentError parse_field(desc, to_buf("X"), 1, 1)
        @test_throws ArgumentError parse_field(desc, to_buf("   "), 1, 3)
    end

    @testset "construction validation" begin
        @test_throws ArgumentError FWBool(true_val="", false_val="N")
        @test_throws ArgumentError FWBool(true_val="Y", false_val="")
    end

    @testset "_julia_type" begin
        @test FixedWidthParsers._julia_type(FWBool()) === Bool
    end

    @testset "_parse_type_string" begin
        @test _parse_type_string("Bool") isa FWBool
        @test _parse_type_string("Bool").true_val == "Y"
        @test _parse_type_string("Bool(T,F)") isa FWBool
        @test _parse_type_string("Bool(T,F)").true_val == "T"
        @test _parse_type_string("Bool(T,F)").false_val == "F"
        @test _parse_type_string("Bool(YES,NO)").true_val == "YES"
    end

    @testset "_type_to_descriptor" begin
        @test _type_to_descriptor(Bool) isa FWBool
    end

    @testset "parse_file with FWBool" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UAY\nDLN\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :active  => (1, FWBool()),
        )
        sa = parse_file(path, schema)
        @test sa.active == [true, false]
        rm(path)
    end

    @testset "lenient mode with FWBool" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UAY\nDLX\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :active  => (1, FWBool()),
        )
        sa = parse_file(path, schema; on_error=:lenient)
        @test sa.active[1] === true
        @test sa.active[2] === missing
        rm(path)
    end

    @testset "@fixedwidth macro with Bool" begin
        @fixedwidth struct BoolRecord
            code::String = 2
            flag::Bool   = 1
        end
        path = tempname()
        open(path, "w") do io
            write(io, "ABY\nCDN\n")
        end
        sa = parse_file(path, BoolRecord)
        @test sa.flag == [true, false]
        rm(path)
    end
end
```

Add to `test/runtests.jl` — insert `include("test_bool.jl")` after the line `include("test_schema_loading.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — FWBool is not defined

**Step 3: Implement FWBool**

In `src/types.jl`, after the `FWFixedPoint` struct (line 121), add:

```julia
"""
    FWBool(; true_val="Y", false_val="N")

Field descriptor: parse a boolean from a fixed-width field.

The field bytes are stripped of leading/trailing whitespace and compared
against `true_val` and `false_val`. A mismatch throws `ArgumentError`.
"""
struct FWBool
    true_val::String
    false_val::String
end
function FWBool(; true_val::AbstractString="Y", false_val::AbstractString="N")
    isempty(true_val) && throw(ArgumentError("true_val must not be empty"))
    isempty(false_val) && throw(ArgumentError("false_val must not be empty"))
    FWBool(String(true_val), String(false_val))
end
```

In `src/types.jl`, after the `parse_field` for FWFixedPoint (end of file), add:

```julia
"""
    parse_field(fw::FWBool, buf, pos, len) → Bool

Parse a boolean by comparing stripped field bytes against true_val/false_val.
"""
@inline function parse_field(fw::FWBool, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = strip(StringView(@view buf[pos:pos+len-1]))
    sv == fw.true_val && return true
    sv == fw.false_val && return false
    throw(ArgumentError("cannot parse Bool from \"$(String(sv))\": expected \"$(fw.true_val)\" or \"$(fw.false_val)\""))
end
```

In `src/materialization.jl`, after `_julia_type(::FWSkip)` (around line 701), add:

```julia
_julia_type(::FWBool) = Bool
```

In `src/schema.jl`, in `_parse_type_string` (around line 374), before the `Date` line, add:

```julia
    s == "Bool"    && return FWBool()
```

After the `FixedPoint(n)` regex block (around line 386), add:

```julia
    # Bool(T,F)
    m = match(r"^Bool\(([^,]+),([^)]+)\)$", s)
    if m !== nothing
        return FWBool(true_val=strip(m.captures[1]), false_val=strip(m.captures[2]))
    end
```

In `src/schema.jl`, after `_type_to_descriptor(::Type{Skip})` (around line 420), add:

```julia
_type_to_descriptor(::Type{Bool}) = FWBool()
```

In the `@fixedwidth` macro in `src/schema.jl`, in the descriptor_expr if-chain (around line 535), add a branch before the `else`:

```julia
        elseif ftype === :Bool
            :(FixedWidthParsers.FWBool())
```

In `src/FixedWidthParsers.jl`, update the export line:

```julia
export FWString, FWInt, FWFloat, FWDate, FWSkip, FWFixedPoint, FWBool, Skip
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS (388 existing + new FWBool tests)

**Step 5: Commit**

```bash
git add src/types.jl src/schema.jl src/materialization.jl src/FixedWidthParsers.jl test/test_bool.jl test/runtests.jl
git commit -m "feat: add FWBool descriptor with configurable true/false values"
```

---

### Task 2: Custom Pad on FWInt and FWFloat

Add a `pad` field to `FWInt` and `FWFloat`. For non-space pads, replace pad bytes with spaces before parsing.

**Files:**
- Modify: `src/types.jl` — restructure FWInt/FWFloat with pad field
- Create: `test/test_custom_pad.jl` — pad tests
- Modify: `test/runtests.jl` — include test_custom_pad.jl

**Step 1: Write the failing tests**

Create `test/test_custom_pad.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field

@testset "Custom Pad" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "FWInt default pad (space) unchanged" begin
        @test FWInt().pad == ' '
        @test parse_field(FWInt(), to_buf("  42"), 1, 4) == 42
    end

    @testset "FWInt zero-padded" begin
        desc = FWInt(pad='0')
        @test parse_field(desc, to_buf("0042"), 1, 4) == 42
        @test parse_field(desc, to_buf("0000"), 1, 4) == 0
        @test parse_field(desc, to_buf("0001"), 1, 4) == 1
    end

    @testset "FWInt asterisk-padded" begin
        desc = FWInt(pad='*')
        @test parse_field(desc, to_buf("**42"), 1, 4) == 42
    end

    @testset "FWInt negative with pad" begin
        desc = FWInt(pad='0')
        @test parse_field(desc, to_buf("0-42"), 1, 4) == -42
    end

    @testset "FWFloat default pad (space) unchanged" begin
        @test FWFloat().pad == ' '
        @test parse_field(FWFloat(), to_buf("  3.14  "), 1, 8) ≈ 3.14
    end

    @testset "FWFloat zero-padded" begin
        desc = FWFloat(pad='0')
        @test parse_field(desc, to_buf("003.1400"), 1, 8) ≈ 3.14
    end

    @testset "parse_file with padded int" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UA0042\nDL0099\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt(pad='0')),
        )
        sa = parse_file(path, schema)
        @test sa.fnum == [42, 99]
        rm(path)
    end
end
```

Add to `test/runtests.jl`: `include("test_custom_pad.jl")` after `include("test_bool.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — FWInt has no `pad` field

**Step 3: Implement custom pad**

In `src/types.jl`, replace the `FWInt` struct (lines 88-89):

```julia
"""
    FWInt(; pad::Char=' ')

Field descriptor: parse a signed integer from padded ASCII bytes.
Non-space pad characters are replaced with spaces before parsing.
"""
struct FWInt
    pad::Char
end
FWInt(; pad::Char=' ') = FWInt(pad)
```

Replace the `FWFloat` struct (lines 95-96):

```julia
"""
    FWFloat(; pad::Char=' ')

Field descriptor: parse a `Float64` from padded ASCII bytes.
Non-space pad characters are replaced with spaces before parsing.
"""
struct FWFloat
    pad::Char
end
FWFloat(; pad::Char=' ') = FWFloat(pad)
```

Replace `parse_field` for FWInt (lines 204-206):

```julia
@inline function parse_field(fw::FWInt, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.pad != ' '
        # Replace pad bytes with spaces in a stack-allocated copy
        tmp = ntuple(i -> (@inbounds b = buf[pos + i - 1]; b == UInt8(fw.pad) ? 0x20 : b), len)
        tbuf = UInt8[tmp...]
        return _parse_int_bytes(tbuf, 1, len)
    end
    return _parse_int_bytes(buf, pos, len)
end
```

Replace `parse_field` for FWFloat (lines 213-216):

```julia
@inline function parse_field(fw::FWFloat, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.pad != ' '
        tmp = ntuple(i -> (@inbounds b = buf[pos + i - 1]; b == UInt8(fw.pad) ? 0x20 : b), len)
        tbuf = UInt8[tmp...]
        return _parse_float_bytes(tbuf, 1, len)
    end
    return _parse_float_bytes(buf, pos, len)
end
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/types.jl test/test_custom_pad.jl test/runtests.jl
git commit -m "feat: add configurable pad character to FWInt and FWFloat"
```

---

### Task 3: Default Values (`:default` Error Mode)

Add `default` fields to all descriptors. Add `_is_blank` helper. Add `:default` error mode to all fill paths.

**Files:**
- Modify: `src/types.jl` — add default field to FWString, FWInt, FWFloat, FWBool, FWDate, FWFixedPoint
- Modify: `src/materialization.jl` — add _is_blank, modify _fill_column!, _safe_parse_field, _empty_structarray, column type logic
- Create: `test/test_defaults.jl` — default value tests
- Modify: `test/runtests.jl` — include test_defaults.jl

**Step 1: Write the failing tests**

Create `test/test_defaults.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _is_blank

@testset "Default Values" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "_is_blank helper" begin
        @test _is_blank(to_buf("   "), 1, 3, UInt8(' ')) === true
        @test _is_blank(to_buf("  X"), 1, 3, UInt8(' ')) === false
        @test _is_blank(to_buf("000"), 1, 3, UInt8('0')) === true
        @test _is_blank(to_buf("001"), 1, 3, UInt8('0')) === false
    end

    @testset "FWInt with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n  99\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(default=0)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [42, 0, 99]
        @test eltype(sa.val) === Int  # no Missing in column type
        rm(path)
    end

    @testset "FWString with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AB\n  \nCD\n")
        end
        schema = FixedWidthSchema(
            :val => (2, FWString(default="??")),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] == "AB"
        @test sa.val[2] == "??"
        @test sa.val[3] == "CD"
        rm(path)
    end

    @testset "FWFloat with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  3.14\n      \n  1.00\n")
        end
        schema = FixedWidthSchema(
            :val => (6, FWFloat(default=0.0)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] ≈ 3.14
        @test sa.val[2] ≈ 0.0
        @test sa.val[3] ≈ 1.0
        rm(path)
    end

    @testset "FWBool with default" begin
        path = tempname()
        open(path, "w") do io
            write(io, "Y\n \nN\n")
        end
        schema = FixedWidthSchema(
            :val => (1, FWBool(default=false)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [true, false, false]
        rm(path)
    end

    @testset "no default: blank in :default mode throws" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt()),  # no default set
        )
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:default)
        rm(path)
    end

    @testset "malformed data in :default mode throws" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(default=0)),
        )
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:default)
        rm(path)
    end

    @testset "zero-padded blank detection" begin
        path = tempname()
        open(path, "w") do io
            write(io, "0042\n0000\n0099\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(pad='0', default=-1)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val == [42, -1, 99]
        rm(path)
    end

    @testset ":default mode column type is Vector{T}" begin
        path = tempname()
        open(path, "w") do io
            write(io, "42\n")
        end
        schema = FixedWidthSchema(:val => (2, FWInt(default=0)))
        sa = parse_file(path, schema; on_error=:default)
        @test eltype(sa.val) === Int
        rm(path)
    end

    @testset "row-oriented :default mode" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n    \n")
        end
        schema = FixedWidthSchema(:val => (4, FWInt(default=0)))
        rows = parse_file(path, schema; columnar=false, on_error=:default)
        @test rows[1].val == 42
        @test rows[2].val == 0
        rm(path)
    end
end
```

Add to `test/runtests.jl`: `include("test_defaults.jl")` after `include("test_custom_pad.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — no `default` keyword on FWInt, `_is_blank` not defined

**Step 3: Add default fields to all descriptors**

In `src/types.jl`, update every descriptor struct to include a `default` field:

**FWString** — change struct to:
```julia
struct FWString
    pad::Char
    default::Union{AbstractString, Nothing}
end
FWString(; pad::Char=' ', default::Union{AbstractString, Nothing}=nothing) = FWString(pad, default)
```

**FWInt** — change struct to:
```julia
struct FWInt
    pad::Char
    default::Union{Int, Nothing}
end
FWInt(; pad::Char=' ', default::Union{Int, Nothing}=nothing) = FWInt(pad, default)
```

**FWFloat** — change struct to:
```julia
struct FWFloat
    pad::Char
    default::Union{Float64, Nothing}
end
FWFloat(; pad::Char=' ', default::Union{Float64, Nothing}=nothing) = FWFloat(pad, default)
```

**FWBool** — change struct to:
```julia
struct FWBool
    true_val::String
    false_val::String
    default::Union{Bool, Nothing}
end
function FWBool(; true_val::AbstractString="Y", false_val::AbstractString="N",
                  default::Union{Bool, Nothing}=nothing)
    isempty(true_val) && throw(ArgumentError("true_val must not be empty"))
    isempty(false_val) && throw(ArgumentError("false_val must not be empty"))
    FWBool(String(true_val), String(false_val), default)
end
```

**FWDate** — change struct to:
```julia
struct FWDate
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Date, Nothing}
end
FWDate(fmt::AbstractString; default::Union{Dates.Date, Nothing}=nothing) =
    FWDate(Dates.DateFormat(fmt), String(fmt), default)
```

**FWFixedPoint** — change struct to:
```julia
struct FWFixedPoint
    decimals::Int
    default::Union{Float64, Nothing}
end
FWFixedPoint(decimals::Int; default::Union{Float64, Nothing}=nothing) =
    FWFixedPoint(decimals, default)
```

**Step 4: Add `_is_blank` helper and `:default` mode logic**

In `src/materialization.jl`, after the `_rethrow_unwrapped` function (around line 207), add:

```julia
"""
    _is_blank(buf, pos, len, pad_byte) → Bool

Return true if all bytes in buf[pos:pos+len-1] equal pad_byte.
"""
@inline function _is_blank(buf::AbstractVector{UInt8}, pos::Int, len::Int, pad_byte::UInt8)
    @inbounds for i in pos:pos+len-1
        buf[i] != pad_byte && return false
    end
    return true
end

"""
    _pad_byte(descriptor) → UInt8

Return the pad byte for a descriptor. Types with a `pad` field use it;
others default to space (0x20).
"""
_pad_byte(d::FWString) = UInt8(d.pad)
_pad_byte(d::FWInt) = UInt8(d.pad)
_pad_byte(d::FWFloat) = UInt8(d.pad)
_pad_byte(::Any) = UInt8(' ')

"""
    _get_default(descriptor) → value or nothing

Return the default value for a descriptor, or nothing if no default is set.
"""
_get_default(d::FWString) = d.default
_get_default(d::FWInt) = d.default
_get_default(d::FWFloat) = d.default
_get_default(d::FWBool) = d.default
_get_default(d::FWDate) = d.default
_get_default(d::FWFixedPoint) = d.default
_get_default(::Any) = nothing
```

Modify `_fill_column!` dispatch (around line 326) to add `:default`:

```julia
function _fill_column!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if on_error === :strict
        _fill_column_strict!(col, descriptor, width, offset, name, buf, src, record_range)
    elseif on_error === :default
        _fill_column_default!(col, descriptor, width, offset, name, buf, src, record_range)
    else
        _fill_column_lenient!(col, descriptor, width, offset, name, buf, src, record_range)
    end
end
```

Add `_fill_column_default!`:

```julia
function _fill_column_default!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    pb = _pad_byte(descriptor)
    dflt = _get_default(descriptor)
    try
        @inbounds for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            if _is_blank(buf, field_pos, width, pb)
                if dflt === nothing
                    raw = collect(buf[field_pos:field_pos+width-1])
                    col_range = offset:(offset + width - 1)
                    throw(ParseError(i, col_range, raw, _julia_type(descriptor),
                        "Blank field :$(name) has no default value"))
                end
                col[i] = dflt isa AbstractString ? _coerce(descriptor, width, dflt) : dflt
            else
                val = parse_field(descriptor, buf, field_pos, width)
                col[i] = _coerce(descriptor, width, val)
            end
        end
    catch e
        e isa ParseError && rethrow()
        # Rescan to find the failing record
        for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            _is_blank(buf, field_pos, width, pb) && continue
            try
                parse_field(descriptor, buf, field_pos, width)
            catch e2
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(ParseError(i, col_range, raw, _julia_type(descriptor),
                    "Failed to parse field :$(name): $(sprint(showerror, e2))"))
            end
        end
    end
end
```

Similarly, add `:default` handling to the indexed variant of `_fill_column!` (the one taking `indices::Vector{Int}`):

```julia
function _fill_column!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if on_error === :strict
        _fill_column_indexed_strict!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    elseif on_error === :default
        _fill_column_indexed_default!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    else
        _fill_column_indexed_lenient!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    end
end
```

Add indexed default fill:

```julia
function _fill_column_indexed_default!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
)
    pb = _pad_byte(descriptor)
    dflt = _get_default(descriptor)
    try
        @inbounds for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            if _is_blank(buf, field_pos, width, pb)
                if dflt === nothing
                    raw = collect(buf[field_pos:field_pos+width-1])
                    col_range = offset:(offset + width - 1)
                    throw(ParseError(src_i, col_range, raw, _julia_type(descriptor),
                        "Blank field :$(name) has no default value"))
                end
                col[j] = dflt isa AbstractString ? _coerce(descriptor, width, dflt) : dflt
            else
                val = parse_field(descriptor, buf, field_pos, width)
                col[j] = _coerce(descriptor, width, val)
            end
        end
    catch e
        e isa ParseError && rethrow()
        for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            _is_blank(buf, field_pos, width, pb) && continue
            try
                parse_field(descriptor, buf, field_pos, width)
            catch e2
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(ParseError(src_i, col_range, raw, _julia_type(descriptor),
                    "Failed to parse field :$(name): $(sprint(showerror, e2))"))
            end
        end
    end
end
```

Update `_safe_parse_field` (used by row-oriented paths) to handle `:default`:

In the function body (around line 228), change the catch block to:

```julia
function _safe_parse_field(
    field::FieldSpec,
    buf::AbstractVector{UInt8},
    rec_pos::Int,
    record_idx::Int,
    on_error::Symbol,
)
    field_pos = rec_pos + field.offset - 1

    # Default mode: check blank before parse
    if on_error === :default
        pb = _pad_byte(field.type)
        if _is_blank(buf, field_pos, field.width, pb)
            dflt = _get_default(field.type)
            if dflt === nothing
                raw = collect(buf[field_pos:field_pos+field.width-1])
                col_range = field.offset:(field.offset + field.width - 1)
                throw(ParseError(record_idx, col_range, raw, _julia_type(field.type),
                    "Blank field :$(field.name) has no default value"))
            end
            return dflt
        end
    end

    try
        return parse_field(field.type, buf, field_pos, field.width)
    catch e
        raw = collect(buf[field_pos:field_pos+field.width-1])
        col_range = field.offset:(field.offset + field.width - 1)
        if on_error === :lenient
            @warn "Parse error at line $record_idx, field :$(field.name)" exception = e
            return missing
        else  # :strict or :default — malformed data always throws
            throw(
                ParseError(
                    record_idx,
                    col_range,
                    raw,
                    _julia_type(field.type),
                    "Failed to parse field :$(field.name): $(sprint(showerror, e))",
                ),
            )
        end
    end
end
```

Update column type selection — `:default` mode uses `Vector{T}` (same as `:strict`), no Missing needed.

In `_parse_columnar` (around line 275), change the column allocation:

```julia
    columns = if on_error === :lenient
        [Vector{Union{_julia_type(f.type, f.width), Missing}}(undef, n) for f in ns_fields]
    else  # :strict or :default
        [Vector{_julia_type(f.type, f.width)}(undef, n) for f in ns_fields]
    end
```

Apply the same change in `_parse_columnar_indexed` (around line 612) and `_empty_structarray` (around line 676).

**Step 5: Run tests**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/types.jl src/materialization.jl test/test_defaults.jl test/runtests.jl
git commit -m "feat: add default values with :default error mode"
```

---

### Task 4: Post-Parse Transforms

Add `transform` field to all descriptors. Apply transform after parse_field in all fill paths.

**Files:**
- Modify: `src/types.jl` — add transform field to all descriptors
- Modify: `src/materialization.jl` — apply transform in fill paths, column type logic
- Create: `test/test_transforms.jl` — transform tests
- Modify: `test/runtests.jl` — include test_transforms.jl

**Step 1: Write the failing tests**

Create `test/test_transforms.jl`:

```julia
using Test
using FixedWidthParsers

@testset "Post-Parse Transforms" begin

    @testset "FWString with uppercase transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\ndef\n")
        end
        schema = FixedWidthSchema(
            :val => (3, FWString(transform=uppercase)),
        )
        sa = parse_file(path, schema)
        @test sa.val[1] == "ABC"
        @test sa.val[2] == "DEF"
        rm(path)
    end

    @testset "FWFloat with rounding transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "3.14159\n2.71828\n")
        end
        schema = FixedWidthSchema(
            :val => (7, FWFloat(transform=x -> round(x, digits=2))),
        )
        sa = parse_file(path, schema)
        @test sa.val[1] ≈ 3.14
        @test sa.val[2] ≈ 2.72
        rm(path)
    end

    @testset "FWBool with negation transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "Y\nN\n")
        end
        schema = FixedWidthSchema(
            :val => (1, FWBool(transform=!)),
        )
        sa = parse_file(path, schema)
        @test sa.val == [false, true]
        rm(path)
    end

    @testset "transform with :default mode applies to defaults" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\n   \n")
        end
        schema = FixedWidthSchema(
            :val => (3, FWString(default="zzz", transform=uppercase)),
        )
        sa = parse_file(path, schema; on_error=:default)
        @test sa.val[1] == "ABC"
        @test sa.val[2] == "ZZZ"
        rm(path)
    end

    @testset "transform NOT applied to missing in :lenient" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x * 2)),
        )
        sa = parse_file(path, schema; on_error=:lenient)
        @test sa.val[1] == 84
        @test sa.val[2] === missing
        rm(path)
    end

    @testset "transform error in :strict mode throws ParseError" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  -1\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x < 0 ? error("negative!") : x)),
        )
        @test_throws FixedWidthParsers.ParseError parse_file(path, schema; on_error=:strict)
        rm(path)
    end

    @testset "transform error in :lenient mode returns missing" begin
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  -1\n")
        end
        schema = FixedWidthSchema(
            :val => (4, FWInt(transform=x -> x < 0 ? error("negative!") : x)),
        )
        sa = parse_file(path, schema; on_error=:lenient)
        @test sa.val[1] == 42
        @test sa.val[2] === missing
        rm(path)
    end

    @testset "column type is Any when transform is set" begin
        path = tempname()
        open(path, "w") do io
            write(io, "42\n")
        end
        schema = FixedWidthSchema(:val => (2, FWInt(transform=string)))
        sa = parse_file(path, schema)
        @test sa.val[1] == "42"
        rm(path)
    end

    @testset "row-oriented transform" begin
        path = tempname()
        open(path, "w") do io
            write(io, "abc\ndef\n")
        end
        schema = FixedWidthSchema(:val => (3, FWString(transform=uppercase)))
        rows = parse_file(path, schema; columnar=false)
        @test rows[1].val == "ABC"
        @test rows[2].val == "DEF"
        rm(path)
    end
end
```

Add to `test/runtests.jl`: `include("test_transforms.jl")` after `include("test_defaults.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — no `transform` keyword

**Step 3: Add transform field to all descriptors**

In `src/types.jl`, update each struct to add a `transform` field. The pattern for each:

**FWString:**
```julia
struct FWString
    pad::Char
    default::Union{AbstractString, Nothing}
    transform::Union{Function, Nothing}
end
FWString(; pad::Char=' ', default::Union{AbstractString, Nothing}=nothing,
           transform::Union{Function, Nothing}=nothing) = FWString(pad, default, transform)
```

**FWInt:**
```julia
struct FWInt
    pad::Char
    default::Union{Int, Nothing}
    transform::Union{Function, Nothing}
end
FWInt(; pad::Char=' ', default::Union{Int, Nothing}=nothing,
        transform::Union{Function, Nothing}=nothing) = FWInt(pad, default, transform)
```

**FWFloat:**
```julia
struct FWFloat
    pad::Char
    default::Union{Float64, Nothing}
    transform::Union{Function, Nothing}
end
FWFloat(; pad::Char=' ', default::Union{Float64, Nothing}=nothing,
          transform::Union{Function, Nothing}=nothing) = FWFloat(pad, default, transform)
```

**FWBool:**
```julia
struct FWBool
    true_val::String
    false_val::String
    default::Union{Bool, Nothing}
    transform::Union{Function, Nothing}
end
function FWBool(; true_val::AbstractString="Y", false_val::AbstractString="N",
                  default::Union{Bool, Nothing}=nothing,
                  transform::Union{Function, Nothing}=nothing)
    isempty(true_val) && throw(ArgumentError("true_val must not be empty"))
    isempty(false_val) && throw(ArgumentError("false_val must not be empty"))
    FWBool(String(true_val), String(false_val), default, transform)
end
```

**FWDate:**
```julia
struct FWDate
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Date, Nothing}
    transform::Union{Function, Nothing}
end
FWDate(fmt::AbstractString; default::Union{Dates.Date, Nothing}=nothing,
       transform::Union{Function, Nothing}=nothing) =
    FWDate(Dates.DateFormat(fmt), String(fmt), default, transform)
```

**FWFixedPoint:**
```julia
struct FWFixedPoint
    decimals::Int
    default::Union{Float64, Nothing}
    transform::Union{Function, Nothing}
end
FWFixedPoint(decimals::Int; default::Union{Float64, Nothing}=nothing,
             transform::Union{Function, Nothing}=nothing) =
    FWFixedPoint(decimals, default, transform)
```

**Step 4: Add transform application in materialization.jl**

Add a helper:

```julia
"""
    _get_transform(descriptor) → Function or nothing
"""
_get_transform(d::FWString) = d.transform
_get_transform(d::FWInt) = d.transform
_get_transform(d::FWFloat) = d.transform
_get_transform(d::FWBool) = d.transform
_get_transform(d::FWDate) = d.transform
_get_transform(d::FWFixedPoint) = d.transform
_get_transform(::Any) = nothing
```

Update `_julia_type` to return `Any` when transform is set. Add a new 2-arg dispatch that checks transform:

```julia
function _julia_type_with_transform(desc, width::Int)
    _get_transform(desc) !== nothing && return Any
    return _julia_type(desc, width)
end
```

Replace all calls to `_julia_type(f.type, f.width)` in column allocation (`_parse_columnar`, `_parse_columnar_indexed`, `_empty_structarray`) with `_julia_type_with_transform(f.type, f.width)`.

In each fill function (`_fill_column_strict!`, `_fill_column_lenient!`, `_fill_column_default!`, and their indexed variants), after computing `val`, apply the transform:

In `_fill_column_strict!`, change the inner loop to:

```julia
    xform = _get_transform(descriptor)
    try
        @inbounds for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[i] = val
        end
    catch
        # ... rescan logic unchanged, but also try transform ...
```

In `_fill_column_lenient!`, wrap the transform in the try/catch:

```julia
    xform = _get_transform(descriptor)
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        try
            val = parse_field(descriptor, buf, field_pos, width)
            val = _coerce(descriptor, width, val)
            if xform !== nothing
                val = xform(val)
            end
            col[i] = val
        catch e
            @warn "Parse error at line $i, field :$(name)" exception = e
            col[i] = missing
        end
    end
```

In `_fill_column_default!`, apply transform to both parsed values AND default values:

```julia
    xform = _get_transform(descriptor)
    # In the blank branch:
    dflt_val = dflt
    if xform !== nothing
        dflt_val = xform(dflt_val)
    end
    col[i] = dflt_val isa AbstractString ? _coerce(descriptor, width, dflt_val) : dflt_val
    # In the parse branch:
    val = _coerce(descriptor, width, val)
    if xform !== nothing
        val = xform(val)
    end
    col[i] = val
```

Apply the same pattern to all indexed variants and `_safe_parse_field`.

In `_safe_parse_field`, after the successful parse, apply transform:

```julia
    try
        val = parse_field(field.type, buf, field_pos, field.width)
        xform = _get_transform(field.type)
        if xform !== nothing
            val = xform(val)
        end
        return val
    catch e
        ...
    end
```

For `:default` mode blank with default in `_safe_parse_field`:

```julia
    if dflt === nothing
        # ... throw ...
    end
    xform = _get_transform(field.type)
    return xform !== nothing ? xform(dflt) : dflt
```

For the string specialization `_fill_column!` for `FWString` — when transform is set, fall back to the generic fill path:

```julia
function _fill_column!(
    col::AbstractVector,
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    if descriptor.transform !== nothing
        # Fall back to generic path when transform is set
        if on_error === :strict
            _fill_column_strict!(col, descriptor, width, offset, name, buf, src, record_range)
        elseif on_error === :default
            _fill_column_default!(col, descriptor, width, offset, name, buf, src, record_range)
        else
            _fill_column_lenient!(col, descriptor, width, offset, name, buf, src, record_range)
        end
        return
    end
    ISType = _inline_string_type(width)
    _fill_string_column!(col, ISType, descriptor, width, offset, buf, src, record_range)
end
```

Same pattern for the indexed FWString specialization.

**Step 5: Run tests**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/types.jl src/materialization.jl test/test_transforms.jl test/runtests.jl
git commit -m "feat: add post-parse transforms to all field descriptors"
```

---

### Task 5: Schema Visualization

Override `Base.show` for `FixedWidthSchema` with compact and multi-line display.

**Files:**
- Modify: `src/schema.jl` — add Base.show methods, _descriptor_string helper
- Create: `test/test_schema_show.jl` — display tests
- Modify: `test/runtests.jl` — include test_schema_show.jl

**Step 1: Write the failing tests**

Create `test/test_schema_show.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _descriptor_string

@testset "Schema Visualization" begin

    @testset "_descriptor_string" begin
        @test _descriptor_string(FWString()) == "FWString"
        @test _descriptor_string(FWString(pad='0')) == "FWString(pad='0')"
        @test _descriptor_string(FWInt()) == "FWInt"
        @test _descriptor_string(FWInt(pad='0')) == "FWInt(pad='0')"
        @test _descriptor_string(FWFloat()) == "FWFloat"
        @test _descriptor_string(FWBool()) == "FWBool"
        @test _descriptor_string(FWBool(true_val="T", false_val="F")) == "FWBool(\"T\",\"F\")"
        @test _descriptor_string(FWDate("yyyymmdd")) == "FWDate"
        @test _descriptor_string(FWDate("ddmmyyyy")) == "FWDate(\"ddmmyyyy\")"
        @test _descriptor_string(FWFixedPoint(2)) == "FWFixedPoint(2)"
        @test _descriptor_string(FWSkip()) == "FWSkip"
        @test _descriptor_string(FWInt(default=0)) == "FWInt(default=0)"
        @test _descriptor_string(FWInt(pad='0', default=0)) == "FWInt(pad='0', default=0)"
        @test _descriptor_string(FWString(transform=uppercase)) == "FWString+transform"
        @test _descriptor_string(FWInt(pad='0', default=0, transform=abs)) == "FWInt(pad='0', default=0)+transform"
    end

    @testset "compact show" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_skip   => (3, FWSkip()),
            :origin  => (3, FWString()),
        )
        s = sprint(show, schema)
        @test contains(s, "12 bytes")
        @test contains(s, "4 fields")
        @test contains(s, "3 output")
    end

    @testset "multi-line show" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_skip   => (3, FWSkip()),
            :origin  => (3, FWString()),
        )
        s = sprint(show, MIME("text/plain"), schema)
        @test contains(s, "Bytes")
        @test contains(s, "Width")
        @test contains(s, "Name")
        @test contains(s, "Type")
        @test contains(s, "carrier")
        @test contains(s, "fnum")
        @test contains(s, "_skip")
        @test contains(s, "origin")
        @test contains(s, "1:2")
        @test contains(s, "3:6")
        @test contains(s, "FWInt")
    end

    @testset "empty schema show" begin
        schema = FixedWidthSchema()
        s = sprint(show, schema)
        @test contains(s, "0 bytes")
        @test contains(s, "0 fields")
    end
end
```

Add to `test/runtests.jl`: `include("test_schema_show.jl")` after `include("test_transforms.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — _descriptor_string not defined

**Step 3: Implement schema visualization**

In `src/schema.jl`, at the end of the file (after the `@fixedwidth` macro), add:

```julia
# ---------------------------------------------------------------------------
# Schema visualization
# ---------------------------------------------------------------------------

"""
    _descriptor_string(desc) → String

Format a descriptor with its non-default parameters for display.
"""
function _descriptor_string(::FWSkip)
    return "FWSkip"
end

function _descriptor_string(d::FWString)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(repr(d.default))")
    base = isempty(params) ? "FWString" : "FWString($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWInt)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWInt" : "FWInt($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWFloat)
    params = String[]
    d.pad != ' ' && push!(params, "pad='$(d.pad)'")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWFloat" : "FWFloat($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWBool)
    params = String[]
    (d.true_val != "Y" || d.false_val != "N") && push!(params, "\"$(d.true_val)\",\"$(d.false_val)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWBool" : "FWBool($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWDate)
    params = String[]
    d.format_string != "yyyymmdd" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWDate" : "FWDate($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

function _descriptor_string(d::FWFixedPoint)
    params = ["$(d.decimals)"]
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = "FWFixedPoint($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end

"""
    Base.show(io::IO, s::FixedWidthSchema)

Compact single-line display.
"""
function Base.show(io::IO, s::FixedWidthSchema)
    nout = length(s._output_fields)
    nf = length(s.fields)
    print(io, "FixedWidthSchema($(s.record_width) bytes, $nf fields, $nout output)")
end

"""
    Base.show(io::IO, ::MIME"text/plain", s::FixedWidthSchema)

Multi-line REPL display with aligned columns.
"""
function Base.show(io::IO, ::MIME"text/plain", s::FixedWidthSchema)
    nout = length(s._output_fields)
    nf = length(s.fields)
    println(io, "FixedWidthSchema ($(s.record_width) bytes, $nf fields, $nout output)")

    isempty(s.fields) && return

    # Build display rows
    rows = Tuple{String, String, String, String}[]
    for f in s.fields
        last_byte = f.offset + f.width - 1
        bytes_str = "$(f.offset):$(last_byte)"
        width_str = "$(f.width)"
        name_str = string(f.name)
        type_str = _descriptor_string(f.type)
        push!(rows, (bytes_str, width_str, name_str, type_str))
    end

    # Compute column widths
    w_bytes = max(5, maximum(length(r[1]) for r in rows))
    w_width = max(5, maximum(length(r[2]) for r in rows))
    w_name  = max(4, maximum(length(r[3]) for r in rows))

    # Header
    println(io, " ", rpad("Bytes", w_bytes), "  ", rpad("Width", w_width), "  ", rpad("Name", w_name), "  Type")

    # Data rows
    for (bytes_str, width_str, name_str, type_str) in rows
        println(io, " ", lpad(bytes_str, w_bytes), "  ", lpad(width_str, w_width), "  ", rpad(name_str, w_name), "  ", type_str)
    end
end
```

**Step 4: Run tests**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema.jl test/test_schema_show.jl test/runtests.jl
git commit -m "feat: add schema visualization with compact and multi-line show"
```

---

### Task 6: Multi-Record Types

Add `MultiRecordSchema` for files with header/detail/trailer record types using a discriminator byte range.

**Files:**
- Create: `src/multi_record.jl` — MultiRecordSchema struct, construction, parsing
- Modify: `src/FixedWidthParsers.jl` — include multi_record.jl, add exports
- Create: `test/test_multi_record.jl` — multi-record tests
- Modify: `test/runtests.jl` — include test_multi_record.jl

**Step 1: Write the failing tests**

Create `test/test_multi_record.jl`:

```julia
using Test
using FixedWidthParsers

@testset "MultiRecordSchema" begin

    @testset "basic H/D/T parsing" begin
        header_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :title    => (9, FWString()),
        )
        detail_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :code     => (3, FWString()),
            :value    => (6, FWInt()),
        )
        trailer_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :count    => (9, FWInt()),
        )

        ms = MultiRecordSchema(
            1:1,
            "H" => header_schema,
            "D" => detail_schema,
            "T" => trailer_schema,
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HTestFile \n")
            write(io, "DABC   123\n")
            write(io, "DDEF   456\n")
            write(io, "T        3\n")
        end

        result = parse_file(path, ms)
        @test result[:H].title == ["TestFile"]
        @test result[:D].code == ["ABC", "DEF"]
        @test result[:D].value == [123, 456]
        @test result[:T].count == [3]
        rm(path)
    end

    @testset "unknown discriminator throws" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "A  42\nX  99\n")
        end
        @test_throws ArgumentError parse_file(path, ms)
        rm(path)
    end

    @testset "skip_header and skip_footer" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (2, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "H00\nD42\nD99\nT00\n")
        end
        result = parse_file(path, ms; skip_header=1, skip_footer=1)
        @test result[:D].val == [42, 99]
        rm(path)
    end

    @testset "multi-byte discriminator" begin
        schema_hd = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWString()))
        schema_dt = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
        ms = MultiRecordSchema(1:2, "HD" => schema_hd, "DT" => schema_dt)
        path = tempname()
        open(path, "w") do io
            write(io, "HDABC\nDT 42\n")
        end
        result = parse_file(path, ms)
        @test result[:HD].val == ["ABC"]
        @test result[:DT].val == [42]
        rm(path)
    end

    @testset "empty group" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (2, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema, "B" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "A42\nA99\n")
        end
        result = parse_file(path, ms)
        @test length(result[:A]) == 2
        @test length(result[:B]) == 0
        rm(path)
    end

    @testset "construction validation" begin
        schema = FixedWidthSchema(:val => (3, FWString()))
        # Empty discriminator
        @test_throws ArgumentError MultiRecordSchema(1:0, "A" => schema)
        # Empty pairs
        @test_throws ArgumentError MultiRecordSchema(1:1)
        # Duplicate discriminator
        @test_throws ArgumentError MultiRecordSchema(1:1, "A" => schema, "A" => schema)
    end

    @testset "record_width override" begin
        short_schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => short_schema; record_width=10)
        path = tempname()
        open(path, "w") do io
            write(io, "D  42     \nD  99     \n")
        end
        result = parse_file(path, ms)
        @test result[:D].val == [42, 99]
        rm(path)
    end

    @testset "eachrecord with multi-record" begin
        schema_h = FixedWidthSchema(:rec_type => (1, FWString()), :title => (4, FWString()))
        schema_d = FixedWidthSchema(:rec_type => (1, FWString()), :value => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "H" => schema_h, "D" => schema_d)
        path = tempname()
        open(path, "w") do io
            write(io, "HTest\nD  42\nD  99\n")
        end
        records = collect(eachrecord(path, ms))
        @test length(records) == 3
        @test records[1]._type === :H
        @test records[1].title == "Test"
        @test records[2]._type === :D
        @test records[2].value == 42
        rm(path)
    end

    @testset "on_error applies to all schemas" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "D  42\nD  XY\n")
        end
        result = parse_file(path, ms; on_error=:lenient)
        @test result[:D].val[1] == 42
        @test result[:D].val[2] === missing
        rm(path)
    end
end
```

Add to `test/runtests.jl`: `include("test_multi_record.jl")` after `include("test_schema_show.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — MultiRecordSchema not defined

**Step 3: Implement MultiRecordSchema**

Create `src/multi_record.jl`:

```julia
"""
    multi_record.jl — Multi-record type schema for files with mixed record formats.
"""

"""
    MultiRecordSchema

Schema for files with multiple record types identified by a discriminator field.

Each record type maps a discriminator value (e.g. "H", "D", "T") to a
`FixedWidthSchema`. The discriminator byte range is checked for every record
to classify it into the appropriate group.

# Fields
- `discriminator::UnitRange{Int}` — byte range of the discriminator field
- `schemas::Vector{Tuple{String, Symbol, FixedWidthSchema}}` — (disc_value, label, schema) triples
- `record_width::Int` — total bytes per record (max of all schemas or override)
"""
struct MultiRecordSchema
    discriminator::UnitRange{Int}
    schemas::Vector{Tuple{String, Symbol, FixedWidthSchema}}
    record_width::Int
end

"""
    MultiRecordSchema(discriminator, pairs...; record_width=nothing)

Construct a MultiRecordSchema from discriminator range and `value => schema` pairs.

Labels are derived from discriminator values: `"H"` → `:H`, `"DT"` → `:DT`.
"""
function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    length(discriminator) < 1 && throw(ArgumentError("discriminator range must not be empty"))
    isempty(pairs) && throw(ArgumentError("at least one discriminator => schema pair is required"))

    # Check for duplicates
    vals = [p.first for p in pairs]
    length(unique(vals)) != length(vals) && throw(ArgumentError("duplicate discriminator values: $(vals)"))

    schemas = Tuple{String, Symbol, FixedWidthSchema}[]
    max_width = 0
    for (disc_val, schema) in pairs
        label = Symbol(disc_val)
        push!(schemas, (disc_val, label, schema))
        max_width = max(max_width, FixedWidthParsers.record_width(schema))
    end

    rw = record_width !== nothing ? record_width : max_width
    if rw < max_width
        throw(ArgumentError("record_width=$rw is less than the widest schema ($max_width)"))
    end

    return MultiRecordSchema(discriminator, schemas, rw)
end

# ---------------------------------------------------------------------------
# parse_file for MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    parse_file(path, ms::MultiRecordSchema; on_error=:strict, ntasks=1,
               skip_header=0, skip_footer=0, comment=nothing) → Dict{Symbol, StructArray}

Parse a multi-record file. Returns a Dict mapping each record type label to its StructArray.
"""
function parse_file(
    path::AbstractString,
    ms::MultiRecordSchema;
    on_error::Symbol=:strict,
    ntasks::Int=1,
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = MmapSource(path, ms.record_width)
    n = record_count(src)
    buf = buffer(src)

    # Get valid indices (respecting skip_header, skip_footer, comment)
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    valid_indices = indices === nothing ? collect(1:n) : indices

    # First pass: classify records by discriminator
    disc_range = ms.discriminator
    disc_len = length(disc_range)
    disc_offset = first(disc_range)  # 1-based offset within record

    # Build lookup: disc_value → index into ms.schemas
    disc_lookup = Dict{String, Int}()
    for (idx, (disc_val, _, _)) in enumerate(ms.schemas)
        disc_lookup[disc_val] = idx
    end

    groups = [Int[] for _ in ms.schemas]

    for rec_idx in valid_indices
        rec_pos = record_offset(src, rec_idx)
        field_pos = rec_pos + disc_offset - 1
        disc_bytes = String(copy(buf[field_pos:field_pos+disc_len-1]))
        group_idx = get(disc_lookup, disc_bytes, 0)
        if group_idx == 0
            close(src)
            throw(ArgumentError(
                "unknown discriminator value $(repr(disc_bytes)) at record $rec_idx"
            ))
        end
        push!(groups[group_idx], rec_idx)
    end

    # Second pass: parse each group with its schema
    result = Dict{Symbol, StructArray}()
    for (group_idx, (_, label, schema)) in enumerate(ms.schemas)
        group_indices = groups[group_idx]
        if isempty(group_indices)
            result[label] = _empty_structarray(schema, on_error)
        else
            nvalid = length(group_indices)
            result[label] = _parse_columnar_indexed(schema, src, buf, group_indices, on_error, ntasks)
        end
    end

    close(src)
    return result
end

# ---------------------------------------------------------------------------
# eachrecord for MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    MultiRecordIterator

Lazy iterator over multi-record files. Each yielded NamedTuple includes
a `:_type::Symbol` field identifying which schema matched.
"""
struct MultiRecordIterator
    source::AbstractSource
    ms::MultiRecordSchema
    indices::Union{Vector{Int}, Nothing}
end

function eachrecord(
    path::AbstractString,
    ms::MultiRecordSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = MmapSource(path, ms.record_width)
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return MultiRecordIterator(src, ms, indices)
end

function Base.length(iter::MultiRecordIterator)
    iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
end

Base.eltype(::Type{<:MultiRecordIterator}) = NamedTuple
Base.IteratorSize(::Type{<:MultiRecordIterator}) = Base.HasLength()
Base.close(iter::MultiRecordIterator) = close(iter.source)

function Base.iterate(iter::MultiRecordIterator, state::Int=1)
    n = iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
    state > n && return nothing

    src_i = iter.indices === nothing ? state : iter.indices[state]
    buf = buffer(iter.source)
    rec_pos = record_offset(iter.source, src_i)

    # Read discriminator
    disc_range = iter.ms.discriminator
    disc_offset = first(disc_range)
    disc_len = length(disc_range)
    field_pos = rec_pos + disc_offset - 1
    disc_bytes = String(copy(buf[field_pos:field_pos+disc_len-1]))

    # Find matching schema
    for (disc_val, label, schema) in iter.ms.schemas
        if disc_bytes == disc_val
            record = parse_record(schema, buf, rec_pos)
            merged = merge((_type=label,), record)
            return (merged, state + 1)
        end
    end

    throw(ArgumentError("unknown discriminator value $(repr(disc_bytes)) at record $src_i"))
end
```

In `src/FixedWidthParsers.jl`, add `include("multi_record.jl")` after `include("schema_io.jl")`, and add to exports:

```julia
export MultiRecordSchema
```

**Step 4: Run tests**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/multi_record.jl src/FixedWidthParsers.jl test/test_multi_record.jl test/runtests.jl
git commit -m "feat: add MultiRecordSchema for files with mixed record types"
```

---

### Task 7: @generated Specialization Polish

Update `_parse_columnar_generated` to handle FWBool, custom pad, defaults, and transforms. Add `SchemaSpec` for runtime schema specialization.

**Files:**
- Modify: `src/materialization.jl` — update @generated function, add SchemaSpec
- Create: `test/test_generated.jl` — generated-path tests for new features
- Modify: `test/runtests.jl` — include test_generated.jl

**Step 1: Write the failing tests**

Create `test/test_generated.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: record_width, _SCHEMA_CACHE

@testset "@generated Specialization" begin

    @testset "FWBool in @fixedwidth struct" begin
        @fixedwidth struct GenBoolRecord
            code::String = 2
            flag::Bool   = 1
        end
        path = tempname()
        open(path, "w") do io
            write(io, "ABY\nCDN\n")
        end
        sa = parse_file(path, GenBoolRecord)
        @test sa.flag == [true, false]
        @test sa.code == ["AB", "CD"]
        rm(path)
    end

    @testset "generated path matches runtime path" begin
        @fixedwidth struct GenCompareRecord
            carrier::String = 2
            fnum::Int       = 4
            origin::String  = 3
        end
        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, "UA$(lpad(i, 4))ORD\n")
            end
        end
        sa_gen = parse_file(path, GenCompareRecord)
        sa_rt  = parse_file(path, FixedWidthParsers.schema(GenCompareRecord))
        @test sa_gen.carrier == sa_rt.carrier
        @test sa_gen.fnum == sa_rt.fnum
        @test sa_gen.origin == sa_rt.origin
        rm(path)
    end

    @testset "lenient mode in generated path" begin
        @fixedwidth struct GenLenientRecord
            val::Int = 4
        end
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n  99\n")
        end
        sa = parse_file(path, GenLenientRecord; on_error=:lenient)
        @test sa.val[1] == 42
        @test sa.val[2] === missing
        @test sa.val[3] == 99
        rm(path)
    end
end
```

Add to `test/runtests.jl`: `include("test_generated.jl")` after `include("test_multi_record.jl")`.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL if FWBool handling is missing from the @generated path

**Step 3: Update @generated function**

In `src/materialization.jl`, in `_parse_columnar_generated`, add FWBool handling in the per-field parse expressions section (around line 886). After the FWFixedPoint branch:

```julia
        elseif f.type isa FWBool
            tv = f.type.true_val
            fv = f.type.false_val
            bool_sym = Symbol("_bool_", idx)
            push!(preloop_exprs, :($bool_sym = FWBool(true_val=$tv, false_val=$fv)))
            :($sym[i_rec] = parse_field($bool_sym, buf, rec_pos + $off_m1, $w))
```

For custom pad on FWInt/FWFloat, update the existing FWInt/FWFloat branches to handle non-space pads:

```julia
        elseif f.type isa FWInt
            if f.type.pad != ' '
                pad_byte = UInt8(f.type.pad)
                int_sym = Symbol("_int_", idx)
                push!(preloop_exprs, :($int_sym = FWInt(pad=$(f.type.pad))))
                :($sym[i_rec] = parse_field($int_sym, buf, rec_pos + $off_m1, $w))
            else
                :($sym[i_rec] = parse_field(FWInt(), buf, rec_pos + $off_m1, $w))
            end
        elseif f.type isa FWFloat
            if f.type.pad != ' '
                float_sym = Symbol("_float_", idx)
                push!(preloop_exprs, :($float_sym = FWFloat(pad=$(f.type.pad))))
                :($sym[i_rec] = parse_field($float_sym, buf, rec_pos + $off_m1, $w))
            else
                :($sym[i_rec] = parse_field(FWFloat(), buf, rec_pos + $off_m1, $w))
            end
```

For column allocation, update to use `_julia_type_with_transform` if transforms are present (check `f.type` for transform field).

**Step 4: Run tests**

Run: `cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/materialization.jl test/test_generated.jl test/runtests.jl
git commit -m "feat: update @generated path for FWBool and custom pad"
```

---

## Test Verification

After all tasks, run the full test suite:

```bash
cd /Users/brad/Projects/FixedWidthParsers.jl && julia --project -e 'using Pkg; Pkg.test()'
```

All existing tests (388+) plus new tests must pass.

## Summary of New Files

| File | Description |
|------|-------------|
| `src/multi_record.jl` | MultiRecordSchema struct + parse_file + eachrecord |
| `test/test_bool.jl` | FWBool tests |
| `test/test_custom_pad.jl` | Custom numeric pad tests |
| `test/test_defaults.jl` | Default value tests |
| `test/test_transforms.jl` | Post-parse transform tests |
| `test/test_schema_show.jl` | Schema visualization tests |
| `test/test_multi_record.jl` | Multi-record type tests |
| `test/test_generated.jl` | @generated path tests for new features |

## Summary of Modified Files

| File | Changes |
|------|---------|
| `src/types.jl` | FWBool struct, pad/default/transform on all descriptors |
| `src/schema.jl` | _parse_type_string("Bool"), _type_to_descriptor(Bool), @fixedwidth Bool, schema show |
| `src/materialization.jl` | _is_blank, :default mode, transforms, _julia_type_with_transform, @generated polish |
| `src/FixedWidthParsers.jl` | Exports: FWBool, MultiRecordSchema |
| `test/runtests.jl` | Include new test files |
