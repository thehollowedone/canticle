local Codec = require("../src/TransportCodec")
local Frame = require("../src/TransportFrame")

local function nextRandom(state)
    return (state * 1664525 + 1013904223) % 4294967296
end

local function testSchemaBoundaries()
    -- Each accepted domain must fit one integer representation at both ends.
    for _, minimum in { -2147483648, -1, 0, 1 } do
        for _, maximum in { 2147483647, 2147483648, 4294967295 } do
            local codec, reason = Codec.compile({ type = "integer", min = minimum, max = maximum })
            if minimum < 0 and maximum >= 2147483648 then
                assert(
                    not codec and reason == "integer encoding cannot represent declared range",
                    "auto accepted a domain crossing both signed and unsigned ranges"
                )
            else
                assert(codec, "representable range must compile")
                for _, value in { minimum, maximum } do
                    local ok, decoded = codec:decode(assert(codec:encode(value)))
                    assert(ok and decoded == value, "accepted integer boundary must round-trip")
                end
            end
        end
    end

    local field = { name = "flag", schema = { type = "boolean" } }
    for _, schema in
        {
            { type = "object", fields = { flag = field } },
            { type = "object", fields = { field, [3] = field } },
            { type = "enum", values = { "first", [3] = "third" } },
            { type = "enum", values = { "first", extra = "second" } },
        }
    do
        assert(not Codec.compile(schema), "schema list must not silently discard declarations")
    end
    assert(Codec.compile({ type = "object", fields = {} }), "empty object is valid")
    local enum = assert(Codec.compile({ type = "enum", values = { "first", "second" } }))
    assert(buffer.tostring(assert(enum:encode("second"))) == string.char(1), "ordered enum ordinal")
end

local function testFingerprintLabels()
    local function enumFingerprint(first, second)
        return assert(Codec.compile({ type = "enum", values = { first, second } })).fingerprint
    end
    local function objectFingerprint(first, second)
        return assert(Codec.compile({
            type = "object",
            fields = {
                { name = first, schema = { type = "boolean" } },
                { name = second, schema = { type = "boolean" } },
            },
        })).fingerprint
    end
    assert(
        enumFingerprint("A|B", "C") ~= enumFingerprint("A", "B|C"),
        "enum identity must distinguish which label contains the separator"
    )
    assert(
        enumFingerprint("A|B", "C") ~= enumFingerprint("A%7CB", "C"),
        "a literal percent escape must retain its own enum identity"
    )
    assert(
        objectFingerprint("a!b,b", "c") ~= objectFingerprint("a", "b!b,c"),
        "field identity must preserve the boundary between field names"
    )
    assert(enumFingerprint("Ready", "Busy") == 3405451048, "ordinary enum identity changed")
    assert(objectFingerprint("a", "b") == 1894657984, "ordinary field identity changed")
end

local function testFloat32Bounds()
    local bounded =
        assert(Codec.compile({ type = "number", encoding = "f32", min = -0.1, max = 0.1 }))
    for _, value in { -0.1, 0.1 } do
        local encoded, reason = bounded:encode(value)
        assert(not encoded and reason == "invalid_number", "float32 rounds past declared bound")
        assert(
            not bounded:encodeBatch({ value }) and not bounded:encodeCompactBatch({ value }),
            "both batch formats must reject a float32 that rounds outside the declared range"
        )
    end
    assert(bounded:decode(assert(bounded:encode(0.0625))))
    local wide = assert(Codec.compile({ type = "number", encoding = "f32" }))
    assert(not wide:encode(1e100) and not wide:encode(-1e100), "finite f64 overflows f32")
    assert(wide:decode(assert(wide:encode(2 ^ 127))))
    local double = assert(Codec.compile({ type = "number" }))
    assert(double:decode(assert(double:encode(1e100))), "f64 keeps its range")
end

