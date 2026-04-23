# Column Selection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `select` and `exclude` keyword arguments to `parse_file` and `eachrecord` so users can parse only a subset of columns.

**Architecture:** A helper `_apply_column_selection` transforms the schema by converting excluded fields to `FWSkip`, reusing the existing skip machinery. No changes to inner loop code. The helper is called at the top of every entry point before any parsing begins.

**Tech Stack:** Julia, FixedWidthParsers.jl internals (FixedWidthSchema, FieldSpec, FWSkip)

---

### Task 1: `_apply_column_selection` helper + unit tests

**Files:**
- Modify: `src/schema.jl` (insert after `non_skip_indices`, around line 137)
- Create: `test/test_column_selection.jl`
- Modify: `test/runtests.jl` (add include)

**Step 1: Write the failing test**

Create `test/test_column_selection.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _apply_column_selection, FieldSpec

@testset "Column Selection" begin
    @testset "_apply_column_selection" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_pad    => (1, FWSkip()),
            :origin  => (3, FWString()),
        )

        @testset "both nothing returns same schema" begin
            result = _apply_column_selection(schema, nothing, nothing)
            @test result === schema
        end

        @testset "select keeps only named columns" begin
            result = _apply_column_selection(schema, [:carrier, :origin], nothing)
            @test length(result._output_fields) == 2
            @test result._output_names == (:carrier, :origin)
            @test record_width(result) == record_width(schema)
        end

        @testset "exclude removes named columns" begin
            result = _apply_column_selection(schema, nothing, [:fnum])
            @test length(result._output_fields) == 2
            @test result._output_names == (:carrier, :origin)
            @test record_width(result) == record_width(schema)
        end

        @testset "both provided throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, [:carrier], [:fnum])
        end

        @testset "unknown column in select throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, [:nonexistent], nothing)
        end

        @testset "unknown column in exclude throws ArgumentError" begin
            @test_throws ArgumentError _apply_column_selection(schema, nothing, [:nonexistent])
        end

        @testset "select preserves existing FWSkip fields" begin
            result = _apply_column_selection(schema, [:carrier], nothing)
            # _pad was already FWSkip, carrier is kept, fnum+origin become FWSkip
            @test length(result._output_fields) == 1
            @test result._output_names == (:carrier,)
            @test record_width(result) == record_width(schema)
        end

        @testset "exclude a FWSkip field is a no-op" begin
            result = _apply_column_selection(schema, nothing, [:_pad])
            # _pad was already FWSkip — excluding it changes nothing
            @test result._output_names == (:carrier, :fnum, :origin)
        end
    end
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with "UndefVarError: _apply_column_selection not defined"

**Step 3: Write minimal implementation**

In `src/schema.jl`, insert after `non_skip_indices` (after line 137):

```julia
"""
    _apply_column_selection(schema, select, exclude) → FixedWidthSchema

Return a new schema with column selection applied. Excluded fields are
converted to `FWSkip`, preserving the record width and byte offsets.

- `select::Union{Vector{Symbol}, Nothing}` — keep only these columns
- `exclude::Union{Vector{Symbol}, Nothing}` — drop these columns
- Both `nothing` → return original schema unchanged
- Both provided → `ArgumentError`
- Unknown column name → `ArgumentError`
"""
function _apply_column_selection(
    schema::FixedWidthSchema,
    select::Union{AbstractVector{Symbol}, Nothing},
    exclude::Union{AbstractVector{Symbol}, Nothing},
)
    # Fast path: no selection
    if select === nothing && exclude === nothing
        return schema
    end

    # Validate: can't have both
    if select !== nothing && exclude !== nothing
        throw(ArgumentError("cannot specify both `select` and `exclude`"))
    end

    all_names = Set(f.name for f in schema.fields)

    if select !== nothing
        for s in select
            s in all_names || throw(ArgumentError("unknown column :$s in `select`"))
        end
        keep = Set(select)
    else
        for s in exclude
            s in all_names || throw(ArgumentError("unknown column :$s in `exclude`"))
        end
        keep = setdiff(all_names, Set(exclude))
    end

    # Build new schema with non-kept fields converted to FWSkip
    pairs = Pair{Symbol}[]
    for f in schema.fields
        if f.name in keep || f.type isa FWSkip
            push!(pairs, f.name => (f.width, f.type))
        else
            push!(pairs, f.name => (f.width, FWSkip()))
        end
    end

    return FixedWidthSchema(pairs...)
