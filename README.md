# Canticle

Buffer-based networking for Roblox Luau, with bounded codecs, queues, and request lifetimes.

- Reliable, unreliable, request/response, cancellation, and bulk routes.
- Schema-bound channels, standard/compact batches, and optional generated codecs.
- Shared admission budgets, compatibility handshakes, and explicit cleanup.

## Install

Map `src` to a ModuleScript package with Rojo. Require its root:

```lua
local Canticle = require(game:GetService("ReplicatedStorage").Packages.Canticle)
```

## Use

```lua
local codec = assert(Canticle.Codec.compile({ type = "integer", min = 1, max = 32 }))
local bytes = assert(codec:encode(4))
local ok, value = codec:decode(bytes)
```

See the [API guide](docs/api.md) for routes, live remotes, batching, and cleanup.

## Development

Install the tools pinned in `rokit.toml`, then:

```powershell
python tools/check-types.py
luneblox run tests/run.luau
rojo build default.project.json -o build/Canticle.rbxm
```

`src/` contains the runtime, `tools/` the codec generators, and `tests/` the tests.
Type analysis covers every runtime and generator module with both Luau solvers
under default and enabled flags.

[MIT license](LICENSE).
