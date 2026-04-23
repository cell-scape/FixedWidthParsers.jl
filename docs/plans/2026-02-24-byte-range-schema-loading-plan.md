# Byte-Range Schemas and Schema File Loading Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add byte-range field specification to `FixedWidthSchema` and a `load_schema` function that reads schema definitions from CSV, TOML, and JSON files.

**Architecture:** The existing `FixedWidthSchema` inner constructor is refactored into a private helper `_build_schema` that takes a `Vector{FieldSpec}` and `record_width`. Two new outer constructors handle range-based and start+width tuples by normalizing to `FieldSpec` vectors, sorting by offset, inserting `FWSkip` for gaps, and delegating to `_build_schema`. A `_parse_type_string` helper maps strings like `"Int"` to descriptors. `load_schema` dispatches on file extension, parses the file into `(name, start, end, type_string)` tuples, and builds a schema via the range-based constructor. JSON support is a package extension.

**Tech Stack:** Julia, stdlib TOML, JSON3.jl (extension)

---

### Task 1: `_parse_type_string` helper + tests

**Files:**
- Modify: `src/schema.jl` (insert after `_apply_column_selection`, before `schema()` generic)
- Create: `test/test_schema_loading.jl`
- Modify: `test/runtests.jl` (add include)

**Step 1: Write the failing test**

Create `test/test_schema_loading.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _parse_type_string

@testset "Schema Loading" begin
    @testset "_parse_type_string" begin
        @test _parse_type_string("String") isa FWString
        @test _parse_type_string("Int") isa FWInt
        @test _parse_type_string("Float64") isa FWFloat
        @test _parse_type_string("Skip") isa FWSkip
        @test _parse_type_string("Date") isa FWDate
        @test _parse_type_string("Date").format_string == "yyyymmdd"
        @test _parse_type_string("Date(ddmmyyyy)") isa FWDate
        @test _parse_type_string("Date(ddmmyyyy)").format_string == "ddmmyyyy"
        @test _parse_type_string("FixedPoint(2)") isa FWFixedPoint
        @test _parse_type_string("FixedPoint(2)").decimals == 2
        @test _parse_type_string("FixedPoint(0)").decimals == 0
        @test_throws ArgumentError _parse_type_string("Unknown")
        @test_throws ArgumentError _parse_type_string("")
    end
end
```

Add `include("test_schema_loading.jl")` to `test/runtests.jl` after the last include.

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with "UndefVarError: _parse_type_string not defined"

**Step 3: Write minimal implementation**

In `src/schema.jl`, insert after `_apply_column_selection` (after the closing `end` around line 209), before the `schema()` generic section:

```julia
# ---------------------------------------------------------------------------
# _parse_type_string — map type name strings to FW descriptors
# ---------------------------------------------------------------------------

"""
    _parse_type_string(s::AbstractString) → descriptor

Map a type name string to a field-type descriptor instance.

Supported strings: `"String"`, `"Int"`, `"Float64"`, `"Skip"`, `"Date"`,
`"Date(fmt)"`, `"FixedPoint(n)"`.
"""
function _parse_type_string(s::AbstractString)
    s = strip(s)
    s == "String"  && return FWString()
    s == "Int"     && return FWInt()
    s == "Float64" && return FWFloat()
    s == "Skip"    && return FWSkip()
    s == "Date"    && return FWDate("yyyymmdd")

    # Date(fmt)
    m = match(r"^Date\((.+)\)$", s)
    if m !== nothing
        return FWDate(m.captures[1])
    end

    # FixedPoint(n)
    m = match(r"^FixedPoint\((\d+)\)$", s)
    if m !== nothing
        return FWFixedPoint(parse(Int, m.captures[1]))
    end

    throw(ArgumentError("unknown type string \"$s\""))
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema.jl test/test_schema_loading.jl test/runtests.jl
git commit -m "feat: add _parse_type_string helper for type name mapping"
```

---

