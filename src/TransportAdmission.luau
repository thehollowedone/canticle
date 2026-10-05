--!strict

local Admission = {}
type Bucket = { capacity: number, refill: number, tokens: number, last: number }
type RouteBucket = { raw: Bucket, expanded: Bucket }
type PeerBucket = {
    packets: Bucket,
    raw: Bucket,
    expanded: Bucket,
    routes: { [number]: RouteBucket },
}
type SharedBucket = { packets: Bucket, raw: Bucket, expanded: Bucket }
type Spec = { capacity: number, refill: number }

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteInteger(value: any, minimum: number): boolean
    return finite(value) and value == math.floor(value) and value >= minimum
end

local function makeBucket(capacity: number, refill: number, now: number): Bucket
    return { capacity = capacity, refill = refill, tokens = capacity, last = now }
end

local function refresh(bucket: Bucket, now: number)
    bucket.tokens =
        math.min(bucket.capacity, bucket.tokens + math.max(0, now - bucket.last) * bucket.refill)
    bucket.last = math.max(bucket.last, now)
end

local function readSpec(
    options: any,
    name: string,
    fallback: any,
    capacity: number,
    refill: number
): Spec
    local value = options[name] or fallback or {}
    local cap = value.capacity or capacity
    local rate = value.refillPerSecond or refill
    assert(finite(cap) and cap > 0 and finite(rate) and rate >= 0, "invalid admission limit")
    return { capacity = cap, refill = rate }
end

