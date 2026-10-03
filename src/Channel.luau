--!strict
local Channel = {}

local function encode(codec: any, value: any): (buffer?, string?)
    if type(codec.encode) ~= "function" then
        return nil, "encoder_unavailable"
    end
    local called, payload, reason = pcall(codec.encode, codec, value)
    if not called then
        return nil, "encoding_failed"
    end
    return payload, reason
end

function Channel.bind(peer: any, routeId: number, codec: any, responseCodec: any?): any
    local route = peer.routes[routeId]
    assert(not peer.destroyed and route and type(codec) == "table", "invalid channel binding")
    assert(
        route.schemaFingerprint == nil or route.schemaFingerprint == codec.fingerprint,
        "channel schema mismatch"
    )
    if responseCodec then
        assert(
            route.lane == "request" and type(responseCodec) == "table",
            "invalid response schema"
        )
        assert(
            route.responseFingerprint == nil
                or route.responseFingerprint == responseCodec.fingerprint,
            "response schema mismatch"
        )
    end
    local handle = {}
    function handle:send(value: any, latest: boolean?): (boolean, string?)
        local payload, reason = encode(codec, value)
        if not payload then
            return false, reason
        end
        return peer:send(routeId, payload, latest)
    end
    function handle:sendBatch(values: any, compact: boolean?): (boolean, string?)
        if compact then
            return peer:sendCompactBatchValues(routeId, codec, values)
        end
        return peer:sendBatchValues(routeId, codec, values)
    end
    function handle:on(callback: any, rejected: any?): () -> ()
        assert(
            type(callback) == "function" and type(codec.decode) == "function",
            "channel decoder/callback required"
        )
        return peer:on(routeId, function(payload, context)
            local ok, value, reason = codec:decode(payload)
            if ok then
                callback(value, context)
            elseif type(rejected) == "function" then
                rejected(reason, context)
            end
        end)
    end
    function handle:onBatch(callback: any): () -> ()
        return peer:onBatchValues(routeId, codec, callback)
    end
    function handle:request(value: any, timeout: number, callback: any): (number?, string?)
        assert(
            type(callback) == "function"
                and responseCodec
                and type(responseCodec.decode) == "function",
            "response decoder/callback required"
        )
        local payload, reason = encode(codec, value)
        if not payload then
            return nil, reason
        end
        return peer:request(routeId, payload, timeout, function(ok, bytes, failure)
            if not ok then
                callback(false, nil, failure)
                return
            end
            local decoded, response, decodeReason = responseCodec:decode(bytes)
            callback(decoded, response, decodeReason)
        end)
    end
    function handle:respond(requestId: number, value: any): (boolean, string?)
        if not responseCodec then
            return false, "response_encoder_unavailable"
        end
        local payload, reason = encode(responseCodec, value)
        if not payload then
            return false, reason
        end
        return peer:respond(routeId, requestId, payload)
    end
    function handle:cancel(requestId: number): (boolean, string?)
        return peer:cancel(routeId, requestId)
    end
    return table.freeze(handle)
end

return Channel
