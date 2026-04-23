# Header/Footer/Comment Skipping Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `skip_header`, `skip_footer`, and `comment` keyword arguments to `parse_file` and `eachrecord` so users can skip non-data records.

**Architecture:** Pre-scan the mmap buffer to build a `Vector{Int}` of valid record indices (excluding headers, footers, and comment lines). Pass this index to the existing columnar/row/iterator paths. When no filtering is needed, return `nothing` to preserve the existing fast path unchanged.

**Tech Stack:** Julia, FixedWidthParsers.jl internals (MmapSource, FixedWidthSchema, _fill_column!, RecordIterator)

---

### Task 1: `_valid_record_indices` helper + unit tests

**Files:**
- Modify: `src/materialization.jl:88-105` (insert after `_partition_ranges`)
- Create: `test/test_skipping.jl`
- Modify: `test/runtests.jl:16` (add include)

**Step 1: Write the failing test**

Create `test/test_skipping.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _valid_record_indices, MmapSource, record_width

@testset "Record Skipping" begin
    @testset "_valid_record_indices" begin
        # Helper: create a temp file with N fixed-width records (width=4, LF newlines)
        function make_test_file(lines::Vector{String})
            path = tempname()
            open(path, "w") do io
                for line in lines
                    write(io, line * "\n")
                end
            end
            return path
        end

        @testset "no filtering returns nothing" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 0, nothing) === nothing
            close(src)
            rm(path)
        end

        @testset "skip_header only" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 2, 0, nothing) == [3, 4]
            close(src)
            rm(path)
        end

        @testset "skip_footer only" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 1, nothing) == [1, 2, 3]
            close(src)
            rm(path)
        end

        @testset "skip_header + skip_footer" begin
            path = make_test_file(["AAAA", "BBBB", "CCCC", "DDDD"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 1, 1, nothing) == [2, 3]
            close(src)
            rm(path)
        end

        @testset "comment filtering" begin
            path = make_test_file(["#HDR", "AAAA", "#CMT", "BBBB"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 0, 0, UInt8('#')) == [2, 4]
            close(src)
            rm(path)
        end

        @testset "all three combined" begin
            path = make_test_file(["#HDR", "HDR2", "AAAA", "#CMT", "BBBB", "FTR1"])
            src = MmapSource(path, 4)
            # skip_header=1 removes "#HDR", skip_footer=1 removes "FTR1"
            # comment='#' removes "#CMT"
            # remaining from range 2:5 minus comment at 4 → [2, 3, 5]
            @test _valid_record_indices(src, 1, 1, UInt8('#')) == [2, 3, 5]
            close(src)
            rm(path)
        end

        @testset "skip everything returns empty" begin
            path = make_test_file(["AAAA", "BBBB"])
            src = MmapSource(path, 4)
            @test _valid_record_indices(src, 2, 0, nothing) == Int[]
            @test _valid_record_indices(src, 0, 2, nothing) == Int[]
            @test _valid_record_indices(src, 1, 1, nothing) == Int[]
            @test _valid_record_indices(src, 10, 10, nothing) == Int[]
            close(src)
            rm(path)
        end
    end
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with "UndefVarError: _valid_record_indices not defined"

**Step 3: Write minimal implementation**

In `src/materialization.jl`, insert after `_partition_ranges` (after line 105):

```julia
"""
    _valid_record_indices(src, skip_header, skip_footer, comment) → Vector{Int} or nothing

Build a vector of valid 1-based record indices, excluding headers, footers,
and comment lines. Returns `nothing` when no filtering is needed (all three
parameters are at their defaults), signaling the caller to use the fast path.

Comment detection checks the first byte of each record slot against `comment`.
Comment lines must be the same fixed width as data records.
"""
function _valid_record_indices(
    src::AbstractSource,
    skip_header::Int,
    skip_footer::Int,
    comment::Union{UInt8, Nothing},
)
    n = record_count(src)
    lo = 1 + skip_header
    hi = n - skip_footer
    if lo > hi
        return Int[]
    end

    # No comment filter — return simple range as vector (or nothing for no-op)
    if comment === nothing
        if lo == 1 && hi == n
            return nothing  # fast path: no filtering needed
        end
        return collect(lo:hi)
    end

    # Comment filter: check first byte of each record slot
    buf = buffer(src)
    indices = Int[]
    sizehint!(indices, hi - lo + 1)
    for i in lo:hi
        pos = record_offset(src, i)
        if buf[pos] != comment
            push!(indices, i)
        end
    end
    return indices
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS (214 existing + new skipping tests)

