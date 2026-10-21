--!strict

local Peer = if script then require(script.Parent.TransportPeer) else require("./TransportPeer")
type PeerState = typeof(Peer.new({}))
local Manifest = if script
    then require(script.Parent.TransportManifest)
    else require("./TransportManifest")
local Admission = if script
    then require(script.Parent.TransportAdmission)
    else require("./TransportAdmission")
local Callbacks = if script
    then require(script.Parent.TransportCallbacks)
    else require("./TransportCallbacks")
local Remote = {}
type Session = {
    challenge: number,
    epoch: number,
    active: boolean,
    terminal: boolean?,
    terminalAttempts: number?,
    terminalNext: number?,
}
type Creation = { session: Session }
local U32 = 4294967295
local ADAPTER_EVENTS = {
    handshake_denied = 0,
    handshake_mismatch = 0,
    session_replaced = 0,
    peer_creation_failed = 0,
    pre_ready_frame_rejected = 0,
    peer_terminated = 0,
    other = 0,
}

local function integer(value: any, minimum: number, maximum: number): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function defaultHeartbeat(): any
    if script then
        return game:GetService("RunService").Heartbeat
    end

    return nil
end

local function connect(signal: any, callback: any): any
    if signal == nil then
        return nil
    end

    local ok, connection = pcall(function ()
        return signal:Connect(callback)
    end)
    return if ok then connection else nil
end

local function disconnect(connection: any)
    if connection then
        pcall(connection.Disconnect, connection)
    end
end

local function checkedManifest(routes: any, supplied: any): any
    local built, err = Manifest.build(routes)
    assert(built, err)
    assert(
        Manifest.matches(built, supplied and supplied.version, supplied and supplied.fingerprint),
        "transport manifest does not match routes"
    )
    return built
end

local function observe(metrics: any, counters: any?, event: string)
    if counters then
        counters[event] += 1
    end

    local callback = metrics and metrics.adapter

    if type(callback) == "function" then
        Callbacks.synchronous(callback, metrics, event)
    end
end

