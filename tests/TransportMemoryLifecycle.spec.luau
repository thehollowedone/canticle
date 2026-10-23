local Transport = require("../src/Transport")

local function frame(sequence)
    return assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 41,
        sequence = sequence,
        payload = buffer.create(65536),
    }))
end

local function peer()
    return Transport.Peer.new({
        epoch = 41,
        maximumReceiveFramesPerStep = 1,
        routes = {
            {
                id = 1,
                lane = "reliable",
                maximumFrameBytes = 70000,
                maximumPayloadBytes = 65536,
            },
        },
        sendReliable = function() end,
    })
end

return function()
    local live = 0
    local cleanedCallers = 0
    -- Hold the coroutine handles deliberately: closing must release their stacks,
    -- rather than relying on the event scheduler eventually dropping its waiters.
    local _threads = {}

    for index = 1, 200 do
        local value = peer()
        local worker
        value:on(1, function(payload)
            worker = coroutine.running()
            assert(buffer.len(payload) == 65536, "listener must receive the full retained payload")
            coroutine.yield("waiting")
            error("a retired listener resumed")
        end)
        local thread = coroutine.create(function()
            local ok, reason = value:receive(frame(1))
            assert(
                not ok and (reason == "destroyed" or reason == "remote_closed"),
                "retired receive must return a terminal reason"
            )
            cleanedCallers += 1
        end)
        assert(coroutine.resume(thread))
        assert(coroutine.status(thread) == "suspended", "yielding listener must suspend its caller")
        assert(value:receive(frame(2)))
        assert(
            value:status().queuedFrames == 1,
            "second frame must remain queued while the listener yields"
        )
        if index % 2 == 0 then
            value:_terminate("remote_closed")
        else
            value:destroy()
        end
        assert(
            value:status().queuedFrames == 0 and value:status().queuedBytes == 0,
            "retirement must release queued frames and bytes"
        )
        assert(next(value.listeners) == nil, "retirement must release listener registrations")
        table.insert(_threads, worker)
        assert(coroutine.status(worker) == "dead", "owned worker must close on retirement")
        if coroutine.status(thread) ~= "dead" then
            live += 1
        end
    end
    assert(cleanedCallers == 200, "terminal teardown must resume every caller for its cleanup")
    assert(live == 0, `retired receives retained {live} suspended callback stacks`)

    -- The same ownership is needed when heartbeat stepping drains a queued frame.
    local queued = peer()
    assert(queued:receive(frame(1)))
    queued:on(1, function()
        coroutine.yield("queued")
    end)
    assert(queued:receive(frame(2)))
    local step = coroutine.create(function()
        queued:step()
    end)
    assert(coroutine.resume(step))
    assert(
        coroutine.status(step) == "suspended",
        "yielding queue listener must suspend the step caller"
    )
    queued:destroy()
    assert(coroutine.status(step) == "dead", "destroy must cancel a yielding queue drainer")

    -- Self-termination cannot close the running coroutine. The next lifecycle
    -- turn reaps it (Roblox also schedules a deferred reap automatically).
    local selfClosing = peer()
    selfClosing:on(1, function()
        selfClosing:destroy()
        coroutine.yield("self terminated")
    end)
    local selfThread = coroutine.create(function()
        selfClosing:receive(frame(1))
    end)
    assert(coroutine.resume(selfThread))
    selfClosing:step()
    assert(
        coroutine.status(selfThread) == "dead",
        "next lifecycle turn must reap a self-terminated caller"
    )

    -- Cancelling the caller does not strand its worker on an engine wait.
    local abandoned = peer()
    local abandonedWorker
    abandoned:on(1, function()
        abandonedWorker = coroutine.running()
        coroutine.yield("abandoned")
    end)
    local abandonedCaller = coroutine.create(function()
        abandoned:receive(frame(1))
    end)
    assert(coroutine.resume(abandonedCaller))
    coroutine.close(abandonedCaller)
    abandoned:step()
    assert(
        abandoned:status().destroyed and coroutine.status(abandonedWorker) == "dead",
        "abandoned receive must retire the peer and close its worker"
    )

    -- Engine waits resume the owned worker directly, not the suspended caller.
    local scheduled = peer()
    local scheduledWorker
    local scheduledReturned = false
    scheduled:on(1, function()
        scheduledWorker = coroutine.running()
        coroutine.yield("engine wait")
    end)
    local scheduledCaller = coroutine.create(function()
        assert(scheduled:receive(frame(1)))
        scheduledReturned = true
    end)
    assert(coroutine.resume(scheduledCaller))
    assert(coroutine.resume(scheduledWorker))
    assert(
        scheduledReturned and coroutine.status(scheduledCaller) == "dead",
        "resumed worker must finish its suspended receive caller"
    )
    scheduled:destroy()

    -- A caller that completes receive then yields for unrelated work is not owned.
    local returned = peer()
    returned:on(1, function()
        returned:destroy()
    end)
    local caller = coroutine.create(function()
        returned:receive(frame(1))
        coroutine.yield("unrelated")
    end)
    assert(coroutine.resume(caller))
    returned:step()
    assert(
        coroutine.status(caller) == "suspended",
        "completed receive must not own unrelated caller work"
    )
    coroutine.close(caller)
end
