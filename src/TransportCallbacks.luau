--!strict

local Callbacks = {}

function Callbacks.cancel(thread: thread): boolean
    if coroutine.status(thread) == "dead" then
        return true
    end
    if coroutine.running() == thread then
        return false
    end
    if script then
        pcall(task.cancel, thread)
    end
    if coroutine.status(thread) ~= "dead" then
        pcall(coroutine.close, thread)
    end
    return coroutine.status(thread) == "dead"
end

-- Setup, settlement and instrumentation must never retain an unowned task.
-- Yielding application listeners are owned separately by TransportPeer.
function Callbacks.synchronous(callback: any, ...): (boolean, ...any)
    if type(callback) ~= "function" then
        return false, "invalid_callback"
    end
    if callback == os.clock then
        return true, os.clock()
    end
    local thread = coroutine.create(callback)
    local result = table.pack(coroutine.resume(thread, ...))
    if coroutine.status(thread) ~= "dead" then
        Callbacks.cancel(thread)
        return false, "callback_yielded"
    end
    return table.unpack(result, 1, result.n)
end

return Callbacks
