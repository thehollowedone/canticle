# API guide

Require the Canticle package root. Compile schemas and routes once at startup; use the same protocol on both peers.

## Schemas

`Codec.compile(schema)` returns `codec, nil` or `nil, reason`. A codec exposes
`fingerprint`, `maximumBytes` and `maximumDecodedValues`.

Compilation rejects schemas whose worst-case decoded traversal exceeds 65,536
values with `schema_decoded_too_large`. This includes nested arrays of zero-byte
enums or empty records. The count includes containers, primitive values and
absent optional-field visits. Use it to bound traversal work; measure heap use
separately.

| Type | Fields |
| --- | --- |
| `boolean` | No additional fields. |
| `number` | Optional `min`, `max`, and `encoding` (`f32` or default `f64`); values must be finite. |
| `integer` | Required `min`, `max` within the supported 32-bit range; optional `encoding`: `auto`, `varint`, `u8`, `i8`, `u16`, `i16`, `u32`, `i32`. |
| `string` | Required `maxLength`, optional `minLength`; lengths are bytes. |
| `enum` | `values`: ordered, unique strings. |
| `array` | `items`: schema; required `maxLength`, optional `minLength`. Boolean arrays may use `encoding = "packed"`. |
| `object` | Ordered `fields`: `{ name, schema, optional? }`. |

Field order, bounds, and encoding affect compatibility. Optional fields use a presence bitmap. Decoders reject malformed, noncanonical, out-of-range, and trailing data.

| Codec method | Result |
| --- | --- |
| `encode(value)` | `buffer?, reason?` |
| `decode(bytes)` | `ok, value?, reason?` |
| `encodeBatch(values, limits?)` / `encodeCompactBatch(values, limits?)` | `buffer?, reason?` |
| `decodeBatch(bytes, limits?)` / `decodeCompactBatch(bytes, limits?)` | `ok, values?, reason?` |

Batch methods accept `maximumItems`, `maximumItemBytes`, `maximumPayloadBytes`
and `maximumDecodedValues`. Each ordinary or compact batch has a hard
262,144-value allowance, including its outer slots. Set `maximumDecodedValues`
to an integer from 1 through 262,144 to lower that allowance. Exceeding it returns
`decoded_work_limit` before the next allocation or traversal. Generated client
encoders, including trusted mode, and native decoders enforce the same allowance.
Schema fingerprints and wire encoding are unchanged by these traversal limits.

Compact batches omit item-length headers and require route opt-in.

## Routes and remotes

Create a reliable RemoteEvent and a separate handshake RemoteEvent on the server. Add an UnreliableRemoteEvent only if needed. Both sides use the same routes and `Manifest.build(routes)` result.

```lua
local codec = assert(Canticle.Codec.compile({ type = "integer", min = 1, max = 32 }))
local routes = assert(Canticle.Config.routes({
    {
        id = 1, lane = "reliable",
        schemaFingerprint = codec.fingerprint,
        maximumFrameBytes = 128,
        maximumPayloadBytes = codec.maximumBytes,
    },
}))
local manifest = assert(Canticle.Manifest.build(routes))
```

With `Canticle`, `codec`, `routes`, `manifest`, and the two remotes available in each script:

```lua
-- Server
local server = Canticle.Remote.server(reliableRemote, nil, function(player)
    return { routes = routes }
end, {
    handshakeRemote = handshakeRemote,
    manifest = manifest,
    onPeer = function(player, peer)
        Canticle.Channel.bind(peer, 1, codec):on(function(value, context)
            -- value: decoded integer; context: route metadata.
        end)
    end,
})
```

```lua
-- Client
local peer, close = Canticle.Remote.client(reliableRemote, nil, {
    routes = routes,
    manifest = manifest,
    handshakeRemote = handshakeRemote,
    bindPeer = function(peer)
        -- Register incoming listeners here, before readiness.
    end,
})
local channel = Canticle.Channel.bind(peer, 1, codec)
local ok, reason = channel:send(4)
-- Call close() when the owning client lifecycle ends.
```

The adapter handles readiness, Heartbeat progress and player departure.
`Remote.client()` raises an error if the handshake or readiness confirmation
fails. Use `pcall` around setup when the game needs to handle a failed connection.
`server:findPeer(player)` returns an existing peer; `server:removePeer(player)`
retires one player; `server:destroy()` shuts down the adapter. Both peers must
have matching manifests before they become ready.