### Task 2: Range-based and start+width `FixedWidthSchema` constructors + tests

**Files:**
- Modify: `src/schema.jl` (refactor inner constructor, add new constructors)
- Modify: `test/test_schema_loading.jl`

**Step 1: Write the failing test**

Add to `test/test_schema_loading.jl` inside `"Schema Loading"`:

```julia
    @testset "Range-based FixedWidthSchema" begin
        using FixedWidthParsers: record_width, field_names, field_offsets, n_fields

        @testset "basic range construction" begin
            s = FixedWidthSchema(
                :carrier => (1:2, FWString()),
                :fnum    => (3:6, FWInt()),
                :origin  => (7:9, FWString()),
            )
            @test record_width(s) == 9
            @test field_names(s) == (:carrier, :fnum, :origin)
            @test field_offsets(s) == (1, 3, 7)
        end

        @testset "gap auto-fills with FWSkip" begin
            s = FixedWidthSchema(
                :carrier => (1:2, FWString()),
                :origin  => (7:9, FWString()),
            )
            @test record_width(s) == 9
            @test n_fields(s) == 3  # carrier, _skip_3_6, origin
            @test field_offsets(s) == (1, 3, 7)
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 4
        end

        @testset "fields need not be in order" begin
            s = FixedWidthSchema(
                :origin  => (7:9, FWString()),
                :carrier => (1:2, FWString()),
            )
            @test field_names(s) == (:carrier, :_skip_3_6, :origin)
            @test field_offsets(s) == (1, 3, 7)
        end

        @testset "overlapping fields throw" begin
            @test_throws ArgumentError FixedWidthSchema(
                :a => (1:5, FWString()),
                :b => (3:7, FWString()),
            )
        end

        @testset "record_width keyword extends schema" begin
            s = FixedWidthSchema(
                :a => (1:2, FWString());
                record_width=10,
            )
            @test record_width(s) == 10
            @test n_fields(s) == 2  # a, trailing skip
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 8
        end

        @testset "record_width keyword too small throws" begin
            @test_throws ArgumentError FixedWidthSchema(
                :a => (1:5, FWString());
                record_width=3,
            )
        end

        @testset "gap at start fills with FWSkip" begin
            s = FixedWidthSchema(
                :a => (5:7, FWString()),
            )
            @test record_width(s) == 7
            @test n_fields(s) == 2  # leading skip, a
            @test s.fields[1].type isa FWSkip
            @test s.fields[1].width == 4
            @test field_offsets(s) == (1, 5)
        end
    end

    @testset "Start+width FixedWidthSchema" begin
        using FixedWidthParsers: record_width, field_names, field_offsets

        @testset "basic start+width construction" begin
            s = FixedWidthSchema(
                :carrier => (1, 2, FWString()),
                :fnum    => (3, 4, FWInt()),
            )
            @test record_width(s) == 6
            @test field_names(s) == (:carrier, :fnum)
            @test field_offsets(s) == (1, 3)
        end

        @testset "start+width with gap" begin
            s = FixedWidthSchema(
                :carrier => (1, 2, FWString()),
                :origin  => (7, 3, FWString()),
            )
            @test record_width(s) == 9
            @test s.fields[2].type isa FWSkip
        end
    end

    @testset "Mixing modes throws" begin
        @test_throws ArgumentError FixedWidthSchema(
            :a => (2, FWString()),
            :b => (3:5, FWString()),
        )
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `FixedWidthSchema` does not accept range-based pairs

**Step 3: Write minimal implementation**

Refactor `FixedWidthSchema` in `src/schema.jl`. Replace the existing `struct FixedWidthSchema` block (lines 67-88) with:

```julia
struct FixedWidthSchema
    fields::Vector{FieldSpec}
    record_width::Int
    offsets::Vector{Int}
    _output_fields::Vector{FieldSpec}   # non-skip fields (cached)
    _output_names::Tuple                # Tuple of Symbol names for non-skip fields

    # Private inner constructor — takes a pre-built FieldSpec vector and record width.
    # All public constructors normalize their input and delegate here.
    function FixedWidthSchema(fields::Vector{FieldSpec}, rw::Int)
        offsets = [f.offset for f in fields]
        out_fields = [f for f in fields if !(f.type isa FWSkip)]
        out_names = Tuple(f.name for f in out_fields)
        return new(fields, rw, offsets, out_fields, out_names)
    end
