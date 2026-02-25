using Test
using FixedWidthParsers
using FixedWidthParsers: FieldSpec, record_width, field_names,
                          field_offsets, n_fields, non_skip_indices

@testset "Schema" begin
    @testset "FieldSpec construction" begin
        fs = FieldSpec(:carrier, 2, FWString())
        @test fs.name == :carrier
        @test fs.width == 2
        @test fs.type isa FWString
    end

    @testset "FixedWidthSchema from pairs" begin
        schema = FixedWidthSchema(
            :carrier    => (2, FWString()),
            :flight_num => (4, FWInt()),
            :skip       => (1, FWSkip()),
            :origin     => (3, FWString()),
        )

        @test n_fields(schema) == 4
        @test record_width(schema) == 10  # 2 + 4 + 1 + 3
        @test field_names(schema) == (:carrier, :flight_num, :skip, :origin)
        @test field_offsets(schema) == (1, 3, 7, 8)  # 1-indexed cumulative
    end

    @testset "non_skip_indices" begin
        schema = FixedWidthSchema(
            :a    => (2, FWString()),
            :skip => (1, FWSkip()),
            :b    => (3, FWInt()),
        )
        @test non_skip_indices(schema) == [1, 3]
    end

    @testset "record_width" begin
        schema = FixedWidthSchema(
            :x => (5, FWString()),
            :y => (3, FWInt()),
        )
        @test record_width(schema) == 8
    end
end
