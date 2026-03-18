using Test
using FixedWidthParsers

@testset "Bundled Schemas" begin

    @testset "SSIM multi-record schema" begin
        @test SSIM_SCHEMA isa MultiRecordSchema
        @test SSIM_SCHEMA.discriminator == 1:1
        @test SSIM_SCHEMA.record_width == 200
        @test length(SSIM_SCHEMA.schemas) == 5

        # Check discriminator values and labels
        disc_vals = [dv for (dv, _, _) in SSIM_SCHEMA.schemas]
        labels = [lbl for (_, lbl, _) in SSIM_SCHEMA.schemas]
        @test disc_vals == ["1", "2", "3", "4", "5"]
        @test labels == [:type_1, :type_2, :type_3, :type_4, :type_5]
    end

    @testset "standalone schemas exist" begin
        @test AIRCRAFT_SCHEMA isa FixedWidthSchema
        @test AIRPORT_SCHEMA isa FixedWidthSchema
        @test MCT_SCHEMA isa FixedWidthSchema
        @test MCT_PRIORITY_SCHEMA isa FixedWidthSchema
        @test REGIONAL_SCHEMA isa FixedWidthSchema
        @test SEATS_SCHEMA isa FixedWidthSchema
    end

    @testset "standalone schema field spot checks" begin
        # Aircraft: first field is fleet at 1:3
        aircraft_names = FixedWidthParsers.field_names(AIRCRAFT_SCHEMA)
        @test :fleet in aircraft_names
        @test :equip in aircraft_names

        # Regional: small schema with region, airport, city
        regional_names = FixedWidthParsers.field_names(REGIONAL_SCHEMA)
        @test :region in regional_names
        @test :airport in regional_names
        @test :city in regional_names

        # MCT: has record_type, arrival_station, time, etc.
        mct_names = FixedWidthParsers.field_names(MCT_SCHEMA)
        @test :arrival_station in mct_names
        @test :departure_station in mct_names
        @test :serial_number in mct_names
    end
end
