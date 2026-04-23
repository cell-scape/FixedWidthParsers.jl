using Test
using FixedWidthParsers
using FixedWidthParsers: parse_field, FWString, FWInt, FWFloat, FWSkip,
                          FWDate, FWFixedPoint, Skip

@testset "Field Types" begin
    to_buf(s) = Vector{UInt8}(s)

    @testset "FWInt" begin
        buf = to_buf("  42")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        buf = to_buf("-123")
        @test parse_field(FWInt(), buf, 1, 4) == -123

        buf = to_buf("0007")
        @test parse_field(FWInt(), buf, 1, 4) == 7

        # Leading + is accepted
        buf = to_buf(" +42")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        # Trailing spaces after digits are accepted
        buf = to_buf("42  ")
        @test parse_field(FWInt(), buf, 1, 4) == 42

        # Leading and trailing spaces around a signed value
        buf = to_buf(" -5 ")
        @test parse_field(FWInt(), buf, 1, 4) == -5
    end

    @testset "FWInt strictness — reject malformed integers" begin
        # Non-leading '-' must not flip the sign silently
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1-23"), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("12-3"), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("5-"), 1, 2)

        # Non-leading '+' is also invalid
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1+2"), 1, 3)

        # Double signs
        @test_throws ArgumentError parse_field(FWInt(), to_buf("--5"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("++5"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-+5"), 1, 3)

        # Sign followed by space (no digit contiguous with the sign)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-  5"), 1, 4)

        # Interior spaces between digits
        @test_throws ArgumentError parse_field(FWInt(), to_buf("1 2"), 1, 3)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("12 34"), 1, 5)

        # No digits at all
        @test_throws ArgumentError parse_field(FWInt(), to_buf("    "), 1, 4)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("-"), 1, 1)
        @test_throws ArgumentError parse_field(FWInt(), to_buf("+"), 1, 1)
    end

    @testset "FWFloat" begin
        buf = to_buf("  3.14  ")
        @test parse_field(FWFloat(), buf, 1, 8) ≈ 3.14

        buf = to_buf("-1.5")
        @test parse_field(FWFloat(), buf, 1, 4) ≈ -1.5
    end

    @testset "FWString" begin
        buf = to_buf("UA ")
        val = parse_field(FWString(), buf, 1, 3)
        @test val == "UA"          # trailing spaces stripped
        @test typeof(val) <: AbstractString

        buf = to_buf("ORD")
        @test parse_field(FWString(), buf, 1, 3) == "ORD"
    end

    @testset "FWString with padding char" begin
        buf = to_buf("UA0")
        val = parse_field(FWString(pad='0'), buf, 1, 3)
        @test val == "UA"
    end

    @testset "FWString all-spaces returns empty string" begin
        buf = to_buf("   ")
        val = parse_field(FWString(), buf, 1, 3)
        @test val == ""
    end

    @testset "FWSkip" begin
        buf = to_buf("XXXXX")
        @test parse_field(FWSkip(), buf, 1, 5) === nothing
    end

    @testset "FWDate" begin
        buf = to_buf("20260224")
        val = parse_field(FWDate("yyyymmdd"), buf, 1, 8)
        @test val == Date(2026, 2, 24)
    end

    @testset "FWDate fast paths pick specialized type parameters" begin
        # Recognized formats encode the format identifier in the type parameter
        # so parse_field can dispatch to a zero-tokenizer byte-level parser.
        d_yyyymmdd = FWDate("yyyymmdd")
        @test d_yyyymmdd isa FWDate{:yyyymmdd}
        @test d_yyyymmdd isa FWDate   # UnionAll still matches

        d_iso = FWDate("yyyy-mm-dd")
        @test d_iso isa FWDate{:yyyy_mm_dd}

        # Unrecognized formats fall into the :generic bucket and use Dates.jl.
        d_custom = FWDate("yyyy/mm/dd")
        @test d_custom isa FWDate{:generic}

        # Fast-path results must match the Dates.jl result for the same bytes
        buf = to_buf("20260224")
        @test parse_field(d_yyyymmdd, buf, 1, 8) == Date(2026, 2, 24)
        buf = to_buf("2026-02-24")
        @test parse_field(d_iso, buf, 1, 10) == Date(2026, 2, 24)
        buf = to_buf("2026/02/24")
        @test parse_field(d_custom, buf, 1, 10) == Date(2026, 2, 24)

        # Leap day
        buf = to_buf("20240229")
        @test parse_field(d_yyyymmdd, buf, 1, 8) == Date(2024, 2, 29)

        # Invalid date via fast path: Date(y,m,d) throws on out-of-range
        buf = to_buf("20260230")   # Feb 30 — invalid
        @test_throws ArgumentError parse_field(d_yyyymmdd, buf, 1, 8)

        # ISO fast path rejects missing separators (falls back, which also errors)
        buf = to_buf("2026X02-24")
        @test_throws ArgumentError parse_field(d_iso, buf, 1, 10)
    end

    @testset "FWDate fast path — regression against Dates.jl" begin
        # Fuzz a handful of dates and compare fast path vs Dates.jl
        fast = FWDate("yyyymmdd")
        iso  = FWDate("yyyy-mm-dd")
        dfmt = Dates.DateFormat("yyyymmdd")
        ifmt = Dates.DateFormat("yyyy-mm-dd")
        for y in 1900:50:2100, m in (1, 4, 7, 12), d in (1, 15, 28)
            s1 = string(y) * lpad(string(m), 2, '0') * lpad(string(d), 2, '0')
            s2 = string(y) * "-" * lpad(string(m), 2, '0') * "-" * lpad(string(d), 2, '0')
            b1 = to_buf(s1); b2 = to_buf(s2)
            @test parse_field(fast, b1, 1, 8) == Dates.Date(s1, dfmt)
            @test parse_field(iso,  b2, 1, 10) == Dates.Date(s2, ifmt)
        end
    end

    @testset "FWDate fast path — dduuuyy (e.g. 10Jan26)" begin
        # Common airline/banking format: day + 3-letter month abbrev + 2-digit year.
        # Mirrors Dates.jl semantics: the 2-digit year is literal (e.g. "26" → year 26).
        d = FWDate("dduuuyy")
        @test d isa FWDate{:dduuuyy}

        dfmt = Dates.DateFormat("dduuuyy")

        cases = [
            "10Jan26", "05Feb99", "31Dec00", "01Jul50",
            "28Feb24", "29Feb24",  # leap day
            "15Mar20", "30Sep95", "01Apr01", "31Aug77",
        ]
        for s in cases
            buf = to_buf(s)
            @test parse_field(d, buf, 1, 7) == Dates.Date(s, dfmt)
        end

        # Invalid month abbreviation falls through to the generic Dates.jl path,
        # which then also rejects it.
        @test_throws ArgumentError parse_field(d, to_buf("10Xxx26"), 1, 7)

        # Width mismatch falls back to generic. Dates.jl is lenient about the
        # `yy` token and will greedily consume trailing digits, so a 9-byte
        # "10Jan2026" resolves to Date(2026, 1, 10) — we must match that.
        @test parse_field(d, to_buf("10Jan2026"), 1, 9) == Dates.Date(2026, 1, 10)
    end

    @testset "FWDate/FWTime/FWDateTime — no per-record String copy" begin
        # Regression guard: the old path did `Dates.Date(String(sv), fmt)`,
        # copying the field bytes into a fresh heap String (~48 bytes / call
        # for an 8-byte date). That additional allocation is easy to
        # reintroduce accidentally, so we verify end-to-end that parsing a
        # date-only column allocates below the old path's floor.
        n = 10_000
        lines = IOBuffer()
        for i in 1:n
            m = lpad(string((i % 12) + 1), 2, "0")
            d = lpad(string((i % 28) + 1), 2, "0")
            println(lines, "2026" * m * d)
        end
        src = String(take!(lines))
        schema = FixedWidthSchema(:d => (8, FWDate("yyyymmdd")))

        parse_string(src, schema)  # warm
        a = @allocated parse_string(src, schema)
        # Old path measured ~120 B/record; new path ~72 B/record. Threshold at
        # 100 catches regression with margin for Julia version variation.
        @test a / n < 100
    end

    @testset "FWFixedPoint" begin
        buf = to_buf("00012345")
        val = parse_field(FWFixedPoint(2), buf, 1, 8)
        @test val ≈ 123.45

        buf = to_buf("  500")
        val = parse_field(FWFixedPoint(2), buf, 1, 5)
        @test val ≈ 5.0
    end
end
