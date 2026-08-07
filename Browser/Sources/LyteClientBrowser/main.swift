/// Browser entry: load LyteWire under Chrome, install a JS-callable bridge,
/// exercise frozen wire contracts, prove opaque WebTransport carriage (B-2),
/// drive a control session (B-3), and Conductor-scheduled corpus video
/// (B-5: assemble → VideoBeatConductor → WebCodecs → WebGPU).
///
/// PackageToJS executables use top-level entry (not `@main`) so the module
/// stays free of the parse-as-library / top-level-code conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
