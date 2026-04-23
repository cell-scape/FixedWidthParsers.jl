# Documenter.jl API Reference Design

## Goal

Add Documenter.jl-based API reference documentation for FixedWidthParsers.jl. Local build only (no CI/CD deployment). All 13 exported symbols already have comprehensive docstrings.

## Structure

```
docs/
├── Project.toml          # Documenter + FixedWidthParsers deps
├── make.jl               # Build script
└── src/
    ├── index.md          # Landing page with brief intro
    └── api.md            # API reference via @autodocs
```

Build output: `docs/build/` (gitignored).

## Pages

### index.md

Brief intro: what the package does, install command, link to API reference. Not a tutorial.

### api.md

Single page with `@autodocs` organized by category:
- Field Types: FWString, FWInt, FWFloat, FWDate, FWFixedPoint, FWSkip, Skip
- Schema: FixedWidthSchema, @fixedwidth, schema
- Parsing: parse_file, parse_record, parse_field, eachrecord
- Errors: ParseError

## Build

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
# Open docs/build/index.html
```

## Files to Create/Modify

| File | Action |
|------|--------|
| `docs/Project.toml` | Create: Documenter + FixedWidthParsers deps |
| `docs/make.jl` | Create: makedocs config |
| `docs/src/index.md` | Create: landing page |
| `docs/src/api.md` | Create: API reference |
| `.gitignore` | Add `docs/build/` |
