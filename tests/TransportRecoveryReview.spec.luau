local T = require("../src/Transport")
local hierarchical = false
return function()
    local routes = {
        { id = 1, lane = "reliable", maximumFrameBytes = 128, maximumPayloadBytes = 64 },
        { id = 2, lane = "unreliable", maximumFrameBytes = 128, maximumPayloadBytes = 64 },
        { id = 3, lane = "request", maximumFrameBytes = 128, maximumPayloadBytes = 64 },
    }
    local function frame(epoch, n, lane, route)
        return assert(T.Frame.encode({
            epoch = epoch,
            sequence = n,
            lane = lane or "reliable",
            route = route or 1,
            payload = buffer.create(1),
        }))
    end
    local function signal()
        local hs = {}
        local s = {}
        function s:Connect(fn)
            hs[fn] = true
            return {
                Disconnect = function()
                    hs[fn] = nil
                end,
            }
        end
        function s:Fire(...)
            for fn in table.clone(hs) do
                fn(...)
            end
        end
        function s:Count()
            local n = 0
            for _ in hs do
                n += 1
            end
            return n
        end
        return s
    end
    local function fixture(optionsFor, settings)
        local p = {}
        local r = { OnServerEvent = signal(), OnClientEvent = signal() }
        local h = { OnServerEvent = signal(), OnClientEvent = signal() }
        local heartbeat = signal()
        function r:FireServer(f)
            self.OnServerEvent:Fire(p, f)
        end
        function r:FireClient(_, f)
            self.OnClientEvent:Fire(f)
        end
        function h:FireServer(...)
            self.OnServerEvent:Fire(p, ...)
        end
        function h:FireClient(_, ...)
            self.OnClientEvent:Fire(...)
        end
        local manifest = assert(T.Manifest.build(routes))
        settings = settings or {}
        settings.handshakeRemote = h
        settings.manifest = manifest
        settings.stepSignal = heartbeat
        local server = T.Remote.server(r, nil, optionsFor or function()
            return { routes = routes }
        end, settings)
        local function client(challenge, extra)
            local c = extra or {}
            c.routes = routes
            c.handshakeRemote = h
            c.manifest = manifest
            c.handshakeChallenge = challenge
            c.stepSignal = heartbeat
            return T.Remote.client(r, nil, c)
        end
        return server, client, p, r, h, heartbeat, manifest
    end
    -- Malformed configuration must release creation so a corrected attempt can succeed.
    do
        local malformed = true
        local s, _, p, _, h, _, m = fixture(function()
            return { routes = if malformed then 42 else routes }
        end)
        h:FireServer(1, m.version, m.fingerprint)
        assert(pcall(function()
            h:FireServer(1, m.version, m.fingerprint, "ready")
        end))
        assert(s:findPeer(p) == nil)
        malformed = false
        h:FireServer(1, m.version, m.fingerprint, "ready")
        assert(s:findPeer(p))
        s:destroy()
    end
    -- A closed handshake invalidates an in-flight initializer before it can publish.
    if not hierarchical then
        local s, _, p, _, h, _, m = fixture(function()
            coroutine.yield()
            return { routes = routes }
        end)
        h:FireServer(2, m.version, m.fingerprint)
        local co = coroutine.create(function()
            h:FireServer(2, m.version, m.fingerprint, "ready")
        end)
        assert(coroutine.resume(co))
        h:FireServer(2, m.version, m.fingerprint, "closed")
        assert(coroutine.resume(co))
        assert(s:findPeer(p) == nil)
        s:destroy()
    end
    -- A missed terminal notification retries with bounded frequency and closes client once.
    do
        local now = 0
        local s, client, p, r, h, heartbeat, m = fixture(nil, {
            clock = function()
                return now
            end,
        })
        local stopped = 0
        local old = client(101, {
            onTerminate = function()
                stopped += 1
                coroutine.yield()
            end,
        })
        local epoch = old.epoch
        local original = h.FireClient
        local sends = 0
        function h:FireClient(player, ...)
            local phase = select(5, ...)
            if phase == "closed" then
                sends += 1
                if sends == 1 then
                    return
                end
            end
            original(self, player, ...)
        end
        s:findPeer(p):destroy()
        assert(s:findPeer(p) == nil and not old:status().destroyed and sends == 1)
        s:step()
        assert(sends == 1)
        now = 0.5
        s:step()
        assert(
            old:status().destroyed
                and old:status().terminalReason == "remote_closed"
                and stopped == 1
                and sends == 2
        )
        assert(
            h.OnClientEvent:Count() == 0 and r.OnClientEvent:Count() == 0 and heartbeat:Count() == 1
        )
        for i = 1, 20 do
            now = i
            s:step()
        end
        assert(sends == 3)
        h:FireServer(101, m.version, m.fingerprint, "ready")
        assert(s:findPeer(p) == nil and sends == 3)
        local fresh, close = client(102)
        assert(fresh.epoch ~= epoch and fresh:status().sentReliableSequence == 0)
        h.OnClientEvent:Fire(101, epoch, m.version, m.fingerprint, "closed")
        assert(not fresh:status().destroyed)
        r.OnServerEvent:Fire(p, frame(epoch, 1))
        assert(s:findPeer(p):status().receivedReliableSequence == 0)
        close()
        s:destroy()
    end
    -- Terminal retry clock and transport callback must never retain heartbeat execution.
    do
        local yielding = false
        local s, client, p, _, h = fixture(nil, {
            clock = function()
                if yielding then
                    coroutine.yield()
                end
                return 1
            end,
        })
        client(201)
        s:findPeer(p):destroy()
        yielding = true
        local co = coroutine.create(function()
            s:step()
        end)
        assert(coroutine.resume(co))
        assert(coroutine.status(co) == "dead")
        yielding = false
        s:step()
        s:destroy()
    end
    -- Stable peers are serviced while another peer's callback yields; stale steps do not reset work.
    if not hierarchical then
        local s, _, _, r, h, _, m = fixture(function()
            return { routes = routes, maximumReceiveFramesPerStep = 1 }
        end, { maximumReceiveFramesPerStep = 1 })
        local ps = { {}, {}, {} }
        local seen = { 0, 0, 0 }
        local held
        for i, p in ps do
            h.OnServerEvent:Fire(p, i, m.version, m.fingerprint)
            h.OnServerEvent:Fire(p, i, m.version, m.fingerprint, "ready")
            local peer = s:findPeer(p)
            peer:on(1, function()
                seen[i] += 1
                if i == 1 and seen[1] == 2 then
                    held = coroutine.running()
                    coroutine.yield()
                end
            end)
            for n = 1, 3 do
                r.OnServerEvent:Fire(p, frame(peer.epoch, n))
            end
        end
        local co = coroutine.create(function()
            s:step()
        end)
        assert(coroutine.resume(co))
        assert(held == co)
        for _ = 1, 6 do
            local before = seen[1] + seen[2] + seen[3]
            s:step()
            assert(seen[1] + seen[2] + seen[3] - before <= 1)
        end
        assert(seen[2] == 3 and seen[3] == 3)
        local remaining = s:status().receiveRemaining
        assert(coroutine.resume(co))
        assert(s:status().receiveRemaining <= remaining)
        s:step()
        assert(seen[1] == 3)
        s:destroy()
    end
end
