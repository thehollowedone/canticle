return function()
    local Admission = require("../src/TransportAdmission")
    local Config = require("../src/TransportConfig")
    local Frame = require("../src/TransportFrame")
    local Peer = require("../src/TransportPeer")
    local Manifest = require("../src/TransportManifest")
    local routes = {
        {
            id = 1,
            lane = "request",
            maximumFrameBytes = 128,
            maximumPayloadBytes = 64,
            maximumRequestBytes = 8,
        },
        { id = 2, lane = "unreliable", maximumFrameBytes = 128, maximumPayloadBytes = 64 },
    }
    do
        local sent, handled = 0, 0
        local peer = Peer.new({
            epoch = 1,
            routes = routes,
            sendReliable = function()
                sent += 1
            end,
        })
        peer:on(1, function()
            handled += 1
        end)
        local id, reason = peer:request(1, buffer.create(9), 1, function() end)
        assert(
            id == nil and reason == "request_too_large" and sent == 0,
            "oversized request reached the transport"
        )
        assert(
            peer:status().outstandingRequests == 0,
            "rejected request retained an outstanding slot"
        )
        assert(peer:request(1, buffer.create(8), 1, function() end))
        assert(
            peer:respond(1, 1, buffer.create(9)) and sent == 2,
            "responses can exceed the request-only cap"
        )
        for sequence, size in { 9, 8 } do
            local request = assert(Frame.encode({
                epoch = 1,
                route = 1,
                sequence = sequence,
                requestId = sequence,
                lane = "request",
                payload = buffer.create(size),
            }))
            local accepted, why = peer:receive(request, "reliable")
            if size == 9 then
                assert(
                    not accepted and why == "route_bounds" and handled == 0,
                    "receiver dispatched an oversized request"
                )
            else
                assert(
                    accepted and handled == 1,
                    "the next in-order request at the limit must dispatch"
                )
            end
        end
        peer:destroy()
        local route = table.clone(routes[1])
        local tight = assert(Manifest.build({ route }))
        route.maximumRequestBytes = nil
        local default = assert(Manifest.build({ route }))
        assert(
            tight.fingerprint ~= default.fingerprint,
            "peers with different request budgets must detect the mismatch"
        )
        route.maximumRequestBytes = route.maximumPayloadBytes
        assert(
            default.fingerprint == assert(Manifest.build({ route })).fingerprint,
            "stating the default must preserve compatibility"
        )
        route.maximumRequestBytes = route.maximumPayloadBytes + 1
        assert(
            not Manifest.build({ route }),
            "a request cap above the payload limit must be rejected"
        )
    end
    local function frame(sequence, lane, route)
        return assert(Frame.encode({
            epoch = 1,
            sequence = sequence,
            lane = lane or "request",
            route = route or 1,
            requestId = if lane == "unreliable" then nil else sequence,
            payload = buffer.create(1),
        }))
    end

    local peer = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function() end,
        maximumReceiveFramesPerStep = 2,
    })
    local seen = 0
    peer:on(1, function()
        seen += 1
    end)
    for n = 1, 5 do
        assert(peer:receive(frame(n), "reliable"))
    end
    assert(
        seen == 2 and peer:status().queuedFrames == 3,
        "initial receive budget must process two frames and queue three"
    )
    peer:step()
    assert(seen == 4, "first step must process two more queued frames")
    peer:step()
    assert(seen == 5, "second step must process the last queued frame")
    peer:destroy()
    local settled, terminated = 0, 0
    local retiring = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function() end,
        onTerminate = function()
            terminated += 1
        end,
    })
    for _ = 1, 2 do
        assert(retiring:request(1, buffer.create(1), 1, function()
            settled += 1
            coroutine.yield()
        end))
    end
    retiring:destroy()
    retiring:destroy()
    assert(
        settled == 2 and terminated == 1 and retiring:status().outstandingRequests == 0,
        "repeated destroy must settle both requests and terminate exactly once"
    )
    local queue = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function() end,
        maximumReceiveFramesPerStep = 1,
        maximumQueuedFrames = 2,
    })
    queue:on(1, function() end)
    queue:on(2, function() end)
    assert(queue:receive(frame(1, "unreliable", 2), "unreliable"))
    assert(queue:receive(frame(2, "unreliable", 2), "unreliable"))
    assert(
        not queue:receive(frame(3, "unreliable", 2), "unreliable"),
        "excess unreliable frame must be rejected"
    )
    assert(
        queue:receive(frame(1), "reliable") and not queue:status().destroyed,
        "reliable traffic must survive an exhausted unreliable queue"
    )
    queue:step()
    queue:step()
    assert(
        queue:status().receivedReliableSequence == 1,
        "reliable sequence must advance after queued work drains"
    )
    queue:destroy()
    local now = 0
    local gate = Admission.new({
        clock = function()
            return now
        end,
        routeLimits = { [2] = { sharedRoutePackets = { capacity = 1024, refillPerSecond = 660 } } },
    })
    for tick = 1, 900 do
        now = tick / 30
        for p = 1, 20 do
            assert(gate:admit(p, 2, 32, 1, true))
        end
    end
    assert(
        gate:status().accepted == 18000,
        "configured shared route budget must admit all 18000 packets"
    )
    local cfg, reason =
        Config.peer({ epoch = 1, routes = routes, ingressPackets = { capacity = "bad" } })
    assert(
        cfg == nil and reason == "invalid_peer_limits",
        "malformed ingress limits must return invalid_peer_limits"
    )

    local baseline = Admission.new({
        clock = function()
            return now
        end,
    })
    for tick = 1, 900 do
        now = 30 + tick / 30
        for player = 1, 20 do
            baseline:admit(player, 2, 32, 1, true)
        end
    end
    assert(
        (baseline:status().denials.shared_route_packets or 0) > 0,
        "600/s exceeds the unchanged 512/s route default"
    )
    for _, limits in ipairs({
        { capacity = math.huge },
        { capacity = -1 },
        { refillPerSecond = math.huge },
        { refillPerSecond = -1 },
    }) do
        assert(
            not pcall(Admission.new, { routeLimits = { [1] = { sharedRoutePackets = limits } } }),
            "invalid shared route limits must be rejected"
        )
    end

    local reserved = Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function() end,
        ingressPackets = { capacity = 4, refillPerSecond = 0 },
        ingressReliableReserve = 1,
    })
    for n = 1, 3 do
        assert(reserved:receive(frame(n, "unreliable", 2), "unreliable"))
    end
    assert(
        not reserved:receive(frame(4, "unreliable", 2), "unreliable"),
        "unreliable traffic must not consume the reliable ingress reserve"
    )
    assert(
        reserved:receive(frame(1), "reliable") and not reserved:status().destroyed,
        "reserved ingress capacity must admit reliable traffic without retirement"
    )
    reserved:destroy()
end
