# API guide

The package root exposes the full transport API. For a narrower dependency,
require the `TransportCodec`, `TransportConfig`, or `TransportManifest` child
ModuleScript directly. The codec and route configuration each load a single
module. Manifest creation also loads route configuration. Configuring a peer
with `options.egress` loads the scheduler. Compile schemas and routes once at
startup and use the same protocol on both peers.

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
| `number` | Optional `min`, `max`, and `encoding` (`f32` or default `f64`). For `f32`, both the input and the rounded wire value must be finite and within bounds. |
| `integer` | Required `min`, `max` within the supported 32-bit range; optional `encoding`: `auto`, `varint`, `u8`, `i8`, `u16`, `i16`, `u32`, `i32`. |
| `string` | Required `maxLength`, optional `minLength`; lengths are bytes. |
| `enum` | `values`: ordered, unique strings. |
| `array` | `items`: schema; required `maxLength`, optional `minLength`. Boolean arrays may use `encoding = "packed"`. |
| `object` | Ordered `fields`: `{ name, schema, optional? }`. |

Object fields and enum values must be dense lists indexed from one. A negative
integer minimum and a maximum above 2,147,483,647 cannot fit the same supported
encoding. Compilation rejects these declarations before a codec can be used.

Field order, bounds and encoding affect compatibility. Canticle escapes `%`,
`,`, `:`, `{`, `}`, `|`, `?` and `!` in enum labels and object field names
when computing the schema fingerprint. Optional fields use a
presence bitmap in declaration order, starting at the low bit. Unused high bits
in the final byte must be zero. Decoders reject malformed, noncanonical,
out-of-range, and trailing data.

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
| `maximumRequestBytes` | Optional request payload cap in bytes. Defaults to `maximumPayloadBytes`. A tighter cap changes the route fingerprint. Responses keep the full payload allowance. |

## Channels

`Channel.bind(peer, routeId, codec, responseCodec?)` binds value codecs to a route.

| Method | Behavior |
| --- | --- |
| `send(value, latest?, canSend?)` | Returns `ok, reason?`. On an unreliable route, `latest = true` lets a newer update replace a queued one. |
| `sendBatch(values, compact?, canSend?)` | Returns `ok, reason?`. A single permission check covers the entire batch. |
| `on(callback, rejected?)` | Calls `callback(value, context)` on valid input; returns an unsubscribe function. |
| `onBatch(callback)` | Calls `callback(values, context)`; returns an unsubscribe function. |
| `request(value, timeout, callback)` | Returns `requestId?, reason?`; callback receives `ok, response?, reason?`. Requires a response codec. |
| `respond(requestId, value)` | Returns `ok, reason?`; requires a response codec. |
| `cancel(requestId)` | Returns `ok, reason?`. |

Malformed single values reach the optional rejection callback. Set
`schemaFingerprint` on the route to have Canticle check the bound event or request
codec. Set `responseFingerprint` to check a request route’s response codec.
Both peers include the configured fingerprints in their handshake manifests.

Bulk sends and `latest = true` require a peer egress configuration. Pass
`egress = {}` in the client options, server peer factory result or raw peer
options to use the scheduler's defaults. `latest = true` is accepted only on
unreliable routes.

For private data, pass a server-side `canSend` function that reads the recipient's
current permission for the data in this message. For example, an application with
viewer-specific records can send a snapshot on a bulk channel this way.

```lua
local recordId = snapshot.id
local ok, reason = channel:send(snapshot, nil, function()
    return permissions:canView(player, recordId)
end)
```

Canticle checks immediately before handing the frame to the transport. The
function must finish synchronously and return `true` to release the frame.
An immediate send returns `false, "send_withheld"` if the check refuses, errors,
or yields.
For queued sends, `true, "queued"` means the queue accepted the message. If
permission is revoked before delivery, the sender withholds that frame. The
receiver gets subsequent eligible bulk messages with consecutive sequence numbers. A replacement latest
update carries its own check. When visibility differs across batch items,
group items by permission or supply a check that covers every item.
If a custom transport adapter buffers the frame again, it must check current
permission when it releases that second queue.

The scheduler measures each queued frame's age at delivery. Frames older than
`egress.maximumAgeSeconds` expire. Expired latest updates are dropped and
expired reliable bulk terminates the peer with `egress_expired`.

