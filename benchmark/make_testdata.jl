"""
    generate_test_file(path::String, n_records::Int)

Generate a fixed-width test file with `n_records` rows.

Each record has the following layout (24 bytes + newline):

| Field   | Columns | Width | Type   |
|---------|---------|-------|--------|
| carrier | 1-2     | 2     | String |
| fnum    | 3-6     | 4     | Int    |
| (space) | 7       | 1     | Skip   |
| origin  | 8-10    | 3     | String |
| dest    | 11-13   | 3     | String |
| pax     | 14-16   | 3     | Int    |
| revenue | 17-24   | 8     | Int    |
"""
function generate_test_file(path::String, n_records::Int)
    carriers = ("UA", "DL", "AA", "WN")
    airports = ("ORD", "LAX", "JFK", "SFO", "DEN")
    open(path, "w") do io
        for i in 1:n_records
            carrier = carriers[rand(1:length(carriers))]
            fnum = lpad(rand(100:9999), 4)
            origin = airports[rand(1:length(airports))]
            dest = airports[rand(1:length(airports))]
            pax = lpad(rand(1:300), 3)
            rev = lpad(rand(10000:99999999), 8, '0')
            # Total: 2+4+1+3+3+3+8 = 24 bytes + newline
            write(io, carrier, fnum, " ", origin, dest, pax, rev, "\n")
        end
    end
    return path
end