local function testOptionalBitmap()
    local minimal = assert(Codec.compile({
        type = "object",
        fields = { { name = "p", schema = { type = "boolean" }, optional = true } },
    }))
    -- With p absent the only canonical byte is 00. Bit 1 has no field.
    assert(
        not minimal:decode(buffer.fromstring("\2")),
        "optional bitmap accepted a set padding bit"
    )

    local seed = 1847
    for _, count in { 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 63 } do
        local fields = { { name = "tag", schema = { type = "boolean" } } }
        for i = 1, count do
            fields[i + 1] = { name = tostring(i), schema = { type = "boolean" }, optional = true }
        end
        local codec = assert(Codec.compile({ type = "object", fields = fields }))
        for sample = 1, 4 do
            local bitmap = table.create(math.ceil(count / 8), 0)
            local body = { "\1" } -- Required tag precedes the optional field values.
            local value = { tag = true }
            for i = 1, count do
                seed = nextRandom(seed)
                if sample == 1 or (sample > 2 and seed % 3 ~= 0) then
                    local flag = seed % 2 == 0
                    value[tostring(i)] = flag
                    local byte = math.ceil(i / 8)
                    bitmap[byte] += 2 ^ ((i - 1) % 8)
                    table.insert(body, if flag then "\1" else "\0")
                end
            end
            local payload = table.concat(body)
            local wire = string.char(table.unpack(bitmap)) .. payload
            assert(
                buffer.tostring(assert(codec:encode(value))) == wire,
                "optional bitmap wire layout"
            )
            for _, mode in { "decode", "decodeBatch", "decodeCompactBatch" } do
                local function decode(item)
                    local header = if mode == "decode"
                        then ""
                        elseif mode == "decodeBatch" then string.char(1, 0, #item, 0, 0, 0)
                        else "\1\0"
                    return codec[mode](codec, buffer.fromstring(header .. item))
                end
                local ok, decoded = decode(wire)
                assert(ok, "canonical bitmap rejected in " .. mode)
                local record = if mode == "decode" then decoded else decoded[1]
                for _, field in ipairs(fields) do
                    assert(
                        record[field.name] == value[field.name],
                        "wrong optional field in " .. mode
                    )
                end
                local used = count % 8
                if used ~= 0 then
                    for bit = used, 7 do
                        local last = bitmap[#bitmap] + 2 ^ bit
                        local invalid = wire:sub(1, #bitmap - 1) .. string.char(last) .. payload
                        assert(not decode(invalid), "optional bitmap padding accepted in " .. mode)
                    end
                end
            end
        end
    end
end

return function()
    testSchemaBoundaries()
    testOptionalBitmap()
    testFloat32Bounds()
    testFingerprintLabels()
    local codec = assert(
        Codec.compile({
            type = "object",
            fields = {
                { name = "kind", schema = { type = "enum", values = { "ping", "pong" } } },
                { name = "count", schema = { type = "integer", min = 0, max = 255 } },
                {
                    name = "delta",
                    schema = { type = "integer", min = -100000, max = 100000, encoding = "varint" },
                },
                {
                    name = "name",
                    optional = true,
                    schema = { type = "string", minLength = 0, maxLength = 32 },
                },
            },
        }),
        "object codec must compile"
    )
    local encoded = assert(
        codec:encode({ kind = "ping", count = 7, delta = -3, name = "abc" }),
        "object value must encode"
    )
    local ok, value = codec:decode(encoded)
    assert(
        ok
            and value.kind == "ping"
            and value.count == 7
            and value.delta == -3
            and value.name == "abc",
        "encoded object must round-trip"
    )

    local trailing = buffer.create(buffer.len(encoded) + 1)
    buffer.copy(trailing, 0, encoded)
    assert(codec:decode(trailing) == false, "trailing bytes must reject")
    assert(
        Codec.compile({ type = "integer", min = 0, max = 1000, encoding = "u8" }) == nil,
        "out-of-range integer codec must reject"
    )
    assert(
        Codec.compile({ type = "integer", min = 0, max = 4294967295, encoding = "varint" }) == nil,
        "explicit varint must stay inside the signed 32-bit ZigZag range"
    )
    local unsigned32 = assert(
        Codec.compile({ type = "integer", min = 0, max = 4294967295 }),
        "the complete unsigned 32-bit range must compile"
    )
    for _, boundary in ipairs({ 0, 2147483647, 2147483648, 4294967295 }) do
        local boundaryEncoded = assert(unsigned32:encode(boundary), "u32 boundary must encode")
        local boundaryOk, boundaryValue = unsigned32:decode(boundaryEncoded)
        assert(boundaryOk and boundaryValue == boundary, "auto-selected u32 values must round-trip")
    end

    local fixed = assert(
        Codec.compile({ type = "string", minLength = 3, maxLength = 3 }),
        "fixed string codec must compile"
    )
    assert(
        buffer.len(assert(fixed:encode("abc"), "fixed string must encode")) == 3,
        "fixed strings omit redundant lengths"
    )

    local packedBooleans = assert(
        Codec.compile({
            type = "array",
            minLength = 9,
            maxLength = 9,
            encoding = "packed",
            items = { type = "boolean" },
        }),
        "packed boolean arrays must compile"
    )
    local boolValues = { true, false, true, true, false, false, true, false, true }
    local packed = assert(packedBooleans:encode(boolValues), "boolean array must encode")
    assert(buffer.len(packed) == 2, "nine booleans must occupy two bytes")
    local packedOk, packedResult = packedBooleans:decode(packed)
    assert(packedOk and #packedResult == #boolValues, "packed boolean array must decode")
    for i, expected in ipairs(boolValues) do
        assert(packedResult[i] == expected, "packed boolean values must round-trip")
    end
    buffer.writeu8(packed, 1, bit32.bor(buffer.readu8(packed, 1), 0x80))
    assert(not packedBooleans:decode(packed), "unused tail bits must be canonical")
    local largePacked = assert(Codec.compile({
        type = "array",
        minLength = 1000,
        maxLength = 1000,
        encoding = "packed",
        items = { type = "boolean" },
    }))
    local largeValues = table.create(1000)

    for i = 1, 1000 do
        largeValues[i] = i % 3 == 0
    end

    local largeBytes = assert(largePacked:encode(largeValues))
    assert(buffer.len(largeBytes) == 125, "one thousand booleans must occupy 125 bytes")
    local largeOk, largeDecoded = largePacked:decode(largeBytes)
    assert(largeOk, "large packed boolean array must decode")
    for i = 1, 1000 do
        assert(largeDecoded[i] == largeValues[i], "large packed boolean must round-trip")
    end

    local records = assert(Codec.compile({
        type = "array",
        minLength = 2,
        maxLength = 2,
        items = {
            type = "object",
            fields = {
                { name = "x", schema = { type = "integer", min = 1, max = 100, encoding = "u8" } },
                { name = "y", schema = { type = "integer", min = 0, max = 255, encoding = "u8" } },
            },
        },
    }))
    local recordValue = { { x = 1, y = 255 }, { x = 100, y = 0 } }
    local recordBytes = assert(records:encode(recordValue))
    assert(buffer.len(recordBytes) == 4, "fixed byte records use one byte per field")
    local recordOk, decodedRecords = records:decode(recordBytes)
    assert(recordOk and decodedRecords[2].x == 100, "fixed byte records round-trip")
    local recordBatch = assert(records:encodeBatch({ recordValue, recordValue }))
    local recordSlices = assert(Frame.decodeBatch(recordBatch))
    assert(
        buffer.tostring(recordSlices[1]) == buffer.tostring(recordBytes),
        "batch encoding matches item encoding"
    )
    assert(records:encode({ { x = 0, y = 0 }, recordValue[2] }) == nil, "field bounds reject")
    assert(records:encode({ { x = 1, y = 0.5 }, recordValue[2] }) == nil, "fractions reject")
    buffer.writeu8(recordBytes, 0, 0)
    assert(not records:decode(recordBytes), "decode enforces declared field bounds")
    local sixFields = {}

    for i = 1, 6 do
        sixFields[i] = {
            name = `field{i}`,
            schema = { type = "integer", min = if i == 1 then 1 else 0, max = 255, encoding = "u8" },
        }
    end

    local sixCodec = assert(Codec.compile({
        type = "array",
        minLength = 1,
        maxLength = 1,
        items = { type = "object", fields = sixFields },
    }))
    local sixValue = { { field1 = 1, field2 = 2, field3 = 3, field4 = 4, field5 = 5, field6 = 6 } }
    local sixEncoded = assert(sixCodec:encode(sixValue))
    local sixOk, sixDecoded = sixCodec:decode(sixEncoded)
    assert(sixOk and sixDecoded[1].field6 == 6, "six-byte records round-trip")
    local sixBatch = assert(sixCodec:encodeBatch({ sixValue }))
    local batchOk, batchValues = sixCodec:decodeBatch(sixBatch)
    assert(batchOk and batchValues[1][1].field3 == 3, "six-byte records decode in a batch")
    local wrapped = buffer.create(buffer.len(sixBatch) + 7)
    buffer.copy(wrapped, 3, sixBatch)
    local regionOk, regionValues = sixCodec:decodeBatch(wrapped, nil, {
        offset = 3,
        length = buffer.len(sixBatch),
    })
    assert(regionOk and regionValues[1][1].field6 == 6, "batch region decodes without a copy")
    assert(
        not sixCodec:decodeBatch(wrapped, nil, { offset = -1, length = 10 }),
        "bad region rejects"
    )
    buffer.writeu8(sixEncoded, 0, 0)
    assert(not sixCodec:decode(sixEncoded), "six-byte read enforces field bounds")
    local compactSix = assert(sixCodec:encodeCompactBatch({ sixValue, sixValue }))
    assert(
        buffer.len(compactSix) == 2 + 2 * buffer.len(assert(sixCodec:encode(sixValue))),
        "compact batch omits item lengths"
    )
    local compactSixOk, compactSixValues = sixCodec:decodeCompactBatch(compactSix)
    assert(compactSixOk and compactSixValues[2][1].field5 == 5, "compact records round-trip")
    local compactWrapped = buffer.create(buffer.len(compactSix) + 6)
    buffer.copy(compactWrapped, 3, compactSix)
    assert(
        sixCodec:decodeCompactBatch(
            compactWrapped,
            nil,
            { offset = 3, length = buffer.len(compactSix) }
        ),
        "compact region decodes"
    )
    local variableRecords = assert(Codec.compile({
        type = "array",
        minLength = 0,
        maxLength = 3,
        items = {
            type = "object",
            fields = {
                { name = "x", schema = { type = "integer", min = 1, max = 10, encoding = "u8" } },
                { name = "y", schema = { type = "integer", min = 0, max = 255, encoding = "u8" } },
            },
        },
    }))
    for _, sample in ipairs({ {}, { { x = 1, y = 2 } }, { { x = 1, y = 2 }, { x = 10, y = 255 } } }) do
        local variableEncoded = assert(variableRecords:encode(sample))
        assert(buffer.readu8(variableEncoded, 0) == #sample, "variable record length is canonical")
        local variableOk, decoded = variableRecords:decode(variableEncoded)
        assert(variableOk and #decoded == #sample, "variable record array round-trips")
        local batch = assert(variableRecords:encodeBatch({ sample }))
        local variableBatchOk, batchDecoded = variableRecords:decodeBatch(batch)
        assert(variableBatchOk and #batchDecoded[1] == #sample, "variable record batch round-trips")
        local compact = assert(variableRecords:encodeCompactBatch({ sample, sample }))
        local compactOk, compactDecoded = variableRecords:decodeCompactBatch(compact)
        assert(compactOk and #compactDecoded[2] == #sample, "variable compact records round-trip")
    end
    assert(variableRecords:encode({
        { x = 1, y = 2 },
        { x = 2, y = 3 },
        { x = 3, y = 4 },
        { x = 4, y = 5 },
    }) == nil, "variable bounds reject")
    local noncanonicalLength = buffer.create(2)
    buffer.writeu8(noncanonicalLength, 0, 0x80)
    buffer.writeu8(noncanonicalLength, 1, 0)
    assert(not variableRecords:decode(noncanonicalLength), "noncanonical length rejects")
    assert(Codec.compile({
        type = "array",
        maxLength = 4,
        encoding = "packed",
        items = { type = "integer", min = 0, max = 1 },
    }) == nil, "packed encoding must only accept booleans")

    local batchCodec = assert(Codec.compile({ type = "integer", min = 0, max = 65535 }))
    local encodedBatch =
        assert(batchCodec:encodeBatch({ 1, 255, 4096 }), "codec-aware batches must encode")
    local decodedSlices = assert(
        Frame.decodeBatch(encodedBatch),
        "codec-aware batch output must use the standard wire format"
    )
    for i, expected in ipairs({ 1, 255, 4096 }) do
        local itemOk, itemValue = batchCodec:decode(decodedSlices[i])
        assert(itemOk and itemValue == expected, "codec-aware batch item must round-trip")
    end

    local compactIntegers = assert(batchCodec:encodeCompactBatch({ 1, 255, 4096 }))
    local compactOk, compactValues = batchCodec:decodeCompactBatch(compactIntegers)
    assert(compactOk and compactValues[3] == 4096, "generic compact batch round-trips")
    assert(
        not batchCodec:decodeCompactBatch(compactIntegers, { maximumItems = 2 }),
        "compact count cap rejects"
    )

    local state = 0x51A7E
    local scalarCodec = assert(Codec.compile({ type = "integer", min = 0, max = 255 }))
    local packedCodec = assert(Codec.compile({
        type = "array",
        minLength = 0,
        maxLength = 32,
        encoding = "packed",
        items = { type = "boolean" },
    }))
    for length = 0, 159 do
        local candidate = buffer.create(length)

        for offset = 0, length - 1 do
            state = nextRandom(state)
            buffer.writeu8(candidate, offset, state % 256)
        end

        local inspected = pcall(Frame.inspect, candidate, {
            maximumFrameBytes = 128,
            maximumPayloadBytes = 96,
            maximumExpandedBytes = 192,
        })
        assert(inspected, "frame inspection must be total for deterministic malformed input")
        local decoded = pcall(Frame.decodeBatch, candidate, {
            maximumItems = 16,
            maximumItemBytes = 32,
            maximumPayloadBytes = 128,
        })
        assert(decoded, "batch parsing must be total for deterministic malformed input")
        local codecDecoded = pcall(scalarCodec.decodeBatch, scalarCodec, candidate, {
            maximumItems = 16,
            maximumItemBytes = 32,
            maximumPayloadBytes = 128,
        })
        assert(codecDecoded, "codec batch decoding must be total for malformed input")
        assert(
            pcall(scalarCodec.decodeCompactBatch, scalarCodec, candidate, {
                maximumItems = 16,
                maximumItemBytes = 32,
                maximumPayloadBytes = 128,
            }),
            "compact scalar parsing must be total for malformed input"
        )
        assert(
            pcall(packedCodec.decodeCompactBatch, packedCodec, candidate, {
                maximumItems = 16,
                maximumItemBytes = 32,
                maximumPayloadBytes = 128,
            }),
            "compact packed parsing must be total for malformed input"
        )
    end

    for sequence, length in { 0, 1, 95, 96 } do
        local payload = buffer.create(length)

        for offset = 0, length - 1 do
            state = nextRandom(state)
            buffer.writeu8(payload, offset, state % 256)
        end

        local frame = assert(Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 7,
            sequence = sequence,
            payload = payload,
        }))
        local decoded = assert(Frame.decode(frame))
        assert(
            decoded.sequence == sequence
                and buffer.len(decoded.payload) == length
                and buffer.tostring(decoded.payload) == buffer.tostring(payload),
            "deterministic frame roundtrip property must hold"
        )
    end
end
