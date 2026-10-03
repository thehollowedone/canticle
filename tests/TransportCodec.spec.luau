local Codec = require("../src/TransportCodec")
local Frame = require("../src/TransportFrame")

local function nextRandom(state)
    return (state * 1664525 + 1013904223) % 4294967296
end

return function()
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
