# Changelog

## Unreleased

- Preserve request limits and settlement during reentrant callbacks. Disconnecting an old listener leaves its replacement active, including when both registrations use the same function.
- Reject integer schemas whose endpoints require different 32-bit representations. Reject gaps and named keys in object-field and enum declarations before they can silently drop values.
- Reject nonzero unused bits in an object's optional-field bitmap on single and batch reads. Existing Canticle encoders already emit zero padding.
- Reduce per-field work in generated checked byte-record encoders. Regenerate existing client modules to pick up the change.
- Remove three temporary tables from ordinary packet receives and skip the empty receive queue. Yielding listeners retain their resume values and reliable delivery order.
- Load the optional egress scheduler on demand when using standalone route or manifest configuration.
- Check private event and batch permissions at delivery. Withheld bulk messages leave the next reliable sequence available. Each queued frame is checked against its own deadline.
- Share the server’s per-step item and byte limits across peers with pending sends. Incoming frames and request deadlines continue to make progress when the send allowance runs out.
- Enforce request-only byte limits on both peers, check encoded payload sizes before sending, and reject raw batch counts that exceed the 16-bit header.
- Run the optional raw-peer admission callback before parsing. Deny admission when a clock fails or the gate closes during its clock read.
- Check float32 bounds after rounding. Enum labels and field names containing reserved punctuation have updated fingerprints. Rebuild both endpoints and regenerate any specialized codecs for those schemas.

## 0.1.0

- Retire overloaded transport sessions, bound receive work across callbacks, and reserve queued capacity for reliable traffic.
- Add per-route admission limits and drop counters for measured traffic budgets.

- Discard late responses before payload copying; prevent retired decoder completions from dispatching callbacks.
- Standalone Roblox Luau transport with bounded schemas and queues, admission budgets, request lifetimes, readiness handshakes, and lifecycle cleanup.
- Schema-bound channels, compact batches, and optional generated batch codecs.
- Session ownership and epochs remain isolated across yielding setup, reconnect, removal, and shutdown callbacks.
