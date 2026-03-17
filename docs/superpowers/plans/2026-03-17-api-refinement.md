# API Refinement Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make FixedWidthParsers.jl more user-friendly with flexible discriminator keys, ergonomic multi-schema loading, FWTime/FWDateTime/FWCustom descriptors, and optional format columns in schema files.

**Architecture:** Additive changes to the existing descriptor/schema/loading pipeline. New descriptor types mirror FWDate's pattern. MultiRecordSchema normalizes all key types to String internally. `load_schema` gains varargs dispatch for multi-file loading.

**Tech Stack:** Julia 1.10+, Dates stdlib, StructArrays.jl, existing test infrastructure (Test, tempfiles)

**Spec:** `docs/superpowers/specs/2026-03-17-api-refinement-design.md`

**Execution order:** Tasks MUST be executed sequentially (1→2→3→4→5→6→7→8). Chunk 3 depends on Chunks 1 and 2. Specifically: Task 6 requires `FWTime`/`FWDateTime` from Tasks 1-2. Task 7 requires `_build_multi_record_schema` and Char/Int constructors from Task 4.

---

## Chunk 1: New Field Descriptors

### Task 1: FWTime Descriptor

**Files:**
- Modify: `src/types.jl` — add `FWTime` struct and `parse_field` method
- Modify: `src/schema.jl` — add `_descriptor_string`, `_type_to_descriptor`, `_parse_type_string`, and `@fixedwidth` macro branch
- Modify: `src/materialization.jl` — add `_get_default`, `_get_transform`, `_julia_type` methods
- Modify: `src/FixedWidthParsers.jl` — add export
- Create: `test/test_time_datetime.jl` — tests
- Modify: `test/runtests.jl` — include new test file

- [ ] **Step 1: Write failing tests for FWTime**

Create `test/test_time_datetime.jl`:

```julia
using Test
using Dates
using FixedWidthParsers
using FixedWidthParsers: _parse_type_string

@testset "FWTime" begin
    @testset "basic parsing with HH:MM format" begin
        desc = FWTime("HH:MM")
        buf = Vector{UInt8}("14:30")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == Time(14, 30)
    end

    @testset "parsing with HHMM format" begin
        desc = FWTime("HHMM")
        buf = Vector{UInt8}("0830")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 4)
        @test result == Time(8, 30)
    end

    @testset "parsing with HH:MM:SS format" begin
        desc = FWTime("HH:MM:SS")
        buf = Vector{UInt8}("09:15:30")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 8)
        @test result == Time(9, 15, 30)
    end

    @testset "zero-argument constructor defaults to HH:MM" begin
        desc = FWTime()
        @test desc.format_string == "HH:MM"
    end

    @testset "stores format_string" begin
        desc = FWTime("HHMM")
        @test desc.format_string == "HHMM"
    end

    @testset "default value" begin
        desc = FWTime("HHMM"; default=Time(0, 0))
        @test desc.default == Time(0, 0)
    end

    @testset "transform" begin
        desc = FWTime("HHMM"; transform=t -> t + Dates.Hour(1))
        @test desc.transform !== nothing
    end

    @testset "_parse_type_string round-trip" begin
        desc = _parse_type_string("Time")
        @test desc isa FWTime
        @test desc.format_string == "HH:MM"
        desc2 = _parse_type_string("Time(HHMM)")
        @test desc2 isa FWTime
        @test desc2.format_string == "HHMM"
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(:t => (1:5, FWTime("HH:MM")))
        path = tempname()
        open(path, "w") do io
            write(io, "14:30\n09:15\n")
        end
        result = parse_file(path, schema)
        @test result.t == [Time(14, 30), Time(9, 15)]
        rm(path)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: errors about `FWTime` not being defined

- [ ] **Step 3: Implement FWTime struct and parse_field**

In `src/types.jl`, after the `FWDate` section (after line 158), add:

```julia
"""
    FWTime(format::String; default::Union{Dates.Time, Nothing} = nothing)

Field descriptor: parse a `Dates.Time` using the given `DateFormat` pattern
string (e.g. `"HH:MM"`, `"HHMM"`).

Note: In Julia's `DateFormat`, uppercase `M` = minute, lowercase `m` = month.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWTime
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Time, Nothing}
    transform::Union{Function, Nothing}
end
FWTime(
    fmt::AbstractString;
    default::Union{Dates.Time, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWTime(Dates.DateFormat(fmt), String(fmt), default, transform)
FWTime() = FWTime("HH:MM")
```

Add `parse_field` after the existing `FWDate` `parse_field` (after line 348):

```julia
"""
    parse_field(fw::FWTime, buf, pos, len) → Dates.Time

