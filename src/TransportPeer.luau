--!strict

local Config = if script
    then require(script.Parent.TransportConfig)
    else require("./TransportConfig")
local Frame = if script then require(script.Parent.TransportFrame) else require("./TransportFrame")
local Compression = if script
    then require(script.Parent.TransportCompression)
    else require("./TransportCompression")
local Egress = if script
    then require(script.Parent.TransportEgress)
    else require("./TransportEgress")

local Peer = {}
local Impl = {}
Impl.__index = Impl
local U32 = 4294967295
local SEQUENCE_HALF_RANGE = math.floor(U32 / 2)

local function isBuffer(value: any): boolean
    return typeof(value) == "buffer"
end

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function laneIs(lane: any, expected: string): boolean
    return lane == expected
end

local function safe(fn: any, ...): (boolean, ...any)
    return pcall(fn, ...)
end

local function metric(self: any, name: string, ...)
    local metrics = self.metrics
    local fn = metrics and metrics[name]
    if type(fn) == "function" then
        pcall(fn, metrics, ...)
    end
end

function Peer.new(options: any): any
    local config, err = Config.peer(options)
    assert(config, err)
    assert(type(config.sendReliable) == "function", "reliable sender required")
    local routes = {}
    local maximumInboundFrameBytes = 0
    for _, route in ipairs(config.routes) do
        routes[route.id] = route
        maximumInboundFrameBytes = math.max(maximumInboundFrameBytes, route.maximumFrameBytes)
    end
    local clock = config.clock or os.clock
    local value = setmetatable({
        epoch = config.epoch,
        routes = routes,
        sendReliable = config.sendReliable,
        sendUnreliable = config.sendUnreliable,
        admit = config.admit,
        compressor = config.compressor,
        compressionPolicy = config.compressionPolicy,
        permitOutboundCompression = config.permitOutboundCompression == true,
        metrics = config.metrics,
        clock = clock,
        maxRequests = config.maximumOutstandingRequests,
        maxTimeout = config.maximumRequestTimeout,
        sentR = 0,
        sentU = 0,
        recvR = 0,
        recvU = 0,
        sentRoutes = {},
        recvRoutes = {},
        maximumInboundFrameBytes = maximumInboundFrameBytes,
        maximumQueuedBytes = config.maximumQueuedReceiveBytes,
        maximumQueuedFrames = config.maximumQueuedFrames,
        maximumReceiveFramesPerStep = config.maximumReceiveFramesPerStep,
        ingressPacketCapacity = config.ingressPackets.capacity,
        ingressPacketRefill = config.ingressPackets.refillPerSecond,
        ingressPacketTokens = config.ingressPackets.capacity,
        ingressPacketLast = nil,
        nextRequest = 0,
        requests = {},
        requestCount = 0,
        routeRequests = {},
        listeners = {},
        batchListeners = {},
        cancelListeners = {},
        sending = false,
        receiving = false,
        receiveQueue = {},
        receiveQueueHead = 1,
        receiveQueueTail = 0,
        receiveQueueBytes = 0,
        destroyed = false,
    }, Impl)
    if config.egress then
        value.egress = Egress.new(config.egress, clock, function(event, bytes)
            metric(value, "egress", event, bytes)
        end, function(reason)
            value:_terminate(reason)
        end)
    end
    return value
end

local function queuedFrames(self: any): number
    return math.max(0, self.receiveQueueTail - self.receiveQueueHead + 1)
end

