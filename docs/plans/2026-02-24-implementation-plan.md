# FixedWidthParsers.jl Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a high-performance fixed-width file parser for Julia with mmap IO, @generated inner loops, and both macro and runtime schema APIs.

**Architecture:** Mmap-based IO reads files as byte buffers. Schemas define field layouts (widths, types, offsets). `@generated` functions unroll parsing for static schemas. Lazy iterators yield records on demand; materialization collects into StructArrays. Tables.jl interface enables DataFrames interop.

**Tech Stack:** Julia 1.10+, Parsers.jl, StructArrays.jl, StringViews.jl, Tables.jl, Mmap (stdlib), BenchmarkTools.jl, PkgBenchmark.jl

---

### Task 1: Project Scaffolding

**Files:**
- Create: `Project.toml`
- Create: `src/FixedWidthParsers.jl`
- Create: `test/runtests.jl`
- Create: `CLAUDE.md`

**Step 1: Create Project.toml**

```toml
name = "FixedWidthParsers"
uuid = ""  # Generate with `using UUIDs; uuid4()`
authors = ["Brad"]
version = "0.1.0"

[deps]
Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
StringViews = "354b36f9-a18e-4713-926e-db85100087ba"
StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
Tables = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"

[compat]
julia = "1.10"
Parsers = "2"
StringViews = "1"
StructArrays = "0.6"
Tables = "1"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"

[targets]
test = ["Test"]
```

**Step 2: Create minimal module**

```julia
# src/FixedWidthParsers.jl
module FixedWidthParsers

end # module
```

**Step 3: Create test runner**

```julia
# test/runtests.jl
using Test
using FixedWidthParsers

@testset "FixedWidthParsers.jl" begin
    @test true  # smoke test: module loads
end
```

**Step 4: Create CLAUDE.md**

```markdown
# CLAUDE.md — FixedWidthParsers.jl

## Overview
High-performance fixed-width file parser for Julia. Mmap IO + @generated inner loops.

## Build & Test
```bash
cd ~/Projects/FixedWidthParsers.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.test()'
```

## Architecture
- `src/types.jl` — Field type descriptors (FWString, FWInt, etc.) and `parse_field` methods
- `src/schema.jl` — FixedWidthSchema (runtime) + @fixedwidth macro (static)
- `src/io.jl` — MmapSource, ChunkedSource, newline detection
- `src/parsing.jl` — Core parse_record logic, @generated specializations
- `src/iteration.jl` — Lazy `eachrecord` iterator
- `src/materialization.jl` — `parse_file` → StructArray / Vector{T}

## Conventions
- TDD: write failing test first, then implement
- All field parsing goes through `parse_field(::Type{T}, buf, pos, len)` interface
- Byte positions are 1-indexed (Julia convention)
- `@generated` only for static schemas; runtime schemas use function barriers
```

**Step 5: Generate UUID, instantiate, and run tests**

Run:
```bash
cd ~/Projects/FixedWidthParsers.jl
# Generate UUID and patch into Project.toml
julia -e 'using UUIDs; println(uuid4())'
# (paste UUID into Project.toml)
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: All 1 test passes.

**Step 6: Commit**

```bash
git add Project.toml Manifest.toml src/FixedWidthParsers.jl test/runtests.jl CLAUDE.md
git commit -m "feat: project scaffolding with deps and smoke test"
```

---

### Task 2: Field Type Descriptors and `parse_field`

**Files:**
- Create: `src/types.jl`
- Create: `test/test_types.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("types.jl")` and exports
- Modify: `test/runtests.jl` — add `include("test_types.jl")`

**Step 1: Write failing tests for field type parsing**

```julia
# test/test_types.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field, FWString, FWInt, FWFloat, FWSkip,
                          FWDate, FWFixedPoint, Skip

@testset "Field Types" begin
    # Helper: convert string to UInt8 buffer for testing
    to_buf(s) = Vector{UInt8}(s)

    @testset "FWInt" begin
        buf = to_buf("  42")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        buf = to_buf("-123")
        @test parse_field(FWInt(), buf, 1, 4) == -123

        buf = to_buf("0007")
        @test parse_field(FWInt(), buf, 1, 4) == 7
    end

    @testset "FWFloat" begin
        buf = to_buf("  3.14  ")
        @test parse_field(FWFloat(), buf, 1, 8) ≈ 3.14

        buf = to_buf("-1.5")
        @test parse_field(FWFloat(), buf, 1, 4) ≈ -1.5
    end

    @testset "FWString" begin
        buf = to_buf("UA ")
        val = parse_field(FWString(), buf, 1, 3)
        @test val == "UA"          # trailing spaces stripped
        @test typeof(val) <: AbstractString

        buf = to_buf("ORD")
        @test parse_field(FWString(), buf, 1, 3) == "ORD"
    end

    @testset "FWString with padding char" begin
        buf = to_buf("UA0")
        val = parse_field(FWString(pad='0'), buf, 1, 3)
        @test val == "UA"
    end

    @testset "FWSkip" begin
        buf = to_buf("XXXXX")
        @test parse_field(FWSkip(), buf, 1, 5) === nothing
    end

    @testset "FWDate" begin
        buf = to_buf("20260224")
        val = parse_field(FWDate("yyyymmdd"), buf, 1, 8)
        @test val == Date(2026, 2, 24)

        buf = to_buf("2026055")
        val = parse_field(FWDate("yyyyDDD"), buf, 1, 7)
        @test val == Date(2026, 2, 24)  # day 55 of 2026
    end

    @testset "FWFixedPoint" begin
        buf = to_buf("00012345")
        val = parse_field(FWFixedPoint(2), buf, 1, 8)
        @test val ≈ 123.45

        buf = to_buf("  500")
        val = parse_field(FWFixedPoint(2), buf, 1, 5)
        @test val ≈ 5.0
    end
