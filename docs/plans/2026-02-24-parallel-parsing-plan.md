# Parallel Columnar Parsing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add multi-threaded columnar parsing via `ntasks` keyword argument to `parse_file`, partitioning records across Julia tasks that write to disjoint slices of shared pre-allocated column vectors.

**Architecture:** Memory-mapped buffer is read-only shared state. Each task fills `col[start:stop]` for its record range. Column-major outer loop preserved (function barrier per column). `@sync`/`Threads.@spawn` for task management. `ntasks=1` bypasses threading entirely.

**Tech Stack:** Julia `Base.Threads` (`@spawn`, `@sync`), existing `MmapSource`, `StructArrays`

---

### Task 1: Add `_partition_ranges` helper

**Files:**
- Modify: `src/materialization.jl` (add after line 77, before the internal helpers section)
- Test: `test/test_parallel.jl` (new file)

**Step 1: Write the failing test**

Create `test/test_parallel.jl`:

```julia
using Test
using FixedWidthParsers
using FixedWidthParsers: _partition_ranges

@testset "Parallel Parsing" begin
    @testset "_partition_ranges" begin
        @test _partition_ranges(10, 1) == [1:10]
        @test _partition_ranges(10, 2) == [1:5, 6:10]
        @test _partition_ranges(10, 3) == [1:4, 5:7, 8:10]
        @test _partition_ranges(10, 4) == [1:3, 4:5, 6:8, 9:10]
        @test _partition_ranges(10, 10) == [i:i for i in 1:10]
        # ntasks > n gets clamped
        @test _partition_ranges(3, 10) == [1:1, 2:2, 3:3]
        @test _partition_ranges(1, 4) == [1:1]
    end
end
```

**Step 2: Register test file in `test/runtests.jl`**

Add `include("test_parallel.jl")` after line 15 (after `test_integration.jl`):

```julia
    include("test_parallel.jl")
```

**Step 3: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with `UndefVarError: _partition_ranges not defined`

**Step 4: Implement `_partition_ranges`**

Add to `src/materialization.jl` after line 77 (after the `parse_file` function, before the internal helpers comment):

```julia
"""
    _partition_ranges(n, ntasks) → Vector{UnitRange{Int}}

Partition `1:n` into `min(n, ntasks)` contiguous ranges of roughly equal size.
"""
function _partition_ranges(n::Int, ntasks::Int)
    ntasks = min(n, ntasks)
    chunk = n ÷ ntasks
    remainder = n % ntasks
    ranges = Vector{UnitRange{Int}}(undef, ntasks)
    lo = 1
    for i in 1:ntasks
        hi = lo + chunk - 1 + (i <= remainder ? 1 : 0)
        ranges[i] = lo:hi
        lo = hi + 1
    end
    return ranges
end
```

**Step 5: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass including new `_partition_ranges` tests

**Step 6: Commit**

```bash
git add src/materialization.jl test/test_parallel.jl test/runtests.jl
git commit -m "feat: add _partition_ranges helper for parallel parsing"
```

---

### Task 2: Add range-based `_fill_column_strict!` and `_fill_column_lenient!`

**Files:**
- Modify: `src/materialization.jl:187-243` (add `range` parameter variants)
- Test: `test/test_parallel.jl` (extend)

**Step 1: Write the failing test**

Append to the `"Parallel Parsing"` testset in `test/test_parallel.jl`:

```julia
    @testset "parse_file with ntasks keyword" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, lpad("r$i", 4)[1:4] * lpad(string(i), 3) * "\n")
            end
        end

        @testset "ntasks=1 matches default" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=1)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks=2 produces correct results" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=2)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks=4 produces correct results" begin
            baseline = parse_file(path, schema)
            result = parse_file(path, schema; ntasks=4)
            @test result.name == baseline.name
            @test result.val == baseline.val
        end

        @testset "ntasks > n_records is clamped" begin
            small_path = tempname()
            open(small_path, "w") do io
                write(io, "foo  10\n")
                write(io, "bar  20\n")
            end
            result = parse_file(small_path, schema; ntasks=100)
            @test result.val == [10, 20]
            rm(small_path)
        end

        rm(path)
    end
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with `MethodError: no method matching parse_file(...; ntasks=1)`

**Step 3: Modify `_fill_column_strict!` to accept a range**

In `src/materialization.jl`, change the signature of `_fill_column_strict!` (line 187) to accept `record_range::UnitRange{Int}` instead of `n::Int`, and loop over `record_range` instead of `1:n`:

```julia
@inline function _fill_column_strict!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    try
        @inbounds for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            val = parse_field(descriptor, buf, field_pos, width)
            col[i] = _coerce(descriptor, width, val)
        end
    catch
        # Rescan to find the failing record and produce a rich ParseError
        for i in record_range
            field_pos = record_offset(src, i) + offset - 1
            try
                parse_field(descriptor, buf, field_pos, width)
            catch e
                raw = collect(buf[field_pos:field_pos+width-1])
                col_range = offset:(offset + width - 1)
                throw(
                    ParseError(
                        i, col_range, raw, _julia_type(descriptor),
                        "Failed to parse field :$(name): $(sprint(showerror, e))",
                    ),
                )
            end
        end
    end
