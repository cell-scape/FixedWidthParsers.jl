using Test
using FixedWidthParsers

@testset "Iteration" begin
    schema = FixedWidthSchema(
        :name => (4, FWString()),
        :val  => (3, FWInt()),
    )

    @testset "eachrecord from file" begin
        path = tempname()
        open(path, "w") do io
            write(io, "foo  10\n")
            write(io, "bar  20\n")
            write(io, "baz  30\n")
        end

        records = collect(eachrecord(path, schema))
        @test length(records) == 3
        @test records[1].name == "foo"
        @test records[1].val == 10
        @test records[2].name == "bar"
        @test records[3].val == 30
        rm(path)
    end

    @testset "eachrecord is lazy (break early)" begin
        path = tempname()
        open(path, "w") do io
            for i in 1:100
                write(io, "test$(lpad(i, 3, '0'))\n")
            end
        end

        schema2 = FixedWidthSchema(:s => (7, FWString()))
        count = 0
        for record in eachrecord(path, schema2)
            count += 1
            count >= 5 && break
        end
        @test count == 5
        rm(path)
    end

    @testset "eachrecord length" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AA  001\n")
            write(io, "BB  002\n")
        end

        iter = eachrecord(path, schema)
        @test length(iter) == 2
        close(iter)
        rm(path)
    end

    @testset "eachrecord empty file" begin
        path = tempname()
        open(path, "w") do io end

        records = collect(eachrecord(path, schema))
        @test length(records) == 0
        rm(path)
    end
end