end
```

**Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `FWString` not defined

**Step 3: Implement field types**

```julia
# src/types.jl
using Parsers
using StringViews
using Dates

# ─── Field type descriptors ───────────────────────────────────────────

"""Sentinel type for skipped (padding) fields."""
struct Skip end

"""Parse field as stripped string. `pad` is the character to strip (default: space)."""
struct FWString
    pad::Char
    FWString(; pad::Char=' ') = new(pad)
end

"""Parse field as Int."""
struct FWInt end

"""Parse field as Float64."""
struct FWFloat end

"""Parse field as Date with given format string."""
struct FWDate
    format::DateFormat
    FWDate(fmt::AbstractString) = new(DateFormat(fmt))
end

"""Skip this field, return nothing."""
struct FWSkip end

"""Parse as integer then divide by 10^decimals. E.g. FWFixedPoint(2): "12345" → 123.45"""
struct FWFixedPoint
    decimals::Int
end

# ─── parse_field interface ────────────────────────────────────────────
# All parse_field methods: (descriptor, buffer::Vector{UInt8}, pos::Int, len::Int) → value

function parse_field(::FWInt, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    # Use Parsers.jl for efficient byte-level parsing
    result = Parsers.xparse(Int, buf, pos, pos + len - 1)
    return Parsers.ok(result.code) ? result.val : throw(ArgumentError("Cannot parse Int from bytes at $pos:$(pos+len-1)"))
end

function parse_field(::FWFloat, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    result = Parsers.xparse(Float64, buf, pos, pos + len - 1)
    return Parsers.ok(result.code) ? result.val : throw(ArgumentError("Cannot parse Float64 from bytes at $pos:$(pos+len-1)"))
end

function parse_field(fw::FWString, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    # Find the last non-pad byte
    pad_byte = UInt8(fw.pad)
    last = pos + len - 1
    while last >= pos && buf[last] == pad_byte
        last -= 1
    end
    if last < pos
        return ""
    end
    return StringView(@view buf[pos:last])
end

function parse_field(::FWSkip, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    return nothing
end

function parse_field(fw::FWDate, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    s = StringView(@view buf[pos:pos+len-1])
    return Dates.parse(Date, String(s), fw.format)
end

function parse_field(fw::FWFixedPoint, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    result = Parsers.xparse(Int, buf, pos, pos + len - 1)
    if !Parsers.ok(result.code)
        throw(ArgumentError("Cannot parse FixedPoint from bytes at $pos:$(pos+len-1)"))
    end
    return result.val / (10.0 ^ fw.decimals)
end
```

**Step 4: Update module to include types.jl**

```julia
# src/FixedWidthParsers.jl
module FixedWidthParsers

include("types.jl")

export FWString, FWInt, FWFloat, FWDate, FWSkip, FWFixedPoint, Skip
export parse_field

end # module
```

**Step 5: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Note on Parsers.xparse:** The `Parsers.xparse` API may differ from what's shown above. The implementer should check the actual Parsers.jl source for the correct call signature. The key pattern is: parse directly from `Vector{UInt8}` with byte position range, avoiding String allocation. If `xparse` isn't suitable, fall back to `Parsers.parse(Int, StringView(@view buf[pos:pos+len-1]))` — still avoids full String allocation.

**Step 6: Commit**

```bash
git add src/types.jl test/test_types.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: field type descriptors and parse_field implementations"
```

---

### Task 3: Runtime Schema (FixedWidthSchema)

**Files:**
- Create: `src/schema.jl`
- Create: `test/test_schema.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("schema.jl")` and exports

**Step 1: Write failing tests for schema**

```julia
# test/test_schema.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: FieldSpec, FixedWidthSchema, record_width, field_names,
                          field_types, field_offsets, n_fields, non_skip_indices

@testset "Schema" begin
    @testset "FieldSpec construction" begin
        fs = FieldSpec(:carrier, 2, FWString())
        @test fs.name == :carrier
        @test fs.width == 2
        @test fs.type isa FWString
    end

    @testset "FixedWidthSchema from pairs" begin
        schema = FixedWidthSchema(
            :carrier    => (2, FWString()),
            :flight_num => (4, FWInt()),
            :skip       => (1, FWSkip()),
            :origin     => (3, FWString()),
        )

        @test n_fields(schema) == 4
        @test record_width(schema) == 10  # 2 + 4 + 1 + 3
        @test field_names(schema) == (:carrier, :flight_num, :skip, :origin)
        @test field_offsets(schema) == (1, 3, 7, 8)  # 1-indexed cumulative
    end

    @testset "non_skip_indices" begin
        schema = FixedWidthSchema(
            :a    => (2, FWString()),
            :skip => (1, FWSkip()),
            :b    => (3, FWInt()),
        )
        @test non_skip_indices(schema) == [1, 3]
    end

    @testset "record_width" begin
        schema = FixedWidthSchema(
            :x => (5, FWString()),
            :y => (3, FWInt()),
        )
        @test record_width(schema) == 8
    end
end
```

**Step 2: Run tests to verify they fail**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `FieldSpec` not defined

**Step 3: Implement schema types**

```julia
# src/schema.jl

"""Specification for a single field in a fixed-width record."""
struct FieldSpec
    name::Symbol
    width::Int
    type::Any  # FWString, FWInt, FWFloat, FWDate, FWSkip, FWFixedPoint, or custom
    offset::Int  # 1-based byte offset within record (computed at schema construction)
end

# Constructor without offset (offset computed by schema)
FieldSpec(name::Symbol, width::Int, type) = FieldSpec(name, width, type, 0)

"""
    FixedWidthSchema(pairs...)

Runtime-defined schema for fixed-width records.

# Example
```julia
schema = FixedWidthSchema(
    :carrier    => (2, FWString()),
    :flight_num => (4, FWInt()),
    :origin     => (3, FWString()),
)
```
"""
struct FixedWidthSchema
    fields::Vector{FieldSpec}
    record_width::Int
    offsets::Vector{Int}

    function FixedWidthSchema(pairs::Pair{Symbol}...)
        fields = FieldSpec[]
        offsets = Int[]
        offset = 1
        for (name, (width, type)) in pairs
            push!(fields, FieldSpec(name, width, type, offset))
            push!(offsets, offset)
            offset += width
        end
        rw = offset - 1
        new(fields, rw, offsets)
    end
end

"""Total byte width of one record (excluding newline)."""
record_width(s::FixedWidthSchema) = s.record_width

"""Number of fields in the schema."""
n_fields(s::FixedWidthSchema) = length(s.fields)

"""Tuple of field names."""
field_names(s::FixedWidthSchema) = Tuple(f.name for f in s.fields)

"""Tuple of 1-based byte offsets for each field."""
field_offsets(s::FixedWidthSchema) = Tuple(s.offsets)

"""Vector of field types (descriptors)."""
field_types(s::FixedWidthSchema) = [f.type for f in s.fields]

"""Indices of non-skip fields (for output construction)."""
function non_skip_indices(s::FixedWidthSchema)
    return [i for (i, f) in enumerate(s.fields) if !(f.type isa FWSkip)]
end
```

**Step 4: Update module**

Add to `src/FixedWidthParsers.jl` after `include("types.jl")`:
```julia
include("schema.jl")

export FixedWidthSchema
```

**Step 5: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/schema.jl test/test_schema.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: runtime FixedWidthSchema with field specs and accessors"
```

---

### Task 4: IO Layer — Mmap Source and Newline Detection

**Files:**
- Create: `src/io.jl`
- Create: `test/test_io.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("io.jl")`

**Step 1: Write failing tests**

```julia
# test/test_io.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: MmapSource, detect_newline, record_count, buffer

@testset "IO Layer" begin
    @testset "detect_newline with LF" begin
        buf = Vector{UInt8}("ABCD\nEFGH\n")
        @test detect_newline(buf, 4) == 1  # LF = 1 byte
    end

    @testset "detect_newline with CRLF" begin
        buf = Vector{UInt8}("ABCD\r\nEFGH\r\n")
        @test detect_newline(buf, 4) == 2  # CRLF = 2 bytes
    end

    @testset "detect_newline no trailing newline" begin
        buf = Vector{UInt8}("ABCDEFGH")
        @test detect_newline(buf, 4) == 0  # no newline
    end

    @testset "MmapSource from file with LF" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\n")
            write(io, "BBBB\n")
            write(io, "CCCC\n")
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 3
        @test length(buffer(src)) == 15  # 3 * (4 + 1)
        close(src)
        rm(path)
    end

    @testset "MmapSource from file with CRLF" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\r\n")
            write(io, "BBBB\r\n")
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 2
        close(src)
        rm(path)
    end

    @testset "MmapSource no trailing newline" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\nBBBB")  # last record has no newline
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 2
        close(src)
        rm(path)
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `MmapSource` not defined

**Step 3: Implement IO layer**

```julia
# src/io.jl
using Mmap

"""
    detect_newline(buf, record_width) → Int

Detect newline style from buffer. Returns:
- 0: no newline detected
- 1: LF (\\n)
- 2: CRLF (\\r\\n)
"""
function detect_newline(buf::AbstractVector{UInt8}, record_width::Int)
    if length(buf) <= record_width
        return 0
    end
    pos = record_width + 1
    if buf[pos] == UInt8('\n')
        return 1
    elseif buf[pos] == UInt8('\r') && length(buf) > pos && buf[pos + 1] == UInt8('\n')
        return 2
    end
    return 0
end

"""
    MmapSource

Memory-mapped file source for fixed-width record access.
"""
mutable struct MmapSource
    buf::Vector{UInt8}
    io::IOStream
    record_width::Int
    newline_width::Int
    stride::Int         # record_width + newline_width
    n_records::Int

    function MmapSource(path::AbstractString, record_width::Int)
        io = open(path, "r")
        fsize = filesize(io)
        if fsize == 0
            return new(UInt8[], io, record_width, 0, record_width, 0)
        end
        buf = Mmap.mmap(io, Vector{UInt8}, fsize)
        nl = detect_newline(buf, record_width)
        stride = record_width + nl

        # Calculate number of records
        # Handle case where last record may not have trailing newline
        n = fsize ÷ stride
        remainder = fsize - n * stride
        if remainder == record_width
            n += 1  # last record without newline
        elseif remainder != 0 && remainder != record_width
            @warn "File size ($fsize) not evenly divisible by stride ($stride). Remainder: $remainder bytes."
        end

        new(buf, io, record_width, nl, stride, n)
    end
end

buffer(src::MmapSource) = src.buf
record_count(src::MmapSource) = src.n_records

"""Byte offset (1-based) of record `i` (1-indexed)."""
function record_offset(src::MmapSource, i::Int)
    return (i - 1) * src.stride + 1
end

function Base.close(src::MmapSource)
    finalize(src.buf)  # unmap
    close(src.io)
end
```

**Step 4: Update module**

Add to `src/FixedWidthParsers.jl`:
```julia
include("io.jl")
```

**Step 5: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/io.jl test/test_io.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: MmapSource with newline detection and record counting"
```

---

### Task 5: Core Parsing — `parse_record` for Runtime Schemas

**Files:**
- Create: `src/parsing.jl`
- Create: `test/test_parsing.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("parsing.jl")`

**Step 1: Write failing tests**

```julia
# test/test_parsing.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: parse_record

@testset "Core Parsing" begin
    schema = FixedWidthSchema(
        :carrier    => (2, FWString()),
        :flight_num => (4, FWInt()),
        :skip       => (1, FWSkip()),
        :origin     => (3, FWString()),
        :dest       => (3, FWString()),
    )

    @testset "parse_record returns NamedTuple" begin
        buf = Vector{UInt8}("UA1234 ORDSFO")
        record = parse_record(schema, buf, 1)
        @test record.carrier == "UA"
        @test record.flight_num == 1234
        @test record.origin == "ORD"
        @test record.dest == "SFO"
        @test !haskey(record, :skip)  # skip fields excluded
    end

    @testset "parse_record with leading spaces" begin
        buf = Vector{UInt8}("DL 567 LAXJFK")
        record = parse_record(schema, buf, 1)
        @test record.carrier == "DL"
        @test record.flight_num == 567
        @test record.origin == "LAX"
        @test record.dest == "JFK"
    end

    @testset "parse_record at offset" begin
        buf = Vector{UInt8}("UA1234 ORDSFO\nDL 567 LAXJFK\n")
        record = parse_record(schema, buf, 15)  # second record after \n
        @test record.carrier == "DL"
        @test record.flight_num == 567
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `parse_record` not defined

**Step 3: Implement parse_record**

```julia
# src/parsing.jl

"""
    parse_record(schema::FixedWidthSchema, buf, pos) → NamedTuple

Parse a single record from `buf` starting at byte position `pos`.
Returns a NamedTuple with non-skip fields only.
"""
function parse_record(schema::FixedWidthSchema, buf::AbstractVector{UInt8}, pos::Int)
    # Collect non-skip field names and values
    names = Symbol[]
    values = Any[]
    for field in schema.fields
        if field.type isa FWSkip
            continue
        end
        val = parse_field(field.type, buf, pos + field.offset - 1, field.width)
        push!(names, field.name)
        push!(values, val)
    end
    return NamedTuple{Tuple(names)}(Tuple(values))
end
```

**Step 4: Update module**

Add to `src/FixedWidthParsers.jl`:
```julia
include("parsing.jl")
```

**Step 5: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/parsing.jl test/test_parsing.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: parse_record for runtime schemas returning NamedTuples"
```

---

### Task 6: Lazy Iteration — `eachrecord`

**Files:**
- Create: `src/iteration.jl`
- Create: `test/test_iteration.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("iteration.jl")` and exports

**Step 1: Write failing tests**

```julia
# test/test_iteration.jl
using Test
using FixedWidthParsers

@testset "Iteration" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    @testset "eachrecord from file" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        records = collect(eachrecord(path, schema))
        @test length(records) == 3
        @test records[1].name == "foo"
        @test records[1].val == 10
        @test records[2].name == "bar"
        @test records[3].val == 30
        rm(path)
    end

    @testset "eachrecord is lazy" begin
        path = tempname()
        open(path, "w") do io
            for i in 1:1000
                write(io, "test$(lpad(i, 3, '0'))\n")
            end
        end

        schema2 = FixedWidthSchema(:s => (7, FWString()))
        count = 0
        for record in eachrecord(path, schema2)
            count += 1
            count >= 5 && break
        end
        @test count == 5  # Only iterated 5 times, not 1000
        rm(path)
    end

    @testset "eachrecord length" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AA 1\n")
            write(io, "BB 2\n")
        end

        iter = eachrecord(path, schema)
        @test length(iter) == 2
        close(iter)
        rm(path)
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `eachrecord` not defined

**Step 3: Implement iterator**

```julia
# src/iteration.jl

"""
    RecordIterator

Lazy iterator over fixed-width records in a file.
Parsing happens on each `iterate()` call.
"""
struct RecordIterator{S}
    source::MmapSource
    schema::S
end

"""
    eachrecord(path::AbstractString, schema) → RecordIterator

Return a lazy iterator over records in a fixed-width file.
Records are parsed on demand during iteration.
"""
function eachrecord(path::AbstractString, schema::FixedWidthSchema)
    src = MmapSource(path, record_width(schema))
    return RecordIterator(src, schema)
end

Base.length(iter::RecordIterator) = record_count(iter.source)
Base.eltype(::RecordIterator) = NamedTuple
Base.close(iter::RecordIterator) = close(iter.source)
Base.IteratorSize(::Type{<:RecordIterator}) = Base.HasLength()

function Base.iterate(iter::RecordIterator, state::Int=1)
    state > record_count(iter.source) && return nothing
    pos = record_offset(iter.source, state)
    record = parse_record(iter.schema, buffer(iter.source), pos)
    return (record, state + 1)
end
```

**Step 4: Update module**

Add to `src/FixedWidthParsers.jl`:
```julia
include("iteration.jl")

export eachrecord
```

**Step 5: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/iteration.jl test/test_iteration.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: lazy eachrecord iterator over mmap'd files"
```

---

### Task 7: Materialization — `parse_file`

**Files:**
- Create: `src/materialization.jl`
- Create: `test/test_materialization.jl`
- Modify: `src/FixedWidthParsers.jl` — add `include("materialization.jl")` and exports

**Step 1: Write failing tests**

```julia
# test/test_materialization.jl
using Test
using FixedWidthParsers
using StructArrays

@testset "Materialization" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    function make_test_file()
        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end
        return path
    end

    @testset "parse_file returns StructArray by default" begin
        path = make_test_file()
        result = parse_file(path, schema)
        @test result isa StructArray
        @test length(result) == 3
        @test result.name[1] == "foo"
        @test result.val == [10, 20, 30]
        rm(path)
    end

    @testset "parse_file columnar=false returns Vector" begin
        path = make_test_file()
        result = parse_file(path, schema; columnar=false)
        @test result isa Vector
        @test length(result) == 3
        @test result[1].name == "foo"
        @test result[1].val == 10
        rm(path)
    end

    @testset "parse_file empty file" begin
        path = tempname()
        open(path, "w") do io end  # empty
        result = parse_file(path, schema)
        @test length(result) == 0
        rm(path)
    end

    @testset "parse_file pre-allocates columns" begin
        path = make_test_file()
        result = parse_file(path, schema)
        # StructArray columns should be exact size, no over-allocation
        @test length(result.name) == 3
        @test length(result.val) == 3
        rm(path)
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `parse_file` not defined

**Step 3: Implement materialization**

```julia
# src/materialization.jl
using StructArrays

"""
    parse_file(path, schema; columnar=true, on_error=:strict) → StructArray or Vector

Parse an entire fixed-width file into memory.

- `columnar=true` (default): Returns a `StructArray` (column-oriented, efficient for analytics)
- `columnar=false`: Returns a `Vector{NamedTuple}` (row-oriented)
- `on_error`: `:strict` (throw), `:lenient` (missing), or callback function
"""
function parse_file(path::AbstractString, schema::FixedWidthSchema;
                    columnar::Bool=true, on_error::Union{Symbol,Function}=:strict)
    src = MmapSource(path, record_width(schema))
    n = record_count(src)
    buf = buffer(src)

    if n == 0
        close(src)
        if columnar
            # Return empty StructArray with correct schema
            return _empty_structarray(schema)
        else
            return NamedTuple[]
        end
    end

    if columnar
        result = _parse_columnar(schema, src, buf, n, on_error)
    else
        result = _parse_rows(schema, src, buf, n, on_error)
    end

    close(src)
    return result
end

function _parse_columnar(schema::FixedWidthSchema, src::MmapSource,
                         buf::AbstractVector{UInt8}, n::Int, on_error)
    # Identify non-skip fields
    ns_fields = [f for f in schema.fields if !(f.type isa FWSkip)]
    names = Tuple(f.name for f in ns_fields)

    # Pre-allocate column vectors
    # For now, use Vector{Any} per column and narrow later
    columns = Dict{Symbol, Vector}()
    for f in ns_fields
        T = _julia_type(f.type)
        columns[f.name] = Vector{T}(undef, n)
    end

    # Fill columns in a single pass
    for i in 1:n
        pos = record_offset(src, i)
        for f in ns_fields
            val = parse_field(f.type, buf, pos + f.offset - 1, f.width)
            columns[f.name][i] = val
        end
    end

    # Build StructArray from columns
    col_tuple = NamedTuple{names}(Tuple(columns[name] for name in names))
    return StructArray(col_tuple)
end

function _parse_rows(schema::FixedWidthSchema, src::MmapSource,
                     buf::AbstractVector{UInt8}, n::Int, on_error)
    result = Vector{NamedTuple}(undef, n)
    for i in 1:n
        pos = record_offset(src, i)
        result[i] = parse_record(schema, buf, pos)
    end
    return result
end

function _empty_structarray(schema::FixedWidthSchema)
    ns_fields = [f for f in schema.fields if !(f.type isa FWSkip)]
    names = Tuple(f.name for f in ns_fields)
    columns = Tuple(Vector{_julia_type(f.type)}() for f in ns_fields)
    return StructArray(NamedTuple{names}(columns))
end

"""Map field type descriptor to Julia type for column pre-allocation."""
_julia_type(::FWInt) = Int
_julia_type(::FWFloat) = Float64
_julia_type(::FWString) = AbstractString
_julia_type(::FWDate) = Date
_julia_type(::FWFixedPoint) = Float64
_julia_type(::FWSkip) = Nothing
_julia_type(::Any) = Any  # fallback for custom types
```

**Step 4: Update module**

Add to `src/FixedWidthParsers.jl`:
```julia
include("materialization.jl")

export parse_file
```

**Step 5: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add src/materialization.jl test/test_materialization.jl src/FixedWidthParsers.jl test/runtests.jl
git commit -m "feat: parse_file with StructArray and Vector materialization"
```

---

### Task 8: Error Handling — `ParseError` and Error Modes

**Files:**
- Modify: `src/types.jl` — add `ParseError` type
- Modify: `src/parsing.jl` — add error mode handling
- Create: `test/test_errors.jl`
- Modify: `test/runtests.jl` — add `include("test_errors.jl")`

**Step 1: Write failing tests**

```julia
# test/test_errors.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: ParseError

@testset "Error Handling" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    @testset "ParseError type" begin
        err = ParseError(1, 5:7, UInt8[0x41, 0x42, 0x43], Int, "bad int")
        @test err.line == 1
        @test err.columns == 5:7
        @test err.expected_type == Int
        @test occursin("bad int", err.message)
    end

    @testset "strict mode throws on bad data" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")  # "abc" is not a valid Int
        end

        @test_throws ParseError parse_file(path, schema; on_error=:strict)
        rm(path)
    end

    @testset "lenient mode returns missing" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo abc\n")
            write(io, "bar  42\n")
        end

        result = parse_file(path, schema; on_error=:lenient)
        @test length(result) == 2
        @test ismissing(result.val[1])
        @test result.val[2] == 42
        rm(path)
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `ParseError` not defined

**Step 3: Implement ParseError and error modes**

Add to `src/types.jl`:

```julia
"""
    ParseError <: Exception

Error thrown when a field cannot be parsed in strict mode.
"""
struct ParseError <: Exception
    line::Int
    columns::UnitRange{Int}
    raw_bytes::Vector{UInt8}
    expected_type::Type
    message::String
end

function Base.showerror(io::IO, e::ParseError)
    print(io, "ParseError at line $(e.line), columns $(e.columns): $(e.message)")
    print(io, "\n  Raw bytes: ", String(copy(e.raw_bytes)))
    print(io, "\n  Expected type: ", e.expected_type)
end
```

Modify `parse_field` methods to use `tryparse` pattern, and update `parsing.jl` and `materialization.jl` to pass error mode through. The key change: `parse_field` methods gain an optional error mode, and `parse_record` / `_parse_columnar` catch errors in lenient mode and substitute `missing`.

This requires updating `_julia_type` to return `Union{T, Missing}` when `on_error=:lenient`, and updating the column pre-allocation accordingly.

**Step 4: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/types.jl src/parsing.jl src/materialization.jl test/test_errors.jl test/runtests.jl
git commit -m "feat: ParseError type with strict and lenient error modes"
```

---

### Task 9: `@fixedwidth` Macro and `@generated` Parsing

**Files:**
- Modify: `src/schema.jl` — add `@fixedwidth` macro and static schema types
- Modify: `src/parsing.jl` — add `@generated parse_record` for static schemas
- Create: `test/test_macro.jl`
- Modify: `test/runtests.jl` — add `include("test_macro.jl")`

**Step 1: Write failing tests**

```julia
# test/test_macro.jl
using Test
using FixedWidthParsers
using FixedWidthParsers: record_width, field_names, field_offsets
using Dates

@testset "@fixedwidth Macro" begin
    @testset "basic struct definition" begin
        @fixedwidth struct SimpleRecord
            name::String = 4
            value::Int   = 3
        end

        # Struct should be defined with correct field types
        r = SimpleRecord("test", 42)
        @test r.name == "test"
        @test r.value == 42
    end

    @testset "schema metadata" begin
        @fixedwidth struct SimpleRecord2
            name::String = 4
            value::Int   = 3
        end

        schema = FixedWidthParsers.schema(SimpleRecord2)
        @test record_width(schema) == 7
        @test field_names(schema) == (:name, :value)
        @test field_offsets(schema) == (1, 5)
    end

    @testset "parse_file with @fixedwidth struct" begin
        @fixedwidth struct TestFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "UA1234ORD\n")
            write(io, "DL 567LAX\n")
        end

        result = parse_file(path, TestFlight)
        @test length(result) == 2
        @test result.carrier[1] == "UA"
        @test result.number == [1234, 567]
        @test result.origin[2] == "LAX"
        rm(path)
    end

    @testset "skip fields" begin
        @fixedwidth struct SkipRecord
            a::String = 2
            _::Skip   = 1
            b::Int    = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "AB 123\n")
        end

        result = parse_file(path, SkipRecord)
        @test result.a[1] == "AB"
        @test result.b[1] == 123
        @test !hasproperty(result, :_)  # skip field not in output
        rm(path)
    end

    @testset "eachrecord with @fixedwidth struct" begin
        @fixedwidth struct IterRecord
            x::String = 3
            y::Int    = 2
        end

        path = tempname()
        open(path, "w") do io
            write(io, "abc10\n")
            write(io, "def20\n")
        end

        records = collect(eachrecord(path, IterRecord))
        @test length(records) == 2
        @test records[1].x == "abc"
        @test records[2].y == 20
        rm(path)
    end
end
```

**Step 2: Run tests to verify failure**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `@fixedwidth` not defined

**Step 3: Implement the macro**

The `@fixedwidth` macro needs to:

1. Parse the struct definition, extracting field names, Julia types, and widths from the `= N` syntax
2. Emit the struct definition with only non-skip fields (normal Julia types)
3. Generate a companion `StaticSchema{T}` that encodes widths, offsets, and field types as type parameters
4. Generate specialized `parse_record` and `parse_file` methods that accept the struct type

Key implementation details for `src/schema.jl`:

```julia
"""
    @fixedwidth struct T ... end

Define a fixed-width record type with field widths.

Fields use `fieldname::JuliaType = width` syntax.
Use `_::Skip = width` for padding fields.
"""
macro fixedwidth(expr)
    # Parse struct definition
    # Extract: field names, julia types, widths
    # Emit:
    #   1. The struct (without Skip fields, without = N)
    #   2. A schema() method returning FixedWidthSchema
    #   3. Overloads for parse_file(path, ::Type{T}) and eachrecord(path, ::Type{T})
    # ... (full implementation)
end
```

The macro should map Julia types to field type descriptors:
- `String` → `FWString()`
- `Int` → `FWInt()`
- `Float64` → `FWFloat()`
- `Date` → `FWDate("yyyymmdd")` (default format, override via annotation)
- `Skip` → `FWSkip()`
- `FixedPoint{N}` → `FWFixedPoint(N)`

For the `@generated` path, add to `src/parsing.jl`:

```julia
# Generated parse function for static schemas — unrolls the field parsing loop
@generated function parse_record_generated(::Type{T}, buf::AbstractVector{UInt8}, pos::Int) where T
    schema = FixedWidthParsers.schema(T)
    ns_fields = [f for f in schema.fields if !(f.type isa FWSkip)]
    field_exprs = map(ns_fields) do f
        :(parse_field($(f.type), buf, pos + $(f.offset - 1), $(f.width)))
    end
    names = Tuple(f.name for f in ns_fields)
    quote
        NamedTuple{$names}(($(field_exprs...),))
    end
end
```

**Step 4: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema.jl src/parsing.jl src/materialization.jl src/iteration.jl test/test_macro.jl test/runtests.jl
git commit -m "feat: @fixedwidth macro with @generated parse_record specialization"
```

---

### Task 10: Tables.jl Interface

**Files:**
- Modify: `src/materialization.jl` — add Tables.jl method implementations
- Modify: `test/test_materialization.jl` — add Tables.jl tests

**Step 1: Write failing tests**

Add to `test/test_materialization.jl`:

```julia
using Tables

@testset "Tables.jl interface" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    path = tempname()
    open(path, "w") do io
        write(io, "foo  10\n")
        write(io, "bar  20\n")
    end

    result = parse_file(path, schema)

    @test Tables.istable(typeof(result))
    @test Tables.columnaccess(typeof(result))
    @test Tables.schema(result) !== nothing

    # Can collect into any Tables.jl sink
    rows = Tables.rows(result)
    row1 = first(rows)
    @test Tables.getcolumn(row1, :name) == "foo"
    @test Tables.getcolumn(row1, :val) == 10

    rm(path)
end
```

**Step 2: Run tests — failure expected**

Since `StructArray` already implements Tables.jl, these tests may actually pass immediately. If so, this task is just verification. If not, add the necessary method definitions.

**Step 3: Verify or implement Tables.jl compliance**

StructArrays.jl already implements `Tables.columns`, `Tables.rows`, `Tables.schema`, etc. The main work here is ensuring our `RecordIterator` also implements the Tables interface for lazy consumption:

```julia
# In src/iteration.jl
Tables.istable(::Type{<:RecordIterator}) = true
Tables.rowaccess(::Type{<:RecordIterator}) = true
Tables.rows(iter::RecordIterator) = iter
Tables.schema(iter::RecordIterator) = nothing  # unknown schema for generic NamedTuple
```

**Step 4: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/materialization.jl src/iteration.jl test/test_materialization.jl
git commit -m "feat: Tables.jl interface for both StructArray results and lazy iterators"
```

---

### Task 11: Chunked IO Fallback

**Files:**
- Modify: `src/io.jl` — add `ChunkedSource`
- Modify: `test/test_io.jl` — add chunked IO tests
- Modify: `src/iteration.jl` — support `IO` argument in `eachrecord`

**Step 1: Write failing tests**

Add to `test/test_io.jl`:

```julia
using FixedWidthParsers: ChunkedSource

@testset "ChunkedSource" begin
    @testset "from IOBuffer" begin
        data = "AAAA\nBBBB\nCCCC\n"
        io = IOBuffer(data)
        src = ChunkedSource(io, 4)
        @test record_count(src) == 3
        @test String(buffer(src)) == data
    end

    @testset "eachrecord from IO" begin
        schema = FixedWidthSchema(:val => (4, FWString()))
        io = IOBuffer("AAAA\nBBBB\n")
        records = collect(eachrecord(io, schema))
        @test length(records) == 2
        @test records[1].val == "AAAA"
        @test records[2].val == "BBBB"
    end
end
```

**Step 2: Implement ChunkedSource**

```julia
# Add to src/io.jl

"""
    ChunkedSource

Buffered source for non-seekable IO (pipes, IOBuffer, stdin).
Reads entire stream into memory buffer.
"""
mutable struct ChunkedSource
    buf::Vector{UInt8}
    record_width::Int
    newline_width::Int
    stride::Int
    n_records::Int

    function ChunkedSource(io::IO, record_width::Int; chunk_size::Int=65536)
        buf = read(io)  # read all into memory
        if isempty(buf)
            return new(buf, record_width, 0, record_width, 0)
        end
        nl = detect_newline(buf, record_width)
        stride = record_width + nl
        n = length(buf) ÷ stride
        remainder = length(buf) - n * stride
        if remainder == record_width
            n += 1
        end
        new(buf, record_width, nl, stride, n)
    end
end

buffer(src::ChunkedSource) = src.buf
record_count(src::ChunkedSource) = src.n_records
record_offset(src::ChunkedSource, i::Int) = (i - 1) * src.stride + 1
Base.close(::ChunkedSource) = nothing
```

Update `eachrecord` to accept `IO`:

```julia
function eachrecord(io::IO, schema::FixedWidthSchema)
    src = ChunkedSource(io, record_width(schema))
    return RecordIterator(src, schema)
end
```

**Step 3: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add src/io.jl src/iteration.jl test/test_io.jl
git commit -m "feat: ChunkedSource for non-seekable IO with eachrecord support"
```

---

### Task 12: Benchmark Suite

**Files:**
- Create: `bench/benchmarks.jl`
- Create: `bench/make_testdata.jl`

**Step 1: Create test data generator**

```julia
# bench/make_testdata.jl
using Printf

function generate_test_file(path::String, n_records::Int)
    open(path, "w") do io
        for i in 1:n_records
            carrier = rand(["UA", "DL", "AA", "WN"])
            fnum = lpad(rand(100:9999), 4)
            origin = rand(["ORD", "LAX", "JFK", "SFO", "DEN"])
            dest = rand(["ORD", "LAX", "JFK", "SFO", "DEN"])
            pax = lpad(rand(1:300), 3)
            rev = lpad(rand(10000:99999999), 8)
            write(io, carrier, fnum, " ", origin, dest, pax, rev, "\n")
            # Total width: 2 + 4 + 1 + 3 + 3 + 3 + 8 = 24 bytes + newline
        end
    end
end
```

**Step 2: Create benchmark suite**

```julia
# bench/benchmarks.jl
using BenchmarkTools
using FixedWidthParsers
using PkgBenchmark

include("make_testdata.jl")

const SUITE = BenchmarkGroup()

# Generate test files
const TESTDIR = mktempdir()
generate_test_file(joinpath(TESTDIR, "1M_mixed.dat"), 1_000_000)
generate_test_file(joinpath(TESTDIR, "100K_mixed.dat"), 100_000)

schema = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :skip    => (1, FWSkip()),
    :origin  => (3, FWString()),
    :dest    => (3, FWString()),
    :pax     => (3, FWInt()),
    :revenue => (8, FWInt()),
)

SUITE["parse_file"] = BenchmarkGroup()
SUITE["parse_file"]["1M_columnar"] = @benchmarkable parse_file($(joinpath(TESTDIR, "1M_mixed.dat")), $schema)
SUITE["parse_file"]["1M_rows"] = @benchmarkable parse_file($(joinpath(TESTDIR, "1M_mixed.dat")), $schema; columnar=false)
SUITE["parse_file"]["100K_columnar"] = @benchmarkable parse_file($(joinpath(TESTDIR, "100K_mixed.dat")), $schema)

SUITE["iteration"] = BenchmarkGroup()
SUITE["iteration"]["1M_lazy"] = @benchmarkable begin
    count = 0
    for r in eachrecord($(joinpath(TESTDIR, "1M_mixed.dat")), $schema)
        count += 1
    end
    count
end
```

**Step 3: Run benchmarks to establish baseline**

Run:
```bash
cd ~/Projects/FixedWidthParsers.jl
julia --project -e '
    using PkgBenchmark
    results = benchmarkpkg(".")
    export_markdown(stdout, judge(results, results))
'
```

**Step 4: Commit**

```bash
git add bench/
git commit -m "feat: benchmark suite with PkgBenchmark for regression tracking"
```

---

### Task 13: Integration Test — Full Pipeline

**Files:**
- Create: `test/test_integration.jl`
- Modify: `test/runtests.jl` — add `include("test_integration.jl")`

**Step 1: Write integration test**

```julia
# test/test_integration.jl
using Test
using FixedWidthParsers
using StructArrays
using Dates

@testset "Integration" begin
    @testset "full pipeline: schema → parse → iterate → materialize" begin
        # Create a realistic fixed-width file
        path = tempname()
        open(path, "w") do io
            # carrier(2) fnum(4) pad(1) origin(3) dest(3) date(8) pax(3) rev(8)
            # Total: 32 bytes per record
            write(io, "UA1234 ORDSFO20260224150 00054321\n")
            write(io, "DL 567 LAXJFK20260225 89 00012345\n")
            write(io, "AA9999 DENSFO20260226300 99999999\n")
        end

        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :pad     => (1, FWSkip()),
            :origin  => (3, FWString()),
            :dest    => (3, FWString()),
            :date    => (8, FWDate("yyyymmdd")),
            :pax     => (3, FWInt()),
            :pad2    => (1, FWSkip()),
            :revenue => (8, FWFixedPoint(2)),
        )

        # Test StructArray materialization
        sa = parse_file(path, schema)
        @test sa isa StructArray
        @test length(sa) == 3
        @test sa.carrier == ["UA", "DL", "AA"]
        @test sa.fnum == [1234, 567, 9999]
        @test sa.origin == ["ORD", "LAX", "DEN"]
        @test sa.date[1] == Date(2026, 2, 24)
        @test sa.revenue[1] ≈ 543.21

        # Test lazy iteration
        records = collect(eachrecord(path, schema))
        @test length(records) == 3
        @test records[2].carrier == "DL"

        # Test row materialization
        rows = parse_file(path, schema; columnar=false)
        @test rows[3].pax == 300

        rm(path)
    end
end
```

**Step 2: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add test/test_integration.jl test/runtests.jl
git commit -m "test: full pipeline integration test"
```

---

### Summary of Tasks

| Task | Component | Key Deliverable |
|------|-----------|-----------------|
| 1 | Scaffolding | Project.toml, module, test runner, CLAUDE.md |
| 2 | Field Types | FWString, FWInt, FWFloat, FWDate, FWSkip, FWFixedPoint + parse_field |
| 3 | Schema | FixedWidthSchema runtime type with field specs and accessors |
| 4 | IO Layer | MmapSource, newline detection, record counting |
| 5 | Core Parsing | parse_record for runtime schemas → NamedTuple |
| 6 | Iteration | eachrecord lazy iterator over mmap'd files |
| 7 | Materialization | parse_file → StructArray or Vector |
| 8 | Error Handling | ParseError, strict/lenient modes |
| 9 | @fixedwidth Macro | Static schema macro + @generated parse_record |
| 10 | Tables.jl | Interface compliance for DataFrames interop |
| 11 | Chunked IO | ChunkedSource fallback for pipes/stdin |
| 12 | Benchmarks | PkgBenchmark suite with regression tracking |
| 13 | Integration | Full pipeline integration test |
