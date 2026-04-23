"""
    perf_baseline.jl — Focused baseline runner for RESULTS.md.

Run with: `julia --project --threads=8 benchmark/perf_baseline.jl`

Generates 1M- and 5M-record narrow files and a 500k-record wide file in
`/tmp/fwp_bench/`, measures best-of-5 wall-clock timings, and prints the
tables that feed `benchmark/RESULTS.md`.

Intentionally lightweight — does not use `BenchmarkTools`/`PkgBenchmark`.
If you need statistical rigor, use `benchmark/benchmarks.jl` instead.
"""

using FixedWidthParsers
using FixedWidthParsers: @fixedwidth, Skip
using Printf

const BENCH_DIR   = "/tmp/fwp_bench"
const PATH_1M     = joinpath(BENCH_DIR, "1M.dat")
const PATH_5M     = joinpath(BENCH_DIR, "5M.dat")
const PATH_WIDE   = joinpath(BENCH_DIR, "wide_500k.dat")

# Narrow: same layout as benchmark/benchmarks.jl (24-byte records, 7 fields)
const NARROW = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :skip    => (1, FWSkip()),
    :origin  => (3, FWString()),
    :dest    => (3, FWString()),
    :pax     => (3, FWInt()),
    :revenue => (8, FWInt()),
)

@fixedwidth struct BenchFlight
    carrier::String = 2
    fnum::Int       = 4
    _skip::Skip     = 1
    origin::String  = 3
    dest::String    = 3
    pax::Int        = 3
    revenue::Int    = 8
end

# Wide: 50 × 4-byte int columns (200-byte records)
const WIDE = FixedWidthSchema([Symbol("f", i) => (4, FWInt()) for i in 1:50]...)

function gen_narrow(path, n)
    carriers = ("UA", "DL", "AA", "WN")
    airports = ("ORD", "LAX", "JFK", "SFO", "DEN")
    open(path, "w") do io
        for i in 1:n
            write(io,
                carriers[((i - 1) % 4) + 1],
                lpad(1000 + (i % 9000), 4),
                " ",
                airports[((i - 1) % 5) + 1],
                airports[((i * 3 - 1) % 5) + 1],
                lpad(50 + (i % 250), 3),
                lpad(100000 + i * 7, 8, '0'),
                "\n",
            )
        end
    end
end

function gen_wide(path, n)
    open(path, "w") do io
        for i in 1:n
            for j in 1:50
                write(io, lpad(string((i * j) % 9999), 4))
            end
            write(io, '\n')
        end
    end
end

function ensure_files()
    mkpath(BENCH_DIR)
    isfile(PATH_1M)   || (println("  generating 1M narrow..."); gen_narrow(PATH_1M,   1_000_000))
    isfile(PATH_5M)   || (println("  generating 5M narrow..."); gen_narrow(PATH_5M,   5_000_000))
    isfile(PATH_WIDE) || (println("  generating 500k wide..."); gen_wide(PATH_WIDE,     500_000))
end

function bench(label, n_records, f, reps::Int=5)
    # Warm
    f()
    times = Float64[]
    for _ in 1:reps
        GC.gc()
        push!(times, @elapsed f())
    end
    best = minimum(times)
    med  = sort(times)[div(reps, 2) + 1]
    mrps = n_records / best / 1e6
    @printf("  %-42s  best=%7.1fms  med=%7.1fms  %6.2f M rec/s\n",
            label, best * 1000, med * 1000, mrps)
    return best
end

function main()
    ensure_files()
    println("\n# File sizes:")
    for p in (PATH_1M, PATH_5M, PATH_WIDE)
        @printf("  %-40s  %7.1f MB\n", basename(p), filesize(p) / 1024^2)
    end

    println("\n# Narrow schema — 1M records, Threads.nthreads() = $(Threads.nthreads())")
    bench("runtime columnar ntasks=1",      1_000_000, () -> parse_file(PATH_1M, NARROW))
    bench("runtime columnar ntasks=2",      1_000_000, () -> parse_file(PATH_1M, NARROW; ntasks=2))
    bench("runtime columnar ntasks=4",      1_000_000, () -> parse_file(PATH_1M, NARROW; ntasks=4))
    bench("runtime columnar ntasks=8",      1_000_000, () -> parse_file(PATH_1M, NARROW; ntasks=8))
    bench("@generated ntasks=1",            1_000_000, () -> parse_file(PATH_1M, BenchFlight))
    bench("@generated ntasks=4 (fallback)", 1_000_000, () -> parse_file(PATH_1M, BenchFlight; ntasks=4))
    bench("row-oriented",                   1_000_000, () -> parse_file(PATH_1M, NARROW; columnar=false), 3)

    println("\n# Narrow schema — 5M records")
    bench("runtime columnar ntasks=1",      5_000_000, () -> parse_file(PATH_5M, NARROW))
    bench("runtime columnar ntasks=4",      5_000_000, () -> parse_file(PATH_5M, NARROW; ntasks=4))
    bench("runtime columnar ntasks=8",      5_000_000, () -> parse_file(PATH_5M, NARROW; ntasks=8))
    bench("@generated ntasks=1",            5_000_000, () -> parse_file(PATH_5M, BenchFlight))
    bench("@generated ntasks=4",            5_000_000, () -> parse_file(PATH_5M, BenchFlight; ntasks=4))
    bench("@generated ntasks=8",            5_000_000, () -> parse_file(PATH_5M, BenchFlight; ntasks=8))

    println("\n# Wide schema — 50 int columns, 500k records")
    t1 = bench("ntasks=1", 500_000, () -> parse_file(PATH_WIDE, WIDE))
    for nt in (2, 4, 8)
        t = bench("ntasks=$nt", 500_000, () -> parse_file(PATH_WIDE, WIDE; ntasks=nt))
        @printf("    (%.2fx over ntasks=1)\n", t1 / t)
    end
end

main()
