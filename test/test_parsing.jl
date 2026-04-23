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

    @testset "parse_record strings are owned copies (safe past buffer mutation)" begin
        # Regression guard: previously `parse_field(::FWString, ...)` returned a
        # zero-copy `StringView` into the caller's buffer. That view dangled as
        # soon as the buffer was freed (e.g. after `close` on an mmap source).
        # parse_record must now return owned string values.
        buf = Vector{UInt8}("UA1234 ORDSFO")
        record = parse_record(schema, buf, 1)
        @test record.carrier == "UA"
        @test record.origin == "ORD"

        # Overwrite every byte of the buffer; parsed values must be unaffected.
        fill!(buf, UInt8('Z'))
        @test record.carrier == "UA"
        @test record.origin == "ORD"

        # The string should be a concrete (non-StringView) AbstractString
        @test !(typeof(record.carrier) <: AbstractArray)
        @test record.carrier isa AbstractString
    end

    @testset "eachrecord strings are safe past close" begin
        using FixedWidthParsers: MmapSource

        schema_s = FixedWidthSchema(
            :carrier => (2, FWString()),
            :origin  => (3, FWString()),
        )
        path = tempname()
        open(path, "w") do io
            write(io, "UAORD\n")
            write(io, "DLLAX\n")
        end

        iter = eachrecord(path, schema_s)
        records = collect(iter)
        close(iter)  # releases the mmap buffer

        # After close, stored records must still be valid
        @test records[1].carrier == "UA"
        @test records[1].origin == "ORD"
        @test records[2].carrier == "DL"
        @test records[2].origin == "LAX"
        rm(path)
    end
end