function Remote.client(
    reliable: RemoteEvent,
    unreliable: UnreliableRemoteEvent?,
    options: any
): (any, () -> ())
    assert(type(options) == "table", "peer options required")
    local handshake = options.handshakeRemote
    assert(handshake ~= nil, "transport handshake remote required")
    local manifest = checkedManifest(options.routes, options.manifest)
    local challenge = options.handshakeChallenge or math.random(1, 2147483647)
    assert(integer(challenge, 1, U32), "transport handshake challenge must be a nonzero u32")
    local metrics = options.metrics
    local attempts = options.maximumHandshakeAttempts or 10
    assert(integer(attempts, 1, 100), "invalid handshake attempt limit")
    local stepSignal = options.stepSignal or defaultHeartbeat()
    local initializationOwner: thread? = coroutine.running()
    local epoch: number? = nil
    local confirmed = false
    local state = "OPEN"
    local peer: any = nil
    local handshakeConnection: any = nil
    local reliableConnection: any = nil
    local unreliableConnection: any = nil
    local stepConnection: any = nil
    local function close()
        if state ~= "OPEN" then
            return
        end
        state = "CLOSED"
        initializationOwner = nil
        disconnect(handshakeConnection)
        disconnect(reliableConnection)
        disconnect(unreliableConnection)
        disconnect(stepConnection)
        if peer then
            peer:destroy()
        end
    end
    -- The caller cannot return a disposer if initialization is cancelled.
    -- Reuse normal lifecycle stepping to release that abandoned ownership.
    stepConnection = connect(stepSignal, function ()
        if state ~= "OPEN" then
            return
        end

        local owner = initializationOwner

        if owner and coroutine.status(owner) == "dead" then
            close()
        elseif peer then
            peer:step()
        end
    end)
    handshakeConnection = handshake.OnClientEvent:Connect(function (...)
        if state ~= "OPEN" then
            return
        end

        if select("#", ...) ~= 5 then
            observe(metrics, nil, "handshake_denied")
            return
        end

        local replyChallenge, replyEpoch, version, fingerprint, phase = ...

        if replyChallenge ~= challenge or not integer(replyEpoch, 1, U32) then
            observe(metrics, nil, "handshake_denied")
            return
        end

        if not Manifest.matches(manifest, version, fingerprint) then
            observe(metrics, nil, "handshake_mismatch")
            return
        end

        if phase == "offer" then
            if epoch == nil then
                epoch = replyEpoch
            elseif epoch ~= replyEpoch then
                observe(metrics, nil, "handshake_denied")
            end
        elseif phase == "closed" and epoch == replyEpoch then
            if peer then
                peer:_terminate("remote_closed")
            end
            close()
        elseif phase == "ready" and epoch == replyEpoch then
            confirmed = true
        else
            observe(metrics, nil, "handshake_denied")
        end
    end)
    local waitForRetry = options.handshakeWait
        or function ()
            if script then
                task.wait(0.5)
            end
        end
    for _ = 1, attempts do
        if epoch ~= nil then
            break
        end
        pcall(handshake.FireServer, handshake, challenge, manifest.version, manifest.fingerprint)
        if epoch == nil then
            pcall(waitForRetry)
        end
    end

    if epoch == nil or state ~= "OPEN" then
        observe(metrics, nil, "handshake_denied")
        close()
        error("transport handshake failed")
    end

    local config = table.clone(options)
    config.epoch = epoch
    local suppliedTerminate = config.onTerminate
    config.onTerminate = function (reason)
        if state == "OPEN" then
            -- One terminal control message, never replay application frames.
            close()
            Callbacks.synchronous(
                handshake.FireServer,
                handshake,
                challenge,
                manifest.version,
                manifest.fingerprint,
                "closed"
            )
        end

        if type(suppliedTerminate) == "function" then
            Callbacks.synchronous(suppliedTerminate, reason)
        end
    end
    config.sendReliable = function (frame)
        if not confirmed then
            observe(metrics, nil, "pre_ready_frame_rejected")
            error("transport peer is not ready")
        end
        reliable:FireServer(frame)
    end

    if unreliable then
        config.sendUnreliable = function (frame)
            if not confirmed then
                observe(metrics, nil, "pre_ready_frame_rejected")
                error("transport peer is not ready")
            end
            unreliable:FireServer(frame)
        end
    end

    local made, result = pcall(Peer.new, config)

    if not made then
        observe(metrics, nil, "peer_creation_failed")
        close()
        error("transport peer creation failed: " .. tostring(result))
    end
    peer = result
    reliableConnection = reliable.OnClientEvent:Connect(function (frame)
        if state == "OPEN" and confirmed then
            peer:receive(frame, "reliable")
        elseif state == "OPEN" then
            observe(metrics, nil, "pre_ready_frame_rejected")
        end
    end)
    unreliableConnection = if unreliable
        then unreliable.OnClientEvent:Connect(function (frame)
            if state == "OPEN" and confirmed then
                peer:receive(frame, "unreliable")
            elseif state == "OPEN" then
                observe(metrics, nil, "pre_ready_frame_rejected")
            end
        end)
        else nil
    local bindPeer: ((PeerState) -> ())? = options.bindPeer

    if type(bindPeer) == "function" then
        local bound = pcall(bindPeer, peer)

        if not bound or peer:status().destroyed then
            observe(metrics, nil, "peer_creation_failed")
            close()
            error("transport client peer binding failed")
        end
    end
    for _ = 1, attempts do
        if confirmed then
            break
        end
        pcall(
            handshake.FireServer,
            handshake,
            challenge,
            manifest.version,
            manifest.fingerprint,
            "ready"
        )
        if not confirmed then
            pcall(waitForRetry)
        end
    end
    -- Keep the bounded control listener for terminal notifications.
    if not confirmed or state ~= "OPEN" then
        observe(metrics, nil, "handshake_denied")
        close()
        error("transport handshake confirmation failed")
    end
    initializationOwner = nil
    return peer, close
end

