# Changelog

## November 2026

### Schemas and wire format

- Canticle escapes punctuation in enum labels and object field names when computing schema fingerprints. This distinguishes punctuation inside a name from the separators between schema elements.
- Schema compilation rejects declarations that could visit more than 65,536 values. Standard and compact batches allow up to 262,144 visits, including outer slots. Runtime codecs, generated client encoders and generated server decoders all enforce the batch limit. Callers can lower it with `maximumDecodedValues`. [Schema limits](docs/api.md#schemas)
- Compilation rejects gaps and named keys in object-field and enum lists. It also rejects integer ranges that span both negative values and values above 2,147,483,647.
- Float32 bounds apply to the value after wire rounding as well as to the input. Single-value and batch decoders reject nonzero padding in optional-field bitmaps.

### Transport

- Private events and batches can supply `canSend` to check the recipient's permission at delivery. Withholding a queued bulk frame leaves its sequence number available for the next eligible frame. The scheduler checks each frame's age before sending it.
- Peers share the server's per-step byte and item limits for queued sends. Receive processing and request timeouts continue when that allowance runs out.
- Both peers enforce `maximumRequestBytes` on requests. Senders check encoded payload sizes and reject raw batch counts above 65,535 before writing the frame.
- An optional raw-peer `attempt` callback can reject incoming frames before parsing. Admission also fails if its clock errors or the gate closes during the clock read.
- Request limits hold when a callback opens another request. If a callback settles a request before delivery, the sender skips it. Disconnecting an old listener preserves its replacement, even when both use the same function.

### Performance

- The client generator emits fewer operations per field when encoding checked byte records.
- Ordinary packet receives allocate three fewer temporary tables and skip empty receive queues. Standalone route and manifest configuration load the egress scheduler only when needed.

## 0.1.0

- Introduced schema-bound channels, compact batches and optional generated batch codecs for Roblox Luau. The transport handles readiness handshakes, request lifetimes and session cleanup.
- Added per-route admission limits and drop counters. Receive work is bounded across callbacks, queues reserve capacity for reliable traffic, and overloaded sessions retire.
- Isolated session epochs across yielding setup, reconnect, removal and shutdown. Late responses are discarded before copying their payloads, and a decoder that finishes after retirement cannot dispatch a callback.
