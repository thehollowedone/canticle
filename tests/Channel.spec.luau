local Codec = require("../src/TransportCodec")
local Peer = require("../src/TransportPeer")
local Channel = require("../src/Channel")

return function()
    local requestCodec = assert(Codec.compile({ type = "integer", min = 0, max = 10 }))
    local responseCodec = assert(Codec.compile({ type = "string", maxLength = 16 }))
    local batchCodec = assert(Codec.compile({
        type = "array",
        maxLength = 8,
        encoding = "packed",
        items = { type = "boolean" },
    }))
    local routes = {
        {
            id = 1,
            lane = "request",
            schemaFingerprint = requestCodec.fingerprint,
            responseFingerprint = responseCodec.fingerprint,
        },
        {
            id = 2,
            lane = "reliable",
            allowBatch = true,
            allowCompactBatch = true,
            schemaFingerprint = batchCodec.fingerprint,
        },
    }
    local client, server
    client = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function(bytes)
            assert(server:receive(bytes, "reliable"))
        end,
    })
    server = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function(bytes)
            assert(client:receive(bytes, "reliable"))
        end,
    })
    local outgoing = Channel.bind(client, 1, requestCodec, responseCodec)
    local incoming = Channel.bind(server, 1, requestCodec, responseCodec)
    local observed = 0
    local disconnect = incoming:on(function(value, context)
        observed += 1
        assert(incoming:respond(context.requestId, "value:" .. value))
    end)
    local reply
    assert(outgoing:request(7, 1, function(ok, value, reason)
        assert(ok and not reason, "typed request must complete successfully")
        reply = value
    end))
    assert(
        reply == "value:7" and observed == 1 and client.requestCount == 0,
        "typed reply must retire its pending request"
    )
    assert(outgoing:request(99, 1, function()
        error("invalid request callback must not run")
    end) == nil, "invalid typed request must be refused before sending")
    assert(observed == 1, "local invalid value must not reach server")
    local a = Channel.bind(client, 2, batchCodec)
    local b = Channel.bind(server, 2, batchCodec)
    local values
    local disconnectBatch = b:onBatch(function(batch)
        values = batch
    end)
    assert(a:sendBatch({ { true, false }, { false, true } }, true))
    assert(values[1][1] and not values[2][1], "typed compact batch must deliver")
    disconnectBatch()
    disconnect()
    local wrong = table.clone(batchCodec)
    wrong.fingerprint += 1
    assert(not pcall(Channel.bind, client, 2, wrong), "binding mismatched schema must fail")
    assert(
        not pcall(Channel.bind, client, 1, requestCodec, batchCodec),
        "binding mismatched response schema must fail"
    )
    local rejected = 0
    b:on(function()
        error("malformed value must not dispatch")
    end, function()
        rejected += 1
    end)
    assert(client:send(2, buffer.create(0)))
    assert(rejected == 1, "typed ingress reports invalid values without application dispatch")
    server:destroy()
    client:destroy()
    assert(not a:send({ true }), "channel cannot revive destroyed peer")
end