end

# --- Width-based constructor (original API) ---

"""
    FixedWidthSchema(pairs::Pair{Symbol}...)

Construct a schema from contiguous `(width, descriptor)` pairs.
Offsets are computed automatically from left to right.

```julia
FixedWidthSchema(:carrier => (2, FWString()), :fnum => (4, FWInt()))
```
"""
function FixedWidthSchema(pairs::Pair{Symbol, <:Tuple{Int, Any}}...)
    fields = FieldSpec[]
    offset = 1
    for (name, (width, type)) in pairs
        push!(fields, FieldSpec(name, width, type, offset))
        offset += width
    end
    return FixedWidthSchema(fields, offset - 1)
end

# --- Range-based constructor ---

"""
    FixedWidthSchema(pairs::Pair{Symbol, <:Tuple{UnitRange{Int}, Any}}...; record_width=nothing)

Construct a schema from `(start:end, descriptor)` pairs.
Fields are sorted by start byte. Gaps are auto-filled with `FWSkip`.

```julia
FixedWidthSchema(:carrier => (1:2, FWString()), :origin => (7:9, FWString()))
```
"""
function FixedWidthSchema(
    pairs::Pair{Symbol, <:Tuple{UnitRange{Int}, Any}}...;
    record_width::Union{Int, Nothing}=nothing,
)
    _build_from_ranges(pairs, record_width)
end

# --- Start+width constructor ---

"""
    FixedWidthSchema(pairs::Pair{Symbol, <:Tuple{Int, Int, Any}}...; record_width=nothing)

Construct a schema from `(start, width, descriptor)` 3-tuples.
Converted to ranges internally.

```julia
FixedWidthSchema(:carrier => (1, 2, FWString()), :fnum => (3, 4, FWInt()))
```
"""
function FixedWidthSchema(
    pairs::Pair{Symbol, <:Tuple{Int, Int, Any}}...;
    record_width::Union{Int, Nothing}=nothing,
)
    # Convert (start, width, type) to (start:start+width-1, type)
    range_pairs = [name => (start:start+width-1, type) for (name, (start, width, type)) in pairs]
    _build_from_ranges(range_pairs, record_width)
end

"""
    _build_from_ranges(pairs, record_width) → FixedWidthSchema

Shared implementation for range-based and start+width constructors.
Sorts by start byte, inserts FWSkip for gaps, validates no overlaps.
"""
function _build_from_ranges(pairs, record_width::Union{Int, Nothing})
    # Sort by start byte
    sorted = sort(collect(pairs); by = p -> first(p.second[1]))

    # Validate no overlaps and build fields with gap-filling
    fields = FieldSpec[]
    cursor = 1  # next expected byte position

    for (name, (range, type)) in sorted
        start = first(range)
        stop = last(range)
        width = stop - start + 1

        if start < cursor
            # Find which previous field overlaps
            prev = fields[end]
            prev_end = prev.offset + prev.width - 1
            overlap_start = max(start, prev.offset)
            overlap_end = min(stop, prev_end)
            throw(ArgumentError(
                "fields :$(prev.name) and :$name overlap at bytes $overlap_start-$overlap_end"
            ))
        end

        # Insert FWSkip for gap
        if start > cursor
            gap_width = start - cursor
            gap_name = Symbol("_skip_$(cursor)_$(start - 1)")
            push!(fields, FieldSpec(gap_name, gap_width, FWSkip(), cursor))
        end

        push!(fields, FieldSpec(name, width, type, start))
        cursor = stop + 1
    end

    # Determine final record width
    natural_width = cursor - 1
    if record_width !== nothing
        if record_width < natural_width
            throw(ArgumentError(
                "record_width=$record_width is less than the end of the last field ($natural_width)"
            ))
        end
        if record_width > natural_width
            gap_width = record_width - natural_width
            gap_name = Symbol("_skip_$(cursor)_$(record_width)")
            push!(fields, FieldSpec(gap_name, gap_width, FWSkip(), cursor))
        end
        rw = record_width
    else
        rw = natural_width
    end

    return FixedWidthSchema(fields, rw)