function Impl:_drainReceiveQueue(limit: number)
    local processed = 0
    while
        not self.destroyed
        and processed < limit
        and self.receiveQueueHead <= self.receiveQueueTail
    do
        local head = self.receiveQueueHead
        local queued = self.receiveQueue[head]
        self.receiveQueue[head] = nil
        self.receiveQueueHead = head + 1
        self.receiveQueueBytes -= queued.raw
        local queuedCalled = safe(self._receiveNow, self, queued.frame, queued.carrier)
        processed += 1
        if not queuedCalled then
            self:_terminate("receive_failed")
        end
    end
    if self.destroyed or self.receiveQueueHead > self.receiveQueueTail then
        table.clear(self.receiveQueue)
        self.receiveQueueHead = 1
        self.receiveQueueTail = 0
        self.receiveQueueBytes = 0
    elseif self.receiveQueueHead > self.maximumQueuedFrames then
        local tail = self.receiveQueueTail
        local nextTail = 0
        for index = self.receiveQueueHead, tail do
            nextTail += 1
            self.receiveQueue[nextTail] = self.receiveQueue[index]
            self.receiveQueue[index] = nil
        end
        self.receiveQueueHead = 1
        self.receiveQueueTail = nextTail
    end
    metric(self, "retained", queuedFrames(self), self.requestCount)
    return processed
end

function Impl:onCancel(route: number, fn: any): () -> ()
    assert(
        not self.destroyed
            and self.routes[route]
            and self.routes[route].lane == "request"
            and type(fn) == "function",
        "invalid cancel listener"
    )
    self.cancelListeners[route] = fn
    local live = true
    return function()
        if live and self.cancelListeners[route] == fn then
            self.cancelListeners[route] = nil
        end
        live = false
    end
end

function Impl:on(route: number, fn: any): () -> ()
    assert(not self.destroyed and self.routes[route] and type(fn) == "function", "invalid listener")
    self.listeners[route] = fn
    local live = true
    return function()
        if live and self.listeners[route] == fn then
            self.listeners[route] = nil
        end
        live = false
    end
end

function Impl:onBatchValues(route: number, codec: any, fn: any): () -> ()
    local config = self.routes[route]
    assert(
        not self.destroyed
            and config
            and config.allowBatch == true
            and (config.lane == "reliable" or config.lane == "bulk")
            and type(codec) == "table"
            and type(codec.decodeBatch) == "function"
            and (config.allowCompactBatch ~= true or type(codec.decodeCompactBatch) == "function")
            and (config.schemaFingerprint == nil or config.schemaFingerprint == codec.fingerprint)
            and type(fn) == "function",
        "invalid batch listener"
    )
    local entry = { codec = codec, callback = fn }
    self.batchListeners[route] = entry
    local live = true
    return function()
        if live and self.batchListeners[route] == entry then
            self.batchListeners[route] = nil
        end
        live = false
    end
end

function Impl:_finishRequest(
    requestId: number,
    event: string,
    success: boolean,
    payload: buffer?,
    reason: string?
): boolean
    local pending = self.requests[requestId]
    if not pending then
        return false
    end
    self.requests[requestId] = nil
    self.requestCount -= 1
    local count = math.max(0, (self.routeRequests[pending.route] or 1) - 1)
    self.routeRequests[pending.route] = if count > 0 then count else nil
    metric(self, "request", event)
    safe(pending.callback, success, payload, reason)
    return true
end

function Impl:_terminate(reason: string)
    if self.destroyed then
        return
    end
    self.destroyed = true
    local ids = {}
    for requestId in self.requests do
        table.insert(ids, requestId)
    end
    for _, requestId in ipairs(ids) do
        self:_finishRequest(requestId, "cancelled", false, nil, reason)
    end
    table.clear(self.listeners)
    table.clear(self.batchListeners)
    table.clear(self.cancelListeners)
    table.clear(self.receiveQueue)
    self.receiveQueueHead = 1
    self.receiveQueueTail = 0
    self.receiveQueueBytes = 0
    if self.egress then
        self.egress:close()
    end
    metric(self, "retained", 0, 0)
end

