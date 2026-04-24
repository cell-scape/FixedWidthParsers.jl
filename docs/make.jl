using Documenter
using FixedWidthParsers

# Load the DuckDB extension so its docstrings (e.g. `to_duckdb`) are visible
# to Documenter. The extension activates when both DuckDB and DBInterface
# are imported.
using DBInterface
using DuckDB

DocMeta.setdocmeta!(FixedWidthParsers, :DocTestSetup, :(using FixedWidthParsers); recursive=true)

makedocs(
    sitename = "FixedWidthParsers.jl",
    modules = [FixedWidthParsers],
    remotes = nothing,
    checkdocs = :exports,
    format = Documenter.HTML(edit_link = nothing, repolink = nothing),
    pages = [
        "Home" => "index.md",
        "Tutorials" => [
            "Quick Start"           => "tutorials/quickstart.md",
            "Handling Real Data"    => "tutorials/real_data.md",
            "Streaming to DuckDB"   => "tutorials/duckdb.md",
        ],
        "User Guide"       => "guide.md",
        "DuckDB Extension" => "duckdb.md",
        "Performance"      => "performance.md",
        "API Reference"    => "api.md",
    ],
)
