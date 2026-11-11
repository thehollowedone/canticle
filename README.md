# Canticle

Buffer-based networking for Roblox Luau, with bounded codecs, queues, and request lifetimes.

- Reliable, unreliable, request/response, cancellation, and bulk routes.
- Schema-bound channels, standard/compact batches, and optional generated codecs.
- Shared admission budgets, compatibility handshakes, and explicit cleanup.

## Install

Place a reviewed checkout at `vendor/Canticle` in the game repository, then add
this mapping to the game's Rojo project:

```json
{
  "ReplicatedStorage": {
    "Packages": {
      "$className": "Folder",
      "Canticle": {
        "$path": "vendor/Canticle/src"
      }
    }
  }
}
```

Keep the game's existing service mappings and other packages. Require the
resulting ModuleScript:

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

Install the tools pinned in `rokit.toml`. In PowerShell 7, run:

```powershell
pwsh -NoProfile -File tools/check-types.ps1
lune run tests/run.luau
rojo build default.project.json -o build/Canticle.rbxm
```

`src/` contains the runtime, `tools/` the codec generators, and `tests/` the tests.
Type analysis checks `src/`, `ClientCodecGenerator.luau` and
`NativeCodecGenerator.luau` with both Luau solvers under default and enabled flags.
The generator CLI entrypoints are outside that analysis.

For Studio-only installation, import `build/Canticle.rbxm` and move its
`Canticle` child to `ReplicatedStorage.Packages.Canticle`.

[MIT license](LICENSE).