function Admission.new(options: any): any
    assert(type(options) == "table", "options required")
    local clock = options.clock or os.clock
    local function now(): number
        local ok, value = pcall(clock)
        assert(ok and finite(value), "clock failed")
        return value
    end

    local packet = readSpec(options, "packets", nil, 256, 128)
    local peerRaw = readSpec(options, "rawBytes", nil, 256 * 1024, 128 * 1024)
    local peerExpanded = readSpec(options, "expandedBytes", nil, 512 * 1024, 256 * 1024)
    local routeRaw = readSpec(options, "routeRawBytes", options.route, 128 * 1024, 64 * 1024)
    local routeExpanded =
        readSpec(options, "routeExpandedBytes", options.route, 256 * 1024, 128 * 1024)
    local sharedRaw =
        readSpec(options, "sharedRouteRawBytes", options.sharedRoute, 1024 * 1024, 512 * 1024)
    local sharedPackets = readSpec(options, "sharedRoutePackets", nil, 1024, 512)
    local sharedExpanded = readSpec(
        options,
        "sharedRouteExpandedBytes",
        options.sharedRoute,
        2 * 1024 * 1024,
        1024 * 1024
    )
    local globalRaw = readSpec(options, "globalRawBytes", nil, 4 * 1024 * 1024, 2 * 1024 * 1024)
    local globalPackets = readSpec(options, "globalPackets", nil, 4096, 2048)
    local globalExpanded =
        readSpec(options, "globalExpandedBytes", nil, 8 * 1024 * 1024, 4 * 1024 * 1024)

    local started = now()
    local gate = {
        clock = now,
        specs = {
            packet = packet,
            peerRaw = peerRaw,
            peerExpanded = peerExpanded,
            routeRaw = routeRaw,
            routeExpanded = routeExpanded,
            sharedRaw = sharedRaw,
            sharedExpanded = sharedExpanded,
            sharedPackets = sharedPackets,
        },
        peers = {} :: { [any]: PeerBucket },
        sharedRoutes = {} :: { [number]: SharedBucket },
        globalRaw = makeBucket(globalRaw.capacity, globalRaw.refill, started),
        globalExpanded = makeBucket(globalExpanded.capacity, globalExpanded.refill, started),
        globalPackets = makeBucket(globalPackets.capacity, globalPackets.refill, started),
        closed = false,
    }

    function gate:_peer(id: any)
        local peer: PeerBucket? = self.peers[id]
        if peer then
            return peer
        end
        local current = self.clock()
        local created: PeerBucket = {
            packets = makeBucket(packet.capacity, packet.refill, current),
            raw = makeBucket(peerRaw.capacity, peerRaw.refill, current),
            expanded = makeBucket(peerExpanded.capacity, peerExpanded.refill, current),
            routes = {},
        }
        self.peers[id] = created
        return created
    end

    function gate:_route(peer: any, route: number, current: number)
        local value: RouteBucket? = peer.routes[route]
        if value then
            return value
        end
        local created: RouteBucket = {
            raw = makeBucket(routeRaw.capacity, routeRaw.refill, current),
            expanded = makeBucket(routeExpanded.capacity, routeExpanded.refill, current),
        }
        peer.routes[route] = created
        return created
    end

    function gate:_shared(route: number, current: number)
        local value: SharedBucket? = self.sharedRoutes[route]
        if value then
            return value
        end
        local created: SharedBucket = {
            packets = makeBucket(sharedPackets.capacity, sharedPackets.refill, current),
            raw = makeBucket(sharedRaw.capacity, sharedRaw.refill, current),
            expanded = makeBucket(sharedExpanded.capacity, sharedExpanded.refill, current),
        }
        self.sharedRoutes[route] = created
        return created
    end

    function gate:admit(
        peerId: any,
        route: number,
        rawBytes: number,
        expandedBytes: number
    ): (boolean, string?)
        if
            self.closed
            or not finiteInteger(rawBytes, 0)
            or not finiteInteger(expandedBytes, 0)
            or not finiteInteger(route, 1)
        then
            return false, "invalid_admission"
        end

        local current = self.clock()
        local peer = self:_peer(peerId)
        local peerRoute = self:_route(peer, route, current)
        local sharedRoute = self:_shared(route, current)

        -- Check every bucket before charging any tokens.
        refresh(peer.packets, current)
        refresh(peer.raw, current)
        refresh(peer.expanded, current)
        refresh(peerRoute.raw, current)
        refresh(peerRoute.expanded, current)
        refresh(sharedRoute.packets, current)
        refresh(sharedRoute.raw, current)
        refresh(sharedRoute.expanded, current)
        refresh(self.globalPackets, current)
        refresh(self.globalRaw, current)
        refresh(self.globalExpanded, current)

        if peer.packets.tokens < 1 then
            return false, "peer_packets"
        end
        if peer.raw.tokens < rawBytes then
            return false, "peer_raw_bytes"
        end
        if peer.expanded.tokens < expandedBytes then
            return false, "peer_expanded_bytes"
        end
        if peerRoute.raw.tokens < rawBytes then
            return false, "peer_route_raw_bytes"
        end
        if peerRoute.expanded.tokens < expandedBytes then
            return false, "peer_route_expanded_bytes"
        end
        if sharedRoute.packets.tokens < 1 then
            return false, "shared_route_packets"
        end
        if sharedRoute.raw.tokens < rawBytes then
            return false, "shared_route_raw_bytes"
        end
        if sharedRoute.expanded.tokens < expandedBytes then
            return false, "shared_route_expanded_bytes"
        end
        if self.globalPackets.tokens < 1 then
            return false, "global_packets"
        end
        if self.globalRaw.tokens < rawBytes then
            return false, "global_raw_bytes"
        end
        if self.globalExpanded.tokens < expandedBytes then
            return false, "global_expanded_bytes"
        end

        peer.packets.tokens -= 1
        peer.raw.tokens -= rawBytes
        peer.expanded.tokens -= expandedBytes
        peerRoute.raw.tokens -= rawBytes
        peerRoute.expanded.tokens -= expandedBytes
        sharedRoute.packets.tokens -= 1
        sharedRoute.raw.tokens -= rawBytes
        sharedRoute.expanded.tokens -= expandedBytes
        self.globalPackets.tokens -= 1
        self.globalRaw.tokens -= rawBytes
        self.globalExpanded.tokens -= expandedBytes
        return true, nil
    end

    function gate:clearPeer(peerId: any)
        self.peers[peerId] = nil
    end

    function gate:close()
        self.closed = true
        table.clear(self.peers)
        table.clear(self.sharedRoutes)
    end

    return gate
end

return Admission
