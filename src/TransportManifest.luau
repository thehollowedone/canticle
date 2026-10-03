--!strict

local Config = if script
    then require(script.Parent.TransportConfig)
    else require("./TransportConfig")
local Manifest = {}
local U32 = 4294967295

local function integer(value: any, minimum: number, maximum: number): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function hash(text: string): number
    local value = 2166136261
    for index = 1, #text do
        value = bit32.bxor(value, string.byte(text, index))
        value = (value * 16777619) % 4294967296
    end
    return value
end

local function policyFields(route: any): { string }
    local policy = route.compressionPolicy
    if not policy then
        return { "0", "0", "0", "0" }
    end
    return {
        tostring(policy.minimumBytes),
        tostring(policy.minimumSavingsBytes),
        string.format("%.17g", policy.minimumSavingsRatio),
        tostring(policy.metadataBytes),
    }
end

function Manifest.build(routes: any): (any?, string?)
    local normalized, err = Config.routes(routes)
    if not normalized then
        return nil, err
    end
    local rows = {}
    for _, route in ipairs(normalized) do
        local compression = policyFields(route)
        rows[#rows + 1] = table.concat({
            route.id,
            route.lane,
            route.maximumFrameBytes,
            route.maximumPayloadBytes,
            route.maximumExpandedBytes,
            if route.schemaFingerprint == nil then "none" else tostring(route.schemaFingerprint),
            if route.responseFingerprint == nil
                then "none"
                else tostring(route.responseFingerprint),
            tostring(route.allowBatch == true),
            tostring(route.allowCompactBatch == true),
            route.maximumBatchItems,
            route.maximumBatchItemBytes,
            route.maximumOutstandingRequests,
            tostring(route.allowOutboundCompression == true),
            tostring(route.compressionCodec or ""),
            tostring(route.compressionVersion or 0),
            compression[1],
            compression[2],
            compression[3],
            compression[4],
        }, ":")
    end
    table.sort(rows)
    return table.freeze({
        version = 3,
        fingerprint = hash(table.concat(rows, "|")),
        routes = normalized,
    }),
        nil
end

function Manifest.matches(localManifest: any, version: any, fingerprint: any): boolean
    return type(localManifest) == "table"
        and integer(localManifest.version, 1, 65535)
        and integer(localManifest.fingerprint, 0, U32)
        and integer(version, 1, 65535)
        and integer(fingerprint, 0, U32)
        and version == localManifest.version
        and fingerprint == localManifest.fingerprint
end

return Manifest