end
```

**Important:** The existing width-based constructor's `Pair{Symbol}...` signature currently has no type constraint on the pair value. Adding `Pair{Symbol, <:Tuple{Int, Any}}` makes it unambiguous. However, this may break existing call sites where Julia's type inference produces a less specific type. If tests fail on existing `FixedWidthSchema` calls, the fix is to make the width-based constructor a catch-all that checks the first pair's value type at runtime:

If the typed dispatch doesn't work cleanly, use this fallback approach instead — a single outer constructor that inspects the first pair's value to determine the mode:

```julia
function FixedWidthSchema(pairs::Pair{Symbol}...; record_width::Union{Int, Nothing}=nothing)
    isempty(pairs) && return FixedWidthSchema(FieldSpec[], 0)

    # Determine mode from first pair's value
    first_val = pairs[1].second
    if first_val isa Tuple{UnitRange{Int}, Any}
        # Range mode
        _build_from_ranges(pairs, record_width)
    elseif first_val isa Tuple{Int, Int, Any}
        # Start+width mode — convert to ranges
        range_pairs = [name => (s:s+w-1, type) for (name, (s, w, type)) in pairs]
        _build_from_ranges(range_pairs, record_width)
    elseif first_val isa Tuple{Int, Any}
        # Width mode (original)
        record_width !== nothing && throw(ArgumentError(
            "record_width keyword is only supported with range-based or start+width constructors"
        ))
        fields = FieldSpec[]
        offset = 1
        for (name, (width, type)) in pairs
            push!(fields, FieldSpec(name, width, type, offset))
            offset += width
        end
        FixedWidthSchema(fields, offset - 1)
    else
        throw(ArgumentError(
            "unsupported pair value type: $(typeof(first_val)). " *
            "Expected (width, type), (start:end, type), or (start, width, type)"
        ))
    end
