local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Frame = require("../src/TransportFrame")
local Config = require("../src/TransportConfig")
local Compression = require("../src/TransportCompression")
local Egress = require("../src/TransportEgress")

return function()
    local deferred, sleeping = {}, {}
    local taskMock = {}
    function taskMock.defer(callback)
        table.insert(deferred, callback)
    end
    function taskMock.cancel(thread)
        sleeping[thread] = nil
        coroutine.close(thread)
    end
    function taskMock.wait()
        sleeping[coroutine.running()] = true
        return coroutine.yield()
    end

    local function tick()
        local pending = deferred
        deferred = {}
        for _, callback in pending do
            callback()
        end
    end

    local callbacks = luau.load(fs.readFile("src/TransportCallbacks.luau"), {
        environment = { script = {}, task = taskMock },
        injectGlobals = true,
    })()
    local dependencies = {
        TransportConfig = Config,
        TransportFrame = Frame,
        TransportCompression = Compression,
        TransportEgress = Egress,
        TransportCallbacks = callbacks,
    }
    local Peer = luau.load(fs.readFile("src/TransportPeer.luau"), {
        environment = {
            script = {
                Parent = setmetatable({}, {
                    __index = function(_, name)
                        return name
                    end,
                }),
            },
            task = taskMock,
            require = function(name)
                return (
                    assert(dependencies[name], "mock require must resolve a declared dependency")
                )
            end,
        },
        injectGlobals = true,
    })()
    local function fixture()
        local peer = Peer.new({
            epoch = 11,
            routes = { { id = 1, lane = "reliable" } },
            sendReliable = function() end,
        })
        local worker
        peer:on(1, function()
            worker = coroutine.running()
            taskMock.wait()
        end)
        local cleaned, accepted, reason = false, nil, nil
        local caller = coroutine.create(function()
            accepted, reason = peer:receive(assert(Frame.encode({
                lane = "reliable",
                route = 1,
                epoch = 11,
                sequence = 1,
                payload = buffer.create(1),
            })))
            cleaned = true
        end)
        assert(coroutine.resume(caller))
        return peer,
            worker,
            caller,
            function()
                return cleaned, accepted, reason
            end
    end
    for _ = 1, 100 do
        local peer, worker, caller, result = fixture()
        assert(
            sleeping[worker] and worker ~= caller,
            "engine wait must belong to a worker distinct from its caller"
        )
        peer:destroy()
        assert(
            not sleeping[worker] and coroutine.status(worker) == "dead",
            "retirement must cancel and close the sleeping worker"
        )
        assert(not result(), "caller wake belongs to deferred scheduler")
        tick()
        local cleaned, accepted, reason = result()
        assert(
            cleaned and accepted == false and reason == "destroyed",
            "deferred cleanup must return the destroyed reason to the caller"
        )
        assert(
            coroutine.status(caller) == "dead" and #deferred == 0,
            "deferred cleanup must finish the caller and drain pending work"
        )
    end

    local peer, worker, caller, result = fixture()
    sleeping[worker] = nil
    assert(coroutine.resume(worker))
    assert(not result(), "worker completion must defer the caller wake")
    tick()
    local cleaned, accepted = result()
    assert(
        cleaned and accepted and coroutine.status(caller) == "dead",
        "deferred successful receive must complete its caller"
    )
    peer:destroy()

    local abandoned, abandonedWorker, abandonedCaller = fixture()
    taskMock.cancel(abandonedCaller)
    abandoned:step()
    tick()
    assert(
        coroutine.status(abandonedWorker) == "dead" and next(sleeping) == nil,
        "abandoned caller cleanup must close the worker and remove engine waits"
    )
    assert(#deferred == 0, "abandoned caller cleanup must drain deferred work")
end
