--!strict

local TransportFrame = {}
local MAGIC = 0x4854
local VERSION = 2
local HEADER = 28
local U32 = 4294967295
local LANES = { reliable = 1, unreliable = 2, request = 3, response = 4, cancel = 5, bulk = 6 }
local NAMES = {
    [1] = "reliable",
    [2] = "unreliable",
    [3] = "request",
    [4] = "response",
    [5] = "cancel",
    [6] = "bulk",
}
local FLAG_COMPRESSED = 1
local FLAG_BATCH = 2
local FLAG_LATEST = 4
local FLAG_REQUEST = 8
local FLAG_COMPACT_BATCH = 16

local function laneRequiresRequestId(lane: string): boolean
    return lane == "request" or lane == "response" or lane == "cancel"
end

local function laneIs(lane: any, expected: string): boolean
    return lane == expected
end

local function integer(v: any, lo: number, hi: number): boolean
    return type(v) == "number"
        and v == v
        and v ~= math.huge
        and v ~= -math.huge
        and v == math.floor(v)
        and v >= lo
        and v <= hi
end

local function isBuffer(v: any): boolean
    return typeof(v) == "buffer"
end

function TransportFrame.encode(meta: any): (buffer?, string?)
    if type(meta) ~= "table" or not isBuffer(meta.payload) then
        return nil, "invalid_frame"
    end
    local lane = LANES[meta.lane]
    if
        lane == nil
        or not integer(meta.route, 1, 65535)
        or not integer(meta.epoch, 1, U32)
        or not integer(meta.sequence, 1, U32)
    then
        return nil, "invalid_frame_metadata"
    end
    local requestId = meta.requestId or 0
    if not integer(requestId, 0, U32) then
        return nil, "invalid_request_id"
    end
    if (requestId ~= 0) ~= laneRequiresRequestId(meta.lane) then
        return nil, "invalid_request_id"
    end
    local length = buffer.len(meta.payload)
    local expanded = meta.expandedSize or length
    if not integer(expanded, length, U32) then
        return nil, "invalid_expanded_size"
    end
    local flags = 0
    if meta.compressed == true then
        flags += FLAG_COMPRESSED
    end
    if meta.batch == true then
        flags += FLAG_BATCH
    end
    if meta.compactBatch == true then
        if meta.batch ~= true then
            return nil, "compact_batch_requires_batch"
        end
        flags += FLAG_COMPACT_BATCH
    end
    if meta.latest == true then
        flags += FLAG_LATEST
    end
    if requestId ~= 0 then
        flags += FLAG_REQUEST
    end
    if meta.compressed ~= true and expanded ~= length then
        return nil, "expanded_size_without_compression"
    end
    if meta.latest == true and meta.lane ~= "unreliable" then
        return nil, "latest_requires_unreliable"
    end
    if
        laneIs(meta.lane, "cancel")
        and (length ~= 0 or meta.compressed == true or meta.batch == true or meta.latest == true)
    then
        return nil, "invalid_cancel_frame"
    end
    local out = buffer.create(HEADER + length)
    buffer.writeu16(out, 0, MAGIC)
    buffer.writeu8(out, 2, VERSION)
    buffer.writeu8(out, 3, lane)
    buffer.writeu8(out, 4, flags)
    buffer.writeu8(out, 5, 0)
    buffer.writeu16(out, 6, meta.route)
    buffer.writeu32(out, 8, meta.epoch)
    buffer.writeu32(out, 12, meta.sequence)
    buffer.writeu32(out, 16, requestId)
    buffer.writeu32(out, 20, length)
    buffer.writeu32(out, 24, expanded)
    if length > 0 then
        buffer.copy(out, HEADER, meta.payload)
    end
    return out, nil
end

