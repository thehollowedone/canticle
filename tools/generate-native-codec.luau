local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Generator = require("./NativeCodecGenerator")

local first = if process.args[1] == "--" then 2 else 1
local input, output = process.args[first], process.args[first + 1]
assert(
    input and output,
    "usage: luneblox run tools/generate-native-codec.luau -- schema.json output.luau"
)
local schema = serde.decode("json", fs.readFile(input))
local source, err = Generator.generate(schema)
assert(source, err)
fs.writeFile(output, source)
print(`generated {output}`)
