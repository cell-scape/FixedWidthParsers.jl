# CLAUDE.md — FixedWidthParsers.jl

## Overview
High-performance fixed-width file parser for Julia. Mmap IO + @generated inner loops.

## Build & Test
```bash
cd ~/Projects/FixedWidthParsers.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.test()'
```

## Architecture
- `src/types.jl` — Field type descriptors (FWString, FWInt, etc.) and `parse_field` methods
- `src/schema.jl` — FixedWidthSchema (runtime) + @fixedwidth macro (static)
- `src/io.jl` — MmapSource, ChunkedSource, newline detection
- `src/parsing.jl` — Core parse_record logic, @generated specializations
- `src/iteration.jl` — Lazy `eachrecord` iterator
- `src/materialization.jl` — `parse_file` → StructArray / Vector{T}

## Conventions
- TDD: write failing test first, then implement
- All field parsing goes through `parse_field(descriptor, buf, pos, len)` interface
- Byte positions are 1-indexed (Julia convention)
- `@generated` only for static schemas; runtime schemas use function barriers
