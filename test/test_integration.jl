using Test
using FixedWidthParsers
using StructArrays
using Dates

@testset "Integration" begin
    @testset "full pipeline: runtime schema" begin
        path = tempname()
        open(path, "w") do io
            # carrier(2) fnum(4) pad(1) origin(3) dest(3) date(8) pax(3) pad2(1) rev(8)
            # Total: 2+4+1+3+3+8+3+1+8 = 33 bytes per record
            write(io, "UA1234 ORDSFO20260224150 00054321\n")
            write(io, "DL 567 LAXJFK20260225 89 00012345\n")
            write(io, "AA9999 DENSFO20260226300 99999999\n")
        end

        fwschema = FixedWidthSchema(
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
        sa = parse_file(path, fwschema)
        @test sa isa StructArray
        @test length(sa) == 3
        @test sa.carrier == ["UA", "DL", "AA"]
        @test sa.fnum == [1234, 567, 9999]
        @test sa.origin == ["ORD", "LAX", "DEN"]
        @test sa.dest == ["SFO", "JFK", "SFO"]
        @test sa.date[1] == Date(2026, 2, 24)
        @test sa.date[2] == Date(2026, 2, 25)
        @test sa.date[3] == Date(2026, 2, 26)
        @test sa.pax == [150, 89, 300]
        @test sa.revenue[1] ≈ 543.21
        @test sa.revenue[2] ≈ 123.45
        @test sa.revenue[3] ≈ 999999.99
        @test !hasproperty(sa, :pad)
        @test !hasproperty(sa, :pad2)

        # Test lazy iteration gives same results
        records = collect(eachrecord(path, fwschema))
        @test length(records) == 3
        @test records[1].carrier == "UA"
        @test records[2].fnum == 567
        @test records[3].pax == 300

        # Test row materialization
        rows = parse_file(path, fwschema; columnar=false)
        @test length(rows) == 3
        @test rows[1].carrier == "UA"
        @test rows[2].origin == "LAX"
        @test rows[3].revenue ≈ 999999.99

        rm(path)
    end

    @testset "full pipeline: @fixedwidth macro" begin
        @fixedwidth struct IntegrationFlight
            carrier::String = 2
            number::Int     = 4
            origin::String  = 3
            dest::String    = 3
        end

        path = tempname()
        open(path, "w") do io
            write(io, "UA1234ORDSFO\n")
            write(io, "DL 567LAXJFK\n")
        end

        # parse_file with type
        result = parse_file(path, IntegrationFlight)
        @test result.carrier == ["UA", "DL"]
        @test result.number == [1234, 567]
        @test result.origin == ["ORD", "LAX"]

        # eachrecord with type
        records = collect(eachrecord(path, IntegrationFlight))
        @test records[1].carrier == "UA"
        @test records[2].dest == "JFK"

        rm(path)
    end

    @testset "IOBuffer pipeline" begin
        fwschema = FixedWidthSchema(
            :code => (3, FWString()),
            :val  => (5, FWInt()),
        )

        data = "ABC   10\nDEF   20\nGHI   30\n"
        records = collect(eachrecord(IOBuffer(data), fwschema))
        @test length(records) == 3
        @test records[1].code == "ABC"
        @test records[2].val == 20
        @test records[3].code == "GHI"
    end

    @testset "error handling pipeline" begin
        fwschema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )

        path = tempname()
        open(path, "w") do io
            write(io, "good 42\n")
            write(io, "bad abc\n")
            write(io, "ok   99\n")
        end

        # Strict mode throws
        @test_throws ParseError parse_file(path, fwschema)

        # Lenient mode continues
        result = parse_file(path, fwschema; on_error=:lenient)
        @test length(result) == 3
        @test result.val[1] == 42
        @test ismissing(result.val[2])
        @test result.val[3] == 99

        rm(path)
    end
end
