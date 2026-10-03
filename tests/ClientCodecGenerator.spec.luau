local luau = require("@lune/luau")
local Codec = require("../src/TransportCodec")
local Generator = require("../tools/ClientCodecGenerator")
local Peer = require("../src/TransportPeer")
local codegenEnabled = false
local function load(source)
    return luau.load(source, { codegenEnabled = codegenEnabled })
end

local function check(spec, values)
    local codec = assert(Codec.compile(spec))
    local generated =
        load(luau.compile(assert(Generator.generate(spec)), { optimizationLevel = 2 }))()
    local trusted = load(
        luau.compile(
            assert(Generator.generate(spec, { trustOutbound = true })),
            { optimizationLevel = 2 }
        )
    )()
    assert(
        generated.validatesOutgoing == true and trusted.validatesOutgoing == false,
        "outbound validation mode must be explicit"
    )
    assert(
        generated.fingerprint == codec.fingerprint and generated.maximumBytes == codec.maximumBytes,
        "specialized codec identity and bounds must match runtime codec"
    )
    for _, compact in ipairs({ false, true }) do
        local method = if compact then "encodeCompactBatch" else "encodeBatch"
        local actual = assert(generated[method](generated, values))
        local runtime = assert(codec[method](codec, values))
        local pieces = {}
        local total = 2
        for i, value in ipairs(values) do
            pieces[i] = assert(codec:encode(value))
            total += buffer.len(pieces[i]) + (if compact then 0 else 4)
        end
        local expected = buffer.create(total)
        buffer.writeu16(expected, 0, #values)
        local offset = 2
        for _, piece in ipairs(pieces) do
            if not compact then
                buffer.writeu32(expected, offset, buffer.len(piece))
                offset += 4
            end
            buffer.copy(expected, offset, piece)
            offset += buffer.len(piece)
        end
        assert(
            buffer.tostring(actual) == buffer.tostring(expected),
            "generated encoder must match independent item encoding"
        )
        assert(
            buffer.tostring(assert(trusted[method](trusted, values))) == buffer.tostring(expected),
            "trusted output preserves the same canonical wire for valid values"
        )
        assert(
            buffer.tostring(runtime) == buffer.tostring(expected),
            "runtime memo/fused encoder must match independent items"
        )
    end
    return codec, generated
end

local function run()
    math.randomseed(5481)
    for _, width in ipairs({ 1, 2, 3, 4, 6, 16 }) do
        local fields = {}
        local row = {}
        for i = 1, width do
            local name = if i == 1 then 'slot " value' else "field" .. i
            fields[i] =
                { name = name, schema = { type = "integer", min = 1, max = 200, encoding = "u8" } }
            row[name] = math.random(1, 200)
        end
        for _, fixed in ipairs({ false, true }) do
            local spec = {
                type = "array",
                minLength = if fixed then 2 else 0,
                maxLength = if fixed then 2 else 1000,
                items = { type = "object", fields = fields },
            }
            local one = { row, table.clone(row) }
            local codec, generated =
                check(spec, { one, one, { table.clone(row), table.clone(row) } })
            for _, bad in ipairs({
                0,
                201,
                1.5,
                math.huge,
                -math.huge,
                1e300,
                -1e300,
                4294967296,
                "1",
                false,
                0 / 0,
            }) do
                local invalid = table.clone(row)
                invalid[fields[1].name] = bad
                assert(
                    codec:encodeCompactBatch({ { invalid, row } }) == nil,
                    "runtime ranges/types reject"
                )
                assert(
                    generated:encodeCompactBatch({ { invalid, row } }) == nil,
                    "generated ranges/types reject"
                )
            end
            local missing = table.clone(row)
            missing[fields[1].name] = nil
            assert(
                generated:encodeCompactBatch({ { missing, row } }) == nil,
                "required fields reject"
            )
            local before = assert(generated:encodeCompactBatch({ one, one }))
            row[fields[1].name] = if row[fields[1].name] == 1 then 2 else 1
            local after = assert(generated:encodeCompactBatch({ one, one }))
            assert(
                buffer.tostring(before) ~= buffer.tostring(after),
                "memo cannot persist across calls"
            )
            assert(
                generated:encodeCompactBatch({ one }, { maximumPayloadBytes = 1 }) == nil,
                "specialization must obey payload ceiling"
            )
            assert(
                generated:encodeCompactBatch({ [1] = one, extra = one }) == nil,
                "specialization must reject non-array batch keys"
            )
        end
    end
    for _, length in { 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33 } do
        local spec = {
            type = "array",
            minLength = 0,
            maxLength = 1000,
            encoding = "packed",
            items = { type = "boolean" },
        }
        local values = {}
        for i = 1, length do
            values[i] = math.random(0, 1) == 1
        end
        local codec, generated = check(spec, { values, values, table.clone(values) })
        if length > 0 then
            local bad = table.clone(values)
            bad[length] = 1
            assert(
                codec:encodeCompactBatch({ bad }) == nil
                    and generated:encodeCompactBatch({ bad }) == nil,
                "checked boolean encoding must reject numeric truthiness"
            )
        end
    end
    local fields, row = {}, {}
    for i = 1, 6 do
        fields[i] = { name = "f" .. i, schema = { type = "integer", min = 0, max = 255 } }
        row["f" .. i] = 0
    end
    local spec = {
        type = "array",
        minLength = 0,
        maxLength = 2,
        items = { type = "object", fields = fields },
    }
    local codec = assert(Codec.compile(spec))
    local generated = load(assert(Generator.generate(spec)))()
    for _, encoder in ipairs({ codec, generated }) do
        for key in row do
            row[key] = 0
        end
        local proxy = setmetatable({}, {
            __index = function(_, key)
                row.f1 = 7
                return row[key]
            end,
        })
        local repeated = { row }
        local result = assert(encoder:encodeCompactBatch({ repeated, { proxy }, repeated }))
        local ok, decoded = codec:decodeCompactBatch(result)
        assert(
            ok and decoded[1][1].f1 == 0 and decoded[3][1].f1 == 7,
            "metatable side effects must disable batch memo"
        )
    end
    -- The outer metatable can mutate items that were already encoded.
    local packedSpec = {
        type = "array",
        minLength = 0,
        maxLength = 2,
        encoding = "packed",
        items = { type = "boolean" },
    }
    for _, outerSpec in { packedSpec, spec } do
        local reference = assert(Codec.compile(outerSpec))
        local encoders = {
            reference,
            load(assert(Generator.generate(outerSpec)))(),
            load(assert(Generator.generate(outerSpec, { trustOutbound = true })))(),
        }
        for _, encoder in encoders do
            for _, method in { "encodeBatch", "encodeCompactBatch" } do
                local isPacked = outerSpec == packedSpec
                local initial = if isPacked then false else table.clone(row)
                if not isPacked then
                    initial.f1 = 0
                end
                local repeated = { initial }
                local other = if isPacked then { false } else { table.clone(initial) }
                local accesses = 0
                local outer = table.create(3)
                outer[1], outer[3] = repeated, repeated
                assert(#outer == 3, "regression requires a raw array hole")
                setmetatable(outer, {
                    __iter = function()
                        local key = 0
                        return function()
                            key += 1
                            if key <= 3 then
                                return key, true
                            end
                            return nil
                        end
                    end,
                    __index = function(_, key)
                        if key == 2 then
                            accesses += 1
                            if accesses > 1 then
                                if isPacked then
                                    repeated[1] = true
                                else
                                    repeated[1].f1 = 7
                                end
                            end
                            return other
                        end
                        return nil
                    end,
                })
                local bytes = assert(encoder[method](encoder, outer))
                local decode = if method == "encodeBatch"
                    then reference.decodeBatch
                    else reference.decodeCompactBatch
                local ok, decoded = decode(reference, bytes)
                assert(ok and accesses == 2, "outer proxy must supply its slot in both passes")
                assert(
                    (isPacked and decoded[1][1] == false and decoded[3][1] == true)
                        or (not isPacked and decoded[1][1].f1 == 0 and decoded[3][1].f1 == 7),
                    "outer metatable mutation must disable duplicate serialization memo"
                )
            end
        end
    end
    assert(
        Generator.generate({ type = "boolean" }) == nil,
        "unsupported single-value schema must refuse specialization"
    )
    local countSpec = {
        type = "array",
        minLength = 0,
        maxLength = 1,
        encoding = "packed",
        items = { type = "boolean" },
    }
    for _, countEncoder in
        {
            assert(Codec.compile(countSpec)),
            load(assert(Generator.generate(countSpec)))(),
            load(assert(Generator.generate(countSpec, { trustOutbound = true })))(),
        }
    do
        local oversized = table.create(65536, {})
        for _, method in { "encodeBatch", "encodeCompactBatch" } do
            local bytes, reason =
                countEncoder[method](countEncoder, oversized, { maximumItems = 65536 })
            assert(
                bytes == nil and reason == "batch_item_count",
                "batch count must not overflow uint16 wire field"
            )
        end
        local boundary = table.create(65535, {})
        for _, method in { "encodeBatch", "encodeCompactBatch" } do
            local bytes =
                assert(countEncoder[method](countEncoder, boundary, { maximumItems = 65535 }))
            assert(
                buffer.readu16(bytes, 0) == 65535,
                "uint16 boundary batch count must remain representable"
            )
        end
    end
    local uint8 = {
        type = "array",
        minLength = 1,
        maxLength = 1,
        items = {
            type = "object",
            fields = {
                { name = "v", schema = { type = "integer", min = 0, max = 255, encoding = "u8" } },
            },
        },
    }
    local reference = assert(Codec.compile(uint8))
    local specialized = load(assert(Generator.generate(uint8)))()
    for _, primitive in
        { -1, 0, 0.125, 1, 1.875, 127, 127.125, 128, 254.875, 255, 255.125, 256, 65535, 4294967296 }
    do
        local value = { { v = primitive } }
        local expected = reference:encode(value)
        local actual = specialized:encodeCompactBatch({ value })
        assert(
            (expected ~= nil) == (actual ~= nil),
            "uint8 fast predicate must preserve boundary and fractional rejection"
        )
    end
    local boundCodec = assert(Codec.compile({
        type = "array",
        maxLength = 17,
        encoding = "packed",
        items = { type = "boolean" },
    }))
    local calls = 0
    local peer = Peer.new({
        epoch = 1,
        routes = {
            {
                id = 1,
                lane = "reliable",
                allowBatch = true,
                allowCompactBatch = true,
                schemaFingerprint = boundCodec.fingerprint,
            },
        },
        sendReliable = function()
            calls += 1
        end,
    })
    local wrong = table.clone(boundCodec)
    wrong.fingerprint += 1
    local ok, reason = peer:sendCompactBatchValues(1, wrong, { { true } })
    assert(not ok and reason == "schema_mismatch" and calls == 0, "mismatched encoder cannot send")
    assert(
        not pcall(peer.onBatchValues, peer, 1, wrong, function() end),
        "mismatched decoder cannot bind"
    )
    assert(
        peer:sendCompactBatchValues(1, boundCodec, { { true } }) and calls == 1,
        "matching codec must send exactly once"
    )
    peer:destroy()
end

return function()
    for _, native in { false, true } do
        codegenEnabled = native
        run()
    end
end
