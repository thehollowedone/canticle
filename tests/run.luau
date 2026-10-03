local suites = {
    require("./TransportCodec.spec"),
    require("./TransportAdmission.spec"),
    require("./TransportCore.spec"),
    require("./TransportLifecycle.spec"),
    require("./TransportRemote.spec"),
    require("./TransportEgress.spec"),
    require("./NativeCodecGenerator.spec"),
    require("./ClientCodecGenerator.spec"),
    require("./Channel.spec"),
}

for index, suite in ipairs(suites) do
    assert(type(suite) == "function", `suite {index} did not return a function`)
    suite()
end

print(`Canticle: {#suites} suites passed`)