function Impl:_sendNow(
    route: any,
    lane: string,
    payload: buffer,
    requestId: number?,
    batch: boolean?,
    latest: boolean?,
    compactBatch: boolean?
): (boolean, string?)
    if self.destroyed or not isBuffer(payload) then
        return false, if self.destroyed then "destroyed" else "payload_must_be_buffer"
    end
    if buffer.len(payload) > route.maximumExpandedBytes then
        return false, "payload_too_large"
    end

    local outbound = payload
    local compressed = false
    local expanded = nil
    if
        self.permitOutboundCompression
        and route.allowOutboundCompression == true
        and lane ~= "unreliable"
        and lane ~= "request"
        and lane ~= "cancel"
    then
        metric(self, "compression", "attempted", buffer.len(payload), nil)
        local packed, used, expandedSize, compressionError = Compression.maybeCompress(
            payload,
            self.compressor,
            route.compressionPolicy or self.compressionPolicy
        )
        if packed then
            outbound, compressed, expanded = packed, used, expandedSize
            metric(
                self,
                "compression",
                if used then "win" else "fallback",
                buffer.len(payload),
                buffer.len(packed)
            )
        elseif compressionError then
            metric(self, "compression", "rejected", buffer.len(payload), nil)
            return false, compressionError
        end
    end

    local unreliable = lane == "unreliable"
    local current = self.sentRoutes[route.id] or 0
    local sequence = if current >= U32 then 1 else current + 1
    local frame, err = Frame.encode({
        lane = lane,
        route = route.id,
        epoch = self.epoch,
        sequence = sequence,
        payload = outbound,
        requestId = requestId,
        compressed = compressed,
        expandedSize = expanded,
        batch = batch == true,
        compactBatch = compactBatch == true,
        latest = latest == true,
    })
    if not frame then
        return false, err
    end
    if buffer.len(frame) > route.maximumFrameBytes then
        return false, "frame_too_large"
    end
    local sender = if unreliable then self.sendUnreliable else self.sendReliable
    if type(sender) ~= "function" then
        return false, "transport_unavailable"
    end
    local scheduled = lane == "bulk" or latest == true
    if scheduled then
        if not self.egress then
            return false, "egress_scheduler_required"
        end
        local accepted, scheduleReason = self.egress:submit(
            if latest == true then "latest" else "bulk",
            route.id,
            frame,
            sender,
            not unreliable
        )
        if not accepted then
            return false, scheduleReason
        end
    else
        local ok = safe(sender, frame)
        if not ok then
            self:_terminate("transport_failed")
            return false, "transport_failed"
        end
    end
    if unreliable then
        self.sentU = sequence
    else
        self.sentR = sequence
    end
    self.sentRoutes[route.id] = sequence
    return true, if scheduled then "queued" else nil
end

function Impl:_send(
    route: any,
    lane: string,
    payload: buffer,
    requestId: number?,
    batch: boolean?,
    latest: boolean?,
    compactBatch: boolean?
): (boolean, string?)
    if self.sending then
        return false, "send_in_progress"
    end
    self.sending = true
    local called, sent, reason =
        safe(self._sendNow, self, route, lane, payload, requestId, batch, latest, compactBatch)
    self.sending = false
    if not called then
        self:_terminate("transport_failed")
        return false, "transport_failed"
    end
    return sent, reason
end

function Impl:send(routeId: number, payload: buffer, latest: boolean?): (boolean, string?)
    local route = self.routes[routeId]
    if not route or route.lane == "request" then
        return false, "invalid_route"
    end
    if latest == true and route.lane ~= "unreliable" then
        return false, "latest_requires_unreliable"
    end
    return self:_send(route, route.lane, payload, nil, false, latest)
end

