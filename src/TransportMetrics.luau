--!strict

local Metrics = {}

local LANES = {
    reliable = true,
    unreliable = true,
    request = true,
    response = true,
    bulk = true,
    cancel = true,
}
local REASONS = {
    accepted = true,
    malformed = true,
    limited = true,
    replay = true,
    timeout = true,
    decode = true,
    callback = true,
    closed = true,
    compatibility = true,
    bounds = true,
    sequence = true,
    request = true,
    compression = true,
    other = true,
}
local REQUEST_EVENTS =
    { opened = true, completed = true, timeout = true, cancelled = true, late = true }
local COMPRESSION_EVENTS = { attempted = true, win = true, fallback = true, rejected = true }
local EGRESS_EVENTS = {
    queued = true,
    coalesced = true,
    emitted = true,
    rejected = true,
    expired = true,
    failed = true,
}
local ADAPTER_EVENTS = {
    handshake_denied = true,
    handshake_mismatch = true,
    session_replaced = true,
    peer_creation_failed = true,
    pre_ready_frame_rejected = true,
    other = true,
}
local SIZE_BOUNDS = { 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536, 262144 }
local LATENCY_BOUNDS =
    { 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 1 }
local BATCH_BOUNDS = { 1, 2, 4, 8, 16, 32, 64, 128 }
local DENIAL_SCOPES = {
    peer_packets = true,
    ingress_packets = true,
    peer_raw_bytes = true,
    peer_expanded_bytes = true,
    peer_route_raw_bytes = true,
    peer_route_expanded_bytes = true,
    shared_route_raw_bytes = true,
    shared_route_expanded_bytes = true,
    shared_route_packets = true,
    global_raw_bytes = true,
    global_expanded_bytes = true,
    global_packets = true,
    request_capacity = true,
    callback_capacity = true,
    invalid_admission = true,
    attempt_peer_packets = true,
    attempt_peer_raw_bytes = true,
    attempt_global_packets = true,
    attempt_global_raw_bytes = true,
}

local function increment(map: any, key: string)
    map[key] = (map[key] or 0) + 1
end