end
```

Similarly update `_fill_column_lenient!` (line 223):

```julia
function _fill_column_lenient!(
    col::AbstractVector,
    descriptor,
    width::Int,
    offset::Int,
    name::Symbol,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
)
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        try
            val = parse_field(descriptor, buf, field_pos, width)
            col[i] = _coerce(descriptor, width, val)
        catch e
            @warn "Parse error at line $i, field :$(name)" exception = e
            col[i] = missing
        end
    end
end
```

Update `_fill_column!` (line 169) to pass `record_range` through:

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
    else
        _fill_column_lenient!(col, descriptor, width, offset, name, buf, src, record_range)
    end
end
```

Update the `FWString` specialization of `_fill_column!` (line 252) similarly — change `n::Int` to `record_range::UnitRange{Int}`:

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
    ISType = _inline_string_type(width)
    _fill_string_column!(col, ISType, descriptor, width, offset, buf, src, record_range)
end
```

Update `_fill_string_column!` (line 268) — change `n::Int` to `record_range::UnitRange{Int}`:

```julia
function _fill_string_column!(
    col::AbstractVector,
    ::Type{T},
    descriptor::FWString,
    width::Int,
    offset::Int,
    buf::AbstractVector{UInt8},
    src::AbstractSource,
    record_range::UnitRange{Int},
) where {T}
    pad_byte = UInt8(descriptor.pad)
    empty_val = T("")
    @inbounds for i in record_range
        field_pos = record_offset(src, i) + offset - 1
        last = field_pos + width - 1
        while last >= field_pos && buf[last] == pad_byte
            last -= 1
        end
        actual_len = last - field_pos + 1
        col[i] = actual_len <= 0 ? empty_val : _inline_from_buf(T, buf, field_pos, actual_len)
    end
end
```

**Step 4: Update `_parse_columnar` to use `ntasks` with `@sync`/`@spawn`**

Modify `_parse_columnar` (line 129) to accept `ntasks` and spawn tasks:

```julia
function _parse_columnar(
    schema::FixedWidthSchema,
    src::MmapSource,
    buf::AbstractVector{UInt8},
    n::Int,
    on_error::Symbol,
    ntasks::Int,
)
    ns_fields = schema._output_fields
    names = schema._output_names

    columns = if on_error === :lenient
        [Vector{Union{_julia_type(f.type, f.width), Missing}}(undef, n) for f in ns_fields]
    else
        [Vector{_julia_type(f.type, f.width)}(undef, n) for f in ns_fields]
    end

    ranges = _partition_ranges(n, ntasks)

    for (col_idx, f) in enumerate(ns_fields)
        if length(ranges) == 1
            _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, ranges[1], on_error)
        else
            @sync for r in ranges
                Threads.@spawn _fill_column!(columns[col_idx], f.type, f.width, f.offset, f.name, buf, src, r, on_error)
            end
        end
    end

    col_nt = NamedTuple{names}(Tuple(columns))
    return StructArray(col_nt)
end
```

**Step 5: Update `parse_file` to accept and pass `ntasks`**

Modify the `parse_file` signature (line 55) to add `ntasks::Int=1`:

```julia
function parse_file(
    path::AbstractString,
    schema::FixedWidthSchema;
    columnar::Bool=true,
    on_error::Symbol=:strict,
    ntasks::Int=1,
)
    src = MmapSource(path, record_width(schema))
    n = record_count(src)

    if n == 0
        close(src)
        return columnar ? _empty_structarray(schema, on_error) : NamedTuple[]
    end

    buf = buffer(src)
    result = if columnar
        _parse_columnar(schema, src, buf, n, on_error, ntasks)
    else
        _parse_rows(schema, src, buf, n, on_error)
    end
    close(src)
    return result
end
```

Update the docstring (line 16) to document `ntasks`:

Add this line after `- \`on_error=:lenient\``:
```
- `ntasks=1`           — number of parallel tasks for columnar parsing (default: single-threaded)
```

