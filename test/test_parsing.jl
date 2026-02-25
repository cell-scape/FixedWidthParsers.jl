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

    @testset "parse_record with leading spaces in int" begin
        buf = Vector{UInt8}("DL 567 LAXJFK")
        record = parse_record(schema, buf, 1)
        @test record.carrier == "DL"
        @test record.flight_num == 567
        @test record.origin == "LAX"
        @test record.dest == "JFK"
    end

    @testset "parse_record at offset" begin
        buf = Vector{UInt8}("UA1234 ORDSFO\nDL 567 LAXJFK\n")
        record = parse_record(schema, buf, 15)  # second record starts after \n
        @test record.carrier == "DL"
        @test record.flight_num == 567
    end
end
