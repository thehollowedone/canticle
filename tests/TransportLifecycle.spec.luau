local Transport = require("../src/Transport")

local function bytes(text)
    local out = buffer.create(#text)
    buffer.writestring(out, 0, text)
    return out
end

return function()
    local now = 0
    local sent = {}
    local metrics = Transport.Metrics.new()
    local peer = Transport.Peer.new({
        epoch = 11,
        routes = {
            {
                id = 1,
                lane = "request",
                maximumFrameBytes = 256,
                maximumPayloadBytes = 128,
                maximumOutstandingRequests = 1,
            },
        },
        maximumOutstandingRequests = 4,
        maximumRequestTimeout = 10,
        clock = function()
            return now
        end,
        metrics = metrics,
        sendReliable = function(frame)
            table.insert(sent, frame)
        end,
    })

    local cancelReason = nil
    local firstId = assert(
        peer:request(1, bytes("first"), 5, function(success, _, reason)
            assert(not success, "cancel callback must report failure")
            cancelReason = reason
        end),
        "first request must open"
    )
    local blocked, blockedReason = peer:request(1, bytes("blocked"), 5, function()
        error("capacity-rejected request callback must not run")
    end)
    assert(
        blocked == nil and blockedReason == "invalid_request",
        "capacity must reject another request"
    )
    assert(peer:status().outstandingRequests == 1, "first request must remain outstanding")
    assert(peer:cancel(1, firstId), "outstanding request must cancel")
    assert(cancelReason == "cancelled", "cancel callback reason must match")
    assert(peer:status().outstandingRequests == 0, "cancel must release request capacity")

    local timeoutReason = nil
    assert(
        peer:request(1, bytes("timeout"), 5, function(success, _, reason)
            assert(not success, "timeout callback must report failure")
            timeoutReason = reason
        end),
        "timeout request must open"
    )
    now = 6
    assert(peer:step() == 1, "step must expire one request")
    assert(timeoutReason == "timeout", "timeout callback reason must match")
    assert(peer:status().outstandingRequests == 0, "timeout must release request capacity")

    local destroyReason = nil
    assert(
        peer:request(1, bytes("destroy"), 5, function(success, _, reason)
            assert(not success, "destroy callback must report failure")
            destroyReason = reason
        end),
        "destroyed request must open"
    )
    peer:destroy()
    assert(destroyReason == "destroyed", "destroy callback reason must match")
    assert(peer:status().outstandingRequests == 0, "destroy must clear request capacity")

    local snapshot = metrics:snapshot()
    assert(snapshot.requests.opened == 3, "opened request metric must match")
    assert(snapshot.requests.cancelled == 2, "cancelled request metric must match")
    assert(snapshot.requests.timeout == 1, "timeout request metric must match")
    assert(snapshot.denials.request_capacity == 1, "capacity denial metric must match")
    assert(#sent == 4, "three requests plus one cancel must be emitted")

    local invalidClockPeer = Transport.Peer.new({
        epoch = 12,
        routes = {
            {
                id = 1,
                lane = "request",
                maximumFrameBytes = 256,
                maximumPayloadBytes = 128,
            },
        },
        clock = function()
            return math.huge
        end,
        sendReliable = function() end,
    })
    local invalidClockRequest, invalidClockReason = invalidClockPeer:request(
        1,
        bytes("clock"),
        1,
        function()
            error("invalid-clock request callback must not run")
        end
    )
    assert(
        invalidClockRequest == nil and invalidClockReason == "clock_failed",
        "non-finite clocks must not retain requests"
    )
    assert(
        invalidClockPeer:status().outstandingRequests == 0,
        "clock failure must leave request capacity untouched"
    )
    invalidClockPeer:destroy()

    now = 0
    local lateMetrics = Transport.Metrics.new()
    local latePeer = Transport.Peer.new({
        epoch = 13,
        routes = {
            {
                id = 1,
                lane = "request",
                maximumFrameBytes = 256,
                maximumPayloadBytes = 128,
            },
        },
        clock = function()
            return now
        end,
        sendReliable = function() end,
        metrics = lateMetrics,
    })
    local outboundId = assert(
        latePeer:request(1, bytes("outbound"), 1, function() end),
        "outbound collision fixture must open"
    )
    local inboundCancel = assert(
        Transport.Frame.encode({
            lane = "cancel",
            route = 1,
            epoch = 13,
            sequence = 1,
            requestId = outboundId,
            payload = buffer.create(0),
        }),
        "inbound cancel fixture must encode"
    )
    assert(latePeer:receive(inboundCancel), "inbound cancel must be consumed")
    assert(
        latePeer:status().outstandingRequests == 1,
        "an inbound request ID collision must not cancel a local outbound request"
    )
    now = 2
    assert(latePeer:step() == 1, "colliding local request must still timeout normally")

    local lateResponse = assert(
        Transport.Frame.encode({
            lane = "response",
            route = 1,
            epoch = 13,
            sequence = 2,
            requestId = outboundId,
            payload = bytes("late"),
        }),
        "late response fixture must encode"
    )
    local originalMaterialize = Transport.Frame.materialize
    local materialized = 0
    Transport.Frame.materialize = function(...)
        materialized += 1
        return originalMaterialize(...)
    end
    local called, lateOk, lateReason = pcall(latePeer.receive, latePeer, lateResponse)
    Transport.Frame.materialize = originalMaterialize
    assert(called and materialized == 0, "late responses must not allocate a payload copy")
    assert(
        lateOk and lateReason == "late_response",
        "a response after timeout must consume its cursor as late, not reject"
    )
    assert(
        lateMetrics:snapshot().requests.late == 1,
        "one late response must increment the late metric exactly once"
    )
    local inboundObserved = false
    latePeer:on(1, function()
        inboundObserved = true
    end)
    local afterLate = assert(
        Transport.Frame.encode({
            lane = "request",
            route = 1,
            epoch = 13,
            sequence = 3,
            requestId = 99,
            payload = bytes("after"),
        }),
        "post-late response fixture must encode"
    )
    assert(
        latePeer:receive(afterLate) and inboundObserved,
        "a late response must consume its wire cursor without wedging later requests"
    )
    latePeer:destroy()

    local emitted = {}
    local sendPeer = Transport.Peer.new({
        epoch = 14,
        routes = {
            { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        },
        sendReliable = function(frame)
            coroutine.yield("sending")
            table.insert(emitted, frame)
        end,
    })
    local sendThread = coroutine.create(function()
        return sendPeer:send(1, bytes("first"))
    end)
    local resumed, marker = coroutine.resume(sendThread)
    assert(resumed and marker == "sending", "first sender must reach its yielding adapter")
    local concurrentSend, concurrentReason = sendPeer:send(1, bytes("second"))
    assert(
        not concurrentSend and concurrentReason == "send_in_progress",
        "concurrent yielding send adapters must not emit duplicate sequences"
    )
    assert(coroutine.resume(sendThread), "first sender must resume")
    assert(
        #emitted == 1 and sendPeer:status().sentReliableSequence == 1,
        "serialized sender must commit exactly one frame"
    )
    sendPeer:destroy()

    local receiveOrder = {}
    local receivePeer = Transport.Peer.new({
        epoch = 15,
        routes = {
            { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        },
        sendReliable = function() end,
    })
    receivePeer:on(1, function(payload)
        local value = buffer.readstring(payload, 0, buffer.len(payload))
        table.insert(receiveOrder, value)
        if value == "first" then
            coroutine.yield("receiving")
        end
    end)
    local firstReceive = assert(
        Transport.Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 15,
            sequence = 1,
            payload = bytes("first"),
        }),
        "first serialized receive must encode"
    )
    local secondReceive = assert(
        Transport.Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 15,
            sequence = 2,
            payload = bytes("second"),
        }),
        "second serialized receive must encode"
    )
    local receiveThread = coroutine.create(function()
        return receivePeer:receive(firstReceive)
    end)
    resumed, marker = coroutine.resume(receiveThread)
    assert(resumed and marker == "receiving", "first listener must yield inside receive")
    local queued, queuedReason = receivePeer:receive(secondReceive)
    assert(queued and queuedReason == "queued", "concurrent receive must enter the bounded queue")
    assert(coroutine.resume(receiveThread), "serialized receiver must resume")
    assert(
        receiveOrder[1] == "first" and receiveOrder[2] == "second",
        "yielding listeners must still execute in reliable sequence order"
    )
    assert(receivePeer:status().queuedFrames == 0, "serialized receive queue must drain")
    receivePeer:destroy()

    local runtimeCodec = assert(Transport.Codec.compile({ type = "integer", min = 0, max = 255 }))
    local suspendedCodec = table.clone(runtimeCodec)
    suspendedCodec.decodeCompactBatch = function(_, ...)
        coroutine.yield("decoding")
        return runtimeCodec:decodeCompactBatch(...)
    end
    local retiredCalls = 0
    local decodingPeer = Transport.Peer.new({
        epoch = 16,
        routes = {
            {
                id = 1,
                lane = "reliable",
                allowBatch = true,
                allowCompactBatch = true,
                schemaFingerprint = runtimeCodec.fingerprint,
            },
        },
        sendReliable = function() end,
    })
    decodingPeer:onBatchValues(1, suspendedCodec, function()
        retiredCalls += 1
    end)
    local decodingFrame = assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 16,
        sequence = 1,
        batch = true,
        compactBatch = true,
        payload = assert(runtimeCodec:encodeCompactBatch({ 1 })),
    }))
    local decodingThread = coroutine.create(function()
        return decodingPeer:receive(decodingFrame)
    end)
    local started, decodingMarker = coroutine.resume(decodingThread)
    assert(started and decodingMarker == "decoding", "decoder must suspend inside receive")
    decodingPeer:destroy()
    local finished, accepted, retiredReason = coroutine.resume(decodingThread)
    assert(
        finished and not accepted and retiredReason == "destroyed" and retiredCalls == 0,
        "retired decoder completion must not dispatch application callbacks"
    )
end
