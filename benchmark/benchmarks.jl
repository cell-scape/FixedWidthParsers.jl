using BenchmarkTools
using FixedWidthParsers

include("make_testdata.jl")

const SUITE = BenchmarkGroup()

# ---------------------------------------------------------------------------
# Test data generation
# Generate files once at load time into a temp directory so benchmarks are
# self-contained and do not pollute the repository.
# ---------------------------------------------------------------------------
const BENCHDIR = mktempdir()
generate_test_file(joinpath(BENCHDIR, "100K.dat"), 100_000)
generate_test_file(joinpath(BENCHDIR, "1M.dat"), 1_000_000)

# ---------------------------------------------------------------------------
# Schema shared by all benchmarks
#
# Layout (24 bytes per record + newline):
#   carrier  2  FWString
#   fnum     4  FWInt
#   skip     1  FWSkip
#   origin   3  FWString
#   dest     3  FWString
#   pax      3  FWInt
#   revenue  8  FWInt
# ---------------------------------------------------------------------------
const BENCH_SCHEMA = FixedWidthSchema(
    :carrier => (2, FWString()),
    :fnum    => (4, FWInt()),
    :skip    => (1, FWSkip()),
    :origin  => (3, FWString()),
    :dest    => (3, FWString()),
    :pax     => (3, FWInt()),
    :revenue => (8, FWInt()),
)

# ---------------------------------------------------------------------------
# parse_file benchmarks (columnar and row-oriented)
# ---------------------------------------------------------------------------
SUITE["parse_file"] = BenchmarkGroup()

SUITE["parse_file"]["100K_columnar"] = @benchmarkable parse_file(
    $(joinpath(BENCHDIR, "100K.dat")),
    $BENCH_SCHEMA,
)

SUITE["parse_file"]["1M_columnar"] = @benchmarkable parse_file(
    $(joinpath(BENCHDIR, "1M.dat")),
    $BENCH_SCHEMA,
)

SUITE["parse_file"]["100K_rows"] = @benchmarkable parse_file(
    $(joinpath(BENCHDIR, "100K.dat")),
    $BENCH_SCHEMA;
    columnar = false,
)

# ---------------------------------------------------------------------------
# eachrecord iteration benchmarks
# ---------------------------------------------------------------------------
SUITE["iteration"] = BenchmarkGroup()

SUITE["iteration"]["100K_collect"] = @benchmarkable collect(
    eachrecord($(joinpath(BENCHDIR, "100K.dat")), $BENCH_SCHEMA),
)

SUITE["iteration"]["1M_count"] = @benchmarkable begin
    n = 0
    for _ in eachrecord($(joinpath(BENCHDIR, "1M.dat")), $BENCH_SCHEMA)
        n += 1
    end
    n
end

# ---------------------------------------------------------------------------
# @generated columnar path benchmarks
#
# BenchFlight uses the same layout as BENCH_SCHEMA so the generated path
# parses the same test data files — enabling direct comparison.
# ---------------------------------------------------------------------------
using FixedWidthParsers: @fixedwidth, Skip

@fixedwidth struct BenchFlight
    carrier::String = 2
    fnum::Int       = 4
    _skip::Skip     = 1
    origin::String  = 3
    dest::String    = 3
    pax::Int        = 3
    revenue::Int    = 8
end

SUITE["generated"] = BenchmarkGroup()

SUITE["generated"]["100K_columnar"] = @benchmarkable parse_file(
    $(joinpath(BENCHDIR, "100K.dat")),
    $BenchFlight,
)

SUITE["generated"]["1M_columnar"] = @benchmarkable parse_file(
    $(joinpath(BENCHDIR, "1M.dat")),
    $BenchFlight,
)

# ---------------------------------------------------------------------------
# Parallel columnar parsing benchmarks
# ---------------------------------------------------------------------------
SUITE["parallel"] = BenchmarkGroup()

for nt in [1, 2, 4]
    SUITE["parallel"]["1M_runtime_ntasks=$(nt)"] = @benchmarkable parse_file(
        $(joinpath(BENCHDIR, "1M.dat")),
        $BENCH_SCHEMA;
        ntasks = $nt,
    )

    SUITE["parallel"]["1M_generated_ntasks=$(nt)"] = @benchmarkable parse_file(
        $(joinpath(BENCHDIR, "1M.dat")),
        $BenchFlight;
        ntasks = $nt,
    )
end
