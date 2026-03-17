using Test
using FixedWidthParsers

@testset "Multi-file load_schema" begin

    function _write_schema_csv(path, fields)
        open(path, "w") do io
            println(io, "name,start,end,type")
            for (name, s, e, t) in fields
                println(io, "$name,$s,$e,$t")
            end
        end
    end

    @testset "two bare files → MultiRecordSchema with filename labels" begin
        dir = mktempdir()
        hdr_path = joinpath(dir, "header.csv")
        dtl_path = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr_path, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl_path, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema(hdr_path, dtl_path)
        @test ms isa MultiRecordSchema
        labels = [s[2] for s in ms.schemas]
        @test :header in labels
        @test :detail in labels
    end

    @testset "three bare files" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        trl = joinpath(dir, "trailer.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])
        _write_schema_csv(trl, [("rec_type", 1, 1, "String"), ("count", 2, 10, "Int")])

        ms = load_schema(hdr, dtl, trl)
        labels = [s[2] for s in ms.schemas]
        @test :header in labels
        @test :detail in labels
        @test :trailer in labels
    end

    @testset "Char Pair keys" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema('H' => hdr, 'D' => dtl)
        @test ms isa MultiRecordSchema
        labels = [s[2] for s in ms.schemas]
        @test :H in labels
        @test :D in labels
    end

    @testset "String Pair keys with discriminator keyword" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 3, "String"), ("title", 4, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 3, "String"), ("value", 4, 10, "Int")])

        ms = load_schema("HDR" => hdr, "DTL" => dtl; discriminator=1:3)
        @test ms isa MultiRecordSchema
        @test ms.discriminator == 1:3
    end

    @testset "discriminator keyword with bare files" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 2, "String"), ("title", 3, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 2, "String"), ("value", 3, 10, "Int")])

        ms = load_schema(hdr, dtl; discriminator=1:2)
        @test ms.discriminator == 1:2
    end

    @testset "record_width keyword" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 5, "Int")])

        ms = load_schema(hdr, dtl; record_width=100)
        @test ms.record_width == 100
    end

    @testset "single Pair throws" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        @test_throws ArgumentError load_schema('H' => hdr)
    end

    @testset "duplicate filenames throw" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 5, "String")])
        @test_throws ArgumentError load_schema(hdr, hdr)
    end

    @testset "round-trip: multi-file load → parse_file" begin
        dir = mktempdir()
        hdr = joinpath(dir, "header.csv")
        dtl = joinpath(dir, "detail.csv")
        _write_schema_csv(hdr, [("rec_type", 1, 1, "String"), ("title", 2, 10, "String")])
        _write_schema_csv(dtl, [("rec_type", 1, 1, "String"), ("value", 2, 10, "Int")])

        ms = load_schema('H' => hdr, 'D' => dtl)

        data_path = tempname()
        open(data_path, "w") do io
            write(io, "HTestFile \n")
            write(io, "D       42\n")
        end

        result = parse_file(data_path, ms)
        @test result[:H].title == ["TestFile"]
        @test result[:D].value == [42]
        rm(data_path)
    end
end
