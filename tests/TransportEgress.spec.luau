local Transport = require("../src/Transport")

local function bytes(text)
    local value = buffer.create(#text)
    buffer.writestring(value, 0, text)
    return value
end

return function()
    local routes = {
        { id = 1, lane = "unreliable", maximumFrameBytes = 1000, maximumPayloadBytes = 900 },
        {
            id = 2,
            lane = "bulk",
            allowBatch = true,
            maximumFrameBytes = 256,
            maximumPayloadBytes = 128,
        },
    }
    local unscheduled = Transport.Peer.new({
        epoch = 1,
        routes = routes,
        sendReliable = function() end,
        sendUnreliable = function() end,
    })
    local latestOk, latestReason = unscheduled:send(1, bytes("latest"), true)
    assert(
        not latestOk and latestReason == "egress_scheduler_required",
        "latest traffic must not bypass the bounded scheduler contract"
    )
    local bulkOk, bulkReason = unscheduled:sendBatch(2, { bytes("bulk") })
    assert(
        not bulkOk and bulkReason == "egress_scheduler_required",
        "bulk traffic must not bypass the bounded scheduler contract"
    )
    unscheduled:destroy()

    local now = 0
    local emitted = {}
    local peer = Transport.Peer.new({
        epoch = 2,
        routes = routes,
        clock = function()
            return now
        end,
        egress = {
            maximumItems = 2,
            maximumBytes = 256,
            maximumAgeSeconds = 1,
            maximumItemsPerStep = 2,
            maximumBytesPerStep = 256,
        },
        sendReliable = function(frame)
            table.insert(emitted, frame)
        end,
        sendUnreliable = function(frame)
            table.insert(emitted, frame)
        end,
    })
    assert(peer:send(1, bytes("old"), true), "first latest value must queue")
    assert(peer:send(1, bytes("new"), true), "new latest value must replace in place")
    assert(peer:sendBatch(2, { bytes("bulk") }), "bulk value must queue behind latest")
    local overflow, overflowReason = peer:sendBatch(2, { bytes("overflow") })
    assert(not overflow and overflowReason == "egress_capacity", "egress item cap must reject")
    assert(
        peer:status().egressItems == 2 and peer:status().egressBytes <= 256,
        "queued egress must expose bounded retained cardinality and bytes"
    )
    peer:step()
    assert(#emitted == 2, "one step must drain within the configured work budget")
    local first = assert(Transport.Frame.decode(emitted[1]))
    assert(
        first.latest and buffer.readstring(first.payload, 0, buffer.len(first.payload)) == "new",
        "latest state must coalesce and run before bulk"
    )
    assert(assert(Transport.Frame.inspect(emitted[2])).lane == "bulk", "bulk must retain its lane")

    assert(peer:send(1, bytes("after-drain"), true), "latest must queue after a full drain")
    assert(peer:sendBatch(2, { bytes("after-drain-bulk") }), "bulk must queue after a full drain")
    peer:step()
    assert(
        #emitted == 4 and peer:status().egressItems == 0,
        "submit-drain-submit must remain live for both egress kinds"
    )
    peer:destroy()

    local boundedNow = 0
    local bounded = Transport.Egress.new({
        maximumItems = 4,
        maximumBytes = 256,
        maximumAgeSeconds = 1,
        maximumItemsPerStep = 2,
        maximumBytesPerStep = 256,
    }, function()
        return boundedNow
    end, nil, nil)
    for key = 1, 4 do
        assert(bounded:submit("latest", key, bytes("expired"), function() end, false))
    end
    boundedNow = 2
    bounded:step()
    assert(
        bounded:status().items == 2,
        "expiry cleanup must consume the same per-step work budget as emission"
    )
    bounded:step()
    assert(bounded:status().items == 0, "bounded expiry cleanup must make progress")
    bounded:close()

    local expiring = Transport.Peer.new({
        epoch = 3,
        routes = routes,
        clock = function()
            return now
        end,
        egress = {
            maximumItems = 2,
            maximumBytes = 256,
            maximumAgeSeconds = 1,
            maximumItemsPerStep = 2,
            maximumBytesPerStep = 256,
        },
        sendReliable = function() end,
        sendUnreliable = function() end,
    })
    now = 0
    assert(expiring:sendBatch(2, { bytes("durable") }), "bulk expiry fixture must queue")
    now = 2
    expiring:step()
    assert(
        expiring:status().destroyed,
        "expired reliable bulk must fail the peer closed instead of silently disappearing"
    )
end
