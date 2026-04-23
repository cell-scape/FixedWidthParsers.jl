using Mmap

"""
    AbstractSource

Abstract supertype for all fixed-width record sources. Concrete subtypes must
implement `buffer`, `record_count`, `record_offset`, and `Base.close`.
"""
abstract type AbstractSource end

"""
    detect_newline(buf, record_width) → Int

Detect newline style from buffer. Returns:
- 0: no newline detected
- 1: LF (\\n)
- 2: CRLF (\\r\\n)

Looks at the byte immediately following the first record to determine
the line ending convention used throughout the file.
"""
function detect_newline(buf::AbstractVector{UInt8}, record_width::Int)
    length(buf) <= record_width && return 0
    pos = record_width + 1
    if buf[pos] == UInt8('\n')
        return 1
    elseif buf[pos] == UInt8('\r') && length(buf) > pos && buf[pos + 1] == UInt8('\n')
        return 2
    end
    return 0
end

"""
    MmapSource

Memory-mapped file source for fixed-width record access.

Fields:
- `buf`: mmap'd byte buffer (empty `Vector{UInt8}` for empty files)
- `io`: underlying file handle
- `record_width`: bytes per record (excluding newline)
- `newline_width`: 0 (no newlines), 1 (LF), or 2 (CRLF)
- `stride`: record_width + newline_width (bytes between record starts)
- `n_records`: total record count

Use `close(src)` when done to release the mmap and file handle.
"""
mutable struct MmapSource <: AbstractSource
    buf::Vector{UInt8}
    io::IOStream
    record_width::Int
    newline_width::Int
    stride::Int
    n_records::Int

    function MmapSource(path::AbstractString, record_width::Int)
        io = open(path, "r")
        fsize = filesize(io)
        if fsize == 0
            return new(UInt8[], io, record_width, 0, record_width, 0)
        end
        buf = Mmap.mmap(io, Vector{UInt8}, fsize)
        _advise_sequential(buf)
        nl = detect_newline(buf, record_width)
        stride = record_width + nl
        n = fsize ÷ stride
        remainder = fsize - n * stride
        if remainder == record_width
            n += 1  # last record has no trailing newline
        end
        return new(buf, io, record_width, nl, stride, n)
    end
end

# MADV_SEQUENTIAL == 2 on Linux and macOS. Failure is ignored — madvise is
# strictly an optimization hint that tells the kernel to prefetch pages
# aggressively and drop them after we pass.
@static if Sys.isunix()
    @inline function _advise_sequential(buf::Vector{UInt8})
        @ccall madvise(pointer(buf)::Ptr{Cvoid}, length(buf)::Csize_t, 2::Cint)::Cint
        return buf
    end
else
    @inline _advise_sequential(buf::Vector{UInt8}) = buf
end

"""
    buffer(src::MmapSource) → Vector{UInt8}

Return the underlying mmap'd byte buffer.
"""
buffer(src::MmapSource) = src.buf

"""
    record_count(src::MmapSource) → Int

Return the total number of records in the source.
"""
record_count(src::MmapSource) = src.n_records

"""
    record_offset(src::MmapSource, i::Int) → Int

Return the 1-based byte offset of the start of record `i` (1-indexed).
"""
record_offset(src::MmapSource, i::Int) = (i - 1) * src.stride + 1

"""
    close(src::MmapSource)

Finalize the mmap buffer and close the underlying file handle.
"""
function Base.close(src::MmapSource)
    finalize(src.buf)
    close(src.io)
end

# ---------------------------------------------------------------------------
# ChunkedSource — buffered fallback for non-seekable IO
# ---------------------------------------------------------------------------

"""
    ChunkedSource

Buffered source for non-seekable IO (pipes, IOBuffer, stdin).
Reads the entire stream into a memory buffer upon construction.

Fields:
- `buf`: raw byte buffer containing the full stream contents
- `record_width`: bytes per record (excluding newline)
- `newline_width`: 0 (no newlines), 1 (LF), or 2 (CRLF)
- `stride`: record_width + newline_width (bytes between record starts)
- `n_records`: total record count
"""
mutable struct ChunkedSource <: AbstractSource
    buf::Vector{UInt8}
    record_width::Int
    newline_width::Int
    stride::Int
    n_records::Int

    function ChunkedSource(io::IO, record_width::Int)
        buf = read(io)
        if isempty(buf)
            return new(buf, record_width, 0, record_width, 0)
        end
        nl = detect_newline(buf, record_width)
        stride = record_width + nl
        n = length(buf) ÷ stride
        remainder = length(buf) - n * stride
        if remainder == record_width
            n += 1  # last record has no trailing newline
        end
        return new(buf, record_width, nl, stride, n)
    end
end

"""
    buffer(src::ChunkedSource) → Vector{UInt8}

Return the underlying byte buffer.
"""
buffer(src::ChunkedSource) = src.buf

"""
    record_count(src::ChunkedSource) → Int

Return the total number of records in the source.
"""
record_count(src::ChunkedSource) = src.n_records

"""
    record_offset(src::ChunkedSource, i::Int) → Int

Return the 1-based byte offset of the start of record `i` (1-indexed).
"""
record_offset(src::ChunkedSource, i::Int) = (i - 1) * src.stride + 1

"""
    close(src::ChunkedSource)

No-op. ChunkedSource holds only an in-memory buffer with no external resources.
"""
Base.close(::ChunkedSource) = nothing