function Impl:sendBatch(routeId: number, items: any): (boolean, string?)
    local route = self.routes[routeId]
    if
        not route
        or route.allowBatch ~= true
        or (route.lane ~= "reliable" and route.lane ~= "bulk")
    then
        return false, "batch_forbidden"
    end
    local payload, err = Frame.encodeBatch(items, {
        maximumItems = route.maximumBatchItems,
        maximumItemBytes = route.maximumBatchItemBytes,
        maximumPayloadBytes = route.maximumExpandedBytes,
    })
    if not payload then
        return false, err
    end
    metric(self, "batch", #items)
    return self:_send(route, route.lane, payload, nil, true, false)
end

function Impl:sendBatchValues(routeId: number, codec: any, values: any): (boolean, string?)
    local route = self.routes[routeId]
    if
        not route
        or route.allowBatch ~= true
        or (route.lane ~= "reliable" and route.lane ~= "bulk")
        or type(codec) ~= "table"
        or type(codec.encodeBatch) ~= "function"
    then
        return false, "batch_forbidden"
    end
    if route.schemaFingerprint ~= nil and route.schemaFingerprint ~= codec.fingerprint then
        return false, "schema_mismatch"
    end
    local called, payload, err = safe(codec.encodeBatch, codec, values, {
        maximumItems = route.maximumBatchItems,
        maximumItemBytes = route.maximumBatchItemBytes,
        maximumPayloadBytes = route.maximumExpandedBytes,
    })
    if not called then
        return false, "batch_encoding_failed"
    end
    if not payload then
        return false, err
    end
    metric(self, "batch", #values)
    return self:_send(route, route.lane, payload, nil, true, false)
end

function Impl:sendCompactBatchValues(routeId: number, codec: any, values: any): (boolean, string?)
    local route = self.routes[routeId]
    if
        not route
        or route.allowBatch ~= true
        or route.allowCompactBatch ~= true
        or (route.lane ~= "reliable" and route.lane ~= "bulk")
        or type(codec) ~= "table"
        or type(codec.encodeCompactBatch) ~= "function"
    then
        return false, "batch_forbidden"
    end
    if route.schemaFingerprint ~= nil and route.schemaFingerprint ~= codec.fingerprint then
        return false, "schema_mismatch"
    end
    local called, payload, err = safe(codec.encodeCompactBatch, codec, values, {
        maximumItems = route.maximumBatchItems,
        maximumItemBytes = route.maximumBatchItemBytes,
        maximumPayloadBytes = route.maximumExpandedBytes,
    })
    if not called then
        return false, "batch_encoding_failed"
    end
    if not payload then
        return false, err
    end
    metric(self, "batch", #values)
    return self:_send(route, route.lane, payload, nil, true, false, true)
end

function Impl:_nextRequest(): number?
    for _ = 1, self.maxRequests + 1 do
        self.nextRequest = if self.nextRequest >= U32 then 1 else self.nextRequest + 1
        if self.requests[self.nextRequest] == nil then
            return self.nextRequest
        end
    end
    return nil
end

function Impl:request(
    routeId: number,
    payload: buffer,
    timeout: number,
    callback: any
): (number?, string?)
    local route = self.routes[routeId]
    local routeCount = self.routeRequests[routeId] or 0
    if
        self.destroyed
        or not route
        or route.lane ~= "request"
        or not finite(timeout)
        or timeout <= 0
        or timeout > self.maxTimeout
        or type(callback) ~= "function"
        or self.requestCount >= self.maxRequests
        or routeCount >= route.maximumOutstandingRequests
    then
        metric(self, "denial", "request_capacity")
        return nil, "invalid_request"
    end
    local requestId = self:_nextRequest()
    if not requestId then
        metric(self, "denial", "request_capacity")
        return nil, "request_capacity"
    end
    local ok, now = safe(self.clock)
    if not ok or not finite(now) then
        return nil, "clock_failed"
    end
    self.requests[requestId] = {
        route = routeId,
        deadline = now + timeout,
        callback = callback,
    }
    self.requestCount += 1
    self.routeRequests[routeId] = routeCount + 1
    metric(self, "request", "opened")
    local sent, err = self:_send(route, "request", payload, requestId, false, false)
    if not sent then
        if self.requests[requestId] then
            self:_finishRequest(requestId, "cancelled", false, nil, err)
        end
        return nil, err
    end
    return requestId, nil
end

function Impl:respond(routeId: number, requestId: number, payload: buffer): (boolean, string?)
    local route = self.routes[routeId]
    if not route or route.lane ~= "request" then
        return false, "invalid_request"
    end
    return self:_send(route, "response", payload, requestId, false, false)
end

function Impl:cancel(routeId: number, requestId: number): (boolean, string?)
    local route = self.routes[routeId]
    if not route or route.lane ~= "request" then
        return false, "invalid_request"
    end
    local sent, err = self:_send(route, "cancel", buffer.create(0), requestId, false, false)
    if sent and self.requests[requestId] and self.requests[requestId].route == routeId then
        self:_finishRequest(requestId, "cancelled", false, nil, "cancelled")
    end
    return sent, err
end

function Impl:_expected(route: number, lane: string, sequence: number): (boolean, string?)
    local current = self.recvRoutes[route] or 0
    if current == 0 then
        if lane == "unreliable" or sequence == 1 then
            return true, nil
        end
        return false, "sequence_gap"
    end

    -- Zero is reserved. The nearer half of the sequence ring is forward.
    local distance = (sequence - current) % U32
    local forward = distance > 0 and distance <= SEQUENCE_HALF_RANGE
    if lane == "unreliable" then
        if not forward then
            return false, "stale_unreliable"
        end
        return true, nil
    end
    if distance ~= 1 then
        return false, if forward then "sequence_gap" else "replay"
    end
    return true, nil
end

function Impl:_commit(route: number, lane: string, sequence: number)
    self.recvRoutes[route] = sequence
    if lane == "unreliable" then
        self.recvU = sequence
    else
        self.recvR = sequence
    end
end

function Impl:_receiveNow(frame: buffer, carrier: string?): (boolean, string?)
    if self.destroyed or not isBuffer(frame) then
        return false, if self.destroyed then "destroyed" else "frame_must_be_buffer"
    end
    local raw = buffer.len(frame)
    if raw > self.maximumInboundFrameBytes then
        return false, "frame_too_large"
    end
    local meta, err = Frame.inspect(frame, {
        maximumFrameBytes = self.maximumInboundFrameBytes,
        maximumPayloadBytes = raw,
        maximumExpandedBytes = U32,
    })
    if not meta then
        return false, err
    end
    if
        (carrier == "unreliable" and not laneIs(meta.lane, "unreliable"))
        or (carrier == "reliable" and laneIs(meta.lane, "unreliable"))
    then
        metric(self, "compatibilityMismatch")
        return false, "carrier_mismatch"
    end
    local route = self.routes[meta.route]
    if not route then
        metric(self, "compatibilityMismatch")
        return false, "unknown_route"
    end
    if meta.epoch ~= self.epoch then
        metric(self, "compatibilityMismatch")
        return false, "epoch_mismatch"
    end
    local laneOk = route.lane == meta.lane
        or (
            laneIs(route.lane, "request")
            and (laneIs(meta.lane, "response") or laneIs(meta.lane, "cancel"))
        )
    if not laneOk then
        metric(self, "compatibilityMismatch")
        return false, "lane_mismatch"
    end
    local expected, sequenceError = self:_expected(meta.route, meta.lane, meta.sequence)
    if not expected then
        return false, sequenceError
    end

    -- Consume valid sequences even when admission fails, so later frames stay in order.
    self:_commit(meta.route, meta.lane, meta.sequence)
    if
        raw > route.maximumFrameBytes
        or meta.payloadLength > route.maximumPayloadBytes
        or meta.expandedSize > route.maximumExpandedBytes
    then
        return false, "route_bounds"
    end
    if self.admit then
        local called, admitted, reason = safe(self.admit, meta.route, raw, meta.expandedSize)
        if self.destroyed then
            return false, "destroyed"
        end
        if not called or admitted ~= true then
            metric(self, "denial", if called then reason or "other" else "other")
            return false, if called then reason or "limited" else "admission_failed"
        end
    end
    if meta.compressed and route.allowOutboundCompression ~= true then
        return false, "compression_forbidden"
    end
    if meta.batch and route.allowBatch ~= true then
        return false, "batch_forbidden"
    end
    if meta.compactBatch and route.allowCompactBatch ~= true then
        return false, "compact_batch_forbidden"
    end

    local batchListener = if meta.batch then self.batchListeners[meta.route] else nil
    if meta.compactBatch and not batchListener then
        return false, "compact_batch_listener_required"
    end
    if laneIs(meta.lane, "response") then
        if
            not meta.requestId
            or not self.requests[meta.requestId]
            or self.requests[meta.requestId].route ~= meta.route
        then
            metric(self, "request", "late")
            return true, "late_response"
        end
    end

    local directBatch = batchListener ~= nil and not meta.compressed
    local payload = if directBatch then nil else Frame.materialize(frame, meta)
    if meta.compressed then
        local output, compressionError = Compression.decompress(
            payload :: buffer,
            meta.expandedSize,
            self.compressor,
            route.maximumExpandedBytes
        )
        if not output then
            metric(self, "compression", "rejected", buffer.len(payload :: buffer), nil)
            return false, compressionError
        end
        payload = output
    end

    local slices = nil
    local batchValues = nil
    if meta.batch then
        if batchListener then
            local decoder = if meta.compactBatch
                then batchListener.codec.decodeCompactBatch
                else batchListener.codec.decodeBatch
            if type(decoder) ~= "function" then
                return false, "compact_batch_decoder_required"
            end
            local called, decoded, values, decodeError = safe(
                decoder,
                batchListener.codec,
                if directBatch then frame else payload,
                {
                    maximumItems = route.maximumBatchItems,
                    maximumItemBytes = route.maximumBatchItemBytes,
                    maximumPayloadBytes = route.maximumExpandedBytes,
                },
                if directBatch
                    then { offset = meta.payloadOffset, length = meta.payloadLength }
                    else nil
            )
            if not called or decoded ~= true then
                return false,
                    if called then decodeError or "invalid_batch" else "batch_decode_failed"
            end
            batchValues = values
        else
            slices, err = Frame.decodeBatch(payload, {
                maximumItems = route.maximumBatchItems,
                maximumItemBytes = route.maximumBatchItemBytes,
                maximumPayloadBytes = route.maximumExpandedBytes,
            })
            if not slices then
                return false, err
            end
        end
    end

    if self.destroyed then
        return false, "destroyed"
    end

    if laneIs(meta.lane, "response") then
        self:_finishRequest(meta.requestId, "completed", true, payload, nil)
        return true, nil
    end
    if laneIs(meta.lane, "cancel") then
        local cancelListener = self.cancelListeners[meta.route]
        if cancelListener then
            local ok = safe(cancelListener, meta.requestId, {
                route = meta.route,
                epoch = meta.epoch,
                sequence = meta.sequence,
            })
            if not ok then
                return false, "listener_failed"
            end
        end
        return true, nil
    end

    local listener = if batchListener then batchListener.callback else self.listeners[meta.route]
    if not listener then
        return true, "no_listener"
    end
    local ok = safe(listener, if batchListener then batchValues else payload, {
        route = meta.route,
        lane = meta.lane,
        epoch = meta.epoch,
        sequence = meta.sequence,
        requestId = meta.requestId,
        batch = meta.batch,
        compactBatch = meta.compactBatch,
        latest = meta.latest,
        slices = slices,
    })
    if ok then
        return true, nil
    end
    return false, "listener_failed"
end

function Impl:_admitAttempt(): (boolean, string?)
    local ok, now = safe(self.clock)
    if not ok or not finite(now) then
        return false, "clock_failed"
    end
    local last = self.ingressPacketLast
    if last == nil then
        last = now
    end
    self.ingressPacketTokens = math.min(
        self.ingressPacketCapacity,
        self.ingressPacketTokens + math.max(0, now - last) * self.ingressPacketRefill
    )
    self.ingressPacketLast = math.max(last, now)
    if self.ingressPacketTokens < 1 then
        return false, "ingress_packets"
    end
    self.ingressPacketTokens -= 1
    return true, nil
end

function Impl:receive(frame: any, carrier: string?): (boolean, string?)
    if self.destroyed then
        return false, "destroyed"
    end
    local attempted, attemptReason = self:_admitAttempt()
    if not attempted then
        if carrier ~= "unreliable" then
            self:_terminate(attemptReason or "ingress_limited")
        end
        metric(self, "denial", attemptReason or "ingress_packets")
        return false, attemptReason
    end
    if not isBuffer(frame) then
        return false, "frame_must_be_buffer"
    end
    local raw = buffer.len(frame)
    if raw > self.maximumInboundFrameBytes then
        return false, "frame_too_large"
    end
    if self.receiving or queuedFrames(self) > 0 then
        if
            queuedFrames(self) >= self.maximumQueuedFrames
            or raw > self.maximumQueuedBytes - self.receiveQueueBytes
        then
            if carrier ~= "unreliable" then
                self:_terminate("receive_backpressure")
            end
            return false, "receive_backpressure"
        end
        self.receiveQueueTail += 1
        self.receiveQueue[self.receiveQueueTail] = {
            frame = frame,
            carrier = carrier,
            raw = raw,
        }
        self.receiveQueueBytes += raw
        metric(self, "retained", queuedFrames(self), self.requestCount)
        if self.receiving then
            return true, "queued"
        end
        self.receiving = true
        self:_drainReceiveQueue(self.maximumReceiveFramesPerStep)
        self.receiving = false
        return true, "queued"
    end

    self.receiving = true
    local called, accepted, reason = safe(self._receiveNow, self, frame, carrier)
    local firstAccepted = if called then accepted else false
    local firstReason = if called then reason else "receive_failed"
    self:_drainReceiveQueue(math.max(0, self.maximumReceiveFramesPerStep - 1))
    self.receiving = false
    if not called then
        self:_terminate("receive_failed")
    end
    return firstAccepted, firstReason
end

function Impl:step(): number
    if self.destroyed then
        return 0
    end
    if self.egress then
        self.egress:step()
    end
    if self.destroyed then
        return 0
    end
    if not self.receiving and queuedFrames(self) > 0 then
        self.receiving = true
        self:_drainReceiveQueue(self.maximumReceiveFramesPerStep)
        self.receiving = false
    end
    if self.destroyed or self.requestCount == 0 then
        return 0
    end
    local ok, now = safe(self.clock)
    if not ok or not finite(now) then
        return 0
    end
    local expired = {}
    for requestId, pending in self.requests do
        if pending.deadline <= now then
            table.insert(expired, requestId)
        end
    end
    for _, requestId in ipairs(expired) do
        self:_finishRequest(requestId, "timeout", false, nil, "timeout")
    end
    return #expired
end

function Impl:destroy()
    self:_terminate("destroyed")
end

function Impl:status(): any
    local egress = if self.egress then self.egress:status() else { items = 0, bytes = 0 }
    return {
        destroyed = self.destroyed,
        outstandingRequests = self.requestCount,
        sentReliableSequence = self.sentR,
        sentUnreliableSequence = self.sentU,
        receivedReliableSequence = self.recvR,
        receivedUnreliableSequence = self.recvU,
        queuedFrames = queuedFrames(self),
        queuedBytes = self.receiveQueueBytes,
        egressItems = egress.items,
        egressBytes = egress.bytes,
    }
end

return Peer
