using Test
using FixedWidthParsers
using FixedWidthParsers: @fixedwidth, Skip

@testset "parse_string / parse_bytes / parse_file(io)" begin
    schema = FixedWidthSchema(
        :carrier    => (2, FWString()),
        :flight_num => (4, FWInt()),
        :skip       => (1, FWSkip()),
        :origin     => (3, FWString()),
    )

    data = "UA1234 ORD\nDL 567 LAX\nAA 999 SFO\n"

    @testset "parse_string columnar (FixedWidthSchema)" begin
        sa = parse_string(data, schema)
        @test length(sa) == 3
        @test sa.carrier == ["UA", "DL", "AA"]
        @test sa.flight_num == [1234, 567, 999]
        @test sa.origin == ["ORD", "LAX", "SFO"]
    end

    @testset "parse_string row-oriented" begin
        rows = parse_string(data, schema; columnar=false)
        @test length(rows) == 3
        @test rows[1].carrier == "UA"
        @test rows[2].flight_num == 567
        @test rows[3].origin == "SFO"
    end

    @testset "parse_bytes" begin
        b = Vector{UInt8}(data)
        sa = parse_bytes(b, schema)
        @test length(sa) == 3
        @test sa.carrier == ["UA", "DL", "AA"]
    end

    @testset "parse_file(io::IO, schema)" begin
        sa = parse_file(IOBuffer(data), schema)
        @test length(sa) == 3
        @test sa.flight_num == [1234, 567, 999]
    end

    @testset "skip_header + skip_footer + comment on parse_string" begin
        # Each line must be exactly record_width (=10) bytes before the \n.
        with_extras =
            "HDR       \n" *      # header row (skip_header=1)
            "# comment \n" *      # comment row (filtered by comment=UInt8('#'))
            "UA1234 ORD\n" *
            "DL 567 LAX\n" *
            "FOOTER    \n"        # footer row (skip_footer=1)
        sa = parse_string(with_extras, schema;
                          skip_header=1, skip_footer=1, comment=UInt8('#'))
        @test length(sa) == 2
        @test sa.carrier == ["UA", "DL"]
    end

    @testset "select + exclude" begin
        sa = parse_string(data, schema; select=[:carrier, :flight_num])
        @test propertynames(sa) == (:carrier, :flight_num)

        sa = parse_string(data, schema; exclude=[:origin])
        @test propertynames(sa) == (:carrier, :flight_num)
    end

    @testset "on_error=:lenient on parse_string" begin
        bad = "UA1234 ORD\nDL  abc LAX\n"
        sa = parse_string(bad, schema; on_error=:lenient)
        @test sa.flight_num[1] == 1234
        @test ismissing(sa.flight_num[2])
    end

    @testset "empty input" begin
        @test length(parse_string("", schema)) == 0
        @test length(parse_bytes(UInt8[], schema)) == 0
    end

    @testset "parse_string with @fixedwidth struct" begin
        @fixedwidth struct PSFlight
            carrier::String = 2
            flight_num::Int = 4
            _skip::Skip     = 1
            origin::String  = 3
        end

        sa = parse_string(data, PSFlight)
        @test length(sa) == 3
        @test sa.carrier == ["UA", "DL", "AA"]
        @test sa.flight_num == [1234, 567, 999]
    end

    @testset "parse_string with MultiRecordSchema" begin
        hdr = FixedWidthSchema(:rec_type => (1, FWString()),
                               :title    => (9, FWString()))
        det = FixedWidthSchema(:rec_type => (1, FWString()),
                               :code     => (3, FWString()),
                               :value    => (6, FWInt()))
        ms = MultiRecordSchema(1:1, "H" => hdr, "D" => det)

        mixed = "HGreeting \nDXYZ   100\nDABC   200\n"
        result = parse_string(mixed, ms)
        @test result[:H].title == ["Greeting"]
        @test result[:D].code == ["XYZ", "ABC"]
        @test result[:D].value == [100, 200]
    end
end