Route lanes: `reliable`, `unreliable`, `request`, `bulk`. Relevant options:

| Options | Purpose |
| --- | --- |
| `maximumFrameBytes`, `maximumPayloadBytes`, `maximumExpandedBytes` | Bound wire and expanded sizes. |
| `schemaFingerprint`, `responseFingerprint` | Identify the event/request and response codecs. |
| `allowBatch`, `maximumBatchItems`, `maximumBatchItemBytes` | Batching on reliable/bulk routes; up to 1,024 items. |
| `allowCompactBatch` | Requires `allowBatch` and a compact decoder listener. |
| `maximumOutstandingRequests` | Per-request-route concurrency cap. |

## Channels

`Channel.bind(peer, routeId, codec, responseCodec?)` binds value codecs to a route.

| Method | Behavior |
| --- | --- |
| `send(value, latest?)` | Returns `ok, reason?`. On an unreliable route, `latest = true` enables replaceable coalescing through the peer's egress scheduler. |
| `sendBatch(values, compact?)` | Returns `ok, reason?`. |
| `on(callback, rejected?)` | Calls `callback(value, context)` on valid input; returns an unsubscribe function. |
| `onBatch(callback)` | Calls `callback(values, context)`; returns an unsubscribe function. |
| `request(value, timeout, callback)` | Returns `requestId?, reason?`; callback receives `ok, response?, reason?`. Requires a response codec. |
| `respond(requestId, value)` | Returns `ok, reason?`; requires a response codec. |
| `cancel(requestId)` | Returns `ok, reason?`. |

Malformed single values reach the optional rejection callback. Route fingerprints
detect codec mismatches during setup and batch sending.

Bulk sends and `latest = true` require a peer egress configuration. Pass
`egress = {}` in the client options, server peer factory result or raw peer
options to use the scheduler's defaults. `latest = true` is accepted only on
unreliable routes.

A request listener receives its ID in `context.requestId`. Reply through
`channel:respond(context.requestId, value)` using the response codec bound to
that channel.

## Raw peers and limits

`Peer.new(options)` requires `epoch`, `routes`, and `sendReliable`; add `sendUnreliable` for unreliable routes. Raw payload methods accept buffers:

- `on(route, callback)`, `onCancel(route, callback)`: unsubscribe functions.
- `send(route, payload, latest?)`, `sendBatch(route, buffers)`: `ok, reason?`.
- `onBatchValues(route, codec, callback)`, `sendBatchValues(route, codec, values)`, `sendCompactBatchValues(route, codec, values)`.
- `request(route, payload, timeout, callback)`, `respond(route, requestId, payload)`, `cancel(route, requestId)`.
- `receive(frame, carrier?)`, `step()`, `status()`, `destroy()`.

Call `step()` regularly to drain backlog and expire requests; call `destroy()` on retirement. The remote adapter does both automatically.

Peer limits include `maximumOutstandingRequests`, `maximumRequestTimeout`, `maximumQueuedFrames`, `maximumQueuedReceiveBytes`, `ingressPackets`, and `maximumReceiveFramesPerStep` (default 32, maximum 256).

The server adapter owns a shared `Admission` gate; configure budgets through `lifecycle.admission`. Raw peers can supply `admit(route, rawBytes, expandedBytes)` and an early `attempt` gate. `Admission`, `AttemptAdmission`, `Egress`, `Compression`, `Frame`, and `Metrics` are also exported for custom integrations.

Unreliable frames are capped at 1,000 bytes including headers; batching and compression are unsupported on this lane. Compression requires route opt-in, a versioned codec identity, and expanded-size limits. Request routes do not support compression. Raw and expanded sizes count toward admission before decompression.

## Generated batch codecs

From a source checkout:

```powershell
lune run tools/generate-codec.luau -- schema.json generated
```

Supported schemas: packed Boolean arrays or arrays of records with 1–16 required unsigned byte fields. Output:

- `Client.luau`: checked `encodeBatch`, `encodeCompactBatch`, `fingerprint`, `maximumBytes`, `maximumDecodedValues`, `validatesOutgoing`.
- `Server.luau`: bounded `decodeBatch`, `decodeCompactBatch`, `fingerprint`, `maximumBytes`, `maximumDecodedValues`.

