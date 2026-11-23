--!strict

local Callbacks = if script
    then require(script.Parent.TransportCallbacks)
    else require("./TransportCallbacks")

local Egress = {}
type StepBudget = {
    maximumBytes: number,
    bytesRemaining: number,
    itemsRemaining: number,
    blocked: boolean,
}
type Entry = {
    key: any,
    frame: buffer,
    size: number,
    enqueuedAt: number,
    emit: (buffer) -> (),
    reliable: boolean,
    canSend: (() -> boolean)?,
}

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value: any, minimum: number, maximum: number): boolean
    return finite(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

function Egress.validate(options: any): (any?, string?)
    if type(options) ~= "table" then
        return nil, "invalid_egress"
    end

    local maximumItems = options.maximumItems or 256
    local maximumBytes = options.maximumBytes or 1024 * 1024
    local maximumAgeSeconds = options.maximumAgeSeconds or 1
    local maximumItemsPerStep = options.maximumItemsPerStep or 16
    local maximumBytesPerStep = options.maximumBytesPerStep or 64 * 1024
    local maximumLatestBurst = options.maximumLatestBurst or math.min(4, maximumItems)

    if
        not integer(maximumItems, 1, 4096)
        or not integer(maximumBytes, 1, 64 * 1024 * 1024)
        or not finite(maximumAgeSeconds)
        or maximumAgeSeconds <= 0
        or maximumAgeSeconds > 60
        or not integer(maximumItemsPerStep, 1, maximumItems)
        or not integer(maximumBytesPerStep, 1, maximumBytes)
        or not integer(maximumLatestBurst, 1, maximumItems)
    then
        return nil, "invalid_egress"
    end

    return table.freeze({
        maximumItems = maximumItems,
        maximumBytes = maximumBytes,
        maximumAgeSeconds = maximumAgeSeconds,
        maximumItemsPerStep = maximumItemsPerStep,
        maximumBytesPerStep = maximumBytesPerStep,
        maximumLatestBurst = maximumLatestBurst,
    }),
        nil
end

function Egress.new(
    options: any,
    clock: () -> number,
    onEvent: any,
    onFailure: any,
    budget: StepBudget?
): any
    local limits, err = Egress.validate(options)
    assert(limits, err)
    local queues: { [string]: { [number]: Entry? } } = { latest = {}, bulk = {} }
    local heads = { latest = 1, bulk = 1 }
    local tails = { latest = 0, bulk = 0 }
    local latestByKey: { [any]: Entry? } = {}
    local count = 0
    local bytes = 0
    local closed = false
    local stepping = false
    local latestSinceBulk = 0
    local scheduler = {}

    local function event(name: string, size: number?)
        if type(onEvent) == "function" then
            Callbacks.synchronous(onEvent, name, size)
        end
    end

    function scheduler:submit(
        kind: string,
        key: any,
        frame: buffer,
        emit: (buffer) -> (),
        reliable: boolean,
        canSend: (() -> boolean)?
    ): (boolean, string?)
        if closed then
            return false, "egress_closed"
        end

        if kind ~= "latest" and kind ~= "bulk" then
            return false, "invalid_egress_kind"
        end

        if canSend ~= nil and type(canSend) ~= "function" then
            return false, "invalid_send_guard"
        end

        local ok, now = Callbacks.synchronous(clock)

        if not ok or not finite(now) then
            return false, "clock_failed"
        end
        if closed then
            return false, "egress_closed"
        end

        local size = buffer.len(frame)
        local replaced = if kind == "latest" then latestByKey[key] else nil
        local prospectiveCount = count + (if replaced then 0 else 1)
        local prospectiveBytes = bytes + size - (if replaced then replaced.size else 0)

        if
            size > limits.maximumBytesPerStep
            or (budget ~= nil and size > budget.maximumBytes)
            or prospectiveCount > limits.maximumItems
            or prospectiveBytes > limits.maximumBytes
        then
            event("rejected", size)
            return false, "egress_capacity"
        end

        if replaced then
            replaced.frame = frame
            replaced.size = size
            replaced.enqueuedAt = now
            replaced.emit = emit
            replaced.reliable = reliable
            replaced.canSend = canSend
            bytes = prospectiveBytes
            event("coalesced", size)
            return true, "queued"
        end

        local entry: Entry = {
            key = key,
            frame = frame,
            size = size,
            enqueuedAt = now,
            emit = emit,
            reliable = reliable,
            canSend = canSend,
        }
        tails[kind] += 1
        queues[kind][tails[kind]] = entry
        if kind == "latest" then
            latestByKey[key] = entry
        end
        count = prospectiveCount
        bytes = prospectiveBytes
        event("queued", size)
        return true, "queued"
    end

    local function take(kind: string, entry: Entry)
        local queue = queues[kind]
        local head = heads[kind]
        queue[head] = nil
        heads[kind] = head + 1
        if kind == "latest" and latestByKey[entry.key] == entry then
            latestByKey[entry.key] = nil
        end
        count -= 1
        bytes -= entry.size
        if heads[kind] > tails[kind] then
            table.clear(queues[kind])
            heads[kind] = 1
            tails[kind] = 0
        end
    end

    function scheduler:hasPending(): boolean
        return count > 0
    end

    function scheduler:step(quantum: number?): number
        if closed or stepping then
            return 0
        end

        stepping = true
        local emitted = 0
        local emittedBytes = 0
        local processed = 0

        local maximum = math.min(quantum or limits.maximumItemsPerStep, limits.maximumItemsPerStep)
        while not closed and count > 0 and processed < maximum do
            local ok, now = Callbacks.synchronous(clock)
            if not ok or not finite(now) or closed then
                break
            end
            local hasLatest = queues.latest[heads.latest] ~= nil
            local hasBulk = queues.bulk[heads.bulk] ~= nil
            local kind = if hasLatest
                    and (not hasBulk or latestSinceBulk < limits.maximumLatestBurst)
                then "latest"
                else "bulk"
            local entry = queues[kind][heads[kind]]

            if not entry then
                break
            end
            if emitted > 0 and emittedBytes + entry.size > limits.maximumBytesPerStep then
                break
            end
            local shared = budget
            if shared then
                if shared.itemsRemaining <= 0 or entry.size > shared.bytesRemaining then
                    shared.blocked = true
                    break
                end
                shared.itemsRemaining -= 1
                shared.bytesRemaining -= entry.size
            end

            take(kind, entry)
            processed += 1
            if kind == "latest" then
                latestSinceBulk += 1
            else
                latestSinceBulk = 0
            end

            local expired = now - entry.enqueuedAt > limits.maximumAgeSeconds
            if not expired and entry.canSend then
                local called, allowed = Callbacks.synchronous(entry.canSend)
                if closed then
                    break
                end
                if not called or allowed ~= true then
                    event("withheld", entry.size)
                    continue
                end
                -- Authorization may run application code. Recheck age at the handoff.
                ok, now = Callbacks.synchronous(clock)
                if closed then
                    break
                end
                if not ok or not finite(now) then
                    event("failed", entry.size)
                    if entry.reliable then
                        Callbacks.synchronous(onFailure, "clock_failed")
                        break
                    end
                    continue
                end
                expired = now - entry.enqueuedAt > limits.maximumAgeSeconds
                if kind == "latest" and latestByKey[entry.key] ~= nil then
                    -- A newer value arrived for this key while its guard ran.
                    event("coalesced", entry.size)
                    continue
                end
            end
            if expired then
                event("expired", entry.size)
                if entry.reliable then
                    Callbacks.synchronous(onFailure, "egress_expired")
                    break
                end
            else
                local sent = pcall(entry.emit, entry.frame)

                if not sent then
                    event("failed", entry.size)
                    Callbacks.synchronous(onFailure, "transport_failed")
                    break
                end
                emitted += 1
                emittedBytes += entry.size
                event("emitted", entry.size)
            end
        end
        stepping = false
        return emitted
    end

    function scheduler:status(): any
        return { items = count, bytes = bytes }
    end

    function scheduler:close()
        if closed then
            return
        end
        closed = true
        table.clear(queues.latest)
        table.clear(queues.bulk)
        table.clear(latestByKey)
        heads.latest = 1
        heads.bulk = 1
        tails.latest = 0
        tails.bulk = 0
        latestSinceBulk = 0
        count = 0
        bytes = 0
    end

    return scheduler
end

return Egress