Parse a `Time` value from ASCII bytes using the `DateFormat` stored in `fw`.
"""
@inline function parse_field(fw::FWTime, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.Time(String(sv), fw.format)
end
```

- [ ] **Step 4: Add _descriptor_string for FWTime**

In `src/schema.jl`, after the `_descriptor_string(d::FWDate)` method (after line 683), add:

```julia
function _descriptor_string(d::FWTime)
    params = String[]
    d.format_string != "HH:MM" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWTime" : "FWTime($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end
```

- [ ] **Step 5: Add _type_to_descriptor and _parse_type_string for Time**

In `src/schema.jl`, after `_type_to_descriptor(::Type{Bool})` (line 428), add:

```julia
_type_to_descriptor(::Type{Time}) = FWTime()
```

In the `@fixedwidth` macro (around line 546), add a branch for `:Time`:

```julia
elseif ftype === :Time ||
       (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:Time))
    :(FixedWidthParsers.FWTime())
```

In `_parse_type_string` (around line 376), add before the `Date(fmt)` regex:

```julia
s == "Time"    && return FWTime()

# Time(fmt)
m = match(r"^Time\((.+)\)$", s)
if m !== nothing
    return FWTime(strip(m.captures[1]))
end
```

- [ ] **Step 6: Add materialization methods for FWTime**

In `src/materialization.jl`, after the existing `_get_default`/`_get_transform`/`_julia_type` methods:

```julia
_get_default(d::FWTime) = d.default
_get_transform(d::FWTime) = d.transform
_julia_type(::FWTime) = Dates.Time
```

These are required for `parse_file` to produce correctly-typed `Vector{Time}` columns and to honor `default`/`transform` options.

- [ ] **Step 7: Add FWTime to exports**

In `src/FixedWidthParsers.jl`, add `FWTime` to the export line with other descriptors:

```julia
export FWString, FWInt, FWFloat, FWDate, FWTime, FWSkip, FWFixedPoint, FWBool, Skip
```

- [ ] **Step 8: Add test file to runtests.jl**

In `test/runtests.jl`, add before the closing `end`:

```julia
include("test_time_datetime.jl")
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass including new FWTime tests

- [ ] **Step 10: Commit**

```bash
git add src/types.jl src/schema.jl src/materialization.jl src/FixedWidthParsers.jl test/test_time_datetime.jl test/runtests.jl
git commit -m "feat: add FWTime descriptor with format string support"
```

---

### Task 2: FWDateTime Descriptor

**Files:**
- Modify: `src/types.jl` — add `FWDateTime` struct and `parse_field`
- Modify: `src/schema.jl` — add `_descriptor_string`, `_type_to_descriptor`, `_parse_type_string`, and `@fixedwidth` macro branch
- Modify: `src/materialization.jl` — add `_get_default`, `_get_transform`, `_julia_type` methods
- Modify: `src/FixedWidthParsers.jl` — add export
- Modify: `test/test_time_datetime.jl` — add tests

- [ ] **Step 1: Write failing tests for FWDateTime**

Append to `test/test_time_datetime.jl`:

```julia
@testset "FWDateTime" begin
    @testset "basic parsing with full format" begin
        desc = FWDateTime("yyyy-mm-ddTHH:MM:SS")
        buf = Vector{UInt8}("2026-03-17T14:30:00")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 19)
        @test result == DateTime(2026, 3, 17, 14, 30, 0)
    end

    @testset "compact format" begin
        desc = FWDateTime("yyyymmddHHMM")
        buf = Vector{UInt8}("202603171430")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 12)
        @test result == DateTime(2026, 3, 17, 14, 30)
    end

    @testset "zero-argument constructor defaults to yyyy-mm-ddTHH:MM:SS" begin
        desc = FWDateTime()
        @test desc.format_string == "yyyy-mm-ddTHH:MM:SS"
    end

    @testset "stores format_string" begin
        desc = FWDateTime("yyyymmddHHMM")
        @test desc.format_string == "yyyymmddHHMM"
    end

    @testset "default value" begin
        desc = FWDateTime("yyyymmddHHMM"; default=DateTime(1))
        @test desc.default == DateTime(1)
    end

    @testset "transform" begin
        desc = FWDateTime("yyyymmddHHMM"; transform=identity)
        @test desc.transform !== nothing
    end

    @testset "_parse_type_string round-trip" begin
        desc = _parse_type_string("DateTime")
        @test desc isa FWDateTime
        @test desc.format_string == "yyyy-mm-ddTHH:MM:SS"
        desc2 = _parse_type_string("DateTime(yyyymmddHHMM)")
        @test desc2 isa FWDateTime
        @test desc2.format_string == "yyyymmddHHMM"
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(:dt => (1:12, FWDateTime("yyyymmddHHMM")))
        path = tempname()
        open(path, "w") do io
            write(io, "202603171430\n202603180900\n")
        end
        result = parse_file(path, schema)
        @test result.dt == [DateTime(2026, 3, 17, 14, 30), DateTime(2026, 3, 18, 9, 0)]
        rm(path)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: errors about `FWDateTime` not being defined

- [ ] **Step 3: Implement FWDateTime struct and parse_field**

In `src/types.jl`, after the FWTime section, add:

```julia
"""
    FWDateTime(format::String; default::Union{Dates.DateTime, Nothing} = nothing)

Field descriptor: parse a `Dates.DateTime` using the given `DateFormat` pattern
string (e.g. `"yyyy-mm-ddTHH:MM:SS"`, `"yyyymmddHHMM"`).

Note: In Julia's `DateFormat`, lowercase `m` = month, uppercase `M` = minute.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWDateTime
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.DateTime, Nothing}
    transform::Union{Function, Nothing}