function Remote.server(
    reliable: RemoteEvent,
    unreliable: UnreliableRemoteEvent?,
    optionsFor: (Player) -> any,
    lifecycle: any?
): any
    local settings = lifecycle or {}
    local handshake = settings.handshakeRemote
    assert(handshake ~= nil, "transport handshake remote required")
    local advertised = settings.manifest
    assert(type(advertised) == "table", "transport manifest required")
    local peers: { [Player]: PeerState? } = {}
    local sessions: { [Player]: Session? } = {}
    local creations: { [Player]: Creation? } = {}
    local attemptWindows = {}
    local replacementWindows = {}
    local state = "OPEN"
    local nextEpoch = settings.initialEpoch or math.random(1, 2147483647)
    local clock = settings.clock or os.clock
    assert(
        settings.admission == nil or type(settings.admission) == "table",
        "invalid admission options"
    )
    local admissionOptions = table.clone((settings.admission or {}) :: { [string]: any })
    admissionOptions.clock = admissionOptions.clock or clock
    local admission = Admission.new(admissionOptions)
    local windowSeconds = settings.handshakeAttemptWindowSeconds or 10
    local maximumAttempts = settings.maximumHandshakeAttemptsPerWindow or 32
    local maximumReplacements = settings.maximumHandshakeReplacementsPerWindow or 4
    local metrics = settings.metrics
    local adapterEvents = table.clone(ADAPTER_EVENTS)
    assert(integer(nextEpoch, 1, U32), "invalid initial transport epoch")
    assert(type(clock) == "function", "transport clock required")
    assert(integer(maximumAttempts, 1, 1000), "invalid handshake attempt limit")
    assert(integer(maximumReplacements, 0, 100), "invalid handshake replacement limit")
    assert(
        type(windowSeconds) == "number" and windowSeconds > 0 and windowSeconds <= 300,
        "invalid handshake attempt window"
    )
    local maximumReceiveFramesPerStep = settings.maximumReceiveFramesPerStep or 128
    assert(integer(maximumReceiveFramesPerStep, 1, 4096), "invalid server receive work budget")
    local receiveRemaining = maximumReceiveFramesPerStep
    local peerOrder: { Player } = {}
    local nextPeer = 1
    local stepOwner: thread? = nil
    local stepGeneration = 0
    local handle = {}

    local function allowWindow(windows: any, player: Player, maximum: number): boolean
        local ok, now = pcall(clock)

        if not ok or type(now) ~= "number" or now ~= now then
            return false
        end

        local window = windows[player]

        if not window or now - window.started >= windowSeconds then
            window = { started = now, count = 0 }
            windows[player] = window
        end

        if window.count >= maximum then
            return false
        end
        window.count += 1
        return true
    end

    local function remove(player: Player, _reason: string?)
        creations[player] = nil
        local peer = peers[player]
        peers[player] = nil
        local index = table.find(peerOrder, player)

        if index then
            table.remove(peerOrder, index)
        end

        if peer then
            peer:destroy()
        end
    end

    local function notifyTerminal(player: Player, session: Session)
        if state ~= "OPEN" or sessions[player] ~= session or not session.terminal then
            return
        end

        local attempts = session.terminalAttempts or 0

        if attempts >= 3 then
            return
        end

        local called, now = Callbacks.synchronous(clock)

        if
            not called
            or type(now) ~= "number"
            or now ~= now
            or now == math.huge
            or now == -math.huge
        then
            return
        end

        if session.terminalNext and now < session.terminalNext then
            return
        end
        session.terminalAttempts = attempts + 1
        session.terminalNext = now + 0.5
        Callbacks.synchronous(
            handshake.FireClient,
            handshake,
            player,
            session.challenge,
            session.epoch,
            advertised.version,
            advertised.fingerprint,
            "closed"
        )
    end

    local function create(player: Player, epoch: number, token: Creation): PeerState?
        local called, supplied = pcall(optionsFor, player)

        if
            not called
            or state ~= "OPEN"
            or creations[player] ~= token
            or sessions[player] ~= token.session
            or type(supplied) ~= "table"
        then
            if creations[player] == token then
                creations[player] = nil
            end

            return nil
        end

        local config = table.clone(supplied)
        local compatible = pcall(checkedManifest, config.routes, advertised)

        if not compatible then
            if creations[player] == token then
                creations[player] = nil
            end

            return nil
        end

        local suppliedTerminate = config.onTerminate
        config.onTerminate = function (reason)
            if state == "OPEN" and sessions[player] == token.session then
                token.session.active = false
                token.session.terminal = true
                remove(player, reason)
                observe(metrics, adapterEvents, "peer_terminated")
                notifyTerminal(player, token.session)
            end

            if type(suppliedTerminate) == "function" then
                Callbacks.synchronous(suppliedTerminate, reason)
            end
        end
        config.acquireReceiveWork = function ()
            if receiveRemaining <= 0 then
                return false
            end
            receiveRemaining -= 1
            return true
        end

        local unreliableRoutes: { [number]: boolean } = {}

        for _, route in ipairs(config.routes :: { any }) do
            if route.lane == "unreliable" then
                unreliableRoutes[route.id] = true
            end
        end

        local suppliedAdmit: ((number, number, number) -> (boolean, string?))? = config.admit
        config.admit = function (route: number, rawBytes: number, expandedBytes: number)
            local admitted, reason = admission:admit(
                player,
                route,
                rawBytes,
                expandedBytes,
                unreliableRoutes[route] == true
            )
            if not admitted then
                return false, reason
            end

            if suppliedAdmit ~= nil then
                return suppliedAdmit(route, rawBytes, expandedBytes)
            end

            return true, nil
        end
        config.epoch = epoch
        config.sendReliable = function (frame)
            if
                state == "OPEN"
                and peers[player] ~= nil
                and sessions[player] == token.session
                and token.session.active
            then
                reliable:FireClient(player, frame)
            else
                observe(metrics, adapterEvents, "pre_ready_frame_rejected")
                error("transport peer is not ready")
            end
        end

        local unreliableRemote = unreliable

        if unreliableRemote then
            config.sendUnreliable = function (frame)
                if
                    state == "OPEN"
                    and peers[player] ~= nil
                    and sessions[player] == token.session
                    and token.session.active
                then
                    unreliableRemote:FireClient(player, frame)
                else
                    observe(metrics, adapterEvents, "pre_ready_frame_rejected")
                    error("transport peer is not ready")
                end
            end
        end

        local made, peer = pcall(Peer.new, config)

        if not made or state ~= "OPEN" or creations[player] ~= token then
            if made and peer then
                peer:destroy()
            end

            if creations[player] == token then
                creations[player] = nil
            end

            return nil
        end
        peers[player] = peer
        table.insert(peerOrder, player)
        local onPeer = config.onPeer or settings.onPeer

        if type(onPeer) == "function" then
            local setup = pcall(onPeer, player, peer)

            if not setup or state ~= "OPEN" or creations[player] ~= token then
                if peers[player] == peer then
                    remove(player, "peer_creation_failed")
                end
                peer:destroy()
                if creations[player] == token then
                    creations[player] = nil
                end

                return nil
            end
        end

        if peer:status().destroyed then
            if peers[player] == peer then
                remove(player, "peer_creation_failed")
            end

            if creations[player] == token then
                creations[player] = nil
            end

            return nil
        end
        creations[player] = nil
        token.session.active = true
        return peer
    end

    function handle:findPeer(player: Player): any
        return peers[player]
    end

    function handle:removePeer(player: Player)
        admission:clearPeer(player)
        sessions[player] = nil
        attemptWindows[player] = nil
        replacementWindows[player] = nil
        remove(player, "player_removed")
    end

    function handle:step(): number
        if state ~= "OPEN" then
            return 0
        end

        local owner = stepOwner

        if
            owner
            and coroutine.status(owner) ~= "suspended"
            and coroutine.status(owner) ~= "dead"
        then
            return 0
        end
        stepGeneration += 1
        local generation = stepGeneration
        stepOwner = coroutine.running()
        receiveRemaining = maximumReceiveFramesPerStep
        local expired = 0

        for player, session in sessions do
            if session and session.terminal then
                notifyTerminal(player, session)
            end
        end
        -- Snapshot so terminal callbacks/removals cannot skip or duplicate a peer.
        -- Rotate priority: a busy peer cannot own every heartbeat's first slice.
        local order = table.clone(peerOrder)
        local count = #order
        local first = if count > 0 then ((nextPeer - 1) % count) + 1 else 1
        nextPeer = first + 1
        for offset = 0, count - 1 do
            if generation ~= stepGeneration or state ~= "OPEN" then
                return expired
            end

            local player = order[((first + offset - 1) % count) + 1]
            local peer = peers[player]

            if peer then
                expired += peer:step()
            end
        end

        if generation == stepGeneration then
            stepOwner = nil
        end

        return expired
    end

    function handle:status(): any
        return {
            state = state,
            adapter = table.clone(adapterEvents),
            admission = admission:status(),
            receiveRemaining = receiveRemaining,
            maximumReceiveFramesPerStep = maximumReceiveFramesPerStep,
        }
    end

    local handshakeConnection = handshake.OnServerEvent:Connect(function (player, ...)
        if state ~= "OPEN" then
            return
        end

        if not allowWindow(attemptWindows, player, maximumAttempts) then
            observe(metrics, adapterEvents, "handshake_denied")
            return
        end

        local count = select("#", ...)

        if count ~= 3 and count ~= 4 then
            observe(metrics, adapterEvents, "handshake_denied")
            return
        end

        local challenge, version, fingerprint, phase = ...

        if not integer(challenge, 1, U32) then
            observe(metrics, adapterEvents, "handshake_denied")
            return
        end

        if not Manifest.matches(advertised, version, fingerprint) then
            observe(metrics, adapterEvents, "handshake_mismatch")
            return
        end

        local existing = sessions[player]

        if count == 4 then
            if phase == "closed" and existing and existing.challenge == challenge then
                existing.active = false
                existing.terminal = true
                remove(player, "remote_closed")
                notifyTerminal(player, existing)
                return
            end

            if existing and existing.terminal then
                notifyTerminal(player, existing)
                observe(metrics, adapterEvents, "handshake_denied")
                return
            end

            if phase ~= "ready" or not existing or existing.challenge ~= challenge then
                observe(metrics, adapterEvents, "handshake_denied")
                return
            end

            local existingPeer = peers[player]

            if existing.active and existingPeer and not existingPeer:status().destroyed then
                handshake:FireClient(
                    player,
                    challenge,
                    existing.epoch,
                    advertised.version,
                    advertised.fingerprint,
                    "ready"
                )
                return
            end

            if creations[player] ~= nil then
                observe(metrics, adapterEvents, "handshake_denied")
                return
            end

            local token: Creation = { session = existing :: Session }
            creations[player] = token
            local peer = create(player, existing.epoch, token)

            if state == "OPEN" and peer and sessions[player] == existing then
                handshake:FireClient(
                    player,
                    challenge,
                    existing.epoch,
                    advertised.version,
                    advertised.fingerprint,
                    "ready"
                )
            elseif not peer then
                observe(metrics, adapterEvents, "peer_creation_failed")
            end

            return
        end

        if existing and existing.challenge == challenge then
            if existing.terminal then
                notifyTerminal(player, existing)
                observe(metrics, adapterEvents, "handshake_denied")
                return
            end
            handshake:FireClient(
                player,
                challenge,
                existing.epoch,
                advertised.version,
                advertised.fingerprint,
                "offer"
            )
            return
        end

        if existing and not allowWindow(replacementWindows, player, maximumReplacements) then
            observe(metrics, adapterEvents, "handshake_denied")
            return
        end
        nextEpoch = if nextEpoch >= U32 then 1 else nextEpoch + 1
        local session: Session =
            { challenge = challenge, epoch = nextEpoch, active = false, terminal = false }
        sessions[player] = session
        remove(player, "session_replaced")
        if existing then
            observe(metrics, adapterEvents, "session_replaced")
        end

        if state ~= "OPEN" or sessions[player] ~= session then
            return
        end
        handshake:FireClient(
            player,
            challenge,
            session.epoch,
            advertised.version,
            advertised.fingerprint,
            "offer"
        )
    end)

    local reliableConnection = reliable.OnServerEvent:Connect(function (player, frame)
        local session = sessions[player]
        local peer = if state == "OPEN" and session and session.active then peers[player] else nil

        if peer then
            peer:receive(frame, "reliable")
        elseif state == "OPEN" then
            observe(metrics, adapterEvents, "pre_ready_frame_rejected")
        end
    end)
    local unreliableConnection = if unreliable
        then unreliable.OnServerEvent:Connect(function (player, frame)
            local session = sessions[player]
            local peer = if state == "OPEN"
                    and session
                    and session.active
                then peers[player]
                else nil
            if peer then
                peer:receive(frame, "unreliable")
            elseif state == "OPEN" then
                observe(metrics, adapterEvents, "pre_ready_frame_rejected")
            end
        end)
        else nil
    local players = settings.players

    if players == nil and script then
        players = game:GetService("Players")
    end

    local playerConnection = if players
        then connect(players.PlayerRemoving, function (player)
            handle:removePeer(player)
        end)
        else nil
    local stepConnection = connect(settings.stepSignal or defaultHeartbeat(), function ()
        handle:step()
    end)

    function handle:destroy()
        if state ~= "OPEN" then
            return
        end
        state = "DRAINING"
        disconnect(handshakeConnection)
        disconnect(reliableConnection)
        disconnect(unreliableConnection)
        disconnect(playerConnection)
        disconnect(stepConnection)
        table.clear(creations)
        table.clear(peerOrder)
        table.clear(sessions)
        table.clear(attemptWindows)
        table.clear(replacementWindows)
        for player, peer in peers do
            peers[player] = nil
            if peer then
                peer:destroy()
            end
        end
        admission:close()
        state = "CLOSED"
    end

    return setmetatable(handle, {
        __call = function (value)
            value:destroy()
        end,
    })
end

return Remote
