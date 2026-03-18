using Documenter
using FixedWidthParsers

DocMeta.setdocmeta!(FixedWidthParsers, :DocTestSetup, :(using FixedWidthParsers); recursive=true)

makedocs(
    sitename = "FixedWidthParsers.jl",
    modules = [FixedWidthParsers],
    remotes = nothing,
    checkdocs = :exports,
    format = Documenter.HTML(edit_link = nothing, repolink = nothing),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ],
)
