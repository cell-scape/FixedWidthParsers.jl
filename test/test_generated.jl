using Test
using FixedWidthParsers
using FixedWidthParsers: record_width, _SCHEMA_CACHE

@testset "@generated Specialization" begin

    @testset "FWBool in @fixedwidth struct" begin
        @fixedwidth struct GenBoolRecord
            code::String = 2
            flag::Bool   = 1
        end
        path = tempname()
        open(path, "w") do io
            write(io, "ABY\nCDN\n")
        end
        sa = parse_file(path, GenBoolRecord)
        @test sa.flag == [true, false]
        @test sa.code == ["AB", "CD"]
        rm(path)
    end

    @testset "generated path matches runtime path" begin
        @fixedwidth struct GenCompareRecord
            carrier::String = 2
            fnum::Int       = 4
            origin::String  = 3
        end
        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, "UA$(lpad(i, 4))ORD\n")
            end
        end
        sa_gen = parse_file(path, GenCompareRecord)
        sa_rt  = parse_file(path, FixedWidthParsers.schema(GenCompareRecord))
        @test sa_gen.carrier == sa_rt.carrier
        @test sa_gen.fnum == sa_rt.fnum
        @test sa_gen.origin == sa_rt.origin
        rm(path)
    end

    @testset "lenient mode in generated path" begin
        @fixedwidth struct GenLenientRecord
            val::Int = 4
        end
        path = tempname()
        open(path, "w") do io
            write(io, "  42\n  XY\n  99\n")
        end
        sa = parse_file(path, GenLenientRecord; on_error=:lenient)
        @test sa.val[1] == 42
        @test sa.val[2] === missing
        @test sa.val[3] == 99
        rm(path)
    end

end
