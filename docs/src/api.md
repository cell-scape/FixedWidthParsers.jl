# API Reference

## Field types

```@docs
FWString
FWInt
FWFloat
FWFixedPoint
FWBool
FWDate
FWTime
FWDateTime
FWCustom
FWSkip
Skip
```

## Schemas

```@docs
FixedWidthSchema
@fixedwidth
schema
MultiRecordSchema
```

## Loading schemas from files

```@docs
load_schema
```

## Bundled schemas

```@docs
SSIM_SCHEMA
AIRCRAFT_SCHEMA
AIRPORT_SCHEMA
MCT_SCHEMA
MCT_PRIORITY_SCHEMA
REGIONAL_SCHEMA
SEATS_SCHEMA
```

## Parsing

```@docs
parse_file
parse_string
parse_bytes
parse_record
parse_field
eachrecord
```

## DuckDB integration

```@docs
to_duckdb
```

## Errors

```@docs
ParseError
```
