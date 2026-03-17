using Test
using FixedWidthParsers
using FixedWidthParsers: _parse_type_string

@testset "Schema Loading" begin
    @testset "_parse_type_string" begin
        @test _parse_type_string("String") isa FWString
        @test _parse_type_string("Int") isa FWInt
        @test _parse_type_string("Float64") isa FWFloat
        @test _parse_type_string("Skip") isa FWSkip
        @test _parse_type_string("Date") isa FWDate
        @test _parse_type_string("Date").format_string == "yyyymmdd"
        @test _parse_type_string("Date(ddmmyyyy)") isa FWDate
        @test _parse_type_string("Date(ddmmyyyy)").format_string == "ddmmyyyy"
        @test _parse_type_string("FixedPoint(2)") isa FWFixedPoint
        @test _parse_type_string("FixedPoint(2)").decimals == 2
        @test _parse_type_string("FixedPoint(0)").decimals == 0
        @test_throws ArgumentError _parse_type_string("Unknown")
        @test_throws ArgumentError _parse_type_string("")
        @test_throws ArgumentError _parse_type_string("   ")
        @test_throws ArgumentError _parse_type_string("Date()")
        @test_throws ArgumentError _parse_type_string("FixedPoint()")
        @test_throws ArgumentError _parse_type_string("FixedPoint(2x)")
        @test _parse_type_string("  Int  ") isa FWInt
    end

    @testset "Range-based FixedWidthSchema" begin
        using FixedWidthParsers: record_width, field_names, field_offsets, n_fields

        @testset "basic range construction" begin
            s = FixedWidthSchema(
                :carrier => (1:2, FWString()),
                :fnum    => (3:6, FWInt()),
                :origin  => (7:9, FWString()),
            )
            @test record_width(s) == 9
            @test field_names(s) == (:carrier, :fnum, :origin)
            @test field_offsets(s) == (1, 3, 7)
        end

        @testset "gap auto-fills with FWSkip" begin
            s = FixedWidthSchema(
                :carrier => (1:2, FWString()),
                :origin  => (7:9, FWString()),
            )
            @test record_width(s) == 9
            @test n_fields(s) == 3
            @test field_offsets(s) == (1, 3, 7)
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 4
        end

        @testset "fields need not be in order" begin
            s = FixedWidthSchema(
                :origin  => (7:9, FWString()),
                :carrier => (1:2, FWString()),
            )
            @test field_names(s) == (:carrier, :_skip_3_6, :origin)
            @test field_offsets(s) == (1, 3, 7)
        end

        @testset "overlapping fields throw" begin
            @test_throws ArgumentError FixedWidthSchema(
                :a => (1:5, FWString()),
                :b => (3:7, FWString()),
            )
        end

        @testset "record_width keyword extends schema" begin
            s = FixedWidthSchema(
                :a => (1:2, FWString());
                record_width=10,
            )
            @test record_width(s) == 10
            @test n_fields(s) == 2
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 8
            @test s.fields[2].offset == 3
        end

        @testset "record_width keyword too small throws" begin
            @test_throws ArgumentError FixedWidthSchema(
                :a => (1:5, FWString());
                record_width=3,
            )
        end

        @testset "gap at start fills with FWSkip" begin
            s = FixedWidthSchema(
                :a => (5:7, FWString()),
            )
            @test record_width(s) == 7
            @test n_fields(s) == 2
            @test s.fields[1].type isa FWSkip
            @test s.fields[1].width == 4
            @test field_offsets(s) == (1, 5)
        end
    end

    @testset "Start+width FixedWidthSchema" begin
        using FixedWidthParsers: record_width, field_names, field_offsets

        @testset "basic start+width construction" begin
            s = FixedWidthSchema(
                :carrier => (1, 2, FWString()),
                :fnum    => (3, 4, FWInt()),
            )
            @test record_width(s) == 6
            @test field_names(s) == (:carrier, :fnum)
            @test field_offsets(s) == (1, 3)
        end

        @testset "start+width with record_width" begin
            s = FixedWidthSchema(
                :a => (1, 2, FWString());
                record_width=10,
            )
            @test record_width(s) == 10
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 8
            @test s.fields[2].offset == 3
        end

        @testset "start+width record_width too small throws" begin
            @test_throws ArgumentError FixedWidthSchema(
                :a => (1, 5, FWString());
                record_width=3,
            )
        end

        @testset "start+width with gap" begin
            s = FixedWidthSchema(
                :carrier => (1, 2, FWString()),
                :origin  => (7, 3, FWString()),
            )
            @test record_width(s) == 9
            @test s.fields[2].type isa FWSkip
        end
    end

    @testset "Mixing modes throws" begin
        @test_throws ArgumentError FixedWidthSchema(
            :a => (2, FWString()),
            :b => (3:5, FWString()),
        )
    end

    @testset "String field names auto-convert to Symbol" begin
        using FixedWidthParsers: record_width
        s = FixedWidthSchema("carrier" => (2, FWString()), "fnum" => (4, FWInt()))
        @test record_width(s) == 6
        @test s._output_names == (:carrier, :fnum)
    end

    @testset "String field names in range mode" begin
        using FixedWidthParsers: record_width
        s = FixedWidthSchema("carrier" => (1:2, FWString()), "fnum" => (3:6, FWInt()))
        @test record_width(s) == 6
        @test s._output_names == (:carrier, :fnum)
    end

    @testset "load_schema CSV" begin
        using FixedWidthParsers: record_width, field_names

        @testset "basic CSV loading" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,String")
                println(io, "fnum,3,6,Int")
                println(io, "origin,7,9,String")
            end
            s = load_schema(path)
            @test record_width(s) == 9
            @test s._output_names == (:carrier, :fnum, :origin)
            rm(path)
        end

        @testset "CSV with extra columns" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type,description")
                println(io, "carrier,1,2,String,Airline code")
                println(io, "fnum,3,6,Int,Flight number")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV with comments and blank lines" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "# This is a comment")
                println(io, "name,start,end,type")
                println(io, "")
                println(io, "carrier,1,2,String")
                println(io, "# Another comment")
                println(io, "fnum,3,6,Int")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV column order independent" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "type,end,name,start")
                println(io, "String,2,carrier,1")
                println(io, "Int,6,fnum,3")
            end
            s = load_schema(path)
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "CSV missing required column throws" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,type")
                println(io, "carrier,1,String")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end

        @testset "CSV with gap auto-fills FWSkip" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,String")
                println(io, "origin,7,9,String")
            end
            s = load_schema(path)
            @test record_width(s) == 9
            @test s.fields[2].type isa FWSkip
            @test s.fields[2].width == 4
            rm(path)
        end

        @testset "CSV unknown type throws" begin
            path = tempname() * ".csv"
            open(path, "w") do io
                println(io, "name,start,end,type")
                println(io, "carrier,1,2,Boolean")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end
    end

    @testset "load_schema TOML" begin
        using FixedWidthParsers: record_width

        @testset "basic TOML loading" begin
            path = tempname() * ".toml"
            open(path, "w") do io
                println(io, "[[fields]]")
                println(io, "name = \"carrier\"")
                println(io, "start = 1")
                println(io, "end = 2")
                println(io, "type = \"String\"")
                println(io, "")
                println(io, "[[fields]]")
                println(io, "name = \"fnum\"")
                println(io, "start = 3")
                println(io, "end = 6")
                println(io, "type = \"Int\"")
            end
            s = load_schema(path)
            @test record_width(s) == 6
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "TOML missing field key throws" begin
            path = tempname() * ".toml"
            open(path, "w") do io
                println(io, "[[fields]]")
                println(io, "name = \"carrier\"")
                println(io, "start = 1")
                println(io, "type = \"String\"")
            end
            @test_throws ArgumentError load_schema(path)
            rm(path)
        end
    end

    @testset "load_schema unsupported extension" begin
        path = tempname() * ".xml"
        open(path, "w") do io
            println(io, "<schema/>")
        end
        @test_throws ArgumentError load_schema(path)
        rm(path)
    end

    @testset "load_schema JSON" begin
        using JSON3
        using FixedWidthParsers: record_width

        @testset "basic JSON loading" begin
            path = tempname() * ".json"
            open(path, "w") do io
                write(io, """
                {
                    "fields": [
                        {"name": "carrier", "start": 1, "end": 2, "type": "String"},
                        {"name": "fnum", "start": 3, "end": 6, "type": "Int"}
                    ]
                }
                """)
            end
            s = load_schema(path)
            @test record_width(s) == 6
            @test s._output_names == (:carrier, :fnum)
            rm(path)
        end

        @testset "JSON with gap" begin
            path = tempname() * ".json"
            open(path, "w") do io
                write(io, """
                {
                    "fields": [
                        {"name": "carrier", "start": 1, "end": 2, "type": "String"},
                        {"name": "origin", "start": 7, "end": 9, "type": "String"}
                    ]
                }
                """)
            end
            s = load_schema(path)
            @test record_width(s) == 9
            @test s.fields[2].type isa FWSkip
            rm(path)
        end
    end

    @testset "Round-trip: load schema → parse file" begin
        using FixedWidthParsers: record_width

        # Create a data file
        data_path = tempname()
        open(data_path, "w") do io
            write(io, "UA1234ORD\n")
            write(io, "DL5678LAX\n")
        end

        # Create a CSV schema file
        csv_path = tempname() * ".csv"
        open(csv_path, "w") do io
            println(io, "name,start,end,type")
            println(io, "carrier,1,2,String")
            println(io, "fnum,3,6,Int")
            println(io, "origin,7,9,String")
        end

        schema = load_schema(csv_path)
        result = parse_file(data_path, schema)
        @test length(result) == 2
        @test result.carrier == ["UA", "DL"]
        @test result.fnum == [1234, 5678]
        @test result.origin == ["ORD", "LAX"]

        rm(data_path)
        rm(csv_path)
    end
end