**Step 5: Commit**

```bash
git add src/materialization.jl test/test_skipping.jl test/runtests.jl
git commit -m "feat: add _valid_record_indices helper for record skipping"
```

---

### Task 2: Indexed `_fill_column!` overloads

**Files:**
- Modify: `src/materialization.jl:231-352` (add indexed variants of _fill_column!)

**Step 1: Write the failing test**

Add to `test/test_skipping.jl` inside the `"Record Skipping"` testset:

```julia
    @testset "parse_file with skip_header" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")  # header line (same width=7)
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        result = parse_file(path, schema; skip_header=1)
        @test length(result) == 3
        @test result.name == ["foo", "bar", "baz"]
        @test result.val == [10, 20, 30]
        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `parse_file` does not accept `skip_header` keyword yet

**Step 3: Write minimal implementation**

This task has two parts:

**Part A:** Add indexed `_fill_column!` overloads in `src/materialization.jl`. Insert after the existing `_fill_string_column!` function (after line 352):

```julia
# ---------------------------------------------------------------------------
# Indexed variants: fill column using explicit record index vector
# ---------------------------------------------------------------------------

"""
    _fill_column!(col, descriptor, width, offset, name, buf, src, indices, range, on_error)

Fill column positions `range` using `indices[range]` for source record lookup.
Output position `j` in `range` maps to source record `indices[j]`.
"""
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
    else
        _fill_column_indexed_lenient!(col, descriptor, width, offset, name, buf, src, indices, record_range)
    end
end

@inline function _fill_column_indexed_strict!(
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
    try
        @inbounds for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            val = parse_field(descriptor, buf, field_pos, width)
            col[j] = _coerce(descriptor, width, val)
        end
    catch
        # Rescan to find the failing record and produce a rich ParseError
        for j in record_range
            src_i = indices[j]
            field_pos = record_offset(src, src_i) + offset - 1
            try
                parse_field(descriptor, buf, field_pos, width)
            catch e
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        src_i, col_range, raw, _julia_type(descriptor),
                        "Failed to parse field :$(name): $(sprint(showerror, e))",
                    ),
                )
            end
        end
    end
end

