# API guide

Require the Canticle package root. Compile schemas and routes once at startup; use the same protocol on both peers.

## Schemas

`Codec.compile(schema)` returns `codec, nil` or `nil, reason`. A codec exposes `fingerprint` and `maximumBytes`.

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

Batch limits: `maximumItems`, `maximumItemBytes`, `maximumPayloadBytes`. Compact batches omit item-length headers and require route opt-in.

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

The adapter handles readiness, Heartbeat progress, and player departure. `server:findPeer(player)` returns an existing peer; `removePeer(player)` retires one player; `destroy()` shuts down the adapter. Manifest mismatches refuse readiness.

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
| `send(value, latest?)` | Returns `ok, reason?`; `latest` enables replaceable coalescing when configured. |
| `sendBatch(values, compact?)` | Returns `ok, reason?`. |
| `on(callback, rejected?)` | Calls `callback(value, context)` on valid input; returns an unsubscribe function. |
| `onBatch(callback)` | Calls `callback(values, context)`; returns an unsubscribe function. |
| `request(value, timeout, callback)` | Returns `requestId?, reason?`; callback receives `ok, response?, reason?`. Requires a response codec. |
| `respond(requestId, value)` | Returns `ok, reason?`; requires a response codec. |
| `cancel(requestId)` | Returns `ok, reason?`. |

Malformed single values reach the optional rejection callback. Route fingerprints detect codec mismatches during setup and batch sending.

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
luneblox run tools/generate-codec.luau -- schema.json generated
```

Supported schemas: packed Boolean arrays or arrays of records with 1–16 required unsigned byte fields. Output:

- `Client.luau`: checked `encodeBatch`, `encodeCompactBatch`, `fingerprint`, `maximumBytes`, `validatesOutgoing`.
- `Server.luau`: bounded `decodeBatch`, `decodeCompactBatch`, `fingerprint`, `maximumBytes`.

Use the encoder with batch sends and the decoder with `onBatchValues`; single values use the runtime codec. Keep server decoders in ServerScriptService. The separate `generate-client-codec.luau` and `generate-native-codec.luau` tools accept a schema path and an output file.

Optional `--trust-outbound` skips outgoing primitive checks. Structural/allocation limits and server validation remain active; invalid local primitives may be coerced or throw. Generated modules request native compilation with ordinary Luau fallback. Batch memoization is scoped to one call and disabled for metatable-bearing inputs.
