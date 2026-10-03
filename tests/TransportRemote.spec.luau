local Transport = require("../src/Transport")

local function signal()
    local handlers = {}
    local value = {}
    function value:Connect(handler)
        table.insert(handlers, handler)
        local live = true
        return {
            Disconnect = function()
                if not live then
                    return
                end
                live = false
                local index = table.find(handlers, handler)
                if index then
                    table.remove(handlers, index)
                end
            end,
        }
    end
    function value:Fire(...)
        local snapshot = table.clone(handlers)
        for _, handler in ipairs(snapshot) do
            handler(...)
        end
    end
    return value
end

local function bytes(text)
    local out = buffer.create(#text)
    buffer.writestring(out, 0, text)
    return out
end

return function()
    local player = { UserId = 77 }
    local reliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function reliable:FireServer(frame)
        self.OnServerEvent:Fire(player, frame)
    end
    function reliable:FireClient(target, frame)
        assert(target == player, "server must target the owning peer")
        self.OnClientEvent:Fire(frame)
    end
    local unreliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function unreliable:FireServer(frame)
        self.OnServerEvent:Fire(player, frame)
    end
    function unreliable:FireClient(target, frame)
        assert(target == player, "server must target the owning unreliable peer")
        self.OnClientEvent:Fire(frame)
    end
    local handshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function handshake:FireServer(...)
        self.OnServerEvent:Fire(player, ...)
    end
    function handshake:FireClient(target, ...)
        assert(target == player, "handshake must target the owning peer")
        self.OnClientEvent:Fire(...)
    end
    local players = { PlayerRemoving = signal() }
    local heartbeat = signal()
    local now = 0
    local routes = {
        { id = 1, lane = "reliable", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        { id = 2, lane = "request", maximumFrameBytes = 256, maximumPayloadBytes = 128 },
        { id = 3, lane = "unreliable", maximumFrameBytes = 1000, maximumPayloadBytes = 900 },
    }
    local manifest = assert(Transport.Manifest.build(routes), "route manifest must build")
    local serverMetrics = Transport.Metrics.new()
    local observed = {}
    local server = Transport.Remote.server(reliable, unreliable, function()
        return {
            epoch = 91,
            routes = routes,
            clock = function()
                return now
            end,
        }
    end, {
        handshakeRemote = handshake,
        manifest = manifest,
        initialEpoch = 90,
        players = players,
        stepSignal = heartbeat,
        metrics = serverMetrics,
        onPeer = function(_, peer)
            peer:on(1, function(payload)
                table.insert(observed, buffer.readstring(payload, 0, buffer.len(payload)))
            end)
            peer:on(2, function() end)
        end,
    })
    local premature = assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 91,
        sequence = 1,
        payload = bytes("premature"),
    }))
    reliable.OnServerEvent:Fire(player, premature)
    unreliable.OnServerEvent:Fire(player, premature)
    handshake.OnServerEvent:Fire(player)
    handshake.OnServerEvent:Fire(player, 122, manifest.version, manifest.fingerprint + 1)
    assert(
        server:findPeer(player) == nil and #observed == 0,
        "application frames and incompatible handshakes must not create a peer"
    )
    local initialAdapter = server:status().adapter
    assert(
        initialAdapter.pre_ready_frame_rejected == 2
            and initialAdapter.handshake_denied == 1
            and initialAdapter.handshake_mismatch == 1,
        "adapter status must distinguish pre-ready frames, denials, and manifest mismatches"
    )
    local initialMetrics = serverMetrics:snapshot().adapter
    assert(
        initialMetrics.pre_ready_frame_rejected == 2
            and initialMetrics.handshake_denied == 1
            and initialMetrics.handshake_mismatch == 1,
        "transport metrics must receive the same fixed adapter outcomes"
    )
    local clientMetrics = Transport.Metrics.new()
    local client, closeClient = Transport.Remote.client(reliable, unreliable, {
        routes = routes,
        manifest = manifest,
        handshakeRemote = handshake,
        handshakeChallenge = 123,
        metrics = clientMetrics,
        clock = function()
            return now
        end,
        stepSignal = heartbeat,
        bindPeer = function()
            reliable.OnClientEvent:Fire(premature)
        end,
    })
    assert(
        clientMetrics:snapshot().adapter.pre_ready_frame_rejected == 1,
        "the client must reject and count data delivered before final readiness"
    )

    assert(client:send(1, bytes("hello")), "client adapter must send")
    assert(observed[1] == "hello", "server onPeer must bind before first dispatch")
    assert(server:findPeer(player) ~= nil, "server handle must expose the created peer")

    local timedOut = false
    assert(
        client:request(2, bytes("wait"), 1, function(ok, _, reason)
            timedOut = not ok and reason == "timeout"
        end),
        "adapter request must open"
    )
    now = 2
    heartbeat:Fire()
    assert(timedOut, "adapter heartbeat must service request deadlines automatically")

    local wrongCarrier = assert(
        Transport.Frame.encode({
            lane = "reliable",
            route = 1,
            epoch = 91,
            sequence = 2,
            payload = bytes("carrier"),
        }),
        "carrier fixture must encode"
    )
    unreliable.OnServerEvent:Fire(player, wrongCarrier)
    assert(#observed == 1, "unreliable carrier must reject a declared reliable frame")
    reliable.OnServerEvent:Fire(player, wrongCarrier)
    assert(observed[2] == "carrier", "carrier mismatch must not burn the route sequence")

    handshake.OnServerEvent:Fire(player, 124, manifest.version, manifest.fingerprint)
    assert(
        server:status().adapter.session_replaced == 1,
        "a changed challenge must record one generation replacement"
    )

    players.PlayerRemoving:Fire(player)
    assert(server:findPeer(player) == nil, "player departure must destroy and release its peer")
    closeClient()
    server:destroy()
    assert(server:status().state == "CLOSED", "server adapter must complete lifecycle teardown")

    local budgetPlayer = { UserId = 88 }
    local budgetReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function budgetReliable:FireClient() end
    local budgetHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function budgetHandshake:FireClient() end
    local budgetPlayers = { PlayerRemoving = signal() }
    local budgetPayload = bytes("adapter-owned-byte-admission")
    local budgetFirst = assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 501,
        sequence = 1,
        payload = budgetPayload,
    }))
    local budgetSecond = assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 501,
        sequence = 2,
        payload = budgetPayload,
    }))
    local budgetMetrics = Transport.Metrics.new()
    local budgetObserved = 0
    local customAdmissions = 0
    local budgetServer = Transport.Remote.server(budgetReliable, nil, function()
        return {
            routes = routes,
            metrics = budgetMetrics,
            admit = function()
                customAdmissions += 1
                return true
            end,
        }
    end, {
        handshakeRemote = budgetHandshake,
        manifest = manifest,
        initialEpoch = 500,
        players = budgetPlayers,
        stepSignal = false,
        admission = {
            clock = function()
                return 0
            end,
            rawBytes = { capacity = buffer.len(budgetFirst), refillPerSecond = 0 },
        },
        onPeer = function(_, peer)
            peer:on(1, function()
                budgetObserved += 1
            end)
        end,
    })
    budgetHandshake.OnServerEvent:Fire(budgetPlayer, 800, manifest.version, manifest.fingerprint)
    budgetHandshake.OnServerEvent:Fire(
        budgetPlayer,
        800,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    budgetReliable.OnServerEvent:Fire(budgetPlayer, budgetFirst)
    budgetReliable.OnServerEvent:Fire(budgetPlayer, budgetSecond)
    assert(
        budgetObserved == 1
            and customAdmissions == 1
            and budgetMetrics:snapshot().denials.peer_raw_bytes == 1,
        "server adapters must enforce shared byte admission before caller admission and dispatch"
    )
    budgetPlayers.PlayerRemoving:Fire(budgetPlayer)
    local budgetRejoined = assert(Transport.Frame.encode({
        lane = "reliable",
        route = 1,
        epoch = 502,
        sequence = 1,
        payload = budgetPayload,
    }))
    budgetHandshake.OnServerEvent:Fire(budgetPlayer, 801, manifest.version, manifest.fingerprint)
    budgetHandshake.OnServerEvent:Fire(
        budgetPlayer,
        801,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    budgetReliable.OnServerEvent:Fire(budgetPlayer, budgetRejoined)
    assert(
        budgetObserved == 2 and customAdmissions == 2,
        "player removal must release adapter-owned peer admission"
    )
    budgetServer:destroy()

    local failedReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function failedReliable:FireClient() end
    local failedHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function failedHandshake:FireClient() end
    local failureMetrics = Transport.Metrics.new()
    local failedServer = Transport.Remote.server(failedReliable, nil, function()
        return nil
    end, {
        handshakeRemote = failedHandshake,
        manifest = manifest,
        initialEpoch = 300,
        stepSignal = false,
        players = false,
        metrics = failureMetrics,
    })
    failedHandshake.OnServerEvent:Fire(player, 700, manifest.version, manifest.fingerprint)
    failedHandshake.OnServerEvent:Fire(player, 700, manifest.version, manifest.fingerprint, "ready")
    assert(
        failedServer:status().adapter.peer_creation_failed == 1
            and failureMetrics:snapshot().adapter.peer_creation_failed == 1,
        "peer construction failures must remain visible without exposing their error"
    )
    failedServer:destroy()

    local mismatchReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    local mismatchHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function mismatchHandshake:FireServer(challenge, version, fingerprint)
        self.OnClientEvent:Fire(challenge, 401, version, fingerprint + 1, "offer")
    end
    local mismatchMetrics = Transport.Metrics.new()
    local mismatchCreated = pcall(Transport.Remote.client, mismatchReliable, nil, {
        routes = routes,
        manifest = manifest,
        handshakeRemote = mismatchHandshake,
        handshakeChallenge = 900,
        maximumHandshakeAttempts = 1,
        handshakeWait = function() end,
        stepSignal = false,
        metrics = mismatchMetrics,
    })
    local mismatchAdapter = mismatchMetrics:snapshot().adapter
    assert(
        not mismatchCreated
            and mismatchAdapter.handshake_mismatch == 1
            and mismatchAdapter.handshake_denied == 1,
        "client handshake mismatch and terminal denial must be separately observable"
    )

    local creationReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    local creationHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function creationHandshake:FireServer(challenge, version, fingerprint, phase)
        if phase == nil then
            self.OnClientEvent:Fire(challenge, 402, version, fingerprint, "offer")
            self.OnClientEvent:Fire(challenge, 402, version, fingerprint, "offer")
        end
    end
    local creationMetrics = Transport.Metrics.new()
    local clientCreated = pcall(Transport.Remote.client, creationReliable, nil, {
        routes = routes,
        manifest = manifest,
        handshakeRemote = creationHandshake,
        handshakeChallenge = 901,
        maximumHandshakeAttempts = 1,
        maximumOutstandingRequests = 0,
        handshakeWait = function() end,
        stepSignal = false,
        metrics = creationMetrics,
    })
    local creationAdapter = creationMetrics:snapshot().adapter
    assert(
        not clientCreated
            and creationAdapter.peer_creation_failed == 1
            and creationAdapter.handshake_denied == 0,
        "client creation failures must be bounded without misclassifying idempotent offers"
    )
    local boundedMetrics = Transport.Metrics.new()
    boundedMetrics:adapter("unrecognized")
    local boundedAdapter = boundedMetrics:snapshot().adapter
    assert(
        boundedAdapter.other == 1 and boundedAdapter.unrecognized == nil,
        "adapter metrics must collapse unknown labels into one fixed bucket"
    )

    local raceReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function raceReliable:FireClient() end
    local raceHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    function raceHandshake:FireClient() end
    local entered = false
    local raceServer = Transport.Remote.server(raceReliable, nil, function()
        entered = true
        coroutine.yield()
        return { routes = routes }
    end, {
        handshakeRemote = raceHandshake,
        manifest = manifest,
        initialEpoch = 200,
        stepSignal = false,
        players = false,
    })
    raceHandshake.OnServerEvent:Fire(player, 555, manifest.version, manifest.fingerprint)
    local setup = coroutine.create(function()
        raceHandshake.OnServerEvent:Fire(
            player,
            555,
            manifest.version,
            manifest.fingerprint,
            "ready"
        )
    end)
    assert(coroutine.resume(setup) and entered, "peer creation fixture must suspend in optionsFor")
    raceServer:destroy()
    assert(coroutine.resume(setup), "suspended peer creation must resume after teardown")
    assert(
        raceServer:findPeer(player) == nil and raceServer:status().state == "CLOSED",
        "teardown must invalidate a yielding peer creation"
    )

    local generationReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function generationReliable:FireClient() end
    local generationHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    local readyChallenges = {}
    function generationHandshake:FireClient(_, challenge, _, _, _, phase)
        if phase == "ready" then
            table.insert(readyChallenges, challenge)
        end
    end
    local generationPeers = {}
    local generationServer = Transport.Remote.server(generationReliable, nil, function()
        return { routes = routes }
    end, {
        handshakeRemote = generationHandshake,
        manifest = manifest,
        initialEpoch = 300,
        stepSignal = false,
        players = false,
        onPeer = function(_, peer)
            table.insert(generationPeers, peer)
            coroutine.yield()
        end,
    })
    local function beginGeneration(challenge)
        generationHandshake.OnServerEvent:Fire(
            player,
            challenge,
            manifest.version,
            manifest.fingerprint
        )
        local thread = coroutine.create(function()
            generationHandshake.OnServerEvent:Fire(
                player,
                challenge,
                manifest.version,
                manifest.fingerprint,
                "ready"
            )
        end)
        assert(coroutine.resume(thread), "generation binding must suspend successfully")
        return thread
    end
    local retiredBinding = beginGeneration(600)
    local currentBinding = beginGeneration(601)
    assert(#generationPeers == 2, "both generations must reach their own binding callback")
    assert(
        coroutine.resume(retiredBinding),
        "retired binding must finish without erasing ownership"
    )
    assert(
        generationServer:findPeer(player) == generationPeers[2]
            and generationPeers[1]:status().destroyed,
        "retired binding must preserve the replacement peer"
    )
    assert(coroutine.resume(currentBinding), "current binding must retain its creation token")
    assert(
        generationServer:findPeer(player) == generationPeers[2]
            and not generationPeers[2]:status().destroyed
            and #readyChallenges == 1
            and readyChallenges[1] == 601,
        "only the replacement generation must complete readiness"
    )
    assert(
        generationPeers[2]:send(1, bytes("replacement")),
        "replacement generation must remain usable after stale binding completes"
    )
    generationServer:destroy()

    local departureReliable = { OnClientEvent = signal(), OnServerEvent = signal() }
    function departureReliable:FireClient() end
    local departureHandshake = { OnClientEvent = signal(), OnServerEvent = signal() }
    local offers = {}
    local offerEpochs = {}
    function departureHandshake:FireClient(_, challenge, epoch, _, _, phase)
        if phase == "offer" then
            table.insert(offers, challenge)
            offerEpochs[challenge] = epoch
        end
    end
    local departureServer = Transport.Remote.server(departureReliable, nil, function()
        return { routes = routes }
    end, {
        handshakeRemote = departureHandshake,
        manifest = manifest,
        initialEpoch = 400,
        stepSignal = false,
        players = false,
    })
    departureHandshake.OnServerEvent:Fire(player, 700, manifest.version, manifest.fingerprint)
    departureHandshake.OnServerEvent:Fire(
        player,
        700,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    local departingPeer = departureServer:findPeer(player)
    local departureEntered = false
    assert(
        departingPeer:request(2, bytes("pending"), 1, function()
            departureEntered = true
            coroutine.yield()
        end),
        "old generation must have a pending request cleanup callback"
    )
    local replacing = coroutine.create(function()
        departureHandshake.OnServerEvent:Fire(player, 701, manifest.version, manifest.fingerprint)
    end)
    assert(
        coroutine.resume(replacing) and departureEntered,
        "replacement must suspend in old cleanup"
    )
    departureHandshake.OnServerEvent:Fire(player, 702, manifest.version, manifest.fingerprint)
    departureHandshake.OnServerEvent:Fire(
        player,
        702,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    local newestPeer = departureServer:findPeer(player)
    assert(coroutine.resume(replacing), "stale replacement must finish its own cleanup")
    assert(
        #offers == 2 and offers[2] == 702,
        "stale replacement must not emit an offer after a newer generation owns the player"
    )
    assert(
        newestPeer
            and departureServer:findPeer(player) == newestPeer
            and newestPeer:send(1, bytes("still active")),
        "yielding old cleanup must not retire or replace the newest active session"
    )
    assert(
        newestPeer:request(2, bytes("epoch pending"), 1, function()
            coroutine.yield()
        end),
        "epoch fixture must suspend replacement cleanup"
    )
    local epochReplacement = coroutine.create(function()
        departureHandshake.OnServerEvent:Fire(player, 710, manifest.version, manifest.fingerprint)
    end)
    assert(coroutine.resume(epochReplacement), "replacement epoch must reserve before yielding")
    local otherPlayer = { UserId = 78 }
    departureHandshake.OnServerEvent:Fire(otherPlayer, 800, manifest.version, manifest.fingerprint)
    departureHandshake.OnServerEvent:Fire(
        otherPlayer,
        800,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    assert(
        coroutine.resume(epochReplacement),
        "another player's epoch must not alter the reservation"
    )
    departureHandshake.OnServerEvent:Fire(
        player,
        710,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    newestPeer = departureServer:findPeer(player)
    assert(
        newestPeer and offerEpochs[710] == newestPeer.epoch,
        "resumed offers must carry their reserved epoch rather than the global epoch counter"
    )

    assert(
        newestPeer:request(2, bytes("remove pending"), 1, function()
            coroutine.yield()
        end),
        "removal fixture must have a yielding cleanup callback"
    )
    local removing = coroutine.create(function()
        departureServer:removePeer(player)
    end)
    assert(coroutine.resume(removing), "player removal must suspend in cleanup")
    departureHandshake.OnServerEvent:Fire(player, 703, manifest.version, manifest.fingerprint)
    departureHandshake.OnServerEvent:Fire(
        player,
        703,
        manifest.version,
        manifest.fingerprint,
        "ready"
    )
    local rejoinedPeer = departureServer:findPeer(player)
    assert(coroutine.resume(removing), "retired player removal must finish its own cleanup")
    assert(
        rejoinedPeer
            and departureServer:findPeer(player) == rejoinedPeer
            and rejoinedPeer:send(1, bytes("rejoined")),
        "old removal completion must preserve the rejoined player's session"
    )

    assert(
        rejoinedPeer:request(2, bytes("shutdown pending"), 1, function()
            coroutine.yield()
        end),
        "shutdown fixture must have a yielding cleanup callback"
    )
    local shuttingDown = coroutine.create(function()
        departureHandshake.OnServerEvent:Fire(player, 704, manifest.version, manifest.fingerprint)
    end)
    assert(coroutine.resume(shuttingDown), "shutdown replacement must suspend in cleanup")
    local offerCount = #offers
    departureServer:destroy()
    assert(coroutine.resume(shuttingDown), "shutdown must invalidate the suspended replacement")
    assert(
        #offers == offerCount
            and departureServer:findPeer(player) == nil
            and departureServer:status().state == "CLOSED",
        "closed adapter must not emit a late offer or revive a retired session"
    )
end