function _fill_column_indexed_lenient!(
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
    @inbounds for j in record_range
        src_i = indices[j]
        field_pos = record_offset(src, src_i) + offset - 1
        try
            val = parse_field(descriptor, buf, field_pos, width)
            col[j] = _coerce(descriptor, width, val)
        catch e
            @warn "Parse error at line $src_i, field :$(name)" exception = e
            col[j] = missing
        end
    end
end

# Indexed string specialization
function _fill_column!(
    col::AbstractVector,
    descriptor::FWString,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
    on_error::Symbol,
)
    ISType = _inline_string_type(width)
    _fill_string_column_indexed!(col, ISType, descriptor, width, offset, buf, src, indices, record_range)
end

function _fill_string_column_indexed!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    indices::Vector{Int},
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    empty_val = T("")
    @inbounds for j in record_range
        src_i = indices[j]
        field_pos = record_offset(src, src_i) + offset - 1
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        col[j] = actual_len <= 0 ? empty_val : _inline_from_buf(T, buf, field_pos, actual_len)
    end
end
```

**Part B:** Update `parse_file` signature and `_parse_columnar` / `_parse_rows` to accept and use the new keywords. Modify `parse_file` (lines 63-86):

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
)
    src = MmapSource(path, record_width(schema))
    n = record_count(src)

    if n == 0
        close(src)
        return columnar ? _empty_structarray(schema, on_error) : NamedTuple[]
    end

    buf = buffer(src)
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)

    # Fast path: no filtering — use existing direct paths
    if indices === nothing
        result = if columnar
            _parse_columnar(schema, src, buf, n, on_error, ntasks)
        else
            _parse_rows(schema, src, buf, n, on_error)
        end
        close(src)
        return result
    end

    # Filtered path
    nvalid = length(indices)
    if nvalid == 0
        close(src)
        return columnar ? _empty_structarray(schema, on_error) : NamedTuple[]
    end

    result = if columnar
        _parse_columnar_indexed(schema, src, buf, indices, on_error, ntasks)
    else
        _parse_rows_indexed(schema, src, buf, indices, on_error)
    end
    close(src)
    return result
end
```

**Part C:** Add `_parse_columnar_indexed` and `_parse_rows_indexed`. Insert after `_parse_rows` (after line 381):

```julia
"""
    _parse_columnar_indexed(schema, src, buf, indices, on_error, ntasks) → StructArray

Columnar parse using explicit record indices. Output columns have length
`length(indices)`. Supports parallel fill via `ntasks`.
"""
function _parse_columnar_indexed(
    schema::FixedWidthSchema,
    src::AbstractSource,
    buf::AbstractVector{UInt8},
    indices::Vector{Int},
    on_error::Symbol,
    ntasks::Int,
)
    ns_fields = schema._output_fields
    names = schema._output_names
    nvalid = length(indices)

    columns = if on_error === :lenient
        [Vector{Union{_julia_type(f.type, f.width), Missing}}(undef, nvalid) for f in ns_fields]
    else
        [Vector{_julia_type(f.type, f.width)}(undef, nvalid) for f in ns_fields]
    end

    ranges = _partition_ranges(nvalid, ntasks)

    for (col_idx, f) in enumerate(ns_fields)
        if length(ranges) == 1
            _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, indices, ranges[1], on_error)
        else
            try
                @sync for r in ranges
                    Threads.@spawn _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, indices, r, on_error)
                end
            catch e
                _rethrow_unwrapped(e)
            end
        end
    end

    col_nt = NamedTuple{names}(Tuple(columns))
    return StructArray(col_nt)
end

"""
    _parse_rows_indexed(schema, src, buf, indices, on_error) → Vector{NamedTuple}

Row-oriented parse using explicit record indices.
"""
function _parse_rows_indexed(
    schema::FixedWidthSchema,
    src::AbstractSource,
    buf::AbstractVector{UInt8},
    indices::Vector{Int},
    on_error::Symbol,
)
    ns_fields = schema._output_fields
    names = schema._output_names

    result = Vector{NamedTuple}(undef, length(indices))
    for (j, src_i) in enumerate(indices)
        rec_pos = record_offset(src, src_i)
        nf = length(ns_fields)
        values = ntuple(nf) do k
            @inbounds f = ns_fields[k]
            raw = _safe_parse_field(f, buf, rec_pos, src_i, on_error)
            raw === missing ? missing : _coerce(f.type, f.width, raw)
        end
        result[j] = NamedTuple{names}(values)
    end
    return result
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/materialization.jl test/test_skipping.jl
git commit -m "feat: add indexed column fill and skip_header/footer/comment to parse_file"
```

---

### Task 3: Full skipping test coverage

**Files:**
- Modify: `test/test_skipping.jl`

**Step 1: Write additional tests**

Add these testsets inside the `"Record Skipping"` testset in `test/test_skipping.jl`:

```julia
    @testset "parse_file with skip_footer" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")  # footer
        end

        result = parse_file(path, schema; skip_footer=1)
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]
        rm(path)
    end

    @testset "parse_file with comment" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")  # comment line
            write(io, "bar  20\n")
            write(io, "#cmt 00\n")  # comment line
            write(io, "baz  30\n")
        end

        result = parse_file(path, schema; comment=UInt8('#'))
        @test length(result) == 3
        @test result.name == ["foo", "bar", "baz"]
        @test result.val == [10, 20, 30]
        rm(path)
    end

    @testset "parse_file with all three" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")  # header
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")  # comment
            write(io, "bar  20\n")
            write(io, "FTR  --\n")  # footer
        end

        result = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]
        rm(path)
    end

    @testset "skip all records returns empty" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
        end

        result = parse_file(path, schema; skip_header=2)
        @test length(result) == 0

        result = parse_file(path, schema; skip_footer=2)
        @test length(result) == 0

        result = parse_file(path, schema; skip_header=1, skip_footer=1)
        @test length(result) == 0

        result = parse_file(path, schema; skip_header=100)
        @test length(result) == 0

        rm(path)
    end

    @testset "row-oriented with skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, schema; columnar=false, skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result[1].name == "foo"
        @test result[1].val == 10
        @test result[2].name == "bar"
        @test result[2].val == 20
        rm(path)
    end

    @testset "parallel + skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            for i in 1:100
                if i % 10 == 0
                    write(io, "#cmt 00\n")
                else
                    write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "\n")
                end
            end
            write(io, "FTR  --\n")
        end

        baseline = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'), ntasks=1)
        for nt in [2, 4]
            result = parse_file(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#'), ntasks=nt)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end
        rm(path)
    end

    @testset "no-op defaults match unfiltered" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        baseline = parse_file(path, schema)
        result = parse_file(path, schema; skip_header=0, skip_footer=0, comment=nothing)
        @test result.name == baseline.name
        @test result.val == baseline.val
        rm(path)
    end
```

**Step 2: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add test/test_skipping.jl
git commit -m "test: add comprehensive skipping coverage"
```

---

### Task 4: `eachrecord` skipping support

**Files:**
- Modify: `src/iteration.jl:16-19,46-49,70-73,116-121`
- Modify: `test/test_skipping.jl`

**Step 1: Write the failing test**

Add to `test/test_skipping.jl` inside the `"Record Skipping"` testset:

```julia
    @testset "eachrecord with skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        records = collect(eachrecord(path, schema; skip_header=1, skip_footer=1, comment=UInt8('#')))
        @test length(records) == 2
        @test records[1].name == "foo"
        @test records[1].val == 10
        @test records[2].name == "bar"
        @test records[2].val == 20
        rm(path)
    end

    @testset "eachrecord with IO and skipping" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        data = "HDR  --\nfoo  10\n#cmt 00\nbar  20\n"
        io = IOBuffer(data)

        records = collect(eachrecord(io, schema; skip_header=1, comment=UInt8('#')))
        @test length(records) == 2
        @test records[1].name == "foo"
        @test records[2].name == "bar"
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `eachrecord` does not accept `skip_header` keyword

**Step 3: Write minimal implementation**

Modify `src/iteration.jl`:

1. Update `RecordIterator` struct to hold optional indices:

```julia
struct RecordIterator{S}
    source::AbstractSource
    schema::S
    indices::Union{Vector{Int}, Nothing}  # nothing = use all records
end
```

2. Update `eachrecord` path overload (line 46-49):

```julia
function eachrecord(
    path::AbstractString,
    schema::FixedWidthSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = MmapSource(path, record_width(schema))
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return RecordIterator(src, schema, indices)
end
```

3. Update `eachrecord` IO overload (line 70-73):

```julia
function eachrecord(
    io::IO,
    schema::FixedWidthSchema;
    skip_header::Int=0,
    skip_footer::Int=0,
    comment::Union{UInt8, Nothing}=nothing,
)
    src = ChunkedSource(io, record_width(schema))
    indices = _valid_record_indices(src, skip_header, skip_footer, comment)
    return RecordIterator(src, schema, indices)
end
```

4. Update `length` to respect indices:

```julia
function Base.length(iter::RecordIterator)
    iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
end
```

5. Update `iterate` to use indices:

```julia
function Base.iterate(iter::RecordIterator, state::Int=1)
    n = iter.indices === nothing ? record_count(iter.source) : length(iter.indices)
    state > n && return nothing
    src_i = iter.indices === nothing ? state : iter.indices[state]
    pos = record_offset(iter.source, src_i)
    record = parse_record(iter.schema, buffer(iter.source), pos)
    return (record, state + 1)
end
```

6. Update the `@fixedwidth` macro's `eachrecord` dispatch in `src/schema.jl` (lines 325-333) to pass through keywords:

```julia
        function FixedWidthParsers.eachrecord(
            path::AbstractString,
            ::Type{$(esc(struct_name))};
            skip_header::Int=0,
            skip_footer::Int=0,
            comment::Union{UInt8, Nothing}=nothing,
        )
            return FixedWidthParsers.eachrecord(
                path,
                FixedWidthParsers.schema($(esc(struct_name)));
                skip_header=skip_header,
                skip_footer=skip_footer,
                comment=comment,
            )
        end
```

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/iteration.jl src/schema.jl test/test_skipping.jl
git commit -m "feat: add skip_header/footer/comment to eachrecord"
```

---

### Task 5: `@fixedwidth` parse_file keyword passthrough

**Files:**
- Modify: `src/schema.jl:307-323`
- Modify: `src/materialization.jl:688-707` (`_parse_file_generated`)
- Modify: `test/test_skipping.jl`

**Step 1: Write the failing test**

Add to `test/test_skipping.jl`:

```julia
    @testset "@fixedwidth struct with skipping" begin
        @fixedwidth struct SkipTestRecord
            name::String = 4
            val::Int     = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "HDR  --\n")
            write(io, "foo  10\n")
            write(io, "#cmt 00\n")
            write(io, "bar  20\n")
            write(io, "FTR  --\n")
        end

        result = parse_file(path, SkipTestRecord; skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(result) == 2
        @test result.name == ["foo", "bar"]
        @test result.val == [10, 20]

        # Also test eachrecord (already handled in Task 4)
        records = collect(eachrecord(path, SkipTestRecord; skip_header=1, skip_footer=1, comment=UInt8('#')))
        @test length(records) == 2

        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `@fixedwidth` dispatch doesn't accept `skip_header`

**Step 3: Write minimal implementation**

1. Update `@fixedwidth` macro `parse_file` dispatch in `src/schema.jl` (lines 308-323):

```julia
        function FixedWidthParsers.parse_file(
            path::AbstractString,
            ::Type{$(esc(struct_name))};
            columnar::Bool=true,
            on_error::Symbol=:strict,
            ntasks::Int=1,
            skip_header::Int=0,
            skip_footer::Int=0,
            comment::Union{UInt8, Nothing}=nothing,
        )
            if columnar
                return FixedWidthParsers._parse_file_generated(
                    path, $(esc(struct_name)), on_error, ntasks,
                    skip_header, skip_footer, comment)
            else
                return FixedWidthParsers.parse_file(
                    path, FixedWidthParsers.schema($(esc(struct_name)));
                    columnar=false, on_error=on_error,
                    skip_header=skip_header, skip_footer=skip_footer, comment=comment)
            end
        end
```

2. Update `_parse_file_generated` in `src/materialization.jl` (lines 688-707):

```julia
function _parse_file_generated(
    path::AbstractString, ::Type{T}, on_error::Symbol, ntasks::Int,
    skip_header::Int=0, skip_footer::Int=0, comment::Union{UInt8, Nothing}=nothing,
) where T
    sch = schema(T)
    _SCHEMA_CACHE[T] = sch
    src = MmapSource(path, record_width(sch))
    n = record_count(src)
    if n == 0
        close(src)
        return _empty_structarray(sch, on_error)
    end
    buf = buffer(src)

    indices = _valid_record_indices(src, skip_header, skip_footer, comment)

    result = if indices === nothing && ntasks <= 1
        # Fast generated path: no filtering, no parallelism
        _parse_columnar_generated(T, src, buf, n, Val(on_error))
    elseif indices === nothing
        # Parallel, no filtering
        _parse_columnar(sch, src, buf, n, on_error, ntasks)
    else
        # Filtered path (with or without parallelism)
        nvalid = length(indices)
        if nvalid == 0
            close(src)
            return _empty_structarray(sch, on_error)
        end
        _parse_columnar_indexed(sch, src, buf, indices, on_error, ntasks)
    end
    close(src)
    return result
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add src/schema.jl src/materialization.jl test/test_skipping.jl
git commit -m "feat: add skip_header/footer/comment to @fixedwidth dispatch"
```

---

### Task 6: Update docstrings and API reference

**Files:**
- Modify: `src/materialization.jl:15-61` (parse_file docstring)
- Modify: `src/iteration.jl` (eachrecord docstrings)
- Modify: `docs/src/index.md`

**Step 1: Update `parse_file` docstring**

In `src/materialization.jl`, update the docstring (lines 15-61) to include the new keywords:

Add after the `ntasks` keyword documentation:

```
- `skip_header=0`     — skip the first N records (e.g. column headers)
- `skip_footer=0`     — skip the last N records (e.g. summary/trailer lines)
- `comment=nothing`   — a `UInt8` byte; records whose first byte matches are
                         skipped. Comment lines must be the same fixed width
                         as data records. Example: `comment=UInt8('#')`
```

Add a usage example:

```julia
# Skip 2 header lines, 1 footer, and lines starting with '#'
sa = parse_file("data.dat", schema; skip_header=2, skip_footer=1, comment=UInt8('#'))
```

**Step 2: Update `eachrecord` docstrings**

Update both `eachrecord` docstrings in `src/iteration.jl` to document the new keywords.

**Step 3: Update `docs/src/index.md`**

Add a brief section after the Quick Example showing skipping:

```markdown
## Skipping Headers, Footers, and Comments

```julia
# Skip 2 header lines and 1 footer line
sa = parse_file("data.dat", schema; skip_header=2, skip_footer=1)

# Skip lines whose first byte is '#'
sa = parse_file("data.dat", schema; comment=UInt8('#'))

# Combine all three
sa = parse_file("data.dat", schema; skip_header=1, skip_footer=1, comment=UInt8('#'))
```
```

**Step 4: Verify docs build**

Run: `julia --project=docs docs/make.jl`
Expected: Build succeeds with no warnings

**Step 5: Commit**

```bash
git add src/materialization.jl src/iteration.jl docs/src/index.md
git commit -m "docs: document skip_header/footer/comment keywords"
```