end
```

Use whichever approach results in all existing tests passing. The runtime dispatch approach is safer since it avoids Julia's complex dispatch interactions with `Pair{Symbol}` types. The key requirement is: existing `(width, type)` API must continue working identically.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS (both new and existing)

**Step 5: Commit**

```bash
git add src/schema.jl test/test_schema_loading.jl
git commit -m "feat: add range-based and start+width FixedWidthSchema constructors"
```

---

### Task 3: `load_schema` for CSV and TOML + tests

**Files:**
- Create: `src/schema_io.jl`
- Modify: `src/FixedWidthParsers.jl` (add include and export)
- Modify: `test/test_schema_loading.jl`

**Step 1: Write the failing test**

Add to `test/test_schema_loading.jl` inside `"Schema Loading"`:

```julia
    @testset "load_schema CSV" begin
        using FixedWidthParsers: record_width, field_names

        @testset "basic CSV loading" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,String")
                println(io, "fnum,3,6,Int")
                println(io, "origin,7,9,String")
            end
            s = load_schema(path)
            @test record_width(s) == 9
            @test s._output_names == (:carrier, :fnum, :origin)
            rm(path)
        end

        @testset "CSV with extra columns" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type,description")
                println(io, "carrier,1,2,String,Airline code")
                println(io, "fnum,3,6,Int,Flight number")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV with comments and blank lines" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "# This is a comment")
                println(io, "name,start,end,type")
                println(io, "")
                println(io, "carrier,1,2,String")
                println(io, "# Another comment")
                println(io, "fnum,3,6,Int")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV column order independent" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "type,end,name,start")
                println(io, "String,2,carrier,1")
                println(io, "Int,6,fnum,3")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV missing required column throws" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,type")
                println(io, "carrier,1,String")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end

        @testset "CSV with gap auto-fills FWSkip" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,String")
                println(io, "origin,7,9,String")
            end
            s = load_schema(path)
            @test record_width(s) == 9
            # Gap at bytes 3-6 should be auto-filled
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 4
            rm(path)
        end

        @testset "CSV unknown type throws" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,Boolean")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end
    end

    @testset "load_schema TOML" begin
        using FixedWidthParsers: record_width

        @testset "basic TOML loading" begin
            path = tempname() * ".toml"
            open(path, "w") do io
                println(io, "[[fields]]")
                println(io, "name = \"carrier\"")
                println(io, "start = 1")
                println(io, "end = 2")
                println(io, "type = \"String\"")
                println(io, "")
                println(io, "[[fields]]")
                println(io, "name = \"fnum\"")
                println(io, "start = 3")
                println(io, "end = 6")
                println(io, "type = \"Int\"")
            end
            s = load_schema(path)
            @test record_width(s) == 6
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "TOML missing field key throws" begin
            path = tempname() * ".toml"
            open(path, "w") do io
                println(io, "[[fields]]")
                println(io, "name = \"carrier\"")
                println(io, "start = 1")
                println(io, "type = \"String\"")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end
    end

    @testset "load_schema unsupported extension" begin
        path = tempname() * ".xml"
        open(path, "w") do io
            println(io, "<schema/>")
        end
        @test_throws ArgumentError load_schema(path)
        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `load_schema` not defined

**Step 3: Write minimal implementation**

Create `src/schema_io.jl`:

```julia
"""
    schema_io.jl — Load FixedWidthSchema definitions from CSV, TOML, and JSON files.
"""

import TOML

"""
    load_schema(path::AbstractString; record_width=nothing) → FixedWidthSchema

Load a schema definition from a file. The file format is determined by
the file extension:

- `.csv` — comma-separated with `name,start,end,type` columns
- `.toml` — TOML with `[[fields]]` array of tables
- `.json` — JSON with `{"fields": [...]}` (requires `using JSON3`)

# Keyword Arguments
- `record_width=nothing` — optional total record width; if provided,
  trailing bytes are filled with `FWSkip`

# Examples

```julia
schema = load_schema("flights.csv")
schema = load_schema("flights.toml")
schema = load_schema("flights.json")  # requires JSON3
```
"""
function load_schema(path::AbstractString; record_width::Union{Int, Nothing}=nothing)
    ext = lowercase(splitext(path)[2])
    if ext == ".csv"
        return _load_schema_csv(path; record_width=record_width)
    elseif ext == ".toml"
        return _load_schema_toml(path; record_width=record_width)
    elseif ext == ".json"
        return _load_schema_json(path; record_width=record_width)
    else
        throw(ArgumentError("unsupported schema file extension: $ext"))
    end
end

# --- CSV ---

function _load_schema_csv(path::AbstractString; record_width::Union{Int, Nothing}=nothing)
    lines = readlines(path)

    # Filter out blank lines and comments
    lines = filter(l -> !isempty(strip(l)) && !startswith(strip(l), '#'), lines)
    isempty(lines) && throw(ArgumentError("schema CSV file is empty"))

    # Parse header
    header = Symbol.(strip.(split(lines[1], ',')))
    required = [:name, :start, :end, :type]
    for col in required
        col in header || throw(ArgumentError("schema CSV missing required column: $col"))
    end

    # Column indices
    idx = Dict(col => findfirst(==(col), header) for col in required)

    # Parse data rows
    pairs = Pair{Symbol, Tuple{UnitRange{Int}, Any}}[]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        startswith(strip(line), '#') && continue
        parts = strip.(split(line, ','))
        name = Symbol(parts[idx[:name]])
        start_byte = parse(Int, parts[idx[:start]])
        end_byte = parse(Int, parts[idx[:end]])
        type_desc = _parse_type_string(parts[idx[:type]])
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end

# --- TOML ---

function _load_schema_toml(path::AbstractString; record_width::Union{Int, Nothing}=nothing)
    data = TOML.parsefile(path)
    haskey(data, "fields") || throw(ArgumentError("TOML schema file missing [fields] section"))
    field_defs = data["fields"]

    pairs = Pair{Symbol, Tuple{UnitRange{Int}, Any}}[]
    for (i, fd) in enumerate(field_defs)
        for key in ("name", "start", "end", "type")
            haskey(fd, key) || throw(ArgumentError(
                "TOML field entry $i missing required key: $key"
            ))
        end
        name = Symbol(fd["name"])
        start_byte = fd["start"]::Int
        end_byte = fd["end"]::Int
        type_desc = _parse_type_string(fd["type"])
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthSchema(pairs...; record_width=record_width)
end

# --- JSON (stub — real implementation in extension) ---

function _load_schema_json(path::AbstractString; record_width::Union{Int, Nothing}=nothing)
    throw(ArgumentError(
        "JSON schema loading requires JSON3.jl. Run `using JSON3` before calling load_schema."
    ))
end
```

