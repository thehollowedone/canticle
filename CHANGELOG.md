# Changelog

## Unreleased

### Upgrade notes

- Schema fingerprints changed for enum labels and object field names containing any of `% , : { } | ? !`. If your schemas use these characters, rebuild both endpoints and regenerate their specialized codecs together.
- Schema compilation now rejects a worst-case traversal above 65,536 values. Ordinary and compact batches allow up to 262,144 value visits, including outer slots. Set `maximumDecodedValues` to lower the batch limit. Regenerate existing codecs to apply it to generated encoders and decoders. [Schema limits](docs/api.md#schemas)

### Transport

- Private events and batches can supply `canSend` to check the recipient's permission at delivery. Withholding a queued bulk frame leaves its sequence number available for the next eligible frame. The scheduler checks each frame's age before sending it.
- Peers share the server's per-step byte and item limits for queued sends. Receive processing and request timeouts continue when that allowance runs out.
- Both peers enforce `maximumRequestBytes` on requests. Senders check encoded payload sizes and reject raw batch counts above 65,535 before writing the frame.
- An optional raw-peer `attempt` callback can reject incoming frames before parsing. Admission also fails if its clock errors or the gate closes during the clock read.
- Reentrant callbacks can no longer exceed outstanding request limits or send a request that has already settled. Disconnecting an old listener preserves its replacement, even when both use the same function.

### Codecs and performance

- Schema compilation rejects sparse or named entries in object-field and enum lists, and integer ranges that require both signed and unsigned 32-bit encodings.
- Float32 values must satisfy their bounds after rounding. Single and batch decoders reject nonzero padding in optional-field bitmaps. Existing Canticle encoders already write zero padding.
- Generated checked byte-record encoders do less work per field. Regenerate client modules to pick up the change.
- Ordinary packet receives allocate three fewer temporary tables and skip empty receive queues. Standalone route and manifest configuration load the egress scheduler only when needed.

## 0.1.0

- Introduced schema-bound channels, compact batches and optional generated batch codecs for Roblox Luau. The transport handles readiness handshakes, request lifetimes and session cleanup.
- Added per-route admission limits and drop counters. Receive work is bounded across callbacks, queues reserve capacity for reliable traffic, and overloaded sessions retire.
- Isolated session epochs across yielding setup, reconnect, removal and shutdown. Late responses are discarded before copying their payloads, and a decoder that finishes after retirement cannot dispatch a callback.