local function addBucket(bounds: { number }, values: { number }, value: number)
    for index, bound in ipairs(bounds) do
        if value <= bound then
            values[index] += 1
            return
        end
    end
    values[#values] += 1
end

local function histogram(bounds: { number })
    return table.create(#bounds + 1, 0)
end

function Metrics.new(): any
    local state = {
        packets = {},
        rejections = {},
        rawBytes = 0,
        expandedBytes = 0,
        logicalBytes = 0,
        rawSizes = histogram(SIZE_BOUNDS),
        expandedSizes = histogram(SIZE_BOUNDS),
        logicalSizes = histogram(SIZE_BOUNDS),
        compression = {},
        compressionInputBytes = 0,
        compressionOutputBytes = 0,
        egress = {},
        egressBytes = 0,
        adapter = {
            handshake_denied = 0,
            handshake_mismatch = 0,
            session_replaced = 0,
            peer_creation_failed = 0,
            pre_ready_frame_rejected = 0,
            other = 0,
        },
        batchCount = histogram(BATCH_BOUNDS),
        decodeLatency = histogram(LATENCY_BOUNDS),
        callbackLatency = histogram(LATENCY_BOUNDS),
        requests = {},
        denials = {},
        compatibilityMismatches = 0,
        retainedQueues = 0,
        retainedWaiters = 0,
    }
    local metrics = {}

    function metrics:packet(
        lane: string,
        accepted: boolean,
        reason: string?,
        rawBytes: number?,
        expandedBytes: number?,
        logicalBytes: number?
    )
        lane = if LANES[lane] then lane else "other"
        increment(state.packets, lane .. (if accepted then ".accepted" else ".rejected"))
        if not accepted then
            local key = if reason and REASONS[reason] then reason else "other"
            increment(state.rejections, key)
        end
        if type(rawBytes) == "number" and rawBytes >= 0 then
            state.rawBytes += rawBytes
            addBucket(SIZE_BOUNDS, state.rawSizes, rawBytes)
        end
        if type(expandedBytes) == "number" and expandedBytes >= 0 then
            state.expandedBytes += expandedBytes
            addBucket(SIZE_BOUNDS, state.expandedSizes, expandedBytes)
        end
        if type(logicalBytes) == "number" and logicalBytes >= 0 then
            state.logicalBytes += logicalBytes
            addBucket(SIZE_BOUNDS, state.logicalSizes, logicalBytes)
        end
    end

    function metrics:compression(event: string, inputBytes: number?, outputBytes: number?)
        event = if COMPRESSION_EVENTS[event] then event else "rejected"
        increment(state.compression, event)
        if type(inputBytes) == "number" and inputBytes >= 0 then
            state.compressionInputBytes += inputBytes
        end
        if type(outputBytes) == "number" and outputBytes >= 0 then
            state.compressionOutputBytes += outputBytes
        end
    end

    function metrics:batch(count: number)
        if type(count) == "number" and count >= 0 then
            addBucket(BATCH_BOUNDS, state.batchCount, count)
        end
    end

    function metrics:egress(event: string, bytes: number?)
        increment(state.egress, if EGRESS_EVENTS[event] then event else "failed")
        if type(bytes) == "number" and bytes >= 0 then
            state.egressBytes += bytes
        end
    end

    function metrics:adapter(event: string)
        increment(state.adapter, if ADAPTER_EVENTS[event] then event else "other")
    end

    function metrics:latency(kind: string, seconds: number)
        if type(seconds) ~= "number" or seconds < 0 then
            return
        end
        if kind == "decode" then
            addBucket(LATENCY_BOUNDS, state.decodeLatency, seconds)
        elseif kind == "callback" then
            addBucket(LATENCY_BOUNDS, state.callbackLatency, seconds)
        end
    end

    function metrics:request(event: string)
        if REQUEST_EVENTS[event] then
            increment(state.requests, event)
        end
    end

    function metrics:denial(scope: string)
        increment(state.denials, if DENIAL_SCOPES[scope] then scope else "other")
    end

    function metrics:compatibilityMismatch()
        state.compatibilityMismatches += 1
    end
    function metrics:retained(queues: number, waiters: number)
        state.retainedQueues = math.max(0, math.floor(queues))
        state.retainedWaiters = math.max(0, math.floor(waiters))
    end
    function metrics:record(reason: string, bytes: number?)
        self:packet("reliable", reason == "accepted", reason, bytes, bytes, bytes)
    end

    function metrics:snapshot(): any
        return {
            packets = table.clone(state.packets),
            rejections = table.clone(state.rejections),
            bytes = {
                raw = state.rawBytes,
                expanded = state.expandedBytes,
                logical = state.logicalBytes,
            },
            sizeBounds = table.clone(SIZE_BOUNDS),
            rawSizes = table.clone(state.rawSizes),
            expandedSizes = table.clone(state.expandedSizes),
            logicalSizes = table.clone(state.logicalSizes),
            compression = table.clone(state.compression),
            compressionInputBytes = state.compressionInputBytes,
            compressionOutputBytes = state.compressionOutputBytes,
            egress = table.clone(state.egress),
            egressBytes = state.egressBytes,
            adapter = table.clone(state.adapter),
            batchCount = table.clone(state.batchCount),
            latencyBounds = table.clone(LATENCY_BOUNDS),
            decodeLatency = table.clone(state.decodeLatency),
            callbackLatency = table.clone(state.callbackLatency),
            requests = table.clone(state.requests),
            denials = table.clone(state.denials),
            compatibilityMismatches = state.compatibilityMismatches,
            retainedQueues = state.retainedQueues,
            retainedWaiters = state.retainedWaiters,
        }
    end

    return metrics
end

return Metrics
