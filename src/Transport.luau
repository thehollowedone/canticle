--!strict

return table.freeze({
    Codec = if script then require(script.Parent.TransportCodec) else require("./TransportCodec"),
    Config = if script
        then require(script.Parent.TransportConfig)
        else require("./TransportConfig"),
    Frame = if script then require(script.Parent.TransportFrame) else require("./TransportFrame"),
    Admission = if script
        then require(script.Parent.TransportAdmission)
        else require("./TransportAdmission"),
    Manifest = if script
        then require(script.Parent.TransportManifest)
        else require("./TransportManifest"),
    Metrics = if script
        then require(script.Parent.TransportMetrics)
        else require("./TransportMetrics"),
    Egress = if script
        then require(script.Parent.TransportEgress)
        else require("./TransportEgress"),
    Compression = if script
        then require(script.Parent.TransportCompression)
        else require("./TransportCompression"),
    Peer = if script then require(script.Parent.TransportPeer) else require("./TransportPeer"),
    Remote = if script
        then require(script.Parent.TransportRemote)
        else require("./TransportRemote"),
})