Add to `src/FixedWidthParsers.jl`:

```julia
include("schema_io.jl")
```

after `include("materialization.jl")`, and add `load_schema` to the export list.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema_io.jl src/FixedWidthParsers.jl test/test_schema_loading.jl
git commit -m "feat: add load_schema for CSV and TOML files"
```

---

### Task 4: JSON3 package extension for `load_schema` + tests

**Files:**
- Modify: `Project.toml` (add JSON3 as extension dependency)
- Create: `ext/JSON3Ext.jl`
- Modify: `src/schema_io.jl` (remove stub, make extensible)
- Modify: `test/test_schema_loading.jl`

**Step 1: Write the failing test**

Add to `test/test_schema_loading.jl` inside `"Schema Loading"`:

```julia
    @testset "load_schema JSON" begin
        using JSON3
        using FixedWidthParsers: record_width

        @testset "basic JSON loading" begin
            path = tempname() * ".json"
            open(path, "w") do io
                write(io, """
                {
                    "fields": [
                        {"name": "carrier", "start": 1, "end": 2, "type": "String"},
                        {"name": "fnum", "start": 3, "end": 6, "type": "Int"}
                    ]
                }
                """)
            end
            s = load_schema(path)
            @test record_width(s) == 6
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "JSON with gap" begin
            path = tempname() * ".json"
            open(path, "w") do io
                write(io, """
                {
                    "fields": [
                        {"name": "carrier", "start": 1, "end": 2, "type": "String"},
                        {"name": "origin", "start": 7, "end": 9, "type": "String"}
                    ]
                }
                """)
            end
            s = load_schema(path)
            @test record_width(s) == 9
            @test s.fields[2].type isa FWSkip
            rm(path)
        end
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — JSON3 extension not yet set up

**Step 3: Write minimal implementation**

**Part A: Update `Project.toml`**

Add JSON3 to `[weakdeps]` and define the extension:

```toml
[weakdeps]
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"

[extensions]
JSON3Ext = "JSON3"
```

Also add JSON3 to `[extras]` and to the `test` target so tests can load it:

```toml
[extras]
BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
PkgBenchmark = "32113eaa-f34f-5b0d-bd6c-c81e245fc73d"
Tables = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
benchmark = ["BenchmarkTools", "PkgBenchmark"]
test = ["JSON3", "Tables", "Test"]
```

**Part B: Create `ext/JSON3Ext.jl`**

