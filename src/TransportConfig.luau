--!strict

local Config = {}
local Egress = if script
    then require(script.Parent.TransportEgress)
    else require("./TransportEgress")
local U32 = 4294967295

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value: any, minimum: number, maximum: number): boolean
    return finite(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function denseArray(value: any): boolean
    if type(value) ~= "table" then
        return false
    end
    local length = #value
    local count = 0
    for key in pairs(value) do
        if not integer(key, 1, length) then
            return false
        end
        count += 1
    end
    return count == length
end

local function compressionPolicy(route: any, expanded: number): (any?, string?)
    if route.allowOutboundCompression ~= true then
        return nil, nil
    end
    local raw = route.compressionPolicy or {}
    if type(raw) ~= "table" then
        return nil, "invalid_compression_policy"
    end
    local minimumBytes = raw.minimumBytes or 256
    local minimumSavingsBytes = raw.minimumSavingsBytes or 32
    local minimumSavingsRatio = raw.minimumSavingsRatio or 0.10
    local metadataBytes = raw.metadataBytes or 4
    if
        not integer(minimumBytes, 0, expanded)
        or not integer(minimumSavingsBytes, 0, expanded)
        or not finite(minimumSavingsRatio)
        or minimumSavingsRatio < 0
        or minimumSavingsRatio > 1
        or not integer(metadataBytes, 0, 64)
    then
        return nil, "invalid_compression_policy"
    end
    return table.freeze({
        minimumBytes = minimumBytes,
        minimumSavingsBytes = minimumSavingsBytes,
        minimumSavingsRatio = minimumSavingsRatio,
        metadataBytes = metadataBytes,
        maximumExpandedBytes = expanded,
    }),
        nil
end

-- Avoid literal-type narrowing across independent lane checks.
local function laneIs(lane: any, expected: string): boolean
    return lane == expected
end

function Config.routes(raw: any): ({ any }?, string?)
    if not denseArray(raw) or #raw < 1 or #raw > 256 then
        return nil, "invalid_routes"
    end
    local out: { any } = {}
    local ids = {}
    for index, route in ipairs(raw) do
        if type(route) ~= "table" or not integer(route.id, 1, 65535) or ids[route.id] then
            return nil, "invalid_route_id"
        end
        ids[route.id] = true
        if
            route.lane ~= "reliable"
            and route.lane ~= "unreliable"
            and route.lane ~= "request"
            and route.lane ~= "bulk"
        then
            return nil, "invalid_lane"
        end

        local frame = route.maximumFrameBytes
        if frame == nil then
            frame = if laneIs(route.lane, "unreliable") then 1000 else 4096
        end
        local payload = route.maximumPayloadBytes or math.max(0, frame - 32)
        local expanded = route.maximumExpandedBytes or payload
        if
            not integer(frame, 32, 1024 * 1024)
            or not integer(payload, 0, frame)
            or not integer(expanded, payload, 4 * 1024 * 1024)
        then
            return nil, "invalid_route_bounds"
        end
        if laneIs(route.lane, "unreliable") and frame > 1000 then
            return nil, "unreliable_frame_exceeds_platform_limit"
        end
        if route.schemaFingerprint ~= nil and not integer(route.schemaFingerprint, 0, U32) then
            return nil, "invalid_schema_fingerprint"
        end
        if route.responseFingerprint ~= nil and not integer(route.responseFingerprint, 0, U32) then
            return nil, "invalid_response_fingerprint"
        end

        local allowBatch = route.allowBatch == true
        local allowCompactBatch = route.allowCompactBatch == true
        if allowCompactBatch and not allowBatch then
            return nil, "compact_batch_requires_batch"
        end
        if allowBatch and not laneIs(route.lane, "reliable") and not laneIs(route.lane, "bulk") then
            return nil, "batch_forbidden_for_lane"
        end
        local maximumBatchItems = route.maximumBatchItems or 16
        local maximumBatchItemBytes = route.maximumBatchItemBytes or payload
        if
            allowBatch
            and (
                not integer(maximumBatchItems, 1, 1024)
                or not integer(maximumBatchItemBytes, 0, payload)
            )
        then
            return nil, "invalid_batch_bounds"
        end

        if
            laneIs(route.lane, "unreliable")
            and (allowBatch or route.allowOutboundCompression == true)
        then
            return nil, "unreliable_route_must_be_uncompressed_unbatched"
        end
        if laneIs(route.lane, "request") and route.allowOutboundCompression == true then
            return nil, "request_compression_forbidden"
        end
        local policy, policyError = compressionPolicy(route, expanded)
        if policyError then
            return nil, policyError
        end
        local compressionCodec = route.compressionCodec
        local compressionVersion = route.compressionVersion
        if route.allowOutboundCompression == true then
            if
                type(compressionCodec) ~= "string"
                or #compressionCodec < 1
                or #compressionCodec > 64
                or compressionCodec:find("[^%w%._%-]") ~= nil
                or not integer(compressionVersion, 1, 65535)
            then
                return nil, "invalid_compression_identity"
            end
        elseif compressionCodec ~= nil or compressionVersion ~= nil then
            return nil, "compression_identity_without_compression"
        end

        local routeRequests = if laneIs(route.lane, "request")
            then route.maximumOutstandingRequests or 16
            else 0
        if laneIs(route.lane, "request") and not integer(routeRequests, 1, 1024) then
            return nil, "invalid_route_request_limit"
        end

        local copy = table.clone(route)
        copy.maximumFrameBytes = frame
        copy.maximumPayloadBytes = payload
        copy.maximumExpandedBytes = expanded
        copy.maximumBatchItems = if allowBatch then maximumBatchItems else 0
        copy.maximumBatchItemBytes = if allowBatch then maximumBatchItemBytes else 0
        copy.maximumOutstandingRequests = routeRequests
        copy.allowBatch = allowBatch
        copy.allowCompactBatch = allowCompactBatch
        copy.allowOutboundCompression = route.allowOutboundCompression == true
        copy.compressionCodec = compressionCodec
        copy.compressionVersion = compressionVersion
        copy.compressionPolicy = policy
        out[index] = table.freeze(copy)
    end
    return table.freeze(out), nil
end

function Config.peer(options: any): (any?, string?)
    if type(options) ~= "table" or not integer(options.epoch, 1, U32) then
        return nil, "invalid_epoch"
    end
    local routes, err = Config.routes(options.routes)
    if not routes then
        return nil, err
    end
    local compressionCodec = nil
    local compressionVersion = nil
    for _, route in ipairs(routes) do
        if route.allowOutboundCompression then
            if
                (compressionCodec ~= nil and compressionCodec ~= route.compressionCodec)
                or (compressionVersion ~= nil and compressionVersion ~= route.compressionVersion)
            then
                return nil, "multiple_compression_identities"
            end
            compressionCodec = route.compressionCodec
            compressionVersion = route.compressionVersion
        end
    end
    if compressionCodec ~= nil then
        local compressor = options.compressor
        if
            type(compressor) ~= "table"
            or compressor.identity ~= compressionCodec
            or compressor.version ~= compressionVersion
            or type(compressor.compress) ~= "function"
            or type(compressor.decompressedSize) ~= "function"
            or type(compressor.decompress) ~= "function"
        then
            return nil, "compression_adapter_mismatch"
        end
    end
    local maximumRequests = options.maximumOutstandingRequests or 64
    local maximumTimeout = options.maximumRequestTimeout or 30
    local maximumQueuedReceiveBytes = options.maximumQueuedReceiveBytes or 1024 * 1024
    local maximumQueuedFrames = options.maximumQueuedFrames or 256
    local maximumReceiveFramesPerStep = options.maximumReceiveFramesPerStep or 32
    local ingressPackets = options.ingressPackets or {}
    if type(ingressPackets) ~= "table" then
        return nil, "invalid_peer_limits"
    end
    local ingressPacketCapacity = ingressPackets.capacity or 256
    local ingressPacketRefill = ingressPackets.refillPerSecond or 128
    if
        not integer(maximumRequests, 1, 1024)
        or not finite(maximumTimeout)
        or maximumTimeout <= 0
        or maximumTimeout > 300
        or not integer(maximumQueuedReceiveBytes, 1, 16 * 1024 * 1024)
        or not integer(maximumQueuedFrames, 1, 4096)
        or not integer(maximumReceiveFramesPerStep, 1, 256)
        or not finite(ingressPacketCapacity)
        or ingressPacketCapacity <= 0
        or ingressPacketCapacity > 100000
        or not finite(ingressPacketRefill)
        or ingressPacketRefill < 0
        or ingressPacketRefill > 100000
    then
        return nil, "invalid_peer_limits"
    end
    local copy = table.clone(options)
    copy.routes = routes
    copy.maximumOutstandingRequests = maximumRequests
    copy.maximumRequestTimeout = maximumTimeout
    copy.maximumQueuedReceiveBytes = maximumQueuedReceiveBytes
    copy.maximumQueuedFrames = maximumQueuedFrames
    copy.maximumReceiveFramesPerStep = maximumReceiveFramesPerStep
    copy.ingressPackets = table.freeze({
        capacity = ingressPacketCapacity,
        refillPerSecond = ingressPacketRefill,
    })
    if options.egress ~= nil then
        local egress, egressError = Egress.validate(options.egress)
        if not egress then
            return nil, egressError
        end
        copy.egress = egress
    end
    return copy, nil
end

return Config
