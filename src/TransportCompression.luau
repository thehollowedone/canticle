--!strict

local TransportCompression = {}

export type Adapter = {
    identity: string,
    version: number,
    compress: (buffer) -> buffer,
    decompressedSize: (buffer) -> number,
    decompress: (buffer) -> buffer,
}
export type Policy = {
    minimumBytes: number?,
    minimumSavingsBytes: number?,
    minimumSavingsRatio: number?,
    metadataBytes: number?,
    maximumExpandedBytes: number?,
}

local DEFAULT_MINIMUM_BYTES = 256
local DEFAULT_MINIMUM_SAVINGS_BYTES = 32
local DEFAULT_MINIMUM_SAVINGS_RATIO = 0.10
local DEFAULT_METADATA_BYTES = 4
local DEFAULT_MAXIMUM_EXPANDED_BYTES = 4 * 1024 * 1024
local MAXIMUM_U32 = 4294967295

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteInteger(value: any, minimum: number, maximum: number): boolean
    return finite(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isBuffer(value: any): boolean
    return typeof(value) == "buffer"
end

local function resolvedPolicy(
    policy: Policy?
): (number?, number?, number?, number?, number?, string?)
    local minimumBytes = if policy and policy.minimumBytes
        then policy.minimumBytes
        else DEFAULT_MINIMUM_BYTES
    local minimumSavingsBytes = if policy and policy.minimumSavingsBytes
        then policy.minimumSavingsBytes
        else DEFAULT_MINIMUM_SAVINGS_BYTES
    local minimumSavingsRatio = if policy and policy.minimumSavingsRatio
        then policy.minimumSavingsRatio
        else DEFAULT_MINIMUM_SAVINGS_RATIO
    local metadataBytes = if policy and policy.metadataBytes
        then policy.metadataBytes
        else DEFAULT_METADATA_BYTES
    local maximumExpandedBytes = if policy and policy.maximumExpandedBytes
        then policy.maximumExpandedBytes
        else DEFAULT_MAXIMUM_EXPANDED_BYTES
    if
        not finiteInteger(minimumBytes, 0, MAXIMUM_U32)
        or not finiteInteger(minimumSavingsBytes, 0, MAXIMUM_U32)
        or not finite(minimumSavingsRatio)
        or minimumSavingsRatio < 0
        or minimumSavingsRatio > 1
        or not finiteInteger(metadataBytes, 0, MAXIMUM_U32)
        or not finiteInteger(maximumExpandedBytes, 0, MAXIMUM_U32)
    then
        return nil, nil, nil, nil, nil, "invalid_policy"
    end
    return minimumBytes,
        minimumSavingsBytes,
        minimumSavingsRatio,
        metadataBytes,
        maximumExpandedBytes,
        nil
end

function TransportCompression.maybeCompress(
    payload: any,
    adapter: Adapter?,
    policy: Policy?
): (buffer?, boolean, number?, string?)
    if not isBuffer(payload) then
        return nil, false, nil, "payload_must_be_buffer"
    end
    local rawBytes = buffer.len(payload)
    local minimumBytes, minimumSavingsBytes, minimumSavingsRatio, metadataBytes, maximumExpandedBytes, policyError =
        resolvedPolicy(policy)
    if policyError ~= nil then
        return nil, false, nil, policyError
    end
    if rawBytes > (maximumExpandedBytes :: number) then
        return nil, false, nil, "expanded_payload_too_large"
    end
    if adapter == nil or rawBytes < (minimumBytes :: number) then
        return payload, false, nil, nil
    end
    local called, compressed = pcall(adapter.compress, payload)
    if not called or not isBuffer(compressed) then
        return payload, false, nil, nil
    end
    local compressedBytes = buffer.len(compressed)
    if compressedBytes >= rawBytes then
        return payload, false, nil, nil
    end
    local savings = rawBytes - compressedBytes - (metadataBytes :: number)
    local ratio = if rawBytes == 0 then 0 else savings / rawBytes
    if savings < (minimumSavingsBytes :: number) or ratio < (minimumSavingsRatio :: number) then
        return payload, false, nil, nil
    end
    return compressed, true, rawBytes, nil
end

function TransportCompression.decompress(
    payload: any,
    expandedSize: any,
    adapter: Adapter?,
    maximumExpandedBytes: number?
): (buffer?, string?)
    if not isBuffer(payload) then
        return nil, "payload_must_be_buffer"
    end
    local maximum = maximumExpandedBytes or DEFAULT_MAXIMUM_EXPANDED_BYTES
    if
        not finiteInteger(maximum, 0, MAXIMUM_U32)
        or not finiteInteger(expandedSize, 0, maximum)
    then
        return nil, "invalid_expanded_size"
    end
    if adapter == nil then
        return nil, "compression_unavailable"
    end
    local sizeCalled, preflightSize = pcall(adapter.decompressedSize, payload)
    if
        not sizeCalled
        or not finiteInteger(preflightSize, 0, maximum)
        or preflightSize ~= expandedSize
    then
        return nil, "decompression_preflight_failed"
    end
    local called, result = pcall(adapter.decompress, payload)
    if not called or not isBuffer(result) then
        return nil, "decompression_failed"
    end
    if buffer.len(result) ~= expandedSize then
        return nil, "decompressed_size_mismatch"
    end
    return result, nil
end

return TransportCompression
