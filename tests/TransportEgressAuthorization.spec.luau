local Transport = require("../src/Transport")
local Channel = require("../src/Channel")

local codec = assert(Transport.Codec.compile({ type = "integer", min = 0, max = 100 }))
local routes = {
    { id = 1, lane = "bulk", allowBatch = true, allowCompactBatch = true },
    { id = 2, lane = "unreliable" },
    { id = 3, lane = "reliable" },
}

local function viewer()
    local wire = {}
    local values = {}
    local view = { now = 0, wire = wire, values = values }
    local receiver =
        Transport.Peer.new({ epoch = 1, routes = routes, sendReliable = function() end })
    local function deliver(frame, carrier)
        table.insert(wire, assert(Transport.Frame.inspect(frame)).sequence)
        assert(receiver:receive(frame, carrier))
    end
    local sender = Transport.Peer.new({
        epoch = 1,
        routes = routes,
        egress = { maximumAgeSeconds = 1 },
        clock = function()
            return view.now
        end,
        sendReliable = function(frame)
            deliver(frame, "reliable")
        end,
        sendUnreliable = function(frame)
            deliver(frame, "unreliable")
        end,
    })
    for _, route in routes do
        local incoming = Channel.bind(receiver, route.id, codec)
        incoming:on(function(value)
            table.insert(values, value)
        end)
        if route.allowBatch then
            incoming:onBatch(function(batch)
                for _, value in batch do
                    table.insert(values, value)
                end
            end)
        end
    end
    view.sender = sender
    view.bulk = Channel.bind(sender, 1, codec)
    view.latest = Channel.bind(sender, 2, codec)
    view.reliable = Channel.bind(sender, 3, codec)
    function view:close()
        sender:destroy()
        receiver:destroy()
    end
    return view
end

local function recipientOrdering()
    local retained, revoked = viewer(), viewer()
    local allowed = { [retained] = true, [revoked] = true }
    for _, view in { retained, revoked } do
        local function permitted()
            return allowed[view]
        end
        assert(view.bulk:send(10, false, permitted))
        assert(view.bulk:send(20))
        assert(view.bulk:sendBatch({ 30, 31 }, false, permitted))
        assert(view.bulk:sendBatch({ 40, 41 }, true, permitted))
        assert(view.sender:sendBatch(1, { assert(codec:encode(50)) }, permitted))
        assert(view.bulk:send(60))
        assert(view.bulk:send(70, false, function()
            return permitted() and table.find(view.values, 60) == nil
        end))
        assert(#view.wire == 0, "queued payloads must not reach either carrier at admission")
    end
    allowed[revoked] = false
    revoked.sender:step()
    retained.sender:step()
    assert(
        table.concat(revoked.wire, ",") == "1,2",
        "withheld entries must consume no wire sequence"
    )
    assert(table.concat(revoked.values, ",") == "20,60", "revoked viewer received a private value")
    assert(
        table.concat(retained.wire, ",") == "1,2,3,4,5,6",
        "The authorized viewer must receive six consecutive reliable frames"
    )
    assert(
        table.concat(retained.values, ",") == "10,20,30,31,40,41,50,60",
        "The authorized viewer must receive the permitted values in enqueue order"
    )
    assert(
        not revoked.sender:status().destroyed and revoked.sender:status().egressBytes == 0,
        "Withholding frames must release queued bytes and keep the peer active"
    )
    revoked:close()
    retained:close()
end

local function guardFailures()
    local view = viewer()
    local yielded
    local function deny()
        return false
    end
    assert(
        not view.reliable:send(1, false, deny),
        "A denied immediate reliable send must return failure"
    )
    assert(view.reliable:send(2))
    assert(view.bulk:send(3, false, function()
        error("policy unavailable")
    end))
    assert(view.bulk:send(4, false, function()
        yielded = coroutine.running()
        coroutine.yield()
        return true
    end))
    assert(view.bulk:send(5, false, function()
        return "yes"
    end))
    assert(view.bulk:send(6))
    view.sender:step()
    assert(
        yielded and coroutine.status(yielded) == "dead",
        "yielded permission check must be retired"
    )
    assert(
        table.concat(view.values, ",") == "2,6" and table.concat(view.wire, ",") == "1,1",
        "Only the two public frames may arrive, each starting its route at sequence one"
    )
    assert(
        not view.sender:status().destroyed,
        "A failed permission callback must leave the peer active"
    )
    view:close()
end

local function coalescedPermissions()
    local view = viewer()
    local function allow()
        return true
    end
    local function deny()
        return false
    end
    assert(view.latest:send(1, true, allow))
    assert(view.latest:send(2, true, deny))
    view.sender:step()
    assert(#view.wire == 0, "replacement must not inherit an older permission")
    assert(view.latest:send(3, true, deny))
    assert(view.latest:send(4, true, allow))
    view.sender:step()
    assert(
        #view.wire == 1 and table.concat(view.values, ",") == "4",
        "The allowed replacement must send only its latest value"
    )
    local replaced
    assert(view.latest:send(5, true, function()
        replaced = view.latest:send(6, true, deny)
        return true
    end))
    view.sender:step()
    assert(replaced, "the newer permission must be accepted while the older guard runs")
    assert(#view.wire == 1, "a superseded value must not escape while its replacement is denied")
    assert(view.latest:send(7, true))
    view.sender:step()
    assert(
        table.concat(view.values, ",") == "4,7",
        "withholding a replacement must release the key"
    )
    view:close()
end

local function changedDuringGuard()
    local slow = viewer()
    assert(slow.bulk:send(1, false, function()
        slow.now = 2
        return true
    end))
    slow.sender:step()
    assert(
        #slow.wire == 0 and slow.sender:status().terminalReason == "egress_expired",
        "Bulk data that ages out during authorization must retire the peer before emission"
    )
    slow:close()

    local closing = viewer()
    assert(closing.bulk:send(1, false, function()
        closing.sender:destroy()
        return true
    end))
    assert(closing.bulk:send(2))
    closing.sender:step()
    assert(
        #closing.wire == 0 and closing.sender:status().egressItems == 0,
        "Closing during authorization must discard both frames and clear the queue"
    )
    closing:close()
end

return function()
    recipientOrdering()
    guardFailures()
    coalescedPermissions()
    changedDuringGuard()
end