function TransportFrame.inspect(data: any, limits: any?): (any?, string?)
    if not isBuffer(data) then
        return nil, "frame_must_be_buffer"
    end
    local length = buffer.len(data)
    if length < HEADER then
        return nil, "truncated_header"
    end
    if buffer.readu16(data, 0) ~= MAGIC or buffer.readu8(data, 2) ~= VERSION then
        return nil, "protocol_mismatch"
    end
    local lane = NAMES[buffer.readu8(data, 3)]
    if not lane or buffer.readu8(data, 5) ~= 0 then
        return nil, "invalid_header"
    end
    local flags = buffer.readu8(data, 4)
    if bit32.band(flags, 0xE0) ~= 0 then
        return nil, "unknown_flags"
    end
    if bit32.band(flags, FLAG_COMPACT_BATCH) ~= 0 and bit32.band(flags, FLAG_BATCH) == 0 then
        return nil, "invalid_compact_batch_flag"
    end
    local route = buffer.readu16(data, 6)
    local epoch = buffer.readu32(data, 8)
    local sequence = buffer.readu32(data, 12)
    local requestId = buffer.readu32(data, 16)
    local payloadLength = buffer.readu32(data, 20)
    local expanded = buffer.readu32(data, 24)
    if route == 0 or epoch == 0 or sequence == 0 or length ~= HEADER + payloadLength then
        return nil, "invalid_header"
    end
    local compressed = bit32.band(flags, FLAG_COMPRESSED) ~= 0
    if not compressed and expanded ~= payloadLength then
        return nil, "invalid_expanded_size"
    end
    if expanded < payloadLength then
        return nil, "invalid_expanded_size"
    end
    local hasRequest = bit32.band(flags, FLAG_REQUEST) ~= 0
    if hasRequest ~= (requestId ~= 0) then
        return nil, "invalid_request_id"
    end
    if hasRequest ~= laneRequiresRequestId(lane) then
        return nil, "invalid_request_id"
    end
    local latest = bit32.band(flags, FLAG_LATEST) ~= 0
    if latest and lane ~= "unreliable" then
        return nil, "invalid_latest_flag"
    end
    if
        laneIs(lane, "cancel")
        and (payloadLength ~= 0 or compressed or bit32.band(flags, FLAG_BATCH) ~= 0 or latest)
    then
        return nil, "invalid_cancel_frame"
    end
    if limits then
        if limits.maximumFrameBytes and length > limits.maximumFrameBytes then
            return nil, "frame_too_large"
        end
        if limits.maximumPayloadBytes and payloadLength > limits.maximumPayloadBytes then
            return nil, "payload_too_large"
        end
        if limits.maximumExpandedBytes and expanded > limits.maximumExpandedBytes then
            return nil, "expanded_payload_too_large"
        end
    end
    return {
        lane = lane,
        flags = flags,
        route = route,
        epoch = epoch,
        sequence = sequence,
        requestId = if requestId == 0 then nil else requestId,
        payloadOffset = HEADER,
        payloadLength = payloadLength,
        expandedSize = expanded,
        compressed = compressed,
        batch = bit32.band(flags, FLAG_BATCH) ~= 0,
        compactBatch = bit32.band(flags, FLAG_COMPACT_BATCH) ~= 0,
        latest = latest,
        frameLength = length,
    },
        nil
end

function TransportFrame.materialize(data: buffer, meta: any): buffer
    local out = buffer.create(meta.payloadLength)
    if meta.payloadLength > 0 then
        buffer.copy(out, 0, data, meta.payloadOffset, meta.payloadLength)
    end
    return out
end

function TransportFrame.decode(data: any, limits: any?): (any?, string?)
    local meta, err = TransportFrame.inspect(data, limits)
    if not meta then
        return nil, err
    end
    meta.payload = TransportFrame.materialize(data, meta)
    return meta, nil
end

function TransportFrame.encodeBatch(items: any, limits: any?): (buffer?, string?)
    if type(items) ~= "table" then
        return nil, "invalid_batch"
    end
    local maxItems = if limits and limits.maximumItems then limits.maximumItems else 64
    local maxItem = if limits and limits.maximumItemBytes then limits.maximumItemBytes else 65535
    local maxPayload = if limits and limits.maximumPayloadBytes
        then limits.maximumPayloadBytes
        else 1024 * 1024
    if #items < 1 or #items > maxItems then
        return nil, "batch_item_count"
    end
    local length = #items
    local count = 0
    for key in items do
        if not integer(key, 1, length) then
            return nil, "invalid_batch"
        end
        count += 1
    end
    if count ~= length then
        return nil, "invalid_batch"
    end
    local total = 2
    for index = 1, length do
        local item = items[index]
        if not isBuffer(item) or buffer.len(item) > maxItem then
            return nil, "batch_item_invalid"
        end
        total += 4 + buffer.len(item)
        if total > maxPayload then
            return nil, "batch_too_large"
        end
    end
    local out = buffer.create(total)
    buffer.writeu16(out, 0, #items)
    local offset = 2
    for index = 1, length do
        local item = items[index]
        local n = buffer.len(item)
        buffer.writeu32(out, offset, n)
        offset += 4
        if n > 0 then
            buffer.copy(out, offset, item)
        end
        offset += n
    end
    return out, nil
end

function TransportFrame.decodeBatch(data: any, limits: any?): ({ buffer }?, string?)
    if not isBuffer(data) or buffer.len(data) < 2 then
        return nil, "invalid_batch"
    end
    local count = buffer.readu16(data, 0)
    local maxItems = if limits and limits.maximumItems then limits.maximumItems else 64
    local maxItem = if limits and limits.maximumItemBytes then limits.maximumItemBytes else 65535
    local maxPayload = if limits and limits.maximumPayloadBytes
        then limits.maximumPayloadBytes
        else 1024 * 1024
    if count < 1 or count > maxItems or buffer.len(data) > maxPayload then
        return nil, "batch_item_count"
    end
    local offset = 2
    local out = table.create(count)
    for i = 1, count do
        if offset > buffer.len(data) - 4 then
            return nil, "truncated_batch"
        end
        local n = buffer.readu32(data, offset)
        offset += 4
        if n > maxItem or offset > buffer.len(data) - n then
            return nil, "invalid_batch_item"
        end
        local item = buffer.create(n)
        if n > 0 then
            buffer.copy(item, 0, data, offset, n)
        end
        offset += n
        out[i] = item
    end
    if offset ~= buffer.len(data) then
        return nil, "trailing_batch_bytes"
    end
    return out, nil
end

TransportFrame.HEADER_BYTES = HEADER
TransportFrame.VERSION = VERSION
return TransportFrame
