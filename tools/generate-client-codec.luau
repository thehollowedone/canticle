local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Generator = require("./ClientCodecGenerator")
local first = if process.args[1] == "--" then 2 else 1
local input, output = process.args[first], process.args[first + 1]
assert(
    input and output,
    "usage: luneblox run tools/generate-client-codec.luau -- schema.json output.luau"
)
local source, reason = Generator.generate(
    serde.decode("json", fs.readFile(input)),
    { trustOutbound = table.find(process.args, "--trust-outbound") ~= nil }
)
assert(source, reason)
fs.writeFile(output, source)
print(`generated {output}`)
