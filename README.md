# Canticle

Buffer-based networking for Roblox Luau, with bounded codecs, queues, and request lifetimes.

- Reliable, unreliable and bulk events, plus request/response with cancellation.
- Schema-bound channels, standard/compact batches, and optional generated codecs.
- Shared receive and send budgets, compatibility handshakes, and explicit cleanup.

## Install

### Rojo

Place the Canticle source at `vendor/Canticle` in your game repository. To pin
the revision with Git, add Canticle as a submodule from the game repository root.

```sh
git submodule add https://github.com/thehollowedone/canticle.git vendor/Canticle
```

After cloning a game that already includes the submodule, run
`git submodule update --init vendor/Canticle` to fetch the pinned source.

Merge the following mapping into the `tree` of your game's Rojo project file.

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

### Roblox Studio

From a Canticle source checkout, build the model with Rokit and PowerShell 7.

```powershell
rokit install
New-Item -ItemType Directory -Force build | Out-Null
rojo build default.project.json -o build/Canticle.rbxm
```

Import `build/Canticle.rbxm` into Studio and move the `Canticle` ModuleScript
from the imported folder into `ReplicatedStorage.Packages`. Create the
`Packages` folder if needed.

## Use

A server Script or LocalScript can compile a schema and use it to encode and decode a value.

```lua
local Canticle = require(game:GetService("ReplicatedStorage").Packages.Canticle)
local codec = assert(Canticle.Codec.compile({ type = "integer", min = 1, max = 32 }))
local bytes = assert(codec:encode(4))
local ok, value = codec:decode(bytes)
assert(ok and value == 4)
```

For a script that only serializes values, require the codec directly. This loads
one ModuleScript and exposes the same `compile` function as `Canticle.Codec`.

```lua
local Codec = require(game:GetService("ReplicatedStorage").Packages.Canticle.TransportCodec)
```

For private queued data, pass a server-side `canSend` callback that checks the viewer’s current access just before delivery. Withholding a bulk message leaves later messages in order. See the [channel API and example](docs/api.md#channels).

## Development

Run `rokit install` from the Canticle checkout to install the versions pinned in
`rokit.toml`. Run the type checks and test suite from the same directory.

```powershell
pwsh -NoProfile -File tools/check-types.ps1
lune run tests/run.luau
```

`src/` contains the runtime, `tools/` the codec generators, and `tests/` the tests.
Type analysis checks `src/`, `ClientCodecGenerator.luau` and
`NativeCodecGenerator.luau` with both Luau solvers under default and enabled flags.
The generator CLI entrypoints are outside that analysis.

[API guide](docs/api.md) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)