```julia
module JSON3Ext

using FixedWidthParsers
import JSON3

function FixedWidthParsers._load_schema_json(
    path::AbstractString;
    record_width::Union{Int, Nothing}=nothing,
)
    data = JSON3.read(read(path, String))
    haskey(data, :fields) || throw(ArgumentError("JSON schema file missing \"fields\" key"))
    field_defs = data[:fields]

    pairs = Pair{Symbol, Tuple{UnitRange{Int}, Any}}[]
    for (i, fd) in enumerate(field_defs)
        for key in (:name, :start, :end, :type)
            haskey(fd, key) || throw(ArgumentError(
                "JSON field entry $i missing required key: $key"
            ))
        end
        name = Symbol(fd[:name])
        start_byte = fd[:start]::Int
        end_byte = fd[:end]::Int
        type_desc = FixedWidthParsers._parse_type_string(fd[:type])
        push!(pairs, name => (start_byte:end_byte, type_desc))
    end

    return FixedWidthParsers.FixedWidthSchema(pairs...; record_width=record_width)
end

end # module
```

**Part C: Update `src/schema_io.jl`**

The `_load_schema_json` stub in `src/schema_io.jl` remains as the fallback when JSON3 is not loaded. The extension overrides it. No changes needed — the stub already throws the right error.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

Note: If JSON3 is not installed in the test environment, first run:
`julia --project -e 'using Pkg; Pkg.add("JSON3")'`

**Step 5: Commit**

```bash
git add Project.toml ext/JSON3Ext.jl test/test_schema_loading.jl
git commit -m "feat: add JSON3 package extension for load_schema"
```

---

### Task 5: Round-trip integration test + docstrings + docs

**Files:**
- Modify: `test/test_schema_loading.jl`
- Modify: `docs/src/index.md`
- Modify: `README.md`

**Step 1: Write the integration test**

Add to `test/test_schema_loading.jl` inside `"Schema Loading"`:

```julia
    @testset "Round-trip: load schema → parse file" begin
        using FixedWidthParsers: record_width

        # Create a data file
        data_path = tempname()
        open(data_path, "w") do io
            write(io, "UA1234ORD\n")
            write(io, "DL5678LAX\n")
        end

        # Create a CSV schema file
        csv_path = tempname() * ".csv"
        open(csv_path, "w") do io
            println(io, "name,start,end,type")
            println(io, "carrier,1,2,String")
            println(io, "fnum,3,6,Int")
            println(io, "origin,7,9,String")
        end

        schema = load_schema(csv_path)
        result = parse_file(data_path, schema)
        @test length(result) == 2
        @test result.carrier == ["UA", "DL"]
        @test result.fnum == [1234, 5678]
        @test result.origin == ["ORD", "LAX"]

        rm(data_path)
        rm(csv_path)
    end
```

**Step 2: Update docs and README**

Add a "Loading Schemas from Files" section to `docs/src/index.md` after "Column Selection":

```markdown
## Loading Schemas from Files

```julia
# Load from CSV (name, start, end, type columns)
schema = load_schema("flights.csv")

# Load from TOML
schema = load_schema("flights.toml")

# Load from JSON (requires `using JSON3`)
using JSON3
schema = load_schema("flights.json")
```

You can also construct schemas with explicit byte positions:

```julia
# Range-based: specify start:end for each field
schema = FixedWidthSchema(
    :carrier => (1:2, FWString()),
    :fnum    => (3:6, FWInt()),
    :origin  => (10:12, FWString()),  # gap at 7-9 auto-fills with FWSkip
)

# Start+width: specify (start, width, descriptor)
schema = FixedWidthSchema(
    :carrier => (1, 2, FWString()),
    :fnum    => (3, 4, FWInt()),
)
```
```

Add the same section to `README.md` in the appropriate location (after "Column Selection").

Add a `load_schema` bullet to the Features list in `README.md`:

```
- **Schema file loading** — `load_schema` reads schemas from CSV, TOML, and JSON files
```

**Step 3: Run tests and verify docs build**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

Run: `julia --project=docs docs/make.jl`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add test/test_schema_loading.jl docs/src/index.md README.md
git commit -m "docs: document byte-range schemas and load_schema"
```
