local Admission = require("../src/TransportAdmission")
local Metrics = require("../src/TransportMetrics")

return function()
    local function gate(overrides)
        local options = {
            clock = function()
                return 0
            end,
            packets = { capacity = 100, refillPerSecond = 0 },
            rawBytes = { capacity = 1000, refillPerSecond = 0 },
            expandedBytes = { capacity = 1000, refillPerSecond = 0 },
            routeRawBytes = { capacity = 1000, refillPerSecond = 0 },
            routeExpandedBytes = { capacity = 1000, refillPerSecond = 0 },
            sharedRouteRawBytes = { capacity = 1000, refillPerSecond = 0 },
            sharedRouteExpandedBytes = { capacity = 1000, refillPerSecond = 0 },
            sharedRoutePackets = { capacity = 100, refillPerSecond = 0 },
            globalRawBytes = { capacity = 1000, refillPerSecond = 0 },
            globalExpandedBytes = { capacity = 1000, refillPerSecond = 0 },
            globalPackets = { capacity = 100, refillPerSecond = 0 },
        }
        for key, value in pairs(overrides or {}) do
            options[key] = value
        end
        return Admission.new(options)
    end

    local reasons = {
        { "packets", "peer_packets", 1, 1 },
        { "rawBytes", "peer_raw_bytes", 2, 2 },
        { "expandedBytes", "peer_expanded_bytes", 1, 2 },
        { "routeRawBytes", "peer_route_raw_bytes", 2, 2 },
        { "routeExpandedBytes", "peer_route_expanded_bytes", 1, 2 },
        { "sharedRouteRawBytes", "shared_route_raw_bytes", 2, 2 },
        { "sharedRouteExpandedBytes", "shared_route_expanded_bytes", 1, 2 },
        { "sharedRoutePackets", "shared_route_packets", 1, 1 },
        { "globalPackets", "global_packets", 1, 1 },
        { "globalRawBytes", "global_raw_bytes", 2, 2 },
        { "globalExpandedBytes", "global_expanded_bytes", 1, 2 },
    }
    for _, item in ipairs(reasons) do
        local key, expected, raw, expanded = item[1], item[2], item[3], item[4]
        local capacity = if key:find("Packets", 1, true) or key == "packets" then 0.5 else 1
        local g = gate({ [key] = { capacity = capacity, refillPerSecond = 0 } })
        local ok, reason = g:admit("a", 1, raw, expanded)
        assert(not ok and reason == expected, expected)
    end

    local headerBearing = gate()
    assert(
        headerBearing:admit("header", 1, 29, 1),
        "raw frame bytes may exceed the expanded payload because the frame includes a header"
    )
    local fractional, fractionalReason = headerBearing:admit("header", 1, 1.5, 1)
    assert(
        not fractional and fractionalReason == "invalid_admission",
        "fractional bytes must reject"
    )

    local isolated = gate({
        routeRawBytes = { capacity = 5, refillPerSecond = 0 },
        routeExpandedBytes = { capacity = 5, refillPerSecond = 0 },
    })
    assert(isolated:admit("a", 1, 5, 5), "route must admit within capacity")
    assert(not isolated:admit("a", 1, 1, 1), "route must reject exhausted capacity")
    assert(isolated:admit("a", 2, 5, 5), "routes retain independent capacity")
    assert(isolated:admit("b", 1, 5, 5), "peers retain independent route capacity")

    local legacy = Admission.new({
        route = { capacity = 5, refillPerSecond = 0 },
        sharedRoute = { capacity = 10, refillPerSecond = 0 },
    })
    assert(legacy:admit("a", 1, 5, 5), "legacy route aliases remain supported")

    local atomic = gate({
        packets = { capacity = 1, refillPerSecond = 0 },
        globalRawBytes = { capacity = 1, refillPerSecond = 0 },
    })
    local atomicOk, atomicReason = atomic:admit("atomic", 1, 2, 1)
    assert(
        not atomicOk and atomicReason == "global_raw_bytes",
        "a late aggregate denial must report its exact bucket"
    )
    assert(
        atomic:admit("atomic", 1, 1, 1),
        "failed hierarchical admission must not debit earlier buckets"
    )

    local rollbackNow = 100
    local rollback = gate({
        clock = function()
            return rollbackNow
        end,
        packets = { capacity = 1, refillPerSecond = 1 },
    })
    assert(rollback:admit("clock", 1, 1, 1), "initial clock sample must admit")
    rollbackNow = 0
    assert(not rollback:admit("clock", 1, 1, 1), "clock rollback must not mint tokens")
    rollbackNow = 100
    assert(
        not rollback:admit("clock", 1, 1, 1),
        "returning to the prior timestamp must not refill the same interval twice"
    )

    isolated:clearPeer("a")
    assert(isolated:admit("a", 1, 5, 5), "clearPeer releases peer-local budgets")
    isolated:close()
    local ok, reason = isolated:admit("a", 1, 1, 1)
    assert(not ok and reason == "invalid_admission", "closed admission gate must reject")

    local metrics = Metrics.new()
    metrics:packet("request", true, nil, 32, 64, 48)
    metrics:packet("request", false, "limited", 16, 32, 0)
    metrics:compression("win", 1024, 600)
    metrics:batch(4)
    metrics:latency("decode", 0.001)
    metrics:latency("callback", 0.005)
    metrics:request("opened")
    metrics:request("timeout")
    metrics:denial("shared_route_expanded_bytes")
    metrics:compatibilityMismatch()
    metrics:retained(2, 3)
    local snapshot = metrics:snapshot()
    assert(snapshot.packets["request.accepted"] == 1, "accepted request metric must match")
    assert(snapshot.packets["request.rejected"] == 1, "rejected request metric must match")
    assert(snapshot.bytes.raw == 48 and snapshot.bytes.expanded == 96, "byte metrics must match")
    assert(
        snapshot.compression.win == 1 and snapshot.requests.timeout == 1,
        "compression and timeout metrics must match"
    )
    assert(snapshot.denials.shared_route_expanded_bytes == 1, "denial metric must match")
    assert(snapshot.compatibilityMismatches == 1, "compatibility metric must match")
    assert(
        snapshot.retainedQueues == 2 and snapshot.retainedWaiters == 3,
        "retained work metrics must match"
    )
end
