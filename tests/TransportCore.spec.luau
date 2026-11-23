local Transport = require("../src/Transport")

local function bytes(text)
    local value = buffer.create(#text)
    buffer.writestring(value, 0, text)
    return value
end

local function testOutboundPayloadLimit()
    local packedSize = 4
    local adapter = {
        identity = "fixture",
        version = 1,
        compress = function(data)
            local packed = buffer.create(packedSize)
            buffer.writeu8(packed, 0, buffer.len(data))
            return packed
        end,
        decompressedSize = function(data)
            return buffer.readu8(data, 0)
        end,
        decompress = function(data)
            return buffer.create(buffer.readu8(data, 0))
        end,
    }
    local routes = {
        {
            id = 1,
            lane = "reliable",
            maximumFrameBytes = 64,
            maximumPayloadBytes = 4,
            maximumExpandedBytes = 32,
            allowOutboundCompression = true,
            compressionCodec = adapter.identity,
            compressionVersion = adapter.version,
            compressionPolicy = {
                minimumBytes = 8,
                minimumSavingsBytes = 0,
                minimumSavingsRatio = 0,
                metadataBytes = 0,
            },
        },
    }
    local receiver = Transport.Peer.new({
        epoch = 1,
        routes = routes,
        compressor = adapter,
        sendReliable = function() end,
    })
    local delivered = {}
    receiver:on(1, function(payload)
        table.insert(delivered, buffer.len(payload))
    end)
    local wire = {}
    local sender = Transport.Peer.new({
        epoch = 1,
        routes = routes,
        compressor = adapter,
        permitOutboundCompression = true,
        sendReliable = function(frame)
            table.insert(wire, assert(Transport.Frame.inspect(frame)).sequence)
            assert(receiver:receive(frame, "reliable"))
        end,
    })
    local function expectRefused(size)
        local sent, reason = sender:send(1, buffer.create(size))
        assert(not sent and reason == "payload_too_large", "over-limit payload reached the carrier")
    end
    assert(sender:send(1, buffer.create(4)))
    expectRefused(5)
    packedSize = 5
    expectRefused(16)
    packedSize = 4
    assert(sender:send(1, buffer.create(16)))
    assert(
        table.concat(wire, ",") == "1,2" and table.concat(delivered, ",") == "4,16",
        "accepted payloads must arrive intact with consecutive wire sequences"
    )
    sender:destroy()
    receiver:destroy()
end

local function testBatchCountFitsHeader()
    local empty = buffer.create(0)
    local items = table.create(65535, empty)
    local limits = { maximumItems = 65536 }
    local encoded = assert(Transport.Frame.encodeBatch(items, limits))
    assert(
        buffer.readu16(encoded, 0) == 65535,
        "the 16-bit header must preserve its largest representable batch count"
    )
    items[65536] = empty
    local rejected, reason = Transport.Frame.encodeBatch(items, limits)
    assert(not rejected and reason == "batch_item_count", "batch count must fit the 16-bit header")
end

return function()
    testOutboundPayloadLimit()
    testBatchCountFitsHeader()
    local Frame = Transport.Frame
    local Peer = Transport.Peer
    local Manifest = Transport.Manifest
    local Codec = Transport.Codec
    local Config = Transport.Config

    local frame = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 3,
            sequence = 1,
            payload = bytes("abc"),
        }),
        "reliable frame must encode"
    )
    local meta = assert(Frame.inspect(frame), "encoded frame must inspect")
    assert(meta.payloadLength == 3 and meta.epoch == 3, "frame metadata must match")

    assert(Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 3,
        sequence = 1,
        requestId = 7,
        payload = bytes("invalid"),
    }) == nil, "non-request lanes must reject request IDs")
    assert(Frame.encode({
        lane = "request",
        route = 2,
        epoch = 3,
        sequence = 1,
        payload = bytes("invalid"),
    }) == nil, "request lanes must require request IDs")
    assert(Frame.encode({
        lane = "cancel",
        route = 2,
        epoch = 3,
        sequence = 1,
        requestId = 7,
        payload = bytes("invalid"),
    }) == nil, "cancel frames must have an empty payload")

    local trailing = buffer.create(buffer.len(frame) + 1)
    buffer.copy(trailing, 0, frame)
    assert(Frame.inspect(trailing) == nil, "trailing bytes must invalidate frame")
    assert(
        Frame.encodeBatch({ [1] = bytes("a"), [3] = bytes("c") }) == nil,
        "sparse batches must reject instead of silently truncating"
    )
    assert(
        Frame.encodeBatch({ bytes("a"), named = bytes("b") }) == nil,
        "map fields must not be smuggled through a batch"
    )
    local largeBatchConfig = assert(Config.routes({
        {
            id = 6,
            lane = "reliable",
            allowBatch = true,
            maximumBatchItems = 1024,
            maximumBatchItemBytes = 8,
            maximumFrameBytes = 4096,
            maximumPayloadBytes = 4064,
        },
    }))
    assert(largeBatchConfig[1].maximumBatchItems == 1024, "explicit 1024 item cap must validate")
    assert(
        Config.routes({ { id = 6, lane = "reliable", allowCompactBatch = true } }) == nil,
        "compact capability requires batch"
    )
    local plainManifest =
        assert(Manifest.build({ { id = 6, lane = "reliable", allowBatch = true } }))
    local compactManifest = assert(Manifest.build({
        { id = 6, lane = "reliable", allowBatch = true, allowCompactBatch = true },
    }))
    assert(
        plainManifest.version == 3 and plainManifest.fingerprint ~= compactManifest.fingerprint,
        "compact capability changes handshake identity"
    )
    assert(Config.routes({
        {
            id = 6,
            lane = "reliable",
            allowBatch = true,
            maximumBatchItems = 1025,
            maximumBatchItemBytes = 8,
            maximumFrameBytes = 4096,
            maximumPayloadBytes = 4064,
        },
    }) == nil, "batch item caps must remain bounded")

    local routes = {
        { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        { id = 2, lane = "request", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
    }
    local first = assert(Manifest.build(routes), "first manifest must build")
    local second = assert(Manifest.build(routes), "second manifest must build")
    assert(first.fingerprint == second.fingerprint, "manifest fingerprint must be deterministic")
    for _, identity in { "schemaFingerprint", "responseFingerprint" } do
        local unbound = { id = 1, lane = "request" }
        local bound = table.clone(unbound)
        bound[identity] = 0
        local absentManifest = assert(Manifest.build({ unbound }))
        local zeroManifest = assert(Manifest.build({ bound }))
        assert(
            absentManifest.fingerprint ~= zeroManifest.fingerprint,
            "absent schema identity and explicit zero must have different handshake identities"
        )
        assert(
            not Manifest.matches(absentManifest, zeroManifest.version, zeroManifest.fingerprint),
            "schema enforcement policy mismatch must refuse handshake"
        )
    end
    assert(Manifest.build({
        {
            id = 7,
            lane = "reliable",
            allowOutboundCompression = true,
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
            maximumExpandedBytes = 512,
        },
    }) == nil, "compression routes must name their exact codec identity and version")
    local compressedA = assert(Manifest.build({
        {
            id = 7,
            lane = "reliable",
            allowOutboundCompression = true,
            compressionCodec = "zstd",
            compressionVersion = 1,
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
            maximumExpandedBytes = 512,
        },
    }))
    local compressedB = assert(Manifest.build({
        {
            id = 7,
            lane = "reliable",
            allowOutboundCompression = true,
            compressionCodec = "zstd",
            compressionVersion = 2,
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
            maximumExpandedBytes = 512,
        },
    }))
    assert(
        compressedA.fingerprint ~= compressedB.fingerprint,
        "compressor version must be part of compatibility"
    )

    local clientToServer = {}
    local serverToClient = {}
    local client = Peer.new({
        epoch = 9,
        routes = routes,
        sendReliable = function(value)
            table.insert(clientToServer, value)
        end,
    })
    local server = Peer.new({
        epoch = 9,
        routes = routes,
        sendReliable = function(value)
            table.insert(serverToClient, value)
        end,
    })

    local observed = nil
    server:on(1, function(value)
        observed = buffer.readstring(value, 0, buffer.len(value))
    end)
    assert(client:send(1, bytes("ping")), "client must send reliable payload")
    assert(server:receive(table.remove(clientToServer, 1)), "server must receive reliable payload")
    assert(observed == "ping", "reliable handler must observe payload")

    local batchWire = {}
    local batchRoute = {
        {
            id = 5,
            lane = "reliable",
            allowBatch = true,
            allowCompactBatch = true,
            maximumBatchItems = 8,
            maximumBatchItemBytes = 8,
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
            maximumExpandedBytes = 128,
        },
    }
    local batchSender = Peer.new({
        epoch = 71,
        routes = batchRoute,
        sendReliable = function(value)
            table.insert(batchWire, value)
        end,
    })
    local batchReceiver = Peer.new({
        epoch = 71,
        routes = batchRoute,
        sendReliable = function() end,
    })
    local smallInteger = assert(Codec.compile({ type = "integer", min = 0, max = 255 }))
    local receivedBatch = nil
    batchReceiver:on(5, function(_, context)
        receivedBatch = context.slices
    end)
    assert(
        batchSender:sendBatchValues(5, smallInteger, { 3, 9, 27 }),
        "peer must send values directly through the codec-aware batch path"
    )
    assert(batchReceiver:receive(table.remove(batchWire, 1)), "codec batch frame must be received")
    assert(receivedBatch and #receivedBatch == 3, "codec batch must preserve standard slices")
    for i, expected in ipairs({ 3, 9, 27 }) do
        local itemOk, itemValue = smallInteger:decode(receivedBatch[i])
        assert(itemOk and itemValue == expected, "codec batch payload must decode identically")
    end

    local decodedBatch = nil
    local disconnectBatch = batchReceiver:onBatchValues(5, smallInteger, function(values, context)
        assert(context.batch == true and context.slices == nil, "decoded batch skips item copies")
        decodedBatch = values
    end)
    assert(batchSender:sendBatchValues(5, smallInteger, { 5, 10 }), "decoded batch must send")
    assert(batchReceiver:receive(table.remove(batchWire, 1)), "decoded batch must receive")
    assert(decodedBatch and decodedBatch[1] == 5 and decodedBatch[2] == 10, "decoded values arrive")
    assert(
        batchSender:sendCompactBatchValues(5, smallInteger, { 11, 12 }),
        "compact decoded batch must send"
    )
    local compactWire = table.remove(batchWire, 1)
    local compactMeta = assert(Frame.inspect(compactWire))
    assert(
        compactMeta.batch and compactMeta.compactBatch,
        "compact batch has a distinct frame flag"
    )
    assert(batchReceiver:receive(compactWire), "compact decoded batch must receive")
    assert(
        decodedBatch and decodedBatch[1] == 11 and decodedBatch[2] == 12,
        "compact values arrive"
    )
    disconnectBatch()
    local compactWithoutListener = assert(Frame.encode({
        lane = "reliable",
        route = 5,
        epoch = 71,
        sequence = 4,
        payload = assert(smallInteger:encodeCompactBatch({ 13 })),
        batch = true,
        compactBatch = true,
    }))
    local noListenerOk, noListenerReason = batchReceiver:receive(compactWithoutListener)
    assert(
        not noListenerOk and noListenerReason == "compact_batch_listener_required",
        "compact batches require a decoder"
    )
    assert(Frame.encode({
        lane = "reliable",
        route = 5,
        epoch = 71,
        sequence = 1,
        payload = bytes("x"),
        compactBatch = true,
    }) == nil, "compact flag requires batch")
    local malformedBatch = assert(smallInteger:encodeBatch({ 1, 2 }))
    buffer.writeu32(malformedBatch, 2, 9)
    local valid, _, batchError = smallInteger:decodeBatch(malformedBatch)
    assert(not valid and batchError == "invalid_batch_item", "malformed length must reject")
    local decodedCalls = 0
    batchReceiver:onBatchValues(5, smallInteger, function()
        decodedCalls += 1
    end)
    local badFrame = assert(Frame.encode({
        lane = "reliable",
        route = 5,
        epoch = 71,
        sequence = 5,
        payload = malformedBatch,
        batch = true,
    }))
    assert(not batchReceiver:receive(badFrame), "malformed batch frame must reject")
    assert(decodedCalls == 0, "malformed batch cannot reach a decoded listener")
    local nextPayload = assert(smallInteger:encodeBatch({ 7 }))
    local recoveryFrame = assert(Frame.encode({
        lane = "reliable",
        route = 5,
        epoch = 71,
        sequence = 6,
        payload = nextPayload,
        batch = true,
    }))
    assert(batchReceiver:receive(recoveryFrame), "valid batch follows a rejected frame")
    assert(decodedCalls == 1, "valid batch reaches decoded listener once")
    batchSender:destroy()
    batchReceiver:destroy()
    assert(next(batchReceiver.batchListeners) == nil, "destroy releases decoded batch listener")

    local boundedReceive = Peer.new({
        epoch = 44,
        routes = {
            { id = 1, lane = "reliable", maximumFrameBytes = 128, maximumPayloadBytes = 16 },
        },
        maximumReceiveFramesPerStep = 3,
        ingressPackets = { capacity = 32, refillPerSecond = 0 },
        sendReliable = function() end,
    })
    local boundedObserved = 0
    boundedReceive:on(1, function()
        boundedObserved += 1
        if boundedObserved < 8 then
            local nextFrame = assert(Frame.encode({
                lane = "reliable",
                route = 1,
                epoch = 44,
                sequence = boundedObserved + 1,
                payload = bytes("x"),
            }))
            assert(boundedReceive:receive(nextFrame), "next ordered frame must be retained")
        end
    end)
    local chainStart = assert(Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 44,
        sequence = 1,
        payload = bytes("x"),
    }))
    assert(boundedReceive:receive(chainStart), "first chained frame must be accepted")
    assert(boundedObserved == 3, "one receive callback must obey the configured work budget")
    assert(boundedReceive:status().queuedFrames == 1, "excess work must remain bounded and queued")
    boundedReceive:step()
    assert(boundedObserved == 6, "step must process the next bounded slice in order")
    boundedReceive:step()
    assert(boundedObserved == 8, "later steps must finish queued work without dropping it")
    boundedReceive:destroy()

    server:on(2, function(value, context)
        assert(server:respond(2, context.requestId, value), "server must respond to request")
    end)
    local response = nil
    assert(
        client:request(2, bytes("rpc"), 1, function(ok, value)
            if ok then
                response = buffer.readstring(value, 0, buffer.len(value))
            end
        end),
        "client request must open"
    )
    assert(server:receive(table.remove(clientToServer, 1)), "server must receive request")
    assert(client:receive(table.remove(serverToClient, 1)), "client must receive response")
    assert(response == "rpc", "request payload must round-trip")

    local good = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 9,
            sequence = 2,
            payload = bytes("x"),
        }),
        "post-malformation frame must encode"
    )
    local malformed = buffer.create(buffer.len(good) + 1)
    buffer.copy(malformed, 0, good)
    assert(not server:receive(malformed), "malformed frames reject")
    assert(server:receive(good), "malformed frames must not burn reliable sequence")

    local forgedRequest = assert(
        Frame.encode({
            lane = "request",
            route = 2,
            epoch = 9,
            sequence = 4,
            requestId = 77,
            payload = bytes("forged"),
        }),
        "request fixture must encode"
    )
    buffer.writeu8(forgedRequest, 3, 1)
    assert(Frame.inspect(forgedRequest) == nil, "lane/request-ID mismatch must reject")

    local policyRoutes = {
        {
            id = 1,
            lane = "reliable",
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
            maximumExpandedBytes = 128,
        },
        {
            id = 2,
            lane = "request",
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
        },
        { id = 3, lane = "unreliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        { id = 4, lane = "unreliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
    }
    local policyAdmissionCalls = 0
    local policyPeer = Peer.new({
        epoch = 12,
        routes = policyRoutes,
        sendReliable = function() end,
        admit = function()
            policyAdmissionCalls += 1
            return true, nil
        end,
    })
    local compressed = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 12,
            sequence = 1,
            payload = bytes("z"),
            compressed = true,
            expandedSize = 2,
        }),
        "compressed fixture must encode"
    )
    local compressedOk, compressedReason = policyPeer:receive(compressed)
    assert(
        not compressedOk and compressedReason == "compression_forbidden",
        "routes that did not opt into compression must reject compressed input"
    )
    assert(
        policyAdmissionCalls == 1,
        "forbidden compression flags must still consume application admission"
    )

    local postPolicyObserved = false
    policyPeer:on(1, function()
        postPolicyObserved = true
    end)
    local afterCompressed = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 12,
            sequence = 2,
            payload = bytes("after"),
        }),
        "post-policy fixture must encode"
    )
    assert(
        policyPeer:receive(afterCompressed) and postPolicyObserved,
        "policy rejection must consume its wire cursor without wedging later traffic"
    )

    local cancelledRequestId = nil
    policyPeer:onCancel(2, function(requestId)
        cancelledRequestId = requestId
    end)
    local unknownCancel = assert(
        Frame.encode({
            lane = "cancel",
            route = 2,
            epoch = 12,
            sequence = 1,
            requestId = 999,
            payload = buffer.create(0),
        }),
        "unknown cancel fixture must encode"
    )
    local cancelOk, cancelError = policyPeer:receive(unknownCancel)
    assert(
        cancelOk and cancelError == nil and cancelledRequestId == 999,
        "incoming cancellation must be direction-scoped and handled independently"
    )
    local requestObserved = false
    policyPeer:on(2, function()
        requestObserved = true
    end)
    local validRequest = assert(
        Frame.encode({
            lane = "request",
            route = 2,
            epoch = 12,
            sequence = 2,
            requestId = 1,
            payload = bytes("valid"),
        }),
        "valid request fixture must encode"
    )
    assert(
        policyPeer:receive(validRequest) and requestObserved,
        "cancellation must consume its sequence without redispatching the request listener"
    )

    assert(Transport.Config.routes({
        {
            id = 1,
            lane = "unreliable",
            maximumFrameBytes = 1001,
            maximumPayloadBytes = 900,
        },
    }) == nil, "unreliable routes must reject frames above Roblox's physical ceiling")

    local unreliableObserved = {}
    policyPeer:on(3, function()
        table.insert(unreliableObserved, 3)
    end)
    policyPeer:on(4, function()
        table.insert(unreliableObserved, 4)
    end)
    local laterRouteThree = assert(
        Frame.encode({
            lane = "unreliable",
            route = 3,
            epoch = 12,
            sequence = 2,
            payload = bytes("later"),
        }),
        "later unreliable fixture must encode"
    )
    local earlierRouteFour = assert(
        Frame.encode({
            lane = "unreliable",
            route = 4,
            epoch = 12,
            sequence = 1,
            payload = bytes("earlier"),
        }),
        "earlier unreliable fixture must encode"
    )
    assert(policyPeer:receive(laterRouteThree), "newer route-three state must be accepted")
    assert(
        policyPeer:receive(earlierRouteFour),
        "reordering on one unreliable route must not starve another route"
    )
    assert(
        #unreliableObserved == 2,
        "independent unreliable routes must both deliver their newest state"
    )

    local admissionAttempts = 0
    local admittedObserved = false
    local admissionPeer = Peer.new({
        epoch = 15,
        routes = {
            { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        },
        sendReliable = function() end,
        admit = function()
            admissionAttempts += 1
            return admissionAttempts > 1, "peer_packets"
        end,
    })
    admissionPeer:on(1, function()
        admittedObserved = true
    end)
    local deniedFrame = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 15,
            sequence = 1,
            payload = bytes("denied"),
        }),
        "denied frame must encode"
    )
    local recoveredFrame = assert(
        Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 15,
            sequence = 2,
            payload = bytes("recovered"),
        }),
        "recovery frame must encode"
    )
    local deniedOk, deniedReason = admissionPeer:receive(deniedFrame)
    assert(
        not deniedOk and deniedReason == "peer_packets",
        "admission must reject the limited frame"
    )
    assert(
        admissionPeer:receive(recoveredFrame) and admittedObserved,
        "a transient admission drop must not permanently desynchronize the route"
    )

    local ingressPeer = Peer.new({
        epoch = 16,
        routes = {
            { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        },
        ingressPackets = { capacity = 1, refillPerSecond = 0 },
        sendReliable = function() end,
    })
    assert(
        not ingressPeer:receive("not-a-buffer"),
        "non-buffer malformed ingress must still spend a token"
    )
    local limitedIngress, limitedReason = ingressPeer:receive(deniedFrame, "reliable")
    assert(
        not limitedIngress and limitedReason == "ingress_packets" and ingressPeer:status().destroyed,
        "pre-inspection exhaustion must fail closed instead of leaving a reliable cursor ambiguous"
    )

    local U32 = 4294967295
    local wrapRoutes = {
        { id = 41, lane = "reliable", maximumFrameBytes = 64, maximumPayloadBytes = 16 },
    }
    local wrapReceiver = Peer.new({
        epoch = 41,
        routes = wrapRoutes,
        sendReliable = function() end,
    })
    wrapReceiver:on(41, function() end)
    local function wrapFrame(sequence)
        return assert(Frame.encode({
            lane = "reliable",
            route = 41,
            epoch = 41,
            sequence = sequence,
            payload = bytes("w"),
        }))
    end
    -- Seed the cursor to test rollover without sending four billion frames.
    assert(wrapReceiver:receive(wrapFrame(1), "reliable"), "fresh cursor must start at one")
    wrapReceiver.recvRoutes[41] = U32 - 1
    assert(wrapReceiver:receive(wrapFrame(U32), "reliable"), "final sequence must accept")
    assert(wrapReceiver:receive(wrapFrame(1), "reliable"), "sequence must wrap to one, not exhaust")
    local replayOk, replayReason = wrapReceiver:receive(wrapFrame(U32), "reliable")
    assert(
        not replayOk and replayReason == "replay",
        "a pre-wrap sequence must stay a replay after rollover"
    )

    local staleEpoch = assert(Frame.encode({
        lane = "reliable",
        route = 41,
        epoch = 40,
        sequence = 2,
        payload = bytes("s"),
    }))
    local epochOk, epochReason = wrapReceiver:receive(staleEpoch, "reliable")
    assert(not epochOk and epochReason == "epoch_mismatch", "epoch mismatch must name the epoch")

    local gateManifest = assert(Manifest.build(wrapRoutes))
    assert(
        Manifest.matches(gateManifest, gateManifest.version, gateManifest.fingerprint),
        "a matching advertisement must be accepted"
    )
    assert(
        not Manifest.matches(gateManifest, gateManifest.version + 1, gateManifest.fingerprint),
        "a mismatched version must be refused"
    )
    assert(
        not Manifest.matches(gateManifest, gateManifest.version, gateManifest.fingerprint + 1),
        "a mismatched fingerprint must be refused"
    )
    assert(
        not Manifest.matches(gateManifest, 0 / 0, gateManifest.fingerprint),
        "a malformed version must be refused"
    )

    wrapReceiver:destroy()

    client:destroy()
    server:destroy()
    policyPeer:destroy()
    admissionPeer:destroy()
    ingressPeer:destroy()
end
