# Changelog

## 0.1.0

- Retire overloaded transport sessions, bound receive work across callbacks, and reserve queued capacity for reliable traffic.
- Add per-route admission limits and drop counters for measured traffic budgets.

- Discard late responses before payload copying; prevent retired decoder completions from dispatching callbacks.
- Standalone Roblox Luau transport with bounded schemas and queues, admission budgets, request lifetimes, readiness handshakes, and lifecycle cleanup.
- Schema-bound channels, compact batches, and optional generated batch codecs.
- Session ownership and epochs remain isolated across yielding setup, reconnect, removal, and shutdown callbacks.
