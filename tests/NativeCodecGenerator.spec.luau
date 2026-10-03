local luau = require("@lune/luau")
local Codec = require("../src/TransportCodec")
local Generator = require("../tools/NativeCodecGenerator")

local function equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for key, value in a do
        if not equal(value, b[key]) then
            return false
        end
    end
    for key in b do
        if a[key] == nil then
            return false
        end
    end
    return true
end

return function()
    for _, fixed in ipairs({ true, false }) do
        local fields = {}
        for index, name in { "slot value", "class", "x", "y", "z", "state" } do
            fields[index] = {
                name = name,
                schema = {
                    type = "integer",
                    min = if index == 1 then 1 else 0,
                    max = if index == 1 then 12 else 255,
                    encoding = "u8",
                },
            }
        end
        local spec = {
            type = "array",
            minLength = if fixed then 2 else 0,
            maxLength = if fixed then 2 else 5,
            items = { type = "object", fields = fields },
        }
        local generic = assert(Codec.compile(spec))
        local source = assert(Generator.generate(spec))
        local generated = luau.load(luau.compile(source, { optimizationLevel = 2 }), {
            codegenEnabled = true,
        })()
        assert(generated.fingerprint == generic.fingerprint, "schema fingerprint must match")
        assert(generated.maximumBytes == generic.maximumBytes, "schema byte cap must match")
        local one = { ["slot value"] = 1, class = 2, x = 3, y = 4, z = 5, state = 6 }
        local two = { ["slot value"] = 12, class = 255, x = 0, y = 7, z = 8, state = 9 }
        local sample = { one, two }
        local batch = assert(generic:encodeBatch({ sample, if fixed then sample else {} }))
        local limits = {
            maximumItems = 2,
            maximumItemBytes = generic.maximumBytes,
            maximumPayloadBytes = 1024,
        }
        local expectedOk, expected = generic:decodeBatch(batch, limits)
        local actualOk, actual = generated:decodeBatch(batch, limits)
        assert(
            expectedOk and actualOk and equal(expected, actual),
            "native record decoder must match generic output"
        )
        local compactBatch =
            assert(generic:encodeCompactBatch({ sample, if fixed then sample else {} }))
        local compactExpectedOk, compactExpected = generic:decodeCompactBatch(compactBatch, limits)
        local compactActualOk, compactActual = generated:decodeCompactBatch(compactBatch, limits)
        assert(
            compactExpectedOk and compactActualOk and equal(compactExpected, compactActual),
            "native compact records must match"
        )
        local wrapper = buffer.create(buffer.len(batch) + 8)
        buffer.copy(wrapper, 4, batch)
        local wrappedOk, wrapped =
            generated:decodeBatch(wrapper, limits, { offset = 4, length = buffer.len(batch) })
        assert(wrappedOk and equal(expected, wrapped), "native decoder must honor a frame region")
        assert(
            not generated:decodeBatch(wrapper, limits, { offset = -1, length = 3 }),
            "invalid region rejects"
        )
        local malformed = buffer.create(buffer.len(batch))
        buffer.copy(malformed, 0, batch)
        local recordOffset = if fixed then 6 else 7
        buffer.writeu8(malformed, recordOffset, 0)
        assert(not generated:decodeBatch(malformed, limits), "declared field range rejects")
        buffer.writeu32(malformed, 2, 99999)
        assert(not generated:decodeBatch(malformed, limits), "oversized item rejects")
    end
    local emptySpec = {
        type = "array",
        maxLength = 0,
        items = {
            type = "object",
            fields = {
                { name = "value", schema = { type = "integer", min = 0, max = 255 } },
            },
        },
    }
    local emptyCodec = assert(Codec.compile(emptySpec))
    local emptySource = assert(Generator.generate(emptySpec))
    local emptyDecoder = luau.load(luau.compile(emptySource), { codegenEnabled = true })()
    local emptyBatch = assert(emptyCodec:encodeBatch({ {} }))
    local emptyOk, emptyValues = emptyDecoder:decodeBatch(emptyBatch)
    assert(emptyOk and #emptyValues[1] == 0, "zero-length fixed arrays decode")
    assert(emptyCodec:encodeCompactBatch({ {} }) == nil, "zero-byte compact items reject")
    local packedSpec = {
        type = "array",
        minLength = 0,
        maxLength = 17,
        encoding = "packed",
        items = { type = "boolean" },
    }
    local packedCodec = assert(Codec.compile(packedSpec))
    local packedSource = assert(Generator.generate(packedSpec))
    local packedDecoder = luau.load(luau.compile(packedSource), { codegenEnabled = true })()
    for _, sample in ipairs({
        {},
        { true },
        { true, false, true, true, false, false, true, false, true },
        table.create(17, true),
    }) do
        local batch = assert(packedCodec:encodeBatch({ sample }))
        local genericOk, genericValues = packedCodec:decodeBatch(batch)
        local nativeOk, nativeValues = packedDecoder:decodeBatch(batch)
        assert(
            genericOk and nativeOk and equal(genericValues, nativeValues),
            "native packed decoder must match"
        )
        local compact = assert(packedCodec:encodeCompactBatch({ sample }))
        local compactGenericOk, compactGeneric = packedCodec:decodeCompactBatch(compact)
        local compactNativeOk, compactNative = packedDecoder:decodeCompactBatch(compact)
        assert(
            compactGenericOk and compactNativeOk and equal(compactGeneric, compactNative),
            "native compact packed decoder must match"
        )
    end
    local tailBatch = assert(packedCodec:encodeBatch({ { true } }))
    buffer.writeu8(tailBatch, buffer.len(tailBatch) - 1, 0x81)
    assert(
        not packedDecoder:decodeBatch(tailBatch),
        "native packed decoder rejects unused tail bits"
    )
    for size = 0, 96 do
        local candidate = buffer.create(size)
        for offset = 0, size - 1 do
            buffer.writeu8(candidate, offset, (size * 41 + offset * 79) % 256)
        end
        assert(
            pcall(packedDecoder.decodeCompactBatch, packedDecoder, candidate),
            "native compact parsing is total"
        )
        assert(
            pcall(packedDecoder.decodeBatch, packedDecoder, candidate),
            "native batch parsing is total"
        )
    end
    assert(Generator.generate({ type = "boolean" }) == nil, "unsupported schemas reject")
end