**Step 6: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All 183+ tests pass, including new parallel tests

**Step 7: Commit**

```bash
git add src/materialization.jl test/test_parallel.jl
git commit -m "feat: add ntasks keyword for parallel columnar parsing (runtime schema)"
```

---

### Task 3: Add `ntasks` to the `@fixedwidth` generated path

**Files:**
- Modify: `src/schema.jl:307-322` (macro dispatch overload)
- Modify: `src/materialization.jl:622-635` (`_parse_file_generated`)
- Modify: `src/materialization.jl:501-611` (`_parse_columnar_generated`)
- Test: `test/test_parallel.jl` (extend)

**Step 1: Write the failing test**

Append to `test/test_parallel.jl` inside the `"Parallel Parsing"` testset:

```julia
    @testset "parse_file ntasks with @fixedwidth struct" begin
        @fixedwidth struct ParTestFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
        end

        path = tempname()
        open(path, "w") do io
            for i in 1:100
                carrier = "UA"
                number = lpad(string(i), 4)
                origin = "ORD"
                write(io, carrier * number * origin * "\n")
            end
        end

        baseline = parse_file(path, ParTestFlight)

        @testset "ntasks=$nt" for nt in [1, 2, 4]
            result = parse_file(path, ParTestFlight; ntasks=nt)
            @test result.carrier == baseline.carrier
            @test result.number == baseline.number
            @test result.origin == baseline.origin
        end

        rm(path)
    end
```

Also add the `@fixedwidth` import at the top of the file:

```julia
using FixedWidthParsers: _partition_ranges, @fixedwidth, Skip
```

**Step 2: Run test to verify it fails**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL with `MethodError` — the `@fixedwidth` dispatch of `parse_file` doesn't accept `ntasks`

**Step 3: Update `_parse_columnar_generated` to accept a range**

Change the `@generated` function signature to accept `record_range` instead of `n`:

```julia
@generated function _parse_columnar_generated(::Type{T}, src, buf, n, record_range, ::Val{Mode}) where {T, Mode}
```

Change the column allocation to still use `n` (full size), but change the loop from `1:n` to `record_range`:

In the loop expression (currently line 584-588), change:
```julia
    loop_expr = quote
        @inbounds for i_rec in record_range
            rec_pos = record_offset(src, i_rec)
            $loop_body
        end
    end
```

In the strict-mode error rescan, pass `record_range` to `_rescan_for_error`:

```julia
    if Mode === :strict
        loop_expr = quote
            try
                $loop_expr
            catch
                _rescan_for_error(T, src, buf, record_range)
            end
        end
    end
```

**Step 4: Update `_rescan_for_error` to accept a range**

Change `_rescan_for_error` (line 462) to iterate over a range:

```julia
function _rescan_for_error(::Type{T}, src, buf, record_range) where T
    sch = schema(T)
    for f in sch._output_fields
        for i in record_range
            field_pos = record_offset(src, i) + f.offset - 1
            try
                parse_field(f.type, buf, field_pos, f.width)
            catch e
                raw = collect(buf[field_pos:field_pos+f.width-1])
                col_range = f.offset:(f.offset + f.width - 1)
                throw(ParseError(i, col_range, raw, _julia_type(f.type, f.width),
                    "Failed to parse field :$(f.name): $(sprint(showerror, e))"))
            end
        end
    end
end
```

**Step 5: Update `_parse_file_generated` to accept and use `ntasks`**

```julia
function _parse_file_generated(path::AbstractString, ::Type{T}, on_error::Symbol, ntasks::Int) where T
    sch = schema(T)
    _SCHEMA_CACHE[T] = sch
    src = MmapSource(path, record_width(sch))
    n = record_count(src)
    if n == 0
        close(src)
        return _empty_structarray(sch, on_error)
    end
    buf = buffer(src)
    ranges = _partition_ranges(n, ntasks)
    # Allocate columns once at full size, then fill ranges in parallel
    result = if length(ranges) == 1
        _parse_columnar_generated(T, src, buf, n, ranges[1], Val(on_error))
    else
        # For threaded generated path: allocate columns, then spawn per-range fills
        # Fall back to runtime path with threading since @generated can't easily
        # spawn tasks (the generated code is a single loop body)
        _parse_columnar(sch, src, buf, n, on_error, ntasks)
    end
    close(src)
    return result
end
```

Note: When `ntasks > 1`, the generated path falls back to the runtime threaded path. The `@generated` single-pass loop interleaves all fields in one record scan, making it hard to partition without duplicating the entire generator. The runtime path with function barriers is already fast and thread-safe. When `ntasks=1`, the generated path is used (preserving current performance).

