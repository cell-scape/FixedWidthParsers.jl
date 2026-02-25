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

        r = SimpleRecord("test", 42)
        @test r.name == "test"
        @test r.value == 42
    end

    @testset "schema metadata" begin
        @fixedwidth struct SimpleRecord2
            name::String = 4
            value::Int   = 3
        end

        s = FixedWidthParsers.schema(SimpleRecord2)
        @test record_width(s) == 7
        @test field_names(s) == (:name, :value)
        @test field_offsets(s) == (1, 5)
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
            _pad::Skip = 1
            b::Int    = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "AB 123\n")
        end

        result = parse_file(path, SkipRecord)
        @test result.a[1] == "AB"
        @test result.b[1] == 123
        @test !hasproperty(result, :_pad)
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

    @testset "skip fields excluded from struct" begin
        @fixedwidth struct PaddedRecord
            id::Int    = 4
            _gap::Skip = 2
            code::String = 3
        end

        # Skip fields must not appear as struct fields
        r = PaddedRecord(9999, "XYZ")
        @test r.id == 9999
        @test r.code == "XYZ"
        @test !hasproperty(r, :_gap)
    end

    @testset "schema includes skip fields for correct record_width" begin
        @fixedwidth struct SpacedRecord
            a::String  = 3
            _s1::Skip  = 2
            b::Int     = 4
            _s2::Skip  = 1
        end

        s = FixedWidthParsers.schema(SpacedRecord)
        # Total width must include the skip regions: 3 + 2 + 4 + 1 = 10
        @test record_width(s) == 10
        # field_names includes all fields (skip + non-skip)
        @test field_names(s) == (:a, :_s1, :b, :_s2)
        # Offsets: a@1, _s1@4, b@6, _s2@10
        @test field_offsets(s) == (1, 4, 6, 10)
    end

    @testset "Float64 field type" begin
        @fixedwidth struct FloatRecord
            label::String   = 5
            amount::Float64 = 6
        end

        path = tempname()
        open(path, "w") do io
            write(io, "hello  3.14\n")
            write(io, "world 99.99\n")
        end

        result = parse_file(path, FloatRecord)
        @test result.label[1] == "hello"
        @test result.amount[1] ≈ 3.14
        @test result.amount[2] ≈ 99.99
        rm(path)
    end

    # -----------------------------------------------------------------------
    # @generated columnar path tests
    # -----------------------------------------------------------------------

    @testset "generated vs runtime: identical results" begin
        @fixedwidth struct GenVsRunFlight
            carrier::String  = 2
            number::Int      = 4
            _pad::Skip       = 1
            origin::String   = 3
            dest::String     = 3
            amount::Float64  = 6
        end

        path = tempname()
        open(path, "w") do io
            write(io, "UA1234 ORDSFO  3.14\n")
            write(io, "DL 567 LAXJFK 99.99\n")
        end

        gen = parse_file(path, GenVsRunFlight)                    # generated path
        rt  = parse_file(path, schema(GenVsRunFlight))            # runtime path

        @test gen.carrier == rt.carrier
        @test gen.number  == rt.number
        @test gen.origin  == rt.origin
        @test gen.dest    == rt.dest
        @test gen.amount  ≈  rt.amount
        @test !hasproperty(gen, :_pad)
        rm(path)
    end

    @testset "generated: strict error" begin
        @fixedwidth struct GenStrictRec
            name::String = 4
            val::Int     = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "good 42\n")
            write(io, "bad abc\n")
        end

        @test_throws ParseError parse_file(path, GenStrictRec)
        rm(path)
    end

    @testset "generated: lenient error" begin
        @fixedwidth struct GenLenientRec
            name::String = 4
            val::Int     = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "good 42\n")
            write(io, "bad abc\n")
            write(io, "ok   99\n")
        end

        result = parse_file(path, GenLenientRec; on_error=:lenient)
        @test length(result) == 3
        @test result.name[1] == "good"
        @test result.val[1] == 42
        @test ismissing(result.val[2])
        @test result.val[3] == 99
        rm(path)
    end

    @testset "generated: skip fields excluded" begin
        @fixedwidth struct GenSkipRec
            a::String  = 2
            _gap::Skip = 3
            b::Int     = 4
        end

        path = tempname()
        open(path, "w") do io
            write(io, "AB---1234\n")
        end

        result = parse_file(path, GenSkipRec)
        @test result.a[1] == "AB"
        @test result.b[1] == 1234
        @test !hasproperty(result, :_gap)
        rm(path)
    end

    @testset "generated: row fallback" begin
        @fixedwidth struct GenRowRec
            x::String = 3
            y::Int    = 2
        end

        path = tempname()
        open(path, "w") do io
            write(io, "abc10\n")
            write(io, "def20\n")
        end

        rows = parse_file(path, GenRowRec; columnar=false)
        @test length(rows) == 2
        @test rows[1].x == "abc"
        @test rows[2].y == 20
        rm(path)
    end

    @testset "generated: empty file" begin
        @fixedwidth struct GenEmptyRec
            a::String = 3
            b::Int    = 2
        end

        path = tempname()
        open(path, "w") do io end  # empty file

        result = parse_file(path, GenEmptyRec)
        @test result isa StructArray
        @test length(result) == 0
        rm(path)
    end

    @testset "generated: all field types" begin
        @fixedwidth struct GenAllTypes
            s::String    = 5
            i::Int       = 4
            f::Float64   = 6
        end

        path = tempname()
        open(path, "w") do io
            write(io, "hello1234  3.14\n")
            write(io, "world 567 99.99\n")
        end

        result = parse_file(path, GenAllTypes)
        @test result.s == ["hello", "world"]
        @test result.i == [1234, 567]
        @test result.f[1] ≈ 3.14
        @test result.f[2] ≈ 99.99
        rm(path)
    end
end
