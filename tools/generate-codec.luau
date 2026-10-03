local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Client = require("./ClientCodecGenerator")
local Server = require("./NativeCodecGenerator")
local first = if process.args[1] == "--" then 2 else 1
local input, directory = process.args[first], process.args[first + 1]
assert(
    input and directory,
    "usage: luneblox run tools/generate-codec.luau -- schema.json output-directory"
)
local schema = serde.decode("json", fs.readFile(input))
local client, clientReason =
    Client.generate(schema, { trustOutbound = table.find(process.args, "--trust-outbound") ~= nil })
local server, serverReason = Server.generate(schema)
assert(client, clientReason)
assert(server, serverReason)
if not fs.isDir(directory) then
    fs.writeDir(directory)
end
fs.writeFile(directory .. "/Client.luau", client)
fs.writeFile(directory .. "/Server.luau", server)
print(`generated client encoder and native server decoder in {directory}`)