end
FWDateTime(
    fmt::AbstractString;
    default::Union{Dates.DateTime, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWDateTime(Dates.DateFormat(fmt), String(fmt), default, transform)
FWDateTime() = FWDateTime("yyyy-mm-ddTHH:MM:SS")
```

Add `parse_field` after the FWTime `parse_field`:

```julia
"""
    parse_field(fw::FWDateTime, buf, pos, len) → Dates.DateTime

Parse a `DateTime` value from ASCII bytes using the `DateFormat` stored in `fw`.
"""
@inline function parse_field(fw::FWDateTime, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.DateTime(String(sv), fw.format)
end
```

- [ ] **Step 4: Add _descriptor_string, _type_to_descriptor, _parse_type_string, @fixedwidth for DateTime**

In `src/schema.jl`, after the FWTime `_descriptor_string`:

```julia
function _descriptor_string(d::FWDateTime)
    params = String[]
    d.format_string != "yyyy-mm-ddTHH:MM:SS" && push!(params, "\"$(d.format_string)\"")
    d.default !== nothing && push!(params, "default=$(d.default)")
    base = isempty(params) ? "FWDateTime" : "FWDateTime($(join(params, ", ")))"
    d.transform !== nothing && return base * "+transform"
    return base
end
```

After `_type_to_descriptor(::Type{Time})`:

```julia
_type_to_descriptor(::Type{DateTime}) = FWDateTime()
```

In the `@fixedwidth` macro, add a `:DateTime` branch (after `:Time`):

```julia
elseif ftype === :DateTime ||
       (ftype isa Expr && ftype.head === :(.) && ftype.args[end] === QuoteNode(:DateTime))
    :(FixedWidthParsers.FWDateTime())
```

In `_parse_type_string`, add:

```julia
s == "DateTime" && return FWDateTime()

# DateTime(fmt)
m = match(r"^DateTime\((.+)\)$", s)
if m !== nothing
    return FWDateTime(strip(m.captures[1]))
end
```

- [ ] **Step 5: Add materialization methods for FWDateTime**

In `src/materialization.jl`, after the FWTime methods:

```julia
_get_default(d::FWDateTime) = d.default
_get_transform(d::FWDateTime) = d.transform
_julia_type(::FWDateTime) = Dates.DateTime
```

- [ ] **Step 6: Add FWDateTime to exports**

In `src/FixedWidthParsers.jl`:

```julia
export FWString, FWInt, FWFloat, FWDate, FWTime, FWDateTime, FWSkip, FWFixedPoint, FWBool, Skip
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/types.jl src/schema.jl src/materialization.jl src/FixedWidthParsers.jl test/test_time_datetime.jl
git commit -m "feat: add FWDateTime descriptor with format string support"
```

---

### Task 3: FWCustom Descriptor

**Files:**
- Modify: `src/types.jl` — add `FWCustom{F,D}` struct and `parse_field`
- Modify: `src/schema.jl` — add `_descriptor_string`
- Modify: `src/FixedWidthParsers.jl` — add export
- Create: `test/test_custom_field.jl` — tests
- Modify: `test/runtests.jl` — include new test file

- [ ] **Step 1: Write failing tests for FWCustom**

Create `test/test_custom_field.jl`:

```julia
using Test
using FixedWidthParsers

@testset "FWCustom" begin
    @testset "string mode — basic" begin
        desc = FWCustom(Int, s -> length(strip(s)))
        buf = Vector{UInt8}("hello")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == 5
    end

    @testset "string mode — with trimming" begin
        desc = FWCustom(String, s -> uppercase(strip(s)))
        buf = Vector{UInt8}("abc  ")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 5)
        @test result == "ABC"
    end

    @testset "byte mode — raw access" begin
        desc = FWCustom(UInt8, (buf, pos, len) -> buf[pos]; raw=true)
        buf = Vector{UInt8}("XY")
        result = FixedWidthParsers.parse_field(desc, buf, 1, 2)
        @test result == UInt8('X')
    end

    @testset "default value" begin
        desc = FWCustom(Int, s -> length(s); default=0)
        @test desc.default == 0
    end

    @testset "transform" begin
        desc = FWCustom(Int, s -> parse(Int, strip(s)); transform=x -> x * 2)
        @test desc.transform !== nothing
    end

    @testset "type parameters are concrete" begin
        fn = s -> parse(Int, s)
        desc = FWCustom(Int, fn)
        # F parameter should capture the concrete function type
        @test typeof(desc).parameters[1] === typeof(fn)
    end

    @testset "integration with parse_file" begin
        schema = FixedWidthSchema(
            :name  => (5, FWString()),
            :len   => (3, FWCustom(Int, s -> length(strip(s)))),
        )
        path = tempname()
        open(path, "w") do io
            write(io, "HelloABC\nWorld XY\n")
        end
        result = parse_file(path, schema)
        @test result.len == [3, 2]
        rm(path)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: errors about `FWCustom` not being defined

- [ ] **Step 3: Implement FWCustom struct and parse_field**

In `src/types.jl`, after the FWBool section (after line 208), add:

```julia
"""
    FWCustom(return_type, parse_fn; raw=false, default=nothing, transform=nothing)

Field descriptor: parse a field using a user-provided function.

In string mode (default, `raw=false`), the library extracts the field bytes as
a `String` and passes it to `parse_fn(str)`.

In byte mode (`raw=true`), the library passes the raw buffer:
`parse_fn(buf, pos, len)`.

The struct is parameterized as `FWCustom{F,D}` so Julia can specialize
`parse_field` on the concrete function type in hot loops.

# Examples
```julia
# String mode
FWCustom(Int, s -> length(strip(s)))

# Byte mode
FWCustom(Float64, (buf, pos, len) -> my_parser(buf, pos, len); raw=true)
```
"""
struct FWCustom{F, D}
    return_type::Type
    parse_fn::F
    raw::Bool
    default::D
    transform::Union{Function, Nothing}
end
function FWCustom(
    return_type::Type,
    parse_fn::F;
    raw::Bool=false,
    default::D=nothing,
    transform::Union{Function, Nothing}=nothing,
) where {F, D}
    return FWCustom{F, D}(return_type, parse_fn, raw, default, transform)
end
```

Add `parse_field` after the FWBool `parse_field`:

```julia
"""
    parse_field(fw::FWCustom, buf, pos, len) → value

Parse using a user-provided function. String mode extracts a String;
byte mode passes raw buffer access.
"""
@inline function parse_field(fw::FWCustom, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.raw
        return fw.parse_fn(buf, pos, len)
    else
        sv = String(copy(buf[pos:pos+len-1]))
        return fw.parse_fn(sv)
    end
end
```

- [ ] **Step 4: Add _descriptor_string for FWCustom**

In `src/schema.jl`, after the FWDateTime `_descriptor_string`:

```julia
function _descriptor_string(d::FWCustom)
    mode = d.raw ? "raw" : "string"
    base = "FWCustom($(d.return_type), $mode)"
    d.default !== nothing && (base *= ", default=$(repr(d.default))")
    d.transform !== nothing && (base *= "+transform")
    return base
end
```

- [ ] **Step 5: Add materialization methods for FWCustom**

In `src/materialization.jl`, after the FWDateTime methods:

```julia
_get_default(d::FWCustom) = d.default
_get_transform(d::FWCustom) = d.transform
_julia_type(d::FWCustom) = d.return_type
```

- [ ] **Step 6: Add FWCustom to exports**

In `src/FixedWidthParsers.jl`:

```julia
export FWString, FWInt, FWFloat, FWDate, FWTime, FWDateTime, FWSkip, FWFixedPoint, FWBool, FWCustom, Skip
```

- [ ] **Step 7: Add test file to runtests.jl**

In `test/runtests.jl`, add before the closing `end`:

```julia
include("test_custom_field.jl")
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add src/types.jl src/schema.jl src/materialization.jl src/FixedWidthParsers.jl test/test_custom_field.jl test/runtests.jl
git commit -m "feat: add FWCustom{F,D} descriptor with string and byte modes"
```

---

## Chunk 2: MultiRecordSchema Flexibility & String Field Names

### Task 4: Flexible Discriminator Key Types

**Files:**
- Modify: `src/multi_record.jl` — add Char/Int constructor overloads, Int position shorthand, unconditional trimming
- Modify: `test/test_multi_record.jl` — add tests for new key types

- [ ] **Step 1: Write failing tests for Char keys**

Append to `test/test_multi_record.jl`, inside the outer `@testset`:

```julia
@testset "Char discriminator keys" begin
    header_schema = FixedWidthSchema(
        :rec_type => (1, FWString()),
        :title    => (9, FWString()),
    )
    detail_schema = FixedWidthSchema(
        :rec_type => (1, FWString()),
        :value    => (9, FWInt()),
    )

    ms = MultiRecordSchema(1:1, 'H' => header_schema, 'D' => detail_schema)
    path = tempname()
    open(path, "w") do io
        write(io, "HTestFile \n")
        write(io, "D       42\n")
    end
    result = parse_file(path, ms)
    @test result[:H].title == ["TestFile"]
    @test result[:D].value == [42]
    rm(path)
end

@testset "Char digit keys get :type_ prefix" begin
    schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
    ms = MultiRecordSchema(1:1, '1' => schema, '2' => schema)
    path = tempname()
    open(path, "w") do io
        write(io, "1  42\n2  99\n")
    end
    result = parse_file(path, ms)
    @test haskey(result, :type_1)
    @test haskey(result, :type_2)
    @test result[:type_1].val == [42]
    @test result[:type_2].val == [99]
    rm(path)
end

@testset "Int discriminator keys" begin
    schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
    ms = MultiRecordSchema(1:1, 1 => schema, 2 => schema)
    path = tempname()
    open(path, "w") do io
        write(io, "1  42\n2  99\n")
    end
    result = parse_file(path, ms)
    @test haskey(result, :type_1)
    @test haskey(result, :type_2)
    @test result[:type_1].val == [42]
    rm(path)
end

@testset "Int position shorthand" begin
    schema_h = FixedWidthSchema(:rec_type => (1, FWString()), :title => (4, FWString()))
    schema_d = FixedWidthSchema(:rec_type => (1, FWString()), :value => (4, FWInt()))
    # Int position instead of 1:1 range
    ms = MultiRecordSchema(1, 'H' => schema_h, 'D' => schema_d)
    path = tempname()
    open(path, "w") do io
        write(io, "HTest\nD  42\n")
    end
    result = parse_file(path, ms)
    @test result[:H].title == ["Test"]
    @test result[:D].value == [42]
    rm(path)
end

@testset "unconditional discriminator trimming" begin
    schema = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
    # Key is "H" (no space), disc range is 2 bytes, file has "H " — should match after trimming
    ms = MultiRecordSchema(1:2, "H" => schema, "D" => schema)
    path = tempname()
    open(path, "w") do io
        write(io, "H  42\nD  99\n")
    end
    result = parse_file(path, ms)
    @test result[:H].val == [42]
    @test result[:D].val == [99]
    rm(path)
end

@testset "padded String keys are trimmed at construction" begin
    schema = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
    ms = MultiRecordSchema(1:2, "H " => schema, "D " => schema)
    # Keys are trimmed to "H" and "D" at construction, matching trimmed file bytes
    path = tempname()
    open(path, "w") do io
        write(io, "H  42\nD  99\n")
    end
    result = parse_file(path, ms)
    @test result[:H].val == [42]
    @test result[:D].val == [99]
    rm(path)
end

@testset "Char key requires single-byte discriminator" begin
    schema = FixedWidthSchema(:val => (3, FWString()))
    @test_throws ArgumentError MultiRecordSchema(1:2, 'H' => schema, 'D' => schema)
end

@testset "mixed key types are a MethodError" begin
    schema = FixedWidthSchema(:val => (3, FWString()))
    @test_throws MethodError MultiRecordSchema(1:1, 'H' => schema, "D" => schema)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: errors about no matching constructor for Char/Int keys

- [ ] **Step 3: Implement Char and Int key constructors**

In `src/multi_record.jl`, after the existing `MultiRecordSchema` constructor (after line 112), add:

```julia
# --- Label derivation helpers ---

"""
    _discriminator_label(key) → Symbol

Derive an output label from a discriminator key value.
"""
_discriminator_label(key::AbstractString) = Symbol(key)
_discriminator_label(key::Char) = isdigit(key) ? Symbol("type_", key) : Symbol(key)
_discriminator_label(key::Int) = Symbol("type_", key)

# --- Char key constructor ---

function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{Char, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    length(discriminator) != 1 &&
        throw(ArgumentError("Char discriminator keys require a single-byte range, got $discriminator"))
    # Convert to String-keyed pairs and delegate
    string_pairs = [string(k) => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end

# --- Int key constructor ---

function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{Int, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    string_pairs = [string(k) => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end

# --- Int position shorthand (typed overloads to avoid broad dispatch) ---

function MultiRecordSchema(
    position::Int,
    pairs::Pair{Char, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

function MultiRecordSchema(
    position::Int,
    pairs::Pair{Int, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

function MultiRecordSchema(
    position::Int,
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    return MultiRecordSchema(position:position, pairs...; record_width=record_width)
end

# --- Shared builder ---

function _build_multi_record_schema(
    discriminator::UnitRange{Int},
    string_pairs::Vector{Pair{String, FixedWidthSchema}},
    labels::Vector{Symbol},
    record_width::Union{Int, Nothing},
)
    length(discriminator) < 1 &&
        throw(ArgumentError("discriminator range must not be empty"))
    isempty(string_pairs) &&
        throw(ArgumentError("at least one discriminator => schema pair is required"))

    # Trim keys unconditionally (matches trimming on the file-read side)
    trimmed_pairs = [strip(k) => v for (k, v) in string_pairs]

    vals = [p.first for p in trimmed_pairs]
    length(unique(vals)) != length(vals) &&
        throw(ArgumentError("duplicate discriminator values: $(vals)"))

    schemas = Tuple{String, Symbol, FixedWidthSchema}[]
    max_width = 0
    for (i, (disc_val, sch)) in enumerate(trimmed_pairs)
        push!(schemas, (disc_val, labels[i], sch))
        max_width = max(max_width, FixedWidthParsers.record_width(sch))
    end

    rw = record_width !== nothing ? record_width : max_width
    if rw < max_width
        throw(ArgumentError("record_width=$rw is less than the widest schema ($max_width)"))
    end

    return MultiRecordSchema(discriminator, schemas, rw)
end
```

- [ ] **Step 4: Refactor existing String constructor to use shared builder**

Replace the existing `MultiRecordSchema(discriminator::UnitRange{Int}, pairs::Pair{String, FixedWidthSchema}...)` constructor body to delegate to `_build_multi_record_schema`:

```julia
function MultiRecordSchema(
    discriminator::UnitRange{Int},
    pairs::Pair{String, FixedWidthSchema}...;
    record_width::Union{Int, Nothing}=nothing,
)
    string_pairs = [k => v for (k, v) in pairs]
    labels = [_discriminator_label(k) for (k, _) in pairs]
    _build_multi_record_schema(discriminator, string_pairs, labels, record_width)
end
```

- [ ] **Step 5: Add unconditional discriminator trimming in parse_file and iterate**

In `parse_file` for `MultiRecordSchema` (around line 190), change the discriminator read to trim:

```julia
disc_bytes = strip(String(copy(buf[field_pos:(field_pos + disc_len - 1)])))
```

Similarly in `Base.iterate(iter::MultiRecordIterator, ...)` (around line 329):

```julia
disc_bytes = strip(String(copy(buf[field_pos:(field_pos + disc_len - 1)])))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass (both new and existing)

- [ ] **Step 7: Commit**

```bash
git add src/multi_record.jl test/test_multi_record.jl
git commit -m "feat: support Char, Int, and positional discriminator keys in MultiRecordSchema"
```

---

### Task 5: Accept String Field Names in FixedWidthSchema

**Files:**
- Modify: `src/schema.jl` — widen `Pair{Symbol}` to accept strings
- Modify: `test/test_schema_loading.jl` — add test

- [ ] **Step 1: Write failing test**

Add to `test/test_schema_loading.jl`, inside the outer `@testset`, a new testset:

```julia
@testset "String field names auto-convert to Symbol" begin
    using FixedWidthParsers: record_width
    s = FixedWidthSchema("carrier" => (2, FWString()), "fnum" => (4, FWInt()))
    @test record_width(s) == 6
    @test s._output_names == (:carrier, :fnum)
end

@testset "String field names in range mode" begin
    using FixedWidthParsers: record_width
    s = FixedWidthSchema("carrier" => (1:2, FWString()), "fnum" => (3:6, FWInt()))
    @test record_width(s) == 6
    @test s._output_names == (:carrier, :fnum)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: MethodError — no matching method for `Pair{String}`

- [ ] **Step 3: Widen the FixedWidthSchema constructor signature**

In `src/schema.jl`, change the constructor signature (line 174) from:

```julia
function FixedWidthSchema(pairs::Pair{Symbol}...; record_width::Union{Int,Nothing}=nothing)
```

to:

```julia
function FixedWidthSchema(raw_pairs::Pair...; record_width::Union{Int,Nothing}=nothing)
    # Normalize keys to Symbol, validating types
    pairs = map(raw_pairs) do p
        key = p.first
        if key isa Symbol
            key
        elseif key isa AbstractString
            Symbol(key)
        else
            throw(ArgumentError(
                "field name must be a Symbol or String, got $(typeof(key)): $(repr(key))"
            ))
        end => p.second
    end
```

Then update the rest of the function to use `pairs` (which is now a tuple of normalized pairs). The `isempty` check and the `first_val` extraction stay the same but work on the normalized pairs.

**Important:** Also update `_build_from_ranges` (line 89) to accept the normalized pairs — its input `pairs` will now be a tuple, not splatted `Pair{Symbol}`. The `collect(pairs)` call on line 90 handles this.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/schema.jl test/test_schema_loading.jl
git commit -m "feat: accept String field names in FixedWidthSchema constructors"
```

---

## Chunk 3: Schema File Improvements

> **Dependency:** This chunk requires Chunks 1 and 2 to be complete. Task 6 uses `FWTime`/`FWDateTime` from Tasks 1-2. Task 7 uses `_build_multi_record_schema` and Char/Int constructors from Task 4.

### Task 6: Optional Format Column in Schema Files

**Files:**
- Modify: `src/schema.jl` — add two-argument `_parse_type_string(type_str, format_str)`
- Modify: `src/schema_io.jl` — handle optional format column in CSV and TOML
- Modify: `ext/JSON3Ext.jl` — handle optional format key in JSON
- Modify: `test/test_schema_loading.jl` — add tests

- [ ] **Step 1: Write failing tests for format column**

Add to `test/test_schema_loading.jl`:

```julia
@testset "_parse_type_string with format override" begin
    using FixedWidthParsers: _parse_type_string

    @testset "Date with format override" begin
        desc = _parse_type_string("Date", "ddMMMyy")
        @test desc isa FWDate
        @test desc.format_string == "ddMMMyy"
    end

    @testset "Date(inline) overridden by format column" begin
        desc = _parse_type_string("Date(yyyymmdd)", "ddMMMyy")
        @test desc.format_string == "ddMMMyy"
    end

    @testset "Time with format" begin
        desc = _parse_type_string("Time", "HHMM")
        @test desc isa FWTime
        @test desc.format_string == "HHMM"
    end

    @testset "DateTime with format" begin
        desc = _parse_type_string("DateTime", "yyyymmddHHMM")
        @test desc isa FWDateTime
        @test desc.format_string == "yyyymmddHHMM"
    end

    @testset "empty format falls through to default" begin
        desc = _parse_type_string("Date", "")
        @test desc isa FWDate
        @test desc.format_string == "yyyymmdd"
    end

    @testset "format on non-date type is ignored" begin
        desc = _parse_type_string("Int", "HHMM")
        @test desc isa FWInt
    end

    @testset "empty format for Time falls through to default" begin
        desc = _parse_type_string("Time", "")
        @test desc isa FWTime
        @test desc.format_string == "HH:MM"
    end

    @testset "empty format for DateTime falls through to default" begin
        desc = _parse_type_string("DateTime", "")
        @test desc isa FWDateTime
        @test desc.format_string == "yyyy-mm-ddTHH:MM:SS"
    end
end

@testset "CSV with format column" begin
    using FixedWidthParsers: record_width

    @testset "format column present" begin
        path = tempname() * ".csv"
        open(path, "w") do io
            println(io, "name,start,end,type,format")
            println(io, "carrier,1,2,String,")
            println(io, "dep_date,3,9,Date,ddMMMyy")
            println(io, "dep_time,10,13,Time,HHMM")
        end
        s = load_schema(path)
        @test s.fields[1].type isa FWString
        @test s.fields[2].type isa FWDate
        @test s.fields[2].type.format_string == "ddMMMyy"
        @test s.fields[3].type isa FWTime
        @test s.fields[3].type.format_string == "HHMM"
        rm(path)
    end

    @testset "format column absent still works" begin
        path = tempname() * ".csv"
        open(path, "w") do io
            println(io, "name,start,end,type")
            println(io, "carrier,1,2,String")
        end
        s = load_schema(path)
        @test s.fields[1].type isa FWString
        rm(path)
    end

    @testset "format column present but empty uses default" begin
        path = tempname() * ".csv"
        open(path, "w") do io
            println(io, "name,start,end,type,format")
            println(io, "dep_date,1,8,Date,")
        end
        s = load_schema(path)
        @test s.fields[1].type isa FWDate
        @test s.fields[1].type.format_string == "yyyymmdd"
        rm(path)
    end
end

@testset "TOML with format key" begin
    @testset "format key present" begin
        path = tempname() * ".toml"
        open(path, "w") do io
            println(io, "[[fields]]")
            println(io, "name = \"dep_date\"")
            println(io, "start = 1")
            println(io, "end = 8")
            println(io, "type = \"Date\"")
            println(io, "format = \"ddMMMyy\"")
        end
        s = load_schema(path)
        @test s.fields[1].type isa FWDate
        @test s.fields[1].type.format_string == "ddMMMyy"
        rm(path)
    end

    @testset "format key absent uses default" begin
        path = tempname() * ".toml"
        open(path, "w") do io
            println(io, "[[fields]]")
            println(io, "name = \"dep_date\"")
            println(io, "start = 1")
            println(io, "end = 8")
            println(io, "type = \"Date\"")
        end
        s = load_schema(path)
        @test s.fields[1].type.format_string == "yyyymmdd"
        rm(path)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: MethodError — no two-argument `_parse_type_string`

- [ ] **Step 3: Implement two-argument _parse_type_string**

In `src/schema.jl`, after the existing `_parse_type_string(s)` function, add:

```julia
"""
    _parse_type_string(type_str, format_str) → descriptor

Map a type name string to a field-type descriptor, optionally overriding the
format with `format_str`. The format column takes precedence over any inline
format in the type string (e.g., `Date(yyyymmdd)`).

If `format_str` is empty, delegates to the single-argument form.
If `format_str` is non-empty but the type doesn't use formats, it is ignored.
"""
function _parse_type_string(type_str::AbstractString, format_str::AbstractString)
    type_str = strip(type_str)
    format_str = strip(format_str)

    # If no format override, delegate to existing single-arg form
    isempty(format_str) && return _parse_type_string(type_str)

    # Extract base type name (strip parenthesized params)
    base_type = type_str
    m = match(r"^(\w+)\(", type_str)
    if m !== nothing
        base_type = m.captures[1]
    end

    # Apply format override for Date/Time/DateTime types
    if base_type == "Date"
        return FWDate(format_str)
    elseif base_type == "Time"
        return FWTime(format_str)
    elseif base_type == "DateTime"
        return FWDateTime(format_str)
    end

    # For non-date types, ignore format_str and delegate
    return _parse_type_string(type_str)
end
```

- [ ] **Step 4: Update CSV loader to use format column**

In `src/schema_io.jl`, modify `_load_schema_csv`:

Change the required columns check to only require the 4 core columns. Then detect the optional `:format` column:

```julia
function _load_schema_csv(path::AbstractString; record_width::Union{Int,Nothing}=nothing)
    lines = readlines(path)
    lines = filter(l -> !isempty(strip(l)) && !startswith(strip(l), '#'), lines)
    isempty(lines) && throw(ArgumentError("schema CSV file is empty"))

    header = Symbol.(strip.(split(lines[1], ',')))
    required = [:name, :start, :end, :type]
    for col in required
        col in header || throw(ArgumentError("schema CSV missing required column: $col"))
    end

    idx = Dict(col => findfirst(==(col), header) for col in required)
    has_format = :format in header
    if has_format
        idx[:format] = findfirst(==(:format), header)
    end

    pairs = Pair{Symbol,Tuple{UnitRange{Int},Any}}[]
    for line in lines[2:end]
        parts = strip.(split(line, ','))
        name = Symbol(parts[idx[:name]])
        start_byte = parse(Int, parts[idx[:start]])
        end_byte = parse(Int, parts[idx[:end]])

        if has_format && idx[:format] <= length(parts)
            format_str = parts[idx[:format]]
            type_desc = _parse_type_string(parts[idx[:type]], format_str)
        else
            type_desc = _parse_type_string(parts[idx[:type]])
        end

        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end
```

- [ ] **Step 5: Update TOML loader to use format key**

In `src/schema_io.jl`, modify `_load_schema_toml` — change the field processing loop:

```julia
    for (i, fd) in enumerate(field_defs)
        for key in ("name", "start", "end", "type")
            haskey(fd, key) || throw(
                ArgumentError("TOML field entry $i missing required key: $key"),
            )
        end
        name = Symbol(fd["name"])
        start_byte = fd["start"]::Int
        end_byte = fd["end"]::Int

        format_str = get(fd, "format", "")
        type_desc = _parse_type_string(fd["type"], format_str)

        push!(pairs, name => (start_byte:end_byte, type_desc))
    end
```

- [ ] **Step 6: Update JSON3 extension to use format key**

In `ext/JSON3Ext.jl`, modify the field processing loop:

```julia
    for (i, fd) in enumerate(field_defs)
        for key in (:name, :start, :end, :type)
            haskey(fd, key) || throw(ArgumentError(
                "JSON field entry $i missing required key: $key"
            ))
        end
        name = Symbol(fd[:name])
        start_byte = fd[:start]::Int
        end_byte = fd[:end]::Int

        format_str = get(fd, :format, "")
        type_desc = FixedWidthParsers._parse_type_string(fd[:type], format_str)

        push!(pairs, name => (start_byte:end_byte, type_desc))
    end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/schema.jl src/schema_io.jl ext/JSON3Ext.jl test/test_schema_loading.jl
git commit -m "feat: support optional format column in CSV/TOML/JSON schema files"
```

---

### Task 7: Multi-File load_schema

**Files:**
- Modify: `src/schema_io.jl` — add multi-file `load_schema` overloads
- Create: `test/test_multi_schema_loading.jl` — tests
- Modify: `test/runtests.jl` — include new test file

- [ ] **Step 1: Write failing tests for multi-file load_schema**

Create `test/test_multi_schema_loading.jl`:

```julia
using Test
using FixedWidthParsers

@testset "Multi-file load_schema" begin

    # Helper to create a schema CSV file
    function _write_schema_csv(path, fields)
        open(path, "w") do io
            println(io, "name,start,end,type")
            for (name, s, e, t) in fields
                println(io, "$name,$s,$e,$t")
            end
        end
    end

    @testset "two bare files → MultiRecordSchema with filename labels" begin
        dir = mktempdir()
        hdr_path = joinpath(dir, "header.csv")
        dtl_path = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr_path, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl_path, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema(hdr_path, dtl_path)
        @test ms isa MultiRecordSchema
        # Labels derived from filenames
        labels = [s[2] for s in ms.schemas]
        @test :header in labels
        @test :detail in labels
    end

    @testset "three bare files" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        trl = joinpath(dir, "trailer.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])
        _write_schema_csv(trl, [("rec_type", 1, 1, "String"), ("count", 2, 10, "Int")])

        ms = load_schema(hdr, dtl, trl)
        labels = [s[2] for s in ms.schemas]
        @test :header in labels
        @test :detail in labels
        @test :trailer in labels
    end

    @testset "Char Pair keys" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema('H' => hdr, 'D' => dtl)
        @test ms isa MultiRecordSchema
        labels = [s[2] for s in ms.schemas]
        @test :H in labels
        @test :D in labels
    end

    @testset "String Pair keys with discriminator keyword" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 3, "String"), ("title", 4, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 3, "String"), ("value", 4, 10, "Int")])

        ms = load_schema("HDR" => hdr, "DTL" => dtl; discriminator=1:3)
        @test ms isa MultiRecordSchema
        @test ms.discriminator == 1:3
    end

    @testset "discriminator keyword with bare files" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 2, "String"), ("title", 3, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 2, "String"), ("value", 3, 10, "Int")])

        ms = load_schema(hdr, dtl; discriminator=1:2)
        @test ms.discriminator == 1:2
    end

    @testset "record_width keyword" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 5, "Int")])

        ms = load_schema(hdr, dtl; record_width=100)
        @test ms.record_width == 100
    end

    @testset "single Pair throws" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        @test_throws ArgumentError load_schema('H' => hdr)
    end

    @testset "duplicate filenames throw" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        @test_throws ArgumentError load_schema(hdr, hdr)
    end

    @testset "round-trip: multi-file load → parse_file" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema('H' => hdr, 'D' => dtl)

        data_path = tempname()
        open(data_path, "w") do io
            write(io, "HTestFile \n")
            write(io, "D       42\n")
        end

        result = parse_file(data_path, ms)
        @test result[:H].title == ["TestFile"]
        @test result[:D].value == [42]
        rm(data_path)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: MethodError — no multi-arg `load_schema`

- [ ] **Step 3: Implement multi-file load_schema**

In `src/schema_io.jl`, after the existing `load_schema` function, add:

```julia
# ---------------------------------------------------------------------------
# Multi-file load_schema → MultiRecordSchema
# ---------------------------------------------------------------------------

"""
    load_schema(paths::AbstractString...; discriminator=1:1, record_width=nothing) → MultiRecordSchema

Load multiple schema files and combine into a `MultiRecordSchema`.

Labels are derived from filenames (basename without extension).
Discriminator values are also derived from filenames (the full basename sans extension).
Discriminator defaults to byte 1. At least 2 files are required.

**Note:** Bare-file mode uses filenames as discriminator values. For actual data parsing,
the discriminator bytes in the data file must match these filename-derived values.
For most real-world use cases, prefer the Pair-based form with explicit discriminator
values: `load_schema('H' => "header.csv", 'D' => "detail.csv")`.

# Examples
```julia
ms = load_schema("header.csv", "detail.csv", "trailer.csv")
ms = load_schema("header.csv", "detail.csv"; discriminator=1:2, record_width=200)
```
"""
function load_schema(
    path1::AbstractString,
    path2::AbstractString,
    paths::AbstractString...;
    discriminator::Union{UnitRange{Int}, Int}=1:1,
    record_width::Union{Int, Nothing}=nothing,
)
    all_paths = [path1, path2, paths...]
    disc_range = discriminator isa Int ? (discriminator:discriminator) : discriminator

    # Derive labels and discriminator values from filenames
    labels = _paths_to_labels(all_paths)
    disc_values = [string(label) for label in labels]

    # Load each schema
    schemas = [load_schema(p) for p in all_paths]

    # Build pairs and construct
    string_pairs = Pair{String, FixedWidthSchema}[disc_values[i] => schemas[i] for i in eachindex(all_paths)]
    label_syms = collect(labels)
    _build_multi_record_schema(disc_range, string_pairs, label_syms, record_width)
end

"""
    load_schema(pairs::Pair...; discriminator=1:1, record_width=nothing) → MultiRecordSchema

Load multiple schema files with explicit discriminator values.

At least 2 pairs are required. Keys can be Char, Int, or String.

# Examples
```julia
ms = load_schema('H' => "header.csv", 'D' => "detail.csv")
ms = load_schema("HDR" => "header.csv", "DTL" => "detail.csv"; discriminator=1:3)
```
"""
function load_schema(
    pair1::Pair{T, <:AbstractString},
    pair2::Pair{T, <:AbstractString},
    pairs::Pair{T, <:AbstractString}...;
    discriminator::Union{UnitRange{Int}, Int}=1:1,
    record_width::Union{Int, Nothing}=nothing,
) where {T}
    all_pairs = [pair1, pair2, pairs...]
    disc_range = discriminator isa Int ? (discriminator:discriminator) : discriminator

    # Load each schema
    loaded = [(k, load_schema(v)) for (k, v) in all_pairs]

    # Construct MultiRecordSchema using the appropriate key type
    ms_pairs = [k => sch for (k, sch) in loaded]
    return MultiRecordSchema(disc_range, ms_pairs...; record_width=record_width)
end

# Single-pair overload that throws a helpful error
function load_schema(
    pair::Pair{T, <:AbstractString};
    kwargs...,
) where {T}
    T <: AbstractString && return load_schema(pair.second; kwargs...)  # single file path
    throw(ArgumentError("multi-record schema requires at least 2 record types"))
end

"""
    _paths_to_labels(paths) → Vector{Symbol}

Derive output labels from file paths. Uses basename without extension.
Throws if labels would collide.
"""
function _paths_to_labels(paths::Vector)
    labels = Symbol[]
    for p in paths
        base = splitext(basename(p))[1]
        push!(labels, Symbol(base))
    end
    if length(unique(labels)) != length(labels)
        throw(ArgumentError(
            "schema file names produce duplicate labels: $(labels). " *
            "Use explicit Pair keys instead (e.g., 'H' => \"file.csv\")."
        ))
    end
    return labels
end
```

- [ ] **Step 4: Add test file to runtests.jl**

In `test/runtests.jl`, add before the closing `end`:

```julia
include("test_multi_schema_loading.jl")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/schema_io.jl test/test_multi_schema_loading.jl test/runtests.jl
git commit -m "feat: multi-file load_schema for ergonomic MultiRecordSchema construction"
```

---

## Final Verification

### Task 8: Full Test Suite & Cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run the full test suite**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All 523+ tests pass (original + new)

- [ ] **Step 2: Verify exports are complete**

Check that `src/FixedWidthParsers.jl` exports `FWTime`, `FWDateTime`, `FWCustom`.

- [ ] **Step 3: Final commit if any cleanup needed**

```bash
git status
# Only commit if there are unstaged changes from cleanup
```
