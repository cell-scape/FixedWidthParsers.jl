using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field, _parse_type_string, _type_to_descriptor

@testset "FWBool" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "default Y/N" begin
        desc = FWBool()
        @test parse_field(desc, to_buf("Y"), 1, 1) === true
        @test parse_field(desc, to_buf("N"), 1, 1) === false
    end

    @testset "custom true/false values" begin
        desc = FWBool(true_val = "T", false_val = "F")
        @test parse_field(desc, to_buf("T"), 1, 1) === true
        @test parse_field(desc, to_buf("F"), 1, 1) === false
    end

    @testset "multi-char values" begin
        desc = FWBool(true_val="YES", false_val="NO")
        @test parse_field(desc, to_buf("YES"), 1, 3) === true
        @test parse_field(desc, to_buf("NO "), 1, 3) === false  # trailing space stripped
    end

    @testset "whitespace stripping" begin
        desc = FWBool()
        @test parse_field(desc, to_buf("Y  "), 1, 3) === true
        @test parse_field(desc, to_buf(" N "), 1, 3) === false
        @test parse_field(desc, to_buf("  Y"), 1, 3) === true
    end

    @testset "mismatch throws" begin
        desc = FWBool()
        @test_throws ArgumentError parse_field(desc, to_buf("X"), 1, 1)
        @test_throws ArgumentError parse_field(desc, to_buf("   "), 1, 3)
    end

    @testset "construction validation" begin
        @test_throws ArgumentError FWBool(true_val = "", false_val = "N")
        @test_throws ArgumentError FWBool(true_val = "Y", false_val = "")
    end

    @testset "_julia_type" begin
        @test FixedWidthParsers._julia_type(FWBool()) === Bool
    end

    @testset "_parse_type_string" begin
        @test _parse_type_string("Bool") isa FWBool
        @test _parse_type_string("Bool").true_val == "Y"
        @test _parse_type_string("Bool(T,F)") isa FWBool
        @test _parse_type_string("Bool(T,F)").true_val == "T"
        @test _parse_type_string("Bool(T,F)").false_val == "F"
        @test _parse_type_string("Bool(YES,NO)").true_val == "YES"
    end

    @testset "_type_to_descriptor" begin
        @test _type_to_descriptor(Bool) isa FWBool
    end

    @testset "parse_file with FWBool" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UAY\nDLN\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :active => (1, FWBool()),
        )
        sa = parse_file(path, schema)
        @test sa.active == [true, false]
        rm(path)
    end

    @testset "lenient mode with FWBool" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UAY\nDLX\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :active => (1, FWBool()),
        )
        sa = parse_file(path, schema; on_error = :lenient)
        @test sa.active[1] === true
        @test sa.active[2] === missing
        rm(path)
    end

    @testset "@fixedwidth macro with Bool" begin
        @fixedwidth struct BoolRecord
            code::String = 2
            flag::Bool = 1
        end
        path = tempname()
        open(path, "w") do io
            write(io, "ABY\nCDN\n")
        end
        sa = parse_file(path, BoolRecord)
        @test sa.flag == [true, false]
        rm(path)
    end
end
