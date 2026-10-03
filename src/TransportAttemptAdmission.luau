--!strict

local AttemptAdmission = {}

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function policy(value: any, defaultCapacity: number, defaultRefill: number): any
    local source = value or {}
    assert(type(source) == "table", "attempt admission policy must be a table")
    local capacity = source.capacity or defaultCapacity
    local refill = source.refillPerSecond or defaultRefill
    assert(finite(capacity) and capacity > 0, "attempt admission capacity must be positive")
    assert(finite(refill) and refill >= 0, "attempt admission refill must be nonnegative")
    return table.freeze({ capacity = capacity, refillPerSecond = refill })
end

local function refill(bucket: any, setting: any, now: number)
    local elapsed = math.max(0, now - bucket.last)
    bucket.packets = math.min(
        setting.packets.capacity,
        bucket.packets + elapsed * setting.packets.refillPerSecond
    )
    bucket.bytes =
        math.min(setting.bytes.capacity, bucket.bytes + elapsed * setting.bytes.refillPerSecond)
    bucket.last = math.max(bucket.last, now)
end

function AttemptAdmission.new(options: any?): any
    local settings = options or {}
    local clock = settings.clock or os.clock
    assert(type(clock) == "function", "attempt admission clock required")
    local peerSetting = {
        packets = policy(settings.packets, 512, 256),
        bytes = policy(settings.rawBytes, 512 * 1024, 256 * 1024),
    }
    local globalSetting = {
        packets = policy(settings.globalPackets, 8192, 4096),
        bytes = policy(settings.globalRawBytes, 8 * 1024 * 1024, 4 * 1024 * 1024),
    }
    local ok, initial = pcall(clock)
    assert(ok and finite(initial), "attempt admission clock failed")
    local peers = {}
    local global = {
        packets = globalSetting.packets.capacity,
        bytes = globalSetting.bytes.capacity,
        last = initial,
    }
    local closed = false
    local admission = {}

    function admission:admit(peer: any, rawBytes: any): (boolean, string?)
        if closed or peer == nil or not finite(rawBytes) or rawBytes < 0 then
            return false, if closed then "closed" else "invalid_admission"
        end
        local called, now = pcall(clock)
        if not called or not finite(now) then
            return false, "invalid_admission"
        end
        local bucket = peers[peer]
        if not bucket then
            bucket = {
                packets = peerSetting.packets.capacity,
                bytes = peerSetting.bytes.capacity,
                last = now,
            }
            peers[peer] = bucket
        end
        refill(bucket, peerSetting, now)
        refill(global, globalSetting, now)
        if bucket.packets < 1 then
            return false, "attempt_peer_packets"
        end
        if bucket.bytes < rawBytes then
            return false, "attempt_peer_raw_bytes"
        end
        if global.packets < 1 then
            return false, "attempt_global_packets"
        end
        if global.bytes < rawBytes then
            return false, "attempt_global_raw_bytes"
        end
        bucket.packets -= 1
        bucket.bytes -= rawBytes
        global.packets -= 1
        global.bytes -= rawBytes
        return true, nil
    end

    function admission:clearPeer(peer: any)
        peers[peer] = nil
    end

    function admission:close()
        closed = true
        table.clear(peers)
    end

    return admission
end

return AttemptAdmission
