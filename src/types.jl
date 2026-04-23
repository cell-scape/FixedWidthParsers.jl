"""
    types.jl — Field type descriptors and `parse_field` methods.

Each descriptor struct encodes parsing semantics for one fixed-width column.
The common interface is:

    parse_field(descriptor, buf::AbstractVector{UInt8}, pos::Int, len::Int) → value

`pos` is 1-based; the field occupies bytes `buf[pos:pos+len-1]`.
"""

using Dates
using Parsers
using StringViews: StringView
using InlineStrings: InlineString, String1, String3, String7, String15, String31

# ---------------------------------------------------------------------------
# ParseError
# ---------------------------------------------------------------------------

"""
    ParseError <: Exception

Thrown when a field cannot be parsed in strict mode.

# Fields
- `line::Int`                  — 1-based record (line) number
- `columns::UnitRange{Int}`    — byte column range within the record
- `raw_bytes::Vector{UInt8}`   — the raw bytes that failed to parse
- `expected_type::Type`        — the Julia type the parser expected to produce
- `message::String`            — human-readable description of the failure
"""
struct ParseError <: Exception
    line::Int
    columns::UnitRange{Int}
    raw_bytes::Vector{UInt8}
    expected_type::Type
    message::String
end

function Base.showerror(io::IO, e::ParseError)
    print(io, "ParseError at line $(e.line), columns $(e.columns): $(e.message)")
    print(io, "\n  Raw bytes: ", repr(String(copy(e.raw_bytes))))
    print(io, "\n  Expected type: ", e.expected_type)
end

# ---------------------------------------------------------------------------
# Descriptor types
# ---------------------------------------------------------------------------

"""
    Skip

Sentinel type used in the `@fixedwidth` macro to mark padding / filler fields
that should be skipped without allocating any output storage.
"""
struct Skip end

"""
    FWSkip

Field descriptor: skip this field during parsing.  `parse_field` returns
`nothing`; the bytes are never inspected.
"""
struct FWSkip end

"""
    FWString(; pad::Char = ' ', default::Union{AbstractString, Nothing} = nothing)
    FWString(pad::Char)

Field descriptor: parse a fixed-width string column.

Trailing `pad` characters are stripped before the value is returned.  The
default pad character is an ASCII space (`' '`).

The returned value is a zero-copy `StringView` into the original byte buffer
(or `""` when the field is entirely padding).

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWString
    pad::Char
    default::Union{AbstractString, Nothing}
    transform::Union{Function, Nothing}
end
FWString(;
    pad::Char=' ',
    default::Union{AbstractString, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWString(pad, default, transform)
# Positional single-arg form for backward compat
FWString(pad::Char) = FWString(pad, nothing, nothing)

"""
    FWInt(; pad::Char=' ', default::Union{Int, Nothing} = nothing)

Field descriptor: parse a signed integer from padded ASCII bytes.
Non-space pad characters are replaced with spaces before parsing.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWInt
    pad::Char
    default::Union{Int, Nothing}
    transform::Union{Function, Nothing}
