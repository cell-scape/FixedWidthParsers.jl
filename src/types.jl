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

When `default` is set and `on_error=:default`, a blank field returns `default`
instead of throwing a `ParseError`.
"""
struct FWDate
    format::Dates.DateFormat
    format_string::String
    default::Union{Dates.Date, Nothing}
    transform::Union{Function, Nothing}
end
FWDate(
    fmt::AbstractString;
    default::Union{Dates.Date, Nothing}=nothing,
    transform::Union{Function, Nothing}=nothing,
) = FWDate(Dates.DateFormat(fmt), String(fmt), default, transform)

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

Zero-allocation integer parser.  Walks bytes directly, handling leading/trailing
spaces and an optional leading minus sign.  No function calls in the hot path.
"""
@inline function _parse_int_bytes(buf::AbstractVector{UInt8}, pos::Int, len::Int)
    val = zero(Int)
    neg = false
    has_digit = false
    @inbounds for i in pos:pos+len-1
        b = buf[i]
        if b == 0x2d  # '-'
            neg = true
        elseif b >= 0x30 && b <= 0x39  # '0'-'9'
            val = val * 10 + Int(b - 0x30)
            has_digit = true
        elseif b != 0x20 && b != 0x2b  # not space or '+'
            throw(ArgumentError("invalid base 10 digit '$(Char(b))' in \"$(String(copy(buf[pos:pos+len-1])))\""))
        end
    end
    has_digit || throw(ArgumentError("cannot parse Int from \"$(String(copy(buf[pos:pos+len-1])))\""))
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

Parse a `Date` value from ASCII bytes using the `DateFormat` stored in `fw`.
"""
@inline function parse_field(fw::FWDate, buf::AbstractVector{UInt8}, pos::Int, len::Int)
    sv = StringView(@view buf[pos:pos+len-1])
    return Dates.Date(String(sv), fw.format)
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