Use the encoder with batch sends and the decoder with `onBatchValues`; single values use the runtime codec. Keep server decoders in ServerScriptService. The separate `generate-client-codec.luau` and `generate-native-codec.luau` tools accept a schema path and an output file.

Optional `--trust-outbound` skips outgoing primitive checks. Structural/allocation limits and server validation remain active; invalid local primitives may be coerced or throw. Generated modules request native compilation with ordinary Luau fallback. Batch memoization is scoped to one call and disabled for metatable-bearing inputs.

## Receive budgets and terminal recovery

`maximumReceiveFramesPerStep` limits all frame dispatches between `peer:step()`
calls. Separate remote callbacks do not refill it. Excess frames wait in the
bounded FIFO. The listener runs when the peer drains that frame from the queue.
Call `step()` regularly when using a peer without the Remote adapter.

Terminal overload removes the server peer and marks its session closed. The
same challenge cannot reopen that epoch. The client retains its handshake
listener and exposes `status().terminalReason`, including `remote_closed`.
Pending requests settle once; no application operation is replayed automatically.
Create a new client with a fresh challenge to reconnect, and reconcile any
consequential operation whose result is unknown before retrying it.

Terminal control messages use the existing handshake remote. The server sends
at most three notifications per terminal session, at least 0.5 seconds apart,
from heartbeat stepping or validated handshake traffic. Delivery is best effort:
if all notifications are lost, an application timeout and explicit reconnect are
still needed. Update client and server together. Old clients do not understand
terminal notifications.

Request settlement, metrics, and terminal callbacks must not yield; yielding
callbacks are cancelled. Teardown releases retained state before notifying the
adapter or settling pending requests. Receive listeners keep their existing
yielding behavior while the peer is live. On retirement, suspended receives
(including queued listeners and decoders) are cancelled so their waiting stacks
and payloads cannot outlive the peer. The waiting caller resumes with `false, terminalReason` so its cleanup can run.
Cancelling the caller retires its worker on the next `step()` or peer teardown.

## Reliable capacity and admission sizing

Unreliable traffic cannot spend `ingressReliableReserve` packet tokens. Its
default is min(16, floor(ingress packet capacity / 4)). Queued unreliable frames
also respect `receiveQueueReliableReserve = { frames, bytes }`: defaults reserve
min(8, ceil(queue frame capacity / 4)) slots and enough bytes for the largest
reliable frame, capped by queue capacity. Both reserves may be set to zero.
The reserves divide existing capacity. Size the queue and reliable budgets for
the expected workload; reliable traffic can still exhaust its available capacity.

Admission keeps its shared-route default of 1,024 burst tokens and 512 tokens per
second. Twenty clients sending 30 updates per second need 600 tokens per second
on that route. Increase the sustained allowance to support that rate; a larger
burst alone still runs out under sustained traffic. Measure frame
sizes, dispatch cost, and desired update frequency before changing budgets.
For a measured 600/s route, a bounded override such as
`routeLimits = { [routeId] = { sharedRoutePackets = { capacity = 1024, refillPerSecond = 660 } } }`
provides some headroom without changing other routes.

At most 256 route IDs (1..65535) may have overrides. Supported fields are
`sharedRoutePackets`, `sharedRouteRawBytes`, and `sharedRouteExpandedBytes`.
Capacities must be finite, positive, and at most 1e9; refill rates must be finite,
nonnegative, and at most 1e9. Peer and global packet/raw/expanded buckets also
reserve a default 12.5% for reliable work when the adapter identifies an
unreliable route; `reliableReserveFraction` accepts 0..0.5.

`Admission:status()` and the server adapter's `status().admission` expose accepted
counts and fixed-reason denial counts. Valid reliable frames denied by ordinary
admission still consume their sequence position. Detect missing application
work through request timeouts, acknowledgements or state reconciliation.
Terminal queue or ingress overload closes the session and retires the peer.

The server Remote adapter shares a 128-frame receive budget per step (configurable
from 1 to 4096 with `settings.maximumReceiveFramesPerStep`) and rotates the first
peer served. A suspended listener does not prevent later steps serving other peers.
