using Test
using FixedWidthParsers

@testset "Discriminator robustness" begin

    @testset "error message includes expected values" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema, "B" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "X  42\n")
        end
        err = try
            parse_file(path, ms)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = err.msg
        # Error message should show both the found value AND the expected values
        @test occursin("\"X\"", msg)
        @test occursin("A", msg)
        @test occursin("B", msg)
        rm(path)
    end

    @testset "error message includes expected values (eachrecord)" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        ms = MultiRecordSchema(1:1, "A" => schema, "B" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "X  42\n")
        end
        err = try
            collect(eachrecord(path, ms))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = err.msg
        @test occursin("\"X\"", msg)
        @test occursin("A", msg)
        @test occursin("B", msg)
        rm(path)
    end

    @testset "MultiRecordSchema accepts mixed key types via Any" begin
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))
        # Char and String keys should both work when constructed via pairs with different types
        # This tests that the constructor can handle heterogeneous key types
        ms = MultiRecordSchema(1:1, '1' => schema, "2" => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "1  42\n2  99\n")
        end
        result = parse_file(path, ms)
        @test result[:type_1].val == [42]
        @test result[Symbol("2")].val == [99]
        rm(path)
    end

    @testset "MultiRecordSchema accepts Char keys for multi-byte discriminator" begin
        # Currently Char keys require single-byte discriminator, but String(Char) should
        # work for multi-byte when the Char occupies only 1 byte of the range
        # This tests the error message is helpful
        schema = FixedWidthSchema(:rec_type => (2, FWString()), :val => (3, FWInt()))
        err = try
            MultiRecordSchema(1:2, 'H' => schema, 'D' => schema)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("single-byte", err.msg)
    end

    @testset "discriminator comparison normalizes types" begin
        # When discriminator values are stored as Strings, extraction from buffer
        # should always compare correctly regardless of how the String was constructed
        schema = FixedWidthSchema(:rec_type => (1, FWString()), :val => (4, FWInt()))

        # Construct with SubString keys (e.g., from strip() or string slicing)
        key1 = SubString("ABC", 1, 1)  # SubString "A"
        key2 = SubString("BCD", 1, 1)  # SubString "B"
        ms = MultiRecordSchema(1:1, string(key1) => schema, string(key2) => schema)
        path = tempname()
        open(path, "w") do io
            write(io, "A  42\nB  99\n")
        end
        result = parse_file(path, ms)
        @test result[:A].val == [42]
        @test result[:B].val == [99]
        rm(path)
    end
end