end
FWInt(;
    pad::Char=' ',
    default::Union{Int, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWInt(pad, default, transform)
# Positional single-arg form for backward compat
FWInt(pad::Char) = FWInt(pad, nothing, nothing)

"""
    FWFloat(; pad::Char=' ', default::Union{Float64, Nothing} = nothing)

Field descriptor: parse a `Float64` from padded ASCII bytes.
Non-space pad characters are replaced with spaces before parsing.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWFloat
    pad::Char
    default::Union{Float64, Nothing}
    transform::Union{Function, Nothing}
end
FWFloat(;
    pad::Char=' ',
    default::Union{Float64, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWFloat(pad, default, transform)
# Positional single-arg form for backward compat
FWFloat(pad::Char) = FWFloat(pad, nothing, nothing)

"""
    FWDate(format::String; default::Union{Dates.Date, Nothing} = nothing)

Field descriptor: parse a `Dates.Date` using the given `DateFormat` pattern
string (e.g. `"yyyymmdd"`).

For a handful of common formats (`"yyyymmdd"`, `"yyyy-mm-dd"`, `"dduuuyy"`)
the descriptor is parameterized on a fast-path symbol and `parse_field` uses
a byte-level parser that bypasses `DateFormat` entirely; other formats fall
back to the general `Dates.Date(str, fmt)` path.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWDate{FP}
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Date, Nothing}
    transform::Union{Function, Nothing}
end
FWDate(
    fmt::AbstractString;
    default::Union{Dates.Date, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWDate{_date_fast_path(fmt)}(Dates.DateFormat(fmt), String(fmt), default, transform)

"""
    FWTime(format::String; default::Union{Dates.Time, Nothing} = nothing)

Field descriptor: parse a `Dates.Time` using the given `DateFormat` pattern
string (e.g. `"HH:MM"`, `"HHMM"`).

Note: In Julia's `DateFormat`, uppercase `M` = minute, lowercase `m` = month.

For common formats (`"HHMM"`, `"HHMMSS"`, `"HH:MM"`, `"HH:MM:SS"`) the
descriptor dispatches to a zero-tokenizer byte-level parser; other formats
fall back to the general path.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWTime{FP}
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Time, Nothing}
    transform::Union{Function, Nothing}
end
FWTime(
    fmt::AbstractString;
    default::Union{Dates.Time, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWTime{_time_fast_path(fmt)}(Dates.DateFormat(fmt), String(fmt), default, transform)
FWTime() = FWTime("HH:MM")

"""
    FWDateTime(format::String; default::Union{Dates.DateTime, Nothing} = nothing)

Field descriptor: parse a `Dates.DateTime` using the given `DateFormat` pattern
string (e.g. `"yyyy-mm-ddTHH:MM:SS"`, `"yyyymmddHHMM"`).

Note: In Julia's `DateFormat`, lowercase `m` = month, uppercase `M` = minute.

Fast paths for `"yyyymmddHHMM"` and `"yyyymmddHHMMSS"`; other formats fall
back to the general path.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWDateTime{FP}
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.DateTime, Nothing}
    transform::Union{Function, Nothing}
end
FWDateTime(
    fmt::AbstractString;
    default::Union{Dates.DateTime, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWDateTime{_datetime_fast_path(fmt)}(Dates.DateFormat(fmt), String(fmt), default, transform)
FWDateTime() = FWDateTime("yyyy-mm-ddTHH:MM:SS")

# Map format strings to fast-path symbols. Unknown formats resolve to :generic
# which routes `parse_field` through the general `Dates.jl` path unchanged.
_date_fast_path(fmt::AbstractString) =
    fmt == "yyyymmdd"   ? :yyyymmdd   :
    fmt == "yyyy-mm-dd" ? :yyyy_mm_dd :
    fmt == "dduuuyy"    ? :dduuuyy    :
    :generic

_time_fast_path(fmt::AbstractString) =
    fmt == "HHMM"     ? :HHMM     :
    fmt == "HHMMSS"   ? :HHMMSS   :
    fmt == "HH:MM"    ? :HH_MM    :
    fmt == "HH:MM:SS" ? :HH_MM_SS :
    :generic

_datetime_fast_path(fmt::AbstractString) =
    fmt == "yyyymmddHHMM"   ? :yyyymmddHHMM   :
    fmt == "yyyymmddHHMMSS" ? :yyyymmddHHMMSS :
    :generic

"""
    FWFixedPoint(decimals::Int; default::Union{Float64, Nothing} = nothing)

Field descriptor: parse an implied-decimal fixed-point number.

The raw bytes are interpreted as an integer and then divided by
`10^decimals`.  For example, with `decimals = 2`, the byte sequence
`"12345"` represents `123.45`.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWFixedPoint
    decimals::Int
    default::Union{Float64, Nothing}
    transform::Union{Function, Nothing}
end
FWFixedPoint(
    decimals::Int;
    default::Union{Float64, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWFixedPoint(decimals, default, transform)

"""
    FWBool(; true_val="Y", false_val="N", default::Union{Bool, Nothing} = nothing)

Field descriptor: parse a boolean from a fixed-width field.
The field bytes are stripped of leading/trailing whitespace and compared
against `true_val` and `false_val`. A mismatch throws `ArgumentError`.

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWBool
    true_val::String
    false_val::String
    default::Union{Bool, Nothing}
    transform::Union{Function, Nothing}
end
function FWBool(;
    true_val::AbstractString="Y",
    false_val::AbstractString="N",
    default::Union{Bool, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
)
    isempty(true_val) && throw(ArgumentError("true_val must not be empty"))
    isempty(false_val) && throw(ArgumentError("false_val must not be empty"))
    return FWBool(String(true_val), String(false_val), default, transform)
end

# ---------------------------------------------------------------------------
# Fast byte-level numeric parsers (zero allocation)
# ---------------------------------------------------------------------------

"""
    _parse_int_bytes(buf, pos, len) → Int

Zero-allocation integer parser.  Accepts the grammar:

    [spaces] [ '+' | '-' ] digit+ [spaces]

Any other byte (non-leading sign, interior space, trailing non-space) throws
`ArgumentError`.  No function calls in the hot path.
"""
@inline function _parse_int_bytes(buf::AbstractVector{UInt8}, pos::Int, len::Int)
    stop = pos + len - 1
    i = pos
    # Skip leading spaces
    @inbounds while i <= stop && buf[i] == 0x20
        i += 1
    end
    i > stop && throw(ArgumentError("cannot parse Int from \"$(String(copy(buf[pos:stop])))\""))

    # Optional single sign byte
    neg = false
    @inbounds begin
        b = buf[i]
        if b == 0x2d  # '-'
            neg = true
            i += 1
        elseif b == 0x2b  # '+'
            i += 1
        end
    end

    # One or more digits
    val = zero(Int)
    digit_start = i
    @inbounds while i <= stop
        b = buf[i]
        (b >= 0x30 && b <= 0x39) || break
        val = val * 10 + Int(b - 0x30)
        i += 1
    end
    i == digit_start &&
        throw(ArgumentError("cannot parse Int from \"$(String(copy(buf[pos:stop])))\""))

    # Trailing bytes must be spaces only
    @inbounds while i <= stop
        buf[i] == 0x20 ||
            throw(ArgumentError("invalid base 10 digit '$(Char(buf[i]))' in \"$(String(copy(buf[pos:stop])))\""))
        i += 1
    end

    return neg ? -val : val
end

"""
    _parse_float_bytes(buf, pos, len) → Float64

Zero-allocation float parser for simple decimal notation (e.g. "  3.14", "-1.5").
Delegates to Parsers.xparse for correctness on edge cases.
"""
@inline function _parse_float_bytes(buf::AbstractVector{UInt8}, pos::Int, len::Int)
    result = Parsers.xparse(Float64, buf, pos, pos + len - 1)
    if Parsers.ok(result.code)
        return result.val
    end
    # Fallback for edge cases
    sv = StringView(@view buf[pos:pos+len-1])
    return parse(Float64, strip(sv))
end

# ---------------------------------------------------------------------------
# parse_field implementations
# ---------------------------------------------------------------------------

"""
    parse_field(::FWSkip, buf, pos, len) → nothing

Skip the field entirely.
"""
@inline function parse_field(::FWSkip, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    return nothing
end

"""
    parse_field(fw::FWString, buf, pos, len) → AbstractString

Return a zero-copy `StringView` of `buf[pos:last]` where trailing pad
characters have been removed.  Returns `""` when the field contains only
padding.
"""
@inline function parse_field(fw::FWString, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    pad_byte = UInt8(fw.pad)
    last = pos + len - 1
    while last >= pos && buf[last] == pad_byte
        last -= 1
    end
    last < pos && return ""
    return StringView(@view buf[pos:last])
end

"""
    parse_field(fw::FWInt, buf, pos, len) → Int

Parse a signed integer from ASCII bytes.  Leading and trailing whitespace is
handled transparently.  When `fw.pad != ' '`, pad bytes are replaced with
spaces before parsing.
"""
@inline function parse_field(fw::FWInt, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.pad != ' '
        pad_byte = UInt8(fw.pad)
        tbuf = Vector{UInt8}(undef, len)
        all_pad = true
        @inbounds for i in 1:len
            b = buf[pos + i - 1]
            if b == pad_byte
                tbuf[i] = 0x20
            else
                tbuf[i] = b
                all_pad = false
            end
        end
        # All bytes were pad bytes: the field encodes zero (e.g. "0000" with pad='0')
        all_pad && return 0
        return _parse_int_bytes(tbuf, 1, len)
    end
    return _parse_int_bytes(buf, pos, len)
end

"""
    parse_field(fw::FWFloat, buf, pos, len) → Float64

Parse a floating-point number from ASCII bytes.  Leading and trailing
whitespace is handled transparently.  When `fw.pad != ' '`, pad bytes are
replaced with spaces before parsing.
"""
@inline function parse_field(fw::FWFloat, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.pad != ' '
        pad_byte = UInt8(fw.pad)
        tbuf = Vector{UInt8}(undef, len)
        all_pad = true
        @inbounds for i in 1:len
            b = buf[pos + i - 1]
            if b == pad_byte
                tbuf[i] = 0x20
            else
                tbuf[i] = b
                all_pad = false
            end
        end
        all_pad && return 0.0
        return _parse_float_bytes(tbuf, 1, len)
    end
    return _parse_float_bytes(buf, pos, len)
end

"""
    parse_field(fw::FWDate, buf, pos, len) → Dates.Date

Parse a `Date` value from ASCII bytes. For known `FP` parameter values, a
specialized byte-level parser is used; `FWDate{:generic}` falls back to the
`Dates.DateFormat` interpreter.
"""
@inline function parse_field(fw::FWDate{:yyyymmdd}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 8 || return _parse_date_generic(fw, buf, pos, len)
    @inbounds begin
        y = 1000*_digit(buf[pos])   + 100*_digit(buf[pos+1]) + 10*_digit(buf[pos+2]) + _digit(buf[pos+3])
        m = 10*_digit(buf[pos+4])   + _digit(buf[pos+5])
        d = 10*_digit(buf[pos+6])   + _digit(buf[pos+7])
    end
    return Dates.Date(y, m, d)
end

@inline function parse_field(fw::FWDate{:yyyy_mm_dd}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    (len == 10 &&
        @inbounds(buf[pos+4] == UInt8('-') && buf[pos+7] == UInt8('-'))) ||
        return _parse_date_generic(fw, buf, pos, len)
    @inbounds begin
        y = 1000*_digit(buf[pos])   + 100*_digit(buf[pos+1]) + 10*_digit(buf[pos+2]) + _digit(buf[pos+3])
        m = 10*_digit(buf[pos+5])   + _digit(buf[pos+6])
        d = 10*_digit(buf[pos+8])   + _digit(buf[pos+9])
    end
    return Dates.Date(y, m, d)
end

@inline function parse_field(fw::FWDate{:dduuuyy}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 7 || return _parse_date_generic(fw, buf, pos, len)
    @inbounds begin
        d = 10*_digit(buf[pos])  + _digit(buf[pos+1])
        m = _month_abbrev(buf[pos+2], buf[pos+3], buf[pos+4])
        y = 10*_digit(buf[pos+5]) + _digit(buf[pos+6])
    end
    return Dates.Date(y, m, d)
end

@inline parse_field(fw::FWDate{:generic}, buf::AbstractVector{UInt8}, pos::Int, len::Int) =
    _parse_date_generic(fw, buf, pos, len)

@inline function _parse_date_generic(fw::FWDate, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.Date(sv, fw.format)
end

"""
    parse_field(fw::FWTime, buf, pos, len) → Dates.Time
"""
@inline function parse_field(fw::FWTime{:HHMM}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 4 || return _parse_time_generic(fw, buf, pos, len)
    @inbounds begin
        h  = 10*_digit(buf[pos])   + _digit(buf[pos+1])
        mi = 10*_digit(buf[pos+2]) + _digit(buf[pos+3])
    end
    return Dates.Time(h, mi)
end

@inline function parse_field(fw::FWTime{:HHMMSS}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 6 || return _parse_time_generic(fw, buf, pos, len)
    @inbounds begin
        h  = 10*_digit(buf[pos])   + _digit(buf[pos+1])
        mi = 10*_digit(buf[pos+2]) + _digit(buf[pos+3])
        s  = 10*_digit(buf[pos+4]) + _digit(buf[pos+5])
    end
    return Dates.Time(h, mi, s)
end

@inline function parse_field(fw::FWTime{:HH_MM}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    (len == 5 && @inbounds(buf[pos+2] == UInt8(':'))) ||
        return _parse_time_generic(fw, buf, pos, len)
    @inbounds begin
        h  = 10*_digit(buf[pos])   + _digit(buf[pos+1])
        mi = 10*_digit(buf[pos+3]) + _digit(buf[pos+4])
    end
    return Dates.Time(h, mi)
end

@inline function parse_field(fw::FWTime{:HH_MM_SS}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    (len == 8 &&
        @inbounds(buf[pos+2] == UInt8(':') && buf[pos+5] == UInt8(':'))) ||
        return _parse_time_generic(fw, buf, pos, len)
    @inbounds begin
        h  = 10*_digit(buf[pos])   + _digit(buf[pos+1])
        mi = 10*_digit(buf[pos+3]) + _digit(buf[pos+4])
        s  = 10*_digit(buf[pos+6]) + _digit(buf[pos+7])
    end
    return Dates.Time(h, mi, s)
end

@inline parse_field(fw::FWTime{:generic}, buf::AbstractVector{UInt8}, pos::Int, len::Int) =
    _parse_time_generic(fw, buf, pos, len)

@inline function _parse_time_generic(fw::FWTime, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.Time(sv, fw.format)
end

"""
    parse_field(fw::FWDateTime, buf, pos, len) → Dates.DateTime
"""
@inline function parse_field(fw::FWDateTime{:yyyymmddHHMM}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 12 || return _parse_datetime_generic(fw, buf, pos, len)
    @inbounds begin
        y  = 1000*_digit(buf[pos])   + 100*_digit(buf[pos+1]) + 10*_digit(buf[pos+2])  + _digit(buf[pos+3])
        mo = 10*_digit(buf[pos+4])   + _digit(buf[pos+5])
        d  = 10*_digit(buf[pos+6])   + _digit(buf[pos+7])
        h  = 10*_digit(buf[pos+8])   + _digit(buf[pos+9])
        mi = 10*_digit(buf[pos+10])  + _digit(buf[pos+11])
    end
    return Dates.DateTime(y, mo, d, h, mi)
end

@inline function parse_field(fw::FWDateTime{:yyyymmddHHMMSS}, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    len == 14 || return _parse_datetime_generic(fw, buf, pos, len)
    @inbounds begin
        y  = 1000*_digit(buf[pos])   + 100*_digit(buf[pos+1]) + 10*_digit(buf[pos+2])  + _digit(buf[pos+3])
        mo = 10*_digit(buf[pos+4])   + _digit(buf[pos+5])
        d  = 10*_digit(buf[pos+6])   + _digit(buf[pos+7])
        h  = 10*_digit(buf[pos+8])   + _digit(buf[pos+9])
        mi = 10*_digit(buf[pos+10])  + _digit(buf[pos+11])
        s  = 10*_digit(buf[pos+12])  + _digit(buf[pos+13])
    end
    return Dates.DateTime(y, mo, d, h, mi, s)
end

@inline parse_field(fw::FWDateTime{:generic}, buf::AbstractVector{UInt8}, pos::Int, len::Int) =
    _parse_datetime_generic(fw, buf, pos, len)

@inline function _parse_datetime_generic(fw::FWDateTime, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.DateTime(sv, fw.format)
end

# ---------------------------------------------------------------------------
# Byte-level helpers shared by date/time fast paths
# ---------------------------------------------------------------------------

@inline _digit(b::UInt8) = Int(b) - Int('0')

"""
    _month_abbrev(b1, b2, b3) → Int

Case-insensitive 3-letter English month-abbreviation lookup. Returns the
month number 1..12; throws `ArgumentError` on an unknown triplet. ASCII-only;
the `& 0xDF` trick uppercases letters in one op.
"""
@inline function _month_abbrev(b1::UInt8, b2::UInt8, b3::UInt8)
    u1 = b1 & 0xDF; u2 = b2 & 0xDF; u3 = b3 & 0xDF
    u1 == UInt8('J') && u2 == UInt8('A') && u3 == UInt8('N') && return 1
    u1 == UInt8('F') && u2 == UInt8('E') && u3 == UInt8('B') && return 2
    u1 == UInt8('M') && u2 == UInt8('A') && u3 == UInt8('R') && return 3
    u1 == UInt8('A') && u2 == UInt8('P') && u3 == UInt8('R') && return 4
    u1 == UInt8('M') && u2 == UInt8('A') && u3 == UInt8('Y') && return 5
    u1 == UInt8('J') && u2 == UInt8('U') && u3 == UInt8('N') && return 6
    u1 == UInt8('J') && u2 == UInt8('U') && u3 == UInt8('L') && return 7
    u1 == UInt8('A') && u2 == UInt8('U') && u3 == UInt8('G') && return 8
    u1 == UInt8('S') && u2 == UInt8('E') && u3 == UInt8('P') && return 9
    u1 == UInt8('O') && u2 == UInt8('C') && u3 == UInt8('T') && return 10
    u1 == UInt8('N') && u2 == UInt8('O') && u3 == UInt8('V') && return 11
    u1 == UInt8('D') && u2 == UInt8('E') && u3 == UInt8('C') && return 12
    throw(ArgumentError("unknown 3-letter month abbreviation: \"$(Char(b1))$(Char(b2))$(Char(b3))\""))
end

"""
    parse_field(fw::FWFixedPoint, buf, pos, len) → Float64

Parse an implied-decimal fixed-point number.  The raw integer value is divided
by `10^fw.decimals` to produce a `Float64`.
"""
@inline function parse_field(fw::FWFixedPoint, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    raw = _parse_int_bytes(buf, pos, len)
    return raw / 10.0^fw.decimals
end

"""
    parse_field(fw::FWBool, buf, pos, len) → Bool

Parse a boolean by comparing stripped field bytes against true_val/false_val.
"""
@inline function parse_field(fw::FWBool, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    # Trim leading/trailing spaces (zero allocation)
    first = pos
    last  = pos + len - 1
    @inbounds while first <= last && buf[first] == 0x20; first += 1; end
    @inbounds while last >= first && buf[last]  == 0x20; last  -= 1; end
    trimlen = last - first + 1

    # Compare against true_val
    tv = fw.true_val
    if trimlen == ncodeunits(tv)
        match = true
        @inbounds for k in 1:trimlen
            if buf[first + k - 1] != codeunit(tv, k); match = false; break; end
        end
        match && return true
    end

    # Compare against false_val
    fv = fw.false_val
    if trimlen == ncodeunits(fv)
        match = true
        @inbounds for k in 1:trimlen
            if buf[first + k - 1] != codeunit(fv, k); match = false; break; end
        end
        match && return false
    end

    raw = String(copy(buf[pos:pos+len-1]))
    throw(ArgumentError("cannot parse Bool from \"$(strip(raw))\": expected \"$tv\" or \"$fv\""))
end

"""
    FWCustom(return_type, parse_fn; raw=false, default=nothing, transform=nothing)

Field descriptor: parse a field using a user-provided function.

In string mode (default, `raw=false`), the library extracts the field bytes as
a `String` and passes it to `parse_fn(str)`.

In byte mode (`raw=true`), the library passes the raw buffer:
`parse_fn(buf, pos, len)`.

The struct is parameterized as `FWCustom{F,D}` so Julia can specialize
`parse_field` on the concrete function type in hot loops.

# Examples
```julia
# String mode
FWCustom(Int, s -> length(strip(s)))

# Byte mode
FWCustom(Float64, (buf, pos, len) -> my_parser(buf, pos, len); raw=true)
```
"""
struct FWCustom{F, D}
    return_type::Type
    parse_fn::F
    raw::Bool
    default::D
    transform::Union{Function, Nothing}
end
function FWCustom(
    return_type::Type,
    parse_fn::F;
    raw::Bool=false,
    default::D=nothing,
    transform::Union{Function, Nothing}=nothing,
) where {F, D}
    return FWCustom{F, D}(return_type, parse_fn, raw, default, transform)
end

"""
    parse_field(fw::FWCustom, buf, pos, len) → value

Parse using a user-provided function. String mode extracts a String;
byte mode passes raw buffer access.
"""
@inline function parse_field(fw::FWCustom, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    if fw.raw
        return fw.parse_fn(buf, pos, len)
    else
        s = String(copy(buf[pos:pos+len-1]))
        return fw.parse_fn(s)
    end
end
