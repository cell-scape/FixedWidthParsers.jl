using Test
using FixedWidthParsers

@testset "MultiRecordSchema" begin

    @testset "basic H/D/T parsing" begin
        header_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :title    => (9, FWString()),
        )
        detail_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :code     => (3, FWString()),
            :value    => (6, FWInt()),
        )
        trailer_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :count    => (9, FWInt()),
        )

        ms = MultiRecordSchema(
            1:1,
            "H" => header_schema,
            "D" => detail_schema,
            "T" => trailer_schema,
        )

        path = tempname()
        open(path, "w") do io
            write(io, "HTestFile \n")
            write(io, "DABC   123\n")
            write(io, "DDEF   456\n")
            write(io, "T        3\n")
        end

        result = parse_file(path, ms)
        @test result[:H].title == ["TestFile"]
        @test result[:D].code == ["ABC", "DEF"]
        @test result[:D].value == [123, 456]
        @test result[:T].count == [3]
        rm(path)
    end

    @testset "unknown discriminator throws" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "A  42\nX  99\n")
        end
        @test_throws ArgumentError parse_file(path, ms)
        rm(path)
    end

    @testset "skip_header and skip_footer" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (2, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "H00\nD42\nD99\nT00\n")
        end
        result = parse_file(path, ms; skip_header=1, skip_footer=1)
        @test result[:D].val == [42, 99]
        rm(path)
    end

    @testset "multi-byte discriminator" begin
        schema_hd = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWString()))
        schema_dt = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
        ms = MultiRecordSchema(1:2, "HD" => schema_hd, "DT" => schema_dt)
        path = tempname()
        open(path, "w") do io
            write(io, "HDABC\nDT 42\n")
        end
        result = parse_file(path, ms)
        @test result[:HD].val == ["ABC"]
        @test result[:DT].val == [42]
        rm(path)
    end

    @testset "empty group" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (2, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema, "B" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "A42\nA99\n")
        end
        result = parse_file(path, ms)
        @test length(result[:A]) == 2
        @test length(result[:B]) == 0
        rm(path)
    end

    @testset "construction validation" begin
        schema = FixedWidthSchema(:val => (3, FWString()))
        # Empty discriminator range
        @test_throws ArgumentError MultiRecordSchema(1:0, "A" => schema)
        # No pairs supplied
        @test_throws ArgumentError MultiRecordSchema(1:1)
        # Duplicate discriminator values
        @test_throws ArgumentError MultiRecordSchema(1:1, "A" => schema, "A" => schema)
    end

    @testset "record_width override" begin
        short_schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => short_schema; record_width=10)
        path = tempname()
        open(path, "w") do io
            write(io, "D  42     \nD  99     \n")
        end
        result = parse_file(path, ms)
        @test result[:D].val == [42, 99]
        rm(path)
    end

    @testset "eachrecord with multi-record" begin
        schema_h = FixedWidthSchema(:rec_type => (1, FWString()), :title => (4, FWString()))
        schema_d = FixedWidthSchema(:rec_type => (1, FWString()), :value => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "H" => schema_h, "D" => schema_d)
        path = tempname()
        open(path, "w") do io
            write(io, "HTest\nD  42\nD  99\n")
        end
        records = collect(eachrecord(path, ms))
        @test length(records) == 3
        @test records[1]._type === :H
        @test records[1].title == "Test"
        @test records[2]._type === :D
        @test records[2].value == 42
        rm(path)
    end

    @testset "on_error applies to all schemas" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "D" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "D  42\nD  XY\n")
        end
        result = parse_file(path, ms; on_error=:lenient)
        @test result[:D].val[1] == 42
        @test result[:D].val[2] === missing
        rm(path)
    end

    @testset "Char discriminator keys" begin
        header_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :title    => (9, FWString()),
        )
        detail_schema = FixedWidthSchema(
            :rec_type => (1, FWString()),
            :value    => (9, FWInt()),
        )

        ms = MultiRecordSchema(1:1, 'H' => header_schema, 'D' => detail_schema)
        path = tempname()
        open(path, "w") do io
            write(io, "HTestFile \n")
            write(io, "D       42\n")
        end
        result = parse_file(path, ms)
        @test result[:H].title == ["TestFile"]
        @test result[:D].value == [42]
        rm(path)
    end

    @testset "Char digit keys get :type_ prefix" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, '1' => schema, '2' => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "1  42\n2  99\n")
        end
        result = parse_file(path, ms)
        @test haskey(result, :type_1)
        @test haskey(result, :type_2)
        @test result[:type_1].val == [42]
        @test result[:type_2].val == [99]
        rm(path)
    end

    @testset "Int discriminator keys" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, 1 => schema, 2 => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "1  42\n2  99\n")
        end
        result = parse_file(path, ms)
        @test haskey(result, :type_1)
        @test haskey(result, :type_2)
        @test result[:type_1].val == [42]
        rm(path)
    end

    @testset "Int position shorthand" begin
        schema_h = FixedWidthSchema(:rec_type => (1, FWString()), :title => (4, FWString()))
        schema_d = FixedWidthSchema(:rec_type => (1, FWString()), :value => (4, FWInt()))
        ms = MultiRecordSchema(1, 'H' => schema_h, 'D' => schema_d)
        path = tempname()
        open(path, "w") do io
            write(io, "HTest\nD  42\n")
        end
        result = parse_file(path, ms)
        @test result[:H].title == ["Test"]
        @test result[:D].value == [42]
        rm(path)
    end

    @testset "unconditional discriminator trimming" begin
        schema = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
        ms = MultiRecordSchema(1:2, "H" => schema, "D" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "H  42\nD  99\n")
        end
        result = parse_file(path, ms)
        @test result[:H].val == [42]
        @test result[:D].val == [99]
        rm(path)
    end

    @testset "padded String keys are trimmed at construction" begin
        schema = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
        ms = MultiRecordSchema(1:2, "H " => schema, "D " => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "H  42\nD  99\n")
        end
        result = parse_file(path, ms)
        @test result[:H].val == [42]
        @test result[:D].val == [99]
        rm(path)
    end

    @testset "Char key requires single-byte discriminator" begin
        schema = FixedWidthSchema(:val => (3, FWString()))
        @test_throws ArgumentError MultiRecordSchema(1:2, 'H' => schema, 'D' => schema)
    end

    @testset "mixed key types are a MethodError" begin
        schema = FixedWidthSchema(:val => (3, FWString()))
        @test_throws MethodError MultiRecordSchema(1:1, 'H' => schema, "D" => schema)
    end

end
