--!strict

local Peer = if script then require(script.Parent.TransportPeer) else require("./TransportPeer")
local Manifest = if script
    then require(script.Parent.TransportManifest)
    else require("./TransportManifest")
local Admission = if script
    then require(script.Parent.TransportAdmission)
    else require("./TransportAdmission")
local Remote = {}
local U32 = 4294967295
local ADAPTER_EVENTS = {
    handshake_denied = 0,
    handshake_mismatch = 0,
    session_replaced = 0,
    peer_creation_failed = 0,
    pre_ready_frame_rejected = 0,
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
    local ok, connection = pcall(function()
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
        pcall(callback, metrics, event)
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
    local epoch: number? = nil
    local confirmed = false
    local state = "OPEN"
    local handshakeConnection = handshake.OnClientEvent:Connect(function(...)
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
        elseif phase == "ready" and epoch == replyEpoch then
            confirmed = true
        else
            observe(metrics, nil, "handshake_denied")
        end
    end)
    local waitForRetry = options.handshakeWait
        or function()
            if script then
                task.wait(0.5)
            end
        end
    local attempts = options.maximumHandshakeAttempts or 10
    assert(integer(attempts, 1, 100), "invalid handshake attempt limit")
    for _ = 1, attempts do
        if epoch ~= nil then
            break
        end
        pcall(handshake.FireServer, handshake, challenge, manifest.version, manifest.fingerprint)
        if epoch == nil then
            pcall(waitForRetry)
        end
    end
    if epoch == nil then
        observe(metrics, nil, "handshake_denied")
        disconnect(handshakeConnection)
        state = "CLOSED"
        error("transport handshake failed")
    end

    local config = table.clone(options)
    config.epoch = epoch
    local stepSignal = config.stepSignal or defaultHeartbeat()
    config.sendReliable = function(frame)
        if not confirmed then
            observe(metrics, nil, "pre_ready_frame_rejected")
            error("transport peer is not ready")
        end
        reliable:FireServer(frame)
    end
    if unreliable then
        config.sendUnreliable = function(frame)
            if not confirmed then
                observe(metrics, nil, "pre_ready_frame_rejected")
                error("transport peer is not ready")
            end
            unreliable:FireServer(frame)
        end
    end
    local made, peer = pcall(Peer.new, config)
    if not made then
        observe(metrics, nil, "peer_creation_failed")
        disconnect(handshakeConnection)
        state = "CLOSED"
        error("transport peer creation failed: " .. tostring(peer))
    end
    local reliableConnection = reliable.OnClientEvent:Connect(function(frame)
        if state == "OPEN" and confirmed then
            peer:receive(frame, "reliable")
        elseif state == "OPEN" then
            observe(metrics, nil, "pre_ready_frame_rejected")
        end
    end)
    local unreliableConnection = if unreliable
        then unreliable.OnClientEvent:Connect(function(frame)
            if state == "OPEN" and confirmed then
                peer:receive(frame, "unreliable")
            elseif state == "OPEN" then
                observe(metrics, nil, "pre_ready_frame_rejected")
            end
        end)
        else nil
    local stepConnection = connect(stepSignal, function()
        if state == "OPEN" then
            peer:step()
        end
    end)
    if type(options.bindPeer) == "function" then
        local bound = pcall(options.bindPeer, peer)
        if not bound or peer:status().destroyed then
            observe(metrics, nil, "peer_creation_failed")
            disconnect(handshakeConnection)
            disconnect(reliableConnection)
            disconnect(unreliableConnection)
            disconnect(stepConnection)
            peer:destroy()
            state = "CLOSED"
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
    disconnect(handshakeConnection)
    if not confirmed then
        observe(metrics, nil, "handshake_denied")
        state = "DRAINING"
        disconnect(reliableConnection)
        disconnect(unreliableConnection)
        disconnect(stepConnection)
        peer:destroy()
        state = "CLOSED"
        error("transport handshake confirmation failed")
    end
    return peer,
        function()
            if state ~= "OPEN" then
                return
            end
            state = "DRAINING"
            disconnect(reliableConnection)
            disconnect(unreliableConnection)
            disconnect(stepConnection)
            peer:destroy()
            state = "CLOSED"
        end
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
    local peers = {}
    local sessions = {}
    local creations = {}
    local attemptWindows = {}
    local replacementWindows = {}
    local state = "OPEN"
    local nextEpoch = settings.initialEpoch or math.random(1, 2147483647)
    local clock = settings.clock or os.clock
    assert(
        settings.admission == nil or type(settings.admission) == "table",
        "invalid admission options"
    )
    local admissionOptions = table.clone(settings.admission or {})
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
        if peer then
            peer:destroy()
        end
    end

    local function create(player: Player, epoch: number, token: any): any
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
        local suppliedAdmit = config.admit
        config.admit = function(route, rawBytes, expandedBytes)
            local admitted, reason = admission:admit(player, route, rawBytes, expandedBytes)
            if not admitted then
                return false, reason
            end
            if suppliedAdmit ~= nil then
                return suppliedAdmit(route, rawBytes, expandedBytes)
            end
            return true, nil
        end
        local compatible = pcall(checkedManifest, config.routes, advertised)
        if not compatible then
            if creations[player] == token then
                creations[player] = nil
            end
            return nil
        end
        config.epoch = epoch
        config.sendReliable = function(frame)
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
        if unreliable then
            config.sendUnreliable = function(frame)
                if
                    state == "OPEN"
                    and peers[player] ~= nil
                    and sessions[player] == token.session
                    and token.session.active
                then
                    unreliable:FireClient(player, frame)
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
        local onPeer = config.onPeer or settings.onPeer
        if type(onPeer) == "function" then
            local setup = pcall(onPeer, player, peer)
            if not setup or state ~= "OPEN" or creations[player] ~= token then
                if peers[player] == peer then
                    peers[player] = nil
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
                peers[player] = nil
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
        local expired = 0
        for _, peer in peers do
            expired += peer:step()
        end
        return expired
    end

    function handle:status(): any
        return { state = state, adapter = table.clone(adapterEvents) }
    end

    local handshakeConnection = handshake.OnServerEvent:Connect(function(player, ...)
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
            if phase ~= "ready" or not existing or existing.challenge ~= challenge then
                observe(metrics, adapterEvents, "handshake_denied")
                return
            end
            if existing.active and peers[player] then
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
            local token = { session = existing }
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
        local session = { challenge = challenge, epoch = nextEpoch, active = false }
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

    local reliableConnection = reliable.OnServerEvent:Connect(function(player, frame)
        local session = sessions[player]
        local peer = if state == "OPEN" and session and session.active then peers[player] else nil
        if peer then
            peer:receive(frame, "reliable")
        elseif state == "OPEN" then
            observe(metrics, adapterEvents, "pre_ready_frame_rejected")
        end
    end)
    local unreliableConnection = if unreliable
        then unreliable.OnServerEvent:Connect(function(player, frame)
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
        then connect(players.PlayerRemoving, function(player)
            handle:removePeer(player)
        end)
        else nil
    local stepConnection = connect(settings.stepSignal or defaultHeartbeat(), function()
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
        table.clear(sessions)
        table.clear(attemptWindows)
        table.clear(replacementWindows)
        for player, peer in peers do
            peers[player] = nil
            peer:destroy()
        end
        admission:close()
        state = "CLOSED"
    end

    return setmetatable(handle, {
        __call = function(value)
            value:destroy()
        end,
    })
end

return Remote
