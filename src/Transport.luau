--!strict

local Codec = if script then require(script.Parent.TransportCodec) else require("./TransportCodec")
local Config = if script
    then require(script.Parent.TransportConfig)
    else require("./TransportConfig")
local Frame = if script then require(script.Parent.TransportFrame) else require("./TransportFrame")
local Admission = if script
    then require(script.Parent.TransportAdmission)
    else require("./TransportAdmission")
local Manifest = if script
    then require(script.Parent.TransportManifest)
    else require("./TransportManifest")
local Metrics = if script
    then require(script.Parent.TransportMetrics)
    else require("./TransportMetrics")
local Egress = if script
    then require(script.Parent.TransportEgress)
    else require("./TransportEgress")
local Compression = if script
    then require(script.Parent.TransportCompression)
    else require("./TransportCompression")
local Peer = if script then require(script.Parent.TransportPeer) else require("./TransportPeer")
local Remote = if script
    then require(script.Parent.TransportRemote)
    else require("./TransportRemote")

return table.freeze({
    Codec = Codec,
    Config = Config,
    Frame = Frame,
    Admission = Admission,
    Manifest = Manifest,
    Metrics = Metrics,
    Egress = Egress,
    Compression = Compression,
    Peer = Peer,
    Remote = Remote,
})
