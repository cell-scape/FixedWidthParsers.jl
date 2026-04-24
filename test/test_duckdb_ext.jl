using Test
using FixedWidthParsers
using DuckDB
using DBInterface
using Dates

# Extension sanity: the method is added only when DuckDB is loaded.
@test hasmethod(to_duckdb,
    Tuple{Any, AbstractString, AbstractString, FixedWidthSchema})

@testset "DuckDBExt" begin
    sql(con, q) = DBInterface.execute(con, q) |> collect

    function write_file(rows::Vector{String})
        path = tempname()
        open(path, "w") do io
            for r in rows
                write(io, r, '\n')
            end
        end
        return path
    end

    @testset "basic round-trip (path source)" begin
        schema = FixedWidthSchema(
            :carrier    => (2, FWString()),
            :flight_num => (4, FWInt()),
            :origin     => (3, FWString()),
        )
        path = write_file(["UA1234ORD", "DL 567LAX", "AA 999SFO"])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        tn = to_duckdb(con, "flights", path, schema)
        @test tn == "flights"

        rows = sql(con, "SELECT carrier, flight_num, origin FROM flights ORDER BY flight_num")
        @test length(rows) == 3
        @test rows[1].carrier == "DL" && rows[1].flight_num == 567  && rows[1].origin == "LAX"
        @test rows[2].carrier == "AA" && rows[2].flight_num == 999  && rows[2].origin == "SFO"
        @test rows[3].carrier == "UA" && rows[3].flight_num == 1234 && rows[3].origin == "ORD"

        DBInterface.close!(con)
        rm(path)
    end

    @testset "DDL translation — all core descriptor types" begin
        schema = FixedWidthSchema(
            :s  => (3, FWString()),
            :i  => (4, FWInt()),
            :f  => (5, FWFloat()),
            :fp => (5, FWFixedPoint(2)),
            :b  => (1, FWBool(true_val="Y", false_val="N")),
            :d  => (8, FWDate("yyyymmdd")),
            :t  => (4, FWTime("HHMM")),
            :dt => (12, FWDateTime("yyyymmddHHMM")),
        )
        # 3 + 4 + 5 + 5 + 1 + 8 + 4 + 12 = 42 bytes per record
        path = write_file([
            "abc" * "  42" * "  3.5" * "00125" * "Y" * "20260224" * "0930" * "202603171430",
        ])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "wide", path, schema)

        # Inspect DuckDB's inferred column types
        descr = sql(con, "DESCRIBE wide")
        types = Dict(r.column_name => r.column_type for r in descr)
        @test types["s"]  == "VARCHAR"
        @test types["i"]  == "BIGINT"
        @test types["f"]  == "DOUBLE"
        @test types["fp"] == "DOUBLE"
        @test types["b"]  == "BOOLEAN"
        @test types["d"]  == "DATE"
        @test types["t"]  == "TIME"
        @test types["dt"] == "TIMESTAMP"

        rows = sql(con, "SELECT * FROM wide")
        @test length(rows) == 1
        r = rows[1]
        @test r.s  == "abc"
        @test r.i  == 42
        @test r.f  ≈ 3.5
        @test r.fp ≈ 1.25
        @test r.b  == true
        @test r.d  == Date(2026, 2, 24)
        @test r.t  == Time(9, 30)
        @test r.dt == DateTime(2026, 3, 17, 14, 30)

        DBInterface.close!(con)
        rm(path)
    end

    @testset "chunked insert across chunk boundaries" begin
        schema = FixedWidthSchema(:i => (6, FWInt()))
        n = 1000
        path = write_file([lpad(string(i), 6) for i in 1:n])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        # chunk_size=137 forces several boundaries that don't align with n
        to_duckdb(con, "seq", path, schema; chunk_size=137)

        count_row = sql(con, "SELECT COUNT(*) AS c, SUM(i) AS s FROM seq")[1]
        @test count_row.c == n
        @test count_row.s == sum(1:n)

        DBInterface.close!(con)
        rm(path)
    end

    @testset "skip_header / skip_footer / comment" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = write_file([
            "HDR  99",
            "# cmnt ",
            "foo  10",
            "bar  20",
            "FTR  99",
        ])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "t", path, schema;
            skip_header=1, skip_footer=1, comment=UInt8('#'))

        rows = sql(con, "SELECT name, val FROM t ORDER BY val")
        @test length(rows) == 2
        @test rows[1].name == "foo" && rows[1].val == 10
        @test rows[2].name == "bar" && rows[2].val == 20

        DBInterface.close!(con)
        rm(path)
    end

    @testset "lenient mode — bad fields become NULL" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = write_file([
            "foo  10",
            "bar abc",  # bad int → NULL under :lenient
            "baz  30",
        ])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "t", path, schema; on_error=:lenient)

        # DuckDB reports NULL count and uses IS NULL
        null_count = sql(con, "SELECT COUNT(*) AS c FROM t WHERE val IS NULL")[1].c
        @test null_count == 1
        good = sql(con, "SELECT val FROM t WHERE val IS NOT NULL ORDER BY val")
        @test [r.val for r in good] == [10, 30]

        DBInterface.close!(con)
        rm(path)
    end

    @testset "select / exclude" begin
        schema = FixedWidthSchema(
            :a => (2, FWString()),
            :b => (3, FWInt()),
            :c => (3, FWString()),
        )
        path = write_file(["AB123CDE", "FG456HIJ"])

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "only_a_c", path, schema; select=[:a, :c])
        cols = [r.column_name for r in sql(con, "DESCRIBE only_a_c")]
        @test Set(cols) == Set(["a", "c"])

        to_duckdb(con, "no_b", path, schema; exclude=[:b])
        cols = [r.column_name for r in sql(con, "DESCRIBE no_b")]
        @test Set(cols) == Set(["a", "c"])

        DBInterface.close!(con)
        rm(path)
    end

    @testset "IO source (IOBuffer)" begin
        schema = FixedWidthSchema(:s => (3, FWString()), :i => (4, FWInt()))
        data = "abc1234\nxyz   5\n"
        io = IOBuffer(data)

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "t", io, schema)

        rows = sql(con, "SELECT s, i FROM t ORDER BY i")
        @test length(rows) == 2
        @test rows[1].s == "xyz" && rows[1].i == 5
        @test rows[2].s == "abc" && rows[2].i == 1234

        DBInterface.close!(con)
    end

    @testset "create_table=false appends to existing table" begin
        schema = FixedWidthSchema(:i => (4, FWInt()))

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        DBInterface.execute(con, "CREATE TABLE manual (i BIGINT)")
        DBInterface.execute(con, "INSERT INTO manual VALUES (999)")

        path = write_file(["   1", "   2", "   3"])
        to_duckdb(con, "manual", path, schema; create_table=false)

        rows = sql(con, "SELECT i FROM manual ORDER BY i")
        @test [r.i for r in rows] == [1, 2, 3, 999]

        DBInterface.close!(con)
        rm(path)
    end

    @testset "replace_table=true drops existing" begin
        schema = FixedWidthSchema(:i => (4, FWInt()))

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        DBInterface.execute(con, "CREATE TABLE t (wrong BIGINT)")
        DBInterface.execute(con, "INSERT INTO t VALUES (999)")

        path = write_file(["   1", "   2"])
        to_duckdb(con, "t", path, schema; replace_table=true)

        rows = sql(con, "SELECT * FROM t ORDER BY i")
        @test [r.i for r in rows] == [1, 2]
        cols = [r.column_name for r in sql(con, "DESCRIBE t")]
        @test cols == ["i"]

        DBInterface.close!(con)
        rm(path)
    end

    @testset "empty file produces empty table" begin
        schema = FixedWidthSchema(:s => (3, FWString()))
        path = tempname()
        open(path, "w") do io end

        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "t", path, schema)
        @test sql(con, "SELECT COUNT(*) AS c FROM t")[1].c == 0

        DBInterface.close!(con)
        rm(path)
    end

    @testset "nworkers > 1: concurrent inserts from separate connections" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (5, FWInt()),
        )
        n = 5_000
        path = tempname()
        open(path, "w") do io
            for i in 1:n
                nm = lpad("r$i", 4)[1:4]
                write(io, nm, lpad(string(i), 5), '\n')
            end
        end

        for nw in (2, 4, 8)
            con = DBInterface.connect(DuckDB.DB, ":memory:")
            to_duckdb(con, "t", path, schema;
                nworkers = nw, chunk_size = 500, replace_table = true)
            row = sql(con, "SELECT COUNT(*) AS c, SUM(val) AS s FROM t")[1]
            @test row.c == n
            @test row.s == sum(1:n)
            DBInterface.close!(con)
        end
        rm(path)
    end

    @testset "nworkers with strict-mode error still pinpoints the line" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        # 100 records with a bad int at line 47
        path = tempname()
        open(path, "w") do io
            for i in 1:100
                v = i == 47 ? "XXX" : lpad(string(i), 3)
                write(io, lpad("r$i", 4)[1:4], v, '\n')
            end
        end
        con = DBInterface.connect(DuckDB.DB, ":memory:")
        err = try
            to_duckdb(con, "t", path, schema; nworkers = 4, chunk_size = 20)
            nothing
        catch e
            e
        end
        @test err isa ParseError
        @test err.line == 47
        DBInterface.close!(con)
        rm(path)
    end

    @testset "nworkers with lenient mode" begin
        schema = FixedWidthSchema(
            :name => (4, FWString()),
            :val  => (3, FWInt()),
        )
        path = write_file([
            "foo  10", "bar abc", "baz  30", "qux def", "aaa  50", "bbb  60",
            "ccc  70", "ddd xyz", "eee  90", "fff 100",
        ])
        con = DBInterface.connect(DuckDB.DB, ":memory:")
        to_duckdb(con, "t", path, schema; nworkers = 4, on_error = :lenient, chunk_size = 3)

        null_count = sql(con, "SELECT COUNT(*) AS c FROM t WHERE val IS NULL")[1].c
        @test null_count == 3
        @test sql(con, "SELECT COUNT(*) AS c FROM t")[1].c == 10
        DBInterface.close!(con)
        rm(path)
    end

    @testset "nworkers > 1 with a Connection (not DB) errors cleanly" begin
        schema = FixedWidthSchema(:v => (3, FWInt()))
        path = write_file(["  1", "  2"])
        db = DBInterface.connect(DuckDB.DB, ":memory:")
        con = DBInterface.connect(db)
        @test con isa DuckDB.Connection

        DBInterface.execute(con, "CREATE TABLE t (v BIGINT)")
        err = try
            to_duckdb(con, "t", path, schema;
                nworkers = 4, create_table = false)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DuckDB.DB", err.msg)
        DBInterface.close!(con)
        DBInterface.close!(db)
        rm(path)
    end
end
