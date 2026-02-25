using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field

@testset "Custom Pad" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "FWInt default pad (space) unchanged" begin
        @test FWInt().pad == ' '
        @test parse_field(FWInt(), to_buf("  42"), 1, 4) == 42
    end

    @testset "FWInt zero-padded" begin
        desc = FWInt(pad='0')
        @test parse_field(desc, to_buf("0042"), 1, 4) == 42
        @test parse_field(desc, to_buf("0000"), 1, 4) == 0
        @test parse_field(desc, to_buf("0001"), 1, 4) == 1
    end

    @testset "FWInt asterisk-padded" begin
        desc = FWInt(pad='*')
        @test parse_field(desc, to_buf("**42"), 1, 4) == 42
    end

    @testset "FWInt negative with pad" begin
        desc = FWInt(pad='0')
        @test parse_field(desc, to_buf("0-42"), 1, 4) == -42
    end

    @testset "FWFloat default pad (space) unchanged" begin
        @test FWFloat().pad == ' '
        @test parse_field(FWFloat(), to_buf("  3.14  "), 1, 8) ≈ 3.14
    end

    @testset "FWFloat zero-padded" begin
        desc = FWFloat(pad='0')
        @test parse_field(desc, to_buf("003.1400"), 1, 8) ≈ 3.14
    end

    @testset "FWFloat all-pad returns 0.0" begin
        desc = FWFloat(pad='0')
        @test parse_field(desc, to_buf("00000000"), 1, 8) ≈ 0.0
    end

    @testset "parse_file with padded int" begin
        path = tempname()
        open(path, "w") do io
            write(io, "UA0042\nDL0099\n")
        end
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt(pad='0')),
        )
        sa = parse_file(path, schema)
        @test sa.fnum == [42, 99]
        rm(path)
    end
end