`Remote.server` shares a queued-send allowance across its peers on each step.
The lifecycle settings `maximumEgressItemsPerStep` and `maximumEgressBytesPerStep`
default to 256 entries and 4 MiB. Each attempted queued entry uses its full wire
size, including headers. Waiting peers take turns, and a frame too large for a
whole step returns `egress_capacity` at enqueue. Receive work and request
timeouts keep their own scheduling. Inspect `server:status().egressItemsRemaining`
and `server:status().egressBytesRemaining` for the unused allowance in this step.

A request listener receives its ID in `context.requestId`. Reply through
`channel:respond(context.requestId, value)` using the response codec bound to
that channel.

## Raw peers and limits

`Peer.new(options)` requires `epoch`, `routes`, and `sendReliable`; add `sendUnreliable` for unreliable routes. Raw payload methods accept buffers:

- `on(route, callback)`, `onCancel(route, callback)`: unsubscribe functions.
- `send(route, payload, latest?, canSend?)`, `sendBatch(route, buffers, canSend?)`: `ok, reason?`.
- `onBatchValues(route, codec, callback)`, `sendBatchValues(route, codec, values, canSend?)`, `sendCompactBatchValues(route, codec, values, canSend?)`.
- `request(route, payload, timeout, callback)`, `respond(route, requestId, payload)`, `cancel(route, requestId)`.
- `receive(frame, carrier?)`, `step()`, `status()`, `destroy()`.

Each unsubscribe function owns a single registration. Rebinding a route with the
same callback gives it a new owner. An older unsubscribe leaves that binding active.

Peer and per-route request limits apply when a request reserves its slot, including
when a custom clock opens another request during admission. If an instrumentation
callback settles the request before delivery, the sender returns
`nil, "request_settled"` (or `nil, "destroyed"` on retirement). Its settlement
callback has already run.

Call `step()` regularly to drain backlog and expire requests; call `destroy()` on retirement. The remote adapter does both automatically.

Peer limits include `maximumOutstandingRequests`, `maximumRequestTimeout`, `maximumQueuedFrames`, `maximumQueuedReceiveBytes`, `ingressPackets`, and `maximumReceiveFramesPerStep` (default 32, maximum 256).

The server adapter owns a shared `Admission` gate configured through `lifecycle.admission`. Raw peers can supply `admit(route, rawBytes, expandedBytes)` for route-level admission. `Admission`, `AttemptAdmission`, `Egress`, `Compression`, `Frame`, and `Metrics` are exported for custom integrations.

Raw peers may supply `attempt(rawBytes, carrier) -> (boolean, reason?)`. The per-peer packet bucket runs first. The synchronous callback then sees each buffer’s full wire length, including headers, and zero bytes for other inputs. The physical carrier is `unreliable` when explicitly supplied and `reliable` otherwise. Only `true` permits parsing or queuing. A denial, callback error, or yield drops unreliable traffic and retires a reliable peer before its wire sequence can develop a gap.

Unreliable frames are capped at 1,000 bytes including headers; batching and compression are unsupported on this lane. Compression requires route opt-in, a versioned codec identity, and expanded-size limits. Request routes do not support compression. Raw and expanded sizes count toward admission before decompression.

## Generated batch codecs

The generator supports packed Boolean arrays and arrays of records with 1–16
required unsigned byte fields. For example, save this packed Boolean array
schema as `schema.json` in the Canticle checkout.

```json
{
  "type": "array",
  "encoding": "packed",
  "maxLength": 64,
  "items": { "type": "boolean" }
}
```

Run the generator from the checkout to write both modules into `generated/`.

```powershell
lune run tools/generate-codec.luau -- schema.json generated
```

The two modules expose the following methods and metadata.

- `Client.luau`: checked `encodeBatch`, `encodeCompactBatch`, `fingerprint`, `maximumBytes`, `maximumDecodedValues`, `validatesOutgoing`.
- `Server.luau`: bounded `decodeBatch`, `decodeCompactBatch`, `fingerprint`, `maximumBytes`, `maximumDecodedValues`.

Generate both modules from the same schema and Canticle revision. On a route
with `allowBatch = true`, pass the client encoder to `peer:sendBatchValues` and
register the server decoder with `peer:onBatchValues`. Use the runtime codec
for single values. Keep server decoders in ServerScriptService. The separate `generate-client-codec.luau` and `generate-native-codec.luau` tools accept a schema path and an output file.

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
still needed.

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