**Step 6: Update the macro dispatch in `src/schema.jl`**

Change the `parse_file` dispatch (line 308-322) to accept `ntasks`:

```julia
        function FixedWidthParsers.parse_file(
            path::AbstractString,
            ::Type{$(esc(struct_name))};
            columnar::Bool=true,
            on_error::Symbol=:strict,
            ntasks::Int=1,
        )
            if columnar
                return FixedWidthParsers._parse_file_generated(
                    path, $(esc(struct_name)), on_error, ntasks)
            else
                return FixedWidthParsers.parse_file(
                    path, FixedWidthParsers.schema($(esc(struct_name)));
                    columnar=false, on_error=on_error)
            end
        end
```

**Step 7: Run tests to verify they pass**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

**Step 8: Commit**

```bash
git add src/materialization.jl src/schema.jl test/test_parallel.jl
git commit -m "feat: add ntasks support for @fixedwidth generated path"
```

---

### Task 4: Test error handling in parallel mode

**Files:**
- Test: `test/test_parallel.jl` (extend)

**Step 1: Write the tests**

Append to `test/test_parallel.jl`:

```julia
    @testset "parallel error handling" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        @testset "strict mode throws ParseError with ntasks=2" begin
            path = tempname()
            open(path, "w") do io
                write(io, "foo  10\n")
                write(io, "bar abc\n")  # bad int in second record
                write(io, "baz  30\n")
            end
            err = try
                parse_file(path, schema; ntasks=2)
                nothing
            catch e
                e
            end
            @test err isa ParseError
            @test err.line == 2
            rm(path)
        end

        @testset "lenient mode returns missing with ntasks=2" begin
            path = tempname()
            open(path, "w") do io
                write(io, "foo abc\n")
                write(io, "bar  42\n")
                write(io, "baz def\n")
                write(io, "qux  99\n")
            end
            result = parse_file(path, schema; on_error=:lenient, ntasks=2)
            @test length(result) == 4
            @test ismissing(result.val[1])
            @test result.val[2] == 42
            @test ismissing(result.val[3])
            @test result.val[4] == 99
            rm(path)
        end
    end

    @testset "parallel with empty file" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = tempname()
        open(path, "w") do io end
        result = parse_file(path, schema; ntasks=4)
        @test length(result) == 0
        rm(path)
    end
```

**Step 2: Run tests**

Run: `julia --project -e 'using Pkg; Pkg.test()'`
Expected: All tests pass

**Step 3: Commit**

```bash
git add test/test_parallel.jl
git commit -m "test: add parallel error handling and edge case tests"
```

---

### Task 5: Add parallel benchmarks

**Files:**
- Modify: `benchmark/benchmarks.jl` (append parallel benchmark group)

**Step 1: Add parallel benchmarks**

Append to `benchmark/benchmarks.jl`:

```julia
# ---------------------------------------------------------------------------
# Parallel columnar parsing benchmarks
# ---------------------------------------------------------------------------
SUITE["parallel"] = BenchmarkGroup()

for nt in [1, 2, 4]
    SUITE["parallel"]["1M_runtime_ntasks=$(nt)"] = @benchmarkable parse_file(
        $(joinpath(BENCHDIR, "1M.dat")),
        $BENCH_SCHEMA;
        ntasks = $nt,
    )

    SUITE["parallel"]["1M_generated_ntasks=$(nt)"] = @benchmarkable parse_file(
        $(joinpath(BENCHDIR, "1M.dat")),
        $BenchFlight;
        ntasks = $nt,
    )
end
```

**Step 2: Verify benchmarks load**

Run: `julia --project -e 'include("benchmark/benchmarks.jl"); println(keys(SUITE["parallel"]))'`
Expected: Prints the 6 benchmark keys

**Step 3: Commit**

```bash
git add benchmark/benchmarks.jl
git commit -m "bench: add parallel parsing benchmarks"
```

---

### Task 6: Run full benchmark comparison

**Step 1: Run benchmarks and export results**

```bash
julia --project -e '
    using PkgBenchmark
    results = benchmarkpkg(".")
    export_markdown(stdout, results)
'
```

**Step 2: Verify parallel results show expected behavior**

- `ntasks=1` should match single-threaded baselines
- `ntasks=2` and `ntasks=4` should show improvement on 1M records (depends on machine cores)

**Step 3: Commit any tuning file updates (if needed)**

`benchmark/tune.json` is gitignored, so no action needed.
