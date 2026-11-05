local Codec = require("../src/TransportCodec")

local function genericExpansion()
    -- Compilation must refuse multiplicative zero-byte expansion without ever
    -- decoding the enormous value. This regression allocates schema tables only.
    for _, leaf in
        {
            { type = "enum", values = { "only" } },
            { type = "object", fields = {} },
        }
    do
        local schema = leaf
        for _ = 1, 4 do
            schema = { type = "array", minLength = 128, maxLength = 128, items = schema }
        end
        local amplified, reason = Codec.compile(schema)
        assert(
            amplified == nil and reason == "schema_decoded_too_large",
            "zero-wire-byte nested arrays must be bounded at compilation"
        )
    end

    -- The exact static limit is checked using optional fields and empty values;
    -- do not allocate the declared worst-case value to prove the boundary.
    local staticFields = {
        {
            name = "wide",
            optional = true,
            schema = {
                type = "array",
                maxLength = 63,
                items = {
                    type = "array",
                    maxLength = 1023,
                    items = { type = "enum", values = { "only" } },
                },
            },
        },
        {
            name = "tail",
            optional = true,
            schema = {
                type = "array",
                maxLength = 1021,
                items = { type = "object", fields = {} },
            },
        },
    }
    local staticBoundary = assert(
        Codec.compile({ type = "object", fields = staticFields }),
        "exact 65536-value schema must remain supported"
    )
    assert(
        staticBoundary.maximumDecodedValues == 65536,
        "compiled decoded cost includes containers and primitive values"
    )
    assert(
        staticBoundary:decode(assert(staticBoundary:encode({}))),
        "sparse optional value at the declared static boundary must round-trip"
    )
    staticFields[3] = { name = "extra", schema = { type = "boolean" } }
    local overBoundary, overReason = Codec.compile({ type = "object", fields = staticFields })
    assert(
        overBoundary == nil and overReason == "schema_decoded_too_large",
        "one decoded value over the static cap must fail compilation"
    )

    -- Small aggregate budgets exercise the exact same shared hard-cap code as
    -- the production default without creating a large decoded allocation.
    local cases = {
        {
            schema = { type = "array", maxLength = 3, items = { type = "enum", values = { "x" } } },
            value = { "x", "x", "x" },
            cost = 4,
        },
        {
            schema = { type = "array", maxLength = 3, items = { type = "object", fields = {} } },
            value = { {}, {}, {} },
            cost = 4,
        },
        {
            schema = {
                type = "array",
                maxLength = 3,
                encoding = "packed",
                items = { type = "boolean" },
            },
            value = { true, false, true },
            cost = 4,
        },
        {
            schema = {
                type = "array",
                maxLength = 2,
                items = {
                    type = "object",
                    fields = {
                        { name = "a", schema = { type = "integer", min = 0, max = 255 } },
                        { name = "b", schema = { type = "integer", min = 0, max = 255 } },
                    },
                },
            },
            value = { { a = 1, b = 2 }, { a = 3, b = 4 } },
            cost = 7,
        },
        {
            schema = {
                type = "object",
                fields = {
                    {
                        name = "optional",
                        optional = true,
                        schema = {
                            type = "array",
                            maxLength = 3,
                            items = { type = "enum", values = { "x" } },
                        },
                    },
                },
            },
            value = {},
            cost = 2,
        },
    }
    for _, case in cases do
        local bounded = assert(Codec.compile(case.schema), "bounded expansion fixture must compile")
        local values = { case.value, case.value }
        local exact = 2 + 2 * case.cost -- Outer slots plus each actual decoded value.
        for _, compact in { false, true } do
            local encode = if compact then bounded.encodeCompactBatch else bounded.encodeBatch
            local decode = if compact then bounded.decodeCompactBatch else bounded.decodeBatch
            local limits = { maximumDecodedValues = exact }
            local bytes = assert(
                encode(bounded, values, limits),
                "encoding exactly at the aggregate value limit must succeed"
            )
            local success, decoded = decode(bounded, bytes, limits)
            assert(success and #decoded == 2, "exact aggregate decoded boundary must succeed")
            limits.maximumDecodedValues = exact - 1
            local refused, encodeReason = encode(bounded, values, limits)
            local accepted, _, decodeReason = decode(bounded, bytes, limits)
            assert(
                refused == nil and encodeReason == "decoded_work_limit",
                "encoding must not reset expansion allowance per batch item"
            )
            assert(
                not accepted and decodeReason == "decoded_work_limit",
                "ordinary and compact decoding must share one expansion allowance"
            )
            local framed = buffer.create(buffer.len(bytes) + 5)
            buffer.copy(framed, 3, bytes)
            assert(
                not decode(bounded, framed, limits, { offset = 3, length = buffer.len(bytes) }),
                "batch subregions must not bypass shared expansion limits"
            )
            for _, invalid in { 0, -1, 1.5, math.huge, 0 / 0, 262145 } do
                assert(
                    encode(bounded, values, { maximumDecodedValues = invalid }) == nil,
                    "invalid or above-hard-cap encode budgets must reject"
                )
                assert(
                    not decode(bounded, bytes, { maximumDecodedValues = invalid }),
                    "invalid or above-hard-cap decode budgets must reject"
                )
            end
        end
    end
end

local luau = require("@lune/luau")
local ClientGenerator = require("../tools/ClientCodecGenerator")
local NativeGenerator = require("../tools/NativeCodecGenerator")

return function()
    genericExpansion()
    -- Both specialization families, fixed/variable lengths and checked/trusted
    -- writers must enforce the same aggregate bound as the generic codec.
    for _, native in { false, true } do
        local function load(source)
            return luau.load(
                luau.compile(source, { optimizationLevel = 2 }),
                { codegenEnabled = native }
            )()
        end
        for _, packed in { false, true } do
            for _, fixed in { false, true } do
                local spec = {
                    type = "array",
                    minLength = if fixed then 3 else 0,
                    maxLength = 3,
                    encoding = if packed then "packed" else nil,
                    items = if packed
                        then { type = "boolean" }
                        else {
                            type = "object",
                            fields = {
                                { name = "a", schema = { type = "integer", min = 0, max = 255 } },
                                { name = "b", schema = { type = "integer", min = 0, max = 255 } },
                            },
                        },
                }
                local value = if packed
                    then { true, false, true }
                    else {
                        { a = 1, b = 2 },
                        { a = 3, b = 4 },
                        { a = 5, b = 6 },
                    }
                local codec = assert(Codec.compile(spec))
                local decoder = load(assert(NativeGenerator.generate(spec)))
                assert(
                    decoder.maximumDecodedValues == codec.maximumDecodedValues,
                    "native metadata must match generic decoded bound"
                )
                local exact = if packed then 10 else 22
                for _, trusted in { false, true } do
                    local encoder =
                        load(assert(ClientGenerator.generate(spec, { trustOutbound = trusted })))
                    assert(
                        encoder.maximumDecodedValues == codec.maximumDecodedValues,
                        "client metadata must match generic decoded bound"
                    )
                    assert(
                        encoder.fingerprint == codec.fingerprint
                            and decoder.fingerprint == codec.fingerprint,
                        "generated fingerprints must match the schema codec"
                    )
                    for _, compact in { false, true } do
                        local encode = if compact
                            then encoder.encodeCompactBatch
                            else encoder.encodeBatch
                        local decode = if compact
                            then decoder.decodeCompactBatch
                            else decoder.decodeBatch
                        local genericEncode = if compact
                            then codec.encodeCompactBatch
                            else codec.encodeBatch
                        local values = { value, value }
                        local limits = { maximumDecodedValues = exact }
                        local bytes = assert(encode(encoder, values, limits))
                        assert(
                            buffer.tostring(bytes)
                                == buffer.tostring(assert(genericEncode(codec, values, limits))),
                            "generated wire bytes must match the schema codec"
                        )
                        local ok, decoded = decode(decoder, bytes, limits)
                        assert(
                            ok and #decoded == 2 and #decoded[2] == 3,
                            "generated decoder must accept the exact aggregate boundary"
                        )
                        for _, maximum in { exact - 1, 1, 0, -1, 1.5, math.huge, 0 / 0, 262145 } do
                            local rejected, encodeReason =
                                encode(encoder, values, { maximumDecodedValues = maximum })
                            local accepted, _, decodeReason =
                                decode(decoder, bytes, { maximumDecodedValues = maximum })
                            assert(
                                rejected == nil and encodeReason == "decoded_work_limit",
                                "generated encoder must enforce cumulative and hard limits"
                            )
                            assert(
                                not accepted and decodeReason == "decoded_work_limit",
                                "generated decoder must enforce cumulative and hard limits"
                            )
                        end
                        local framed = buffer.create(buffer.len(bytes) + 7)
                        buffer.copy(framed, 3, bytes)
                        assert(
                            decode(
                                decoder,
                                framed,
                                limits,
                                { offset = 3, length = buffer.len(bytes) }
                            )
                        )
                        local accepted, _, reason = decode(
                            decoder,
                            framed,
                            { maximumDecodedValues = exact - 1 },
                            { offset = 3, length = buffer.len(bytes) }
                        )
                        assert(
                            not accepted and reason == "decoded_work_limit",
                            "framed regions must retain the aggregate limit"
                        )
                    end
                end
            end
        end
    end
end
