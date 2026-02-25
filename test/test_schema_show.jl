using Test
using FixedWidthParsers
using FixedWidthParsers: _descriptor_string

@testset "Schema Visualization" begin

    @testset "_descriptor_string" begin
        @test _descriptor_string(FWString()) == "FWString"
        @test _descriptor_string(FWString(pad='0')) == "FWString(pad='0')"
        @test _descriptor_string(FWInt()) == "FWInt"
        @test _descriptor_string(FWInt(pad='0')) == "FWInt(pad='0')"
        @test _descriptor_string(FWFloat()) == "FWFloat"
        @test _descriptor_string(FWBool()) == "FWBool"
        @test _descriptor_string(FWBool(true_val="T", false_val="F")) == "FWBool(\"T\",\"F\")"
        @test _descriptor_string(FWDate("yyyymmdd")) == "FWDate"
        @test _descriptor_string(FWDate("ddmmyyyy")) == "FWDate(\"ddmmyyyy\")"
        @test _descriptor_string(FWFixedPoint(2)) == "FWFixedPoint(2)"
        @test _descriptor_string(FWSkip()) == "FWSkip"
        @test _descriptor_string(FWInt(default=0)) == "FWInt(default=0)"
        @test _descriptor_string(FWInt(pad='0', default=0)) == "FWInt(pad='0', default=0)"
        @test _descriptor_string(FWString(transform=uppercase)) == "FWString+transform"
        @test _descriptor_string(FWInt(pad='0', default=0, transform=abs)) == "FWInt(pad='0', default=0)+transform"
    end

    @testset "compact show" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_skip   => (3, FWSkip()),
            :origin  => (3, FWString()),
        )
        s = sprint(show, schema)
        @test contains(s, "12 bytes")
        @test contains(s, "4 fields")
        @test contains(s, "3 output")
    end

    @testset "multi-line show" begin
        schema = FixedWidthSchema(
            :carrier => (2, FWString()),
            :fnum    => (4, FWInt()),
            :_skip   => (3, FWSkip()),
            :origin  => (3, FWString()),
        )
        s = sprint(show, MIME("text/plain"), schema)
        @test contains(s, "Bytes")
        @test contains(s, "Width")
        @test contains(s, "Name")
        @test contains(s, "Type")
        @test contains(s, "carrier")
        @test contains(s, "fnum")
        @test contains(s, "_skip")
        @test contains(s, "origin")
        @test contains(s, "1:2")
        @test contains(s, "3:6")
        @test contains(s, "FWInt")
    end

    @testset "empty schema show" begin
        schema = FixedWidthSchema()
        s = sprint(show, schema)
        @test contains(s, "0 bytes")
        @test contains(s, "0 fields")
    end
end
