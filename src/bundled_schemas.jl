"""
    bundled_schemas.jl — Pre-built schemas for common fixed-width file formats.

All schemas are loaded from CSV definitions in the `examples/` directory.
"""

const _EXAMPLES_DIR = joinpath(@__DIR__, "..", "examples")

# ---------------------------------------------------------------------------
# SSIM (Standard Schedules Information Manual) — multi-record, 200-byte lines
# ---------------------------------------------------------------------------

"""
    SSIM_SCHEMA :: MultiRecordSchema

Pre-built multi-record schema for SSIM (Standard Schedules Information Manual) files.

Five record types keyed by the first byte (`1`--`5`), 200-byte records.

| Key | Label      | Description           |
|-----|------------|-----------------------|
| `1` | `:type_1`  | Header record         |
| `2` | `:type_2`  | Carrier/schedule info |
| `3` | `:type_3`  | Flight leg record     |
| `4` | `:type_4`  | Segment data (DEI)    |
| `5` | `:type_5`  | Trailer record        |

```jldoctest
julia> SSIM_SCHEMA isa MultiRecordSchema
true

julia> SSIM_SCHEMA.discriminator
1:1

julia> SSIM_SCHEMA.record_width
200

julia> length(SSIM_SCHEMA.schemas)
5
```
"""
const SSIM_SCHEMA = load_schema(
    '1' => joinpath(_EXAMPLES_DIR, "ssim_type1.csv"),
    '2' => joinpath(_EXAMPLES_DIR, "ssim_type2.csv"),
    '3' => joinpath(_EXAMPLES_DIR, "ssim_type3.csv"),
    '4' => joinpath(_EXAMPLES_DIR, "ssim_type4.csv"),
    '5' => joinpath(_EXAMPLES_DIR, "ssim_type5.csv");
    discriminator=1:1,
    record_width=200,
)

# ---------------------------------------------------------------------------
# Standalone reference-data schemas
# ---------------------------------------------------------------------------

"""
    AIRCRAFT_SCHEMA :: FixedWidthSchema

IATA aircraft equipment reference data. Fields: `fleet`, `equip`, `description`,
`ac_type`, `bodytype`, `ac_range`, `ac_speed`, `ac_pax_cargo`, `ac_pax_only`, `ac_cargo_only`.

```jldoctest
julia> AIRCRAFT_SCHEMA isa FixedWidthSchema
true
```
"""
const AIRCRAFT_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "aircraft.csv"))

"""
    AIRPORT_SCHEMA :: FixedWidthSchema

IATA airport/timezone reference data. Fields: `country`, `time_div`, `state`,
`airport`, `location_type`, `utc_var`, `dst_var_1`, `dst_start_time_1`, ...,
`latitude_degrees`, `longitude_degrees`, `metro_area`, `status`, `location_subtype`,
`location_subctry`.

```jldoctest
julia> AIRPORT_SCHEMA isa FixedWidthSchema
true
```
"""
const AIRPORT_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "airport.csv"))

"""
    MCT_SCHEMA :: FixedWidthSchema

Minimum Connecting Time records in byte order. Fields: `record_type`,
`arrival_station`, `time`, `international_domestic_status`, `departure_station`,
`arrival_carrier`, `arrival_codeshare_indicator`, `arrival_codeshare_carrier`,
`departure_carrier`, `departure_codeshare_indicator`, `departure_codeshare_carrier`,
`arrival_aircraft_type`, `arrival_aircraft_bodytype`, `departure_aircraft_type`,
`departure_aircraft_bodytype`, `arrival_terminal`, `departure_terminal`,
`previous_country`, `previous_station`, `next_country`, `next_station`,
`arrival_flight_number_range_start`, `arrival_flight_number_range_end`,
`departure_flight_number_range_start`, `departure_flight_number_range_end`,
`previous_state`, `next_state`, `previous_region`, `next_region`,
`effective_date`, `discontinue_date`, `suppression_indicator`, `suppression_region`,
`suppression_country`, `suppression_state`, `submitting_carrier_identifier`,
`filing_date`, `action_indicator`, `serial_number`.

```jldoctest
julia> MCT_SCHEMA isa FixedWidthSchema
true
```
"""
const MCT_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "mct_byte_order.csv"))

"""
    MCT_PRIORITY_SCHEMA :: FixedWidthSchema

Minimum Connecting Time records in priority order (same fields as `MCT_SCHEMA`,
sorted by matching priority rather than byte position).

```jldoctest
julia> MCT_PRIORITY_SCHEMA isa FixedWidthSchema
true
```
"""
const MCT_PRIORITY_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "mct_priority_order.csv"))

"""
    REGIONAL_SCHEMA :: FixedWidthSchema

Region/airport/city mapping. Fields: `region`, `airport`, `city`.

```jldoctest
julia> REGIONAL_SCHEMA isa FixedWidthSchema
true
```
"""
const REGIONAL_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "regional.csv"))

"""
    SEATS_SCHEMA :: FixedWidthSchema

Seat configuration data. Fields: `owner`, `equip`, `cabins`, `cabin1`, `cabin2`,
`cabin3`, `total`.

```jldoctest
julia> SEATS_SCHEMA isa FixedWidthSchema
true
```
"""
const SEATS_SCHEMA = load_schema(joinpath(_EXAMPLES_DIR, "seats.csv"))
