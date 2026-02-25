using Test
using FixedWidthParsers
using FixedWidthParsers: MmapSource, ChunkedSource, detect_newline, record_count, buffer, record_offset

@testset "IO Layer" begin
    @testset "detect_newline with LF" begin
        buf = Vector{UInt8}("ABCD\nEFGH\n")
        @test detect_newline(buf, 4) == 1
    end

    @testset "detect_newline with CRLF" begin
        buf = Vector{UInt8}("ABCD\r\nEFGH\r\n")
        @test detect_newline(buf, 4) == 2
    end

    @testset "detect_newline no newline" begin
        buf = Vector{UInt8}("ABCDEFGH")
        @test detect_newline(buf, 4) == 0
    end

    @testset "MmapSource from file with LF" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\n")
            write(io, "BBBB\n")
            write(io, "CCCC\n")
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 3
        @test length(buffer(src)) == 15  # 3 * 5
        @test record_offset(src, 1) == 1
        @test record_offset(src, 2) == 6
        @test record_offset(src, 3) == 11
        close(src)
        rm(path)
    end

    @testset "MmapSource from file with CRLF" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\r\n")
            write(io, "BBBB\r\n")
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 2
        @test record_offset(src, 2) == 7  # stride = 4 + 2 = 6
        close(src)
        rm(path)
    end

    @testset "MmapSource no trailing newline" begin
        path = tempname()
        open(path, "w") do io
            write(io, "AAAA\nBBBB")  # last record has no newline
        end

        src = MmapSource(path, 4)
        @test record_count(src) == 2
        close(src)
        rm(path)
    end

    @testset "MmapSource empty file" begin
        path = tempname()
        open(path, "w") do io end

        src = MmapSource(path, 4)
        @test record_count(src) == 0
        close(src)
        rm(path)
    end
end

@testset "ChunkedSource" begin
    @testset "from IOBuffer" begin
        data = "AAAA\nBBBB\nCCCC\n"
        io = IOBuffer(data)
        src = ChunkedSource(io, 4)
        @test record_count(src) == 3
    end

    @testset "from IOBuffer with CRLF" begin
        data = "AAAA\r\nBBBB\r\n"
        io = IOBuffer(data)
        src = ChunkedSource(io, 4)
        @test record_count(src) == 2
    end

    @testset "eachrecord from IO" begin
        schema = FixedWidthSchema(:val => (4, FWString()))
        io = IOBuffer("AAAA\nBBBB\n")
        records = collect(eachrecord(io, schema))
        @test length(records) == 2
        @test records[1].val == "AAAA"
        @test records[2].val == "BBBB"
    end

    @testset "eachrecord from IOBuffer with FixedWidthSchema" begin
        schema = FixedWidthSchema(
            :name => (3, FWString()),
            :num  => (2, FWInt()),
        )
        io = IOBuffer("abc10\ndef20\n")
        records = collect(eachrecord(io, schema))
        @test length(records) == 2
        @test records[1].name == "abc"
        @test records[2].num == 20
    end
end
