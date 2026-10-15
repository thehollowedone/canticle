return function()
    local Admission = require("../src/TransportAdmission")
    local Config = require("../src/TransportConfig")
    local Frame = require("../src/TransportFrame")
    local Peer = require("../src/TransportPeer")
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
    assert(seen == 2 and peer:status().queuedFrames == 3)
    peer:step()
    assert(seen == 4)
    peer:step()
    assert(seen == 5)
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
    assert(settled == 2 and terminated == 1 and retiring:status().outstandingRequests == 0)
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
    assert(not queue:receive(frame(3, "unreliable", 2), "unreliable"))
    assert(queue:receive(frame(1), "reliable") and not queue:status().destroyed)
    queue:step()
    queue:step()
    assert(queue:status().receivedReliableSequence == 1)
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
    assert(gate:status().accepted == 18000)
    local cfg, reason =
        Config.peer({ epoch = 1, routes = routes, ingressPackets = { capacity = "bad" } })
    assert(cfg == nil and reason == "invalid_peer_limits")

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
            not pcall(Admission.new, { routeLimits = { [1] = { sharedRoutePackets = limits } } })
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
    assert(not reserved:receive(frame(4, "unreliable", 2), "unreliable"))
    assert(reserved:receive(frame(1), "reliable") and not reserved:status().destroyed)
    reserved:destroy()
end