end
```

Add `include("test_column_selection.jl")` to `test/runtests.jl` after the last include.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema.jl test/test_column_selection.jl test/runtests.jl
git commit -m "feat: add _apply_column_selection helper"
```

---

### Task 2: `select`/`exclude` keywords on `parse_file`

**Files:**
- Modify: `src/materialization.jl:72-81` (parse_file signature)
- Modify: `test/test_column_selection.jl`

**Step 1: Write the failing test**

Add to `test/test_column_selection.jl` inside `"Column Selection"`:

```julia
    @testset "parse_file with select" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; select=[:name, :code])
        @test length(result) == 2
        @test hasproperty(result, :name)
        @test hasproperty(result, :code)
        @test !hasproperty(result, :val)
        @test result.name == ["foo", "bar"]
        @test result.code == ["AB", "CD"]
        rm(path)
    end

    @testset "parse_file with exclude" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; exclude=[:val])
        @test length(result) == 2
        @test hasproperty(result, :name)
        @test hasproperty(result, :code)
        @test !hasproperty(result, :val)
        rm(path)
    end

    @testset "parse_file select + exclude throws" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
        end

        @test_throws ArgumentError parse_file(path, schema; select=[:name], exclude=[:val])
        rm(path)
    end

    @testset "parse_file with select row-oriented" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; columnar=false, select=[:name])
        @test length(result) == 2
        @test haskey(result[1], :name)
        @test !haskey(result[1], :val)
        rm(path)
    end

    @testset "parse_file with select + parallel" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "AB\n")
            end
        end

        baseline = parse_file(path, schema; select=[:name, :code], ntasks=1)
        result = parse_file(path, schema; select=[:name, :code], ntasks=4)
        @test result.name == baseline.name
        @test result.code == baseline.code
        rm(path)
    end

    @testset "parse_file with select + skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --HH\n")
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        result = parse_file(path, schema; select=[:name], skip_header=1)
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test !hasproperty(result, :val)
        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `parse_file` does not accept `select` keyword

**Step 3: Write minimal implementation**

Update `parse_file` in `src/materialization.jl` (lines 72-81). Add keywords to signature and apply selection at the top:

```julia
function parse_file(
    path::AbstractString,
    schema::FixedWidthSchema;
    columnar::Bool=true,
    on_error::Symbol=:strict,
    ntasks::Int=1,
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    src = MmapSource(path, record_width(schema))
    # ... rest unchanged
```

The `_apply_column_selection` call is the ONLY change to the function body — everything after operates on the (possibly filtered) schema, and the existing `FWSkip` handling does the rest.

Also update the `parse_file` docstring to document the new keywords.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/materialization.jl test/test_column_selection.jl
git commit -m "feat: add select/exclude keywords to parse_file"
```

---

### Task 3: `select`/`exclude` on `eachrecord` and `@fixedwidth` dispatch

**Files:**
- Modify: `src/iteration.jl:60-66,105-111` (both eachrecord overloads)
- Modify: `src/schema.jl:308-344` (@fixedwidth dispatch)
- Modify: `src/materialization.jl` (_parse_file_generated signature)
- Modify: `test/test_column_selection.jl`

**Step 1: Write the failing test**

Add to `test/test_column_selection.jl`:

```julia
    @testset "eachrecord with select" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10AB\n")
            write(io, "bar  20CD\n")
        end

        records = collect(eachrecord(path, schema; select=[:name]))
        @test length(records) == 2
        @test haskey(records[1], :name)
        @test !haskey(records[1], :val)
        @test records[1].name == "foo"
        rm(path)
    end

    @testset "eachrecord IO with exclude" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
            :code => (2, FWString()),
        )

        data = "foo  10AB\nbar  20CD\n"
        io = IOBuffer(data)

        records = collect(eachrecord(io, schema; exclude=[:val]))
        @test length(records) == 2
        @test haskey(records[1], :name)
        @test haskey(records[1], :code)
        @test !haskey(records[1], :val)
    end

    @testset "@fixedwidth with select" begin
        @fixedwidth struct ColSelFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
        end

        path = tempname()
        open(path, "w") do io
            for i in 1:10
                write(io, "UA" * lpad(string(i), 4) * "ORD\n")
            end
        end

        result = parse_file(path, ColSelFlight; select=[:carrier, :origin])
        @test length(result) == 10
        @test hasproperty(result, :carrier)
        @test hasproperty(result, :origin)
        @test !hasproperty(result, :number)

        records = collect(eachrecord(path, ColSelFlight; select=[:carrier]))
        @test length(records) == 10
        @test haskey(records[1], :carrier)
        @test !haskey(records[1], :number)

        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `eachrecord` does not accept `select` keyword

**Step 3: Write minimal implementation**

**Part A:** Update both `eachrecord` overloads in `src/iteration.jl`. Add `select` and `exclude` keywords, apply selection before constructing iterator:

```julia
function eachrecord(
    path::AbstractString,
    schema::FixedWidthSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
)
    schema = _apply_column_selection(schema, select, exclude)
    src = MmapSource(path, record_width(schema))
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return RecordIterator(src, schema, indices)
end
```

Same pattern for the IO overload.

**Part B:** Update `@fixedwidth` macro dispatch in `src/schema.jl`. Add `select` and `exclude` keywords to both `parse_file` and `eachrecord` dispatches, passing them through:

For `parse_file` dispatch (lines 308-328): add keywords, pass to `_parse_file_generated` and the runtime fallback.

For `eachrecord` dispatch (lines 330-344): add keywords, pass through.

**Part C:** Update `_parse_file_generated` in `src/materialization.jl` to accept and apply `select`/`exclude`:

```julia
function _parse_file_generated(
    path::AbstractString, ::Type{T}, on_error::Symbol, ntasks::Int,
    skip_header::Int=0, skip_footer::Int=0, comment::Union{UInt8, Nothing}=nothing,
    select::Union{AbstractVector{Symbol}, Nothing}=nothing,
    exclude::Union{AbstractVector{Symbol}, Nothing}=nothing,
) where T
    sch = schema(T)
    sch = _apply_column_selection(sch, select, exclude)
    _SCHEMA_CACHE[T] = sch
    # ... rest unchanged
```

Note: When `select`/`exclude` is active with `@fixedwidth` and `ntasks <= 1`, the generated path still works because `_SCHEMA_CACHE[T]` gets the filtered schema and `_parse_columnar_generated` reads from it.

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/iteration.jl src/schema.jl src/materialization.jl test/test_column_selection.jl
git commit -m "feat: add select/exclude to eachrecord and @fixedwidth dispatch"
```

---

### Task 4: Update docstrings, docs, and README

**Files:**
- Modify: `src/materialization.jl` (parse_file docstring — already updated in Task 2)
- Modify: `src/iteration.jl` (eachrecord docstrings)
- Modify: `docs/src/index.md`
- Modify: `README.md`

**Step 1: Update `eachrecord` docstrings**

Add to both `eachrecord` docstrings' `# Keyword Arguments` sections:

```
- `select=nothing`  — `Vector{Symbol}` of columns to include (others become `FWSkip`)
- `exclude=nothing` — `Vector{Symbol}` of columns to exclude (mutually exclusive with `select`)
```

**Step 2: Update `docs/src/index.md`**

Add a section after "Skipping Headers, Footers, and Comments":

```markdown
## Column Selection

```julia
# Parse only specific columns
sa = parse_file("data.dat", schema; select=[:carrier, :origin])

# Exclude columns you don't need
sa = parse_file("data.dat", schema; exclude=[:_pad, :revenue])
```
```

**Step 3: Update `README.md`**

Add a "Column Selection" section after "Skipping Headers, Footers, and Comments":

```markdown
## Column Selection

```julia
# Parse only specific columns
sa = parse_file("flights.dat", schema; select=[:carrier, :origin])

# Exclude columns you don't need
sa = parse_file("flights.dat", schema; exclude=[:fnum])
```
```

**Step 4: Verify docs build**

Run: `julia --project=docs docs/make.jl`
Expected: Build succeeds with no errors

**Step 5: Commit**

```bash
git add src/iteration.jl docs/src/index.md README.md
git commit -m "docs: document select/exclude keywords"
```
