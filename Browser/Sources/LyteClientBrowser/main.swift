/// Browser entry: load LyteWire under Chrome, install a JS-callable bridge,
/// exercise frozen wire contracts, prove opaque WebTransport carriage (B-2),
/// drive a control-only session (B-3: Noise / pair / capabilities), and
/// classify canned Annex-B for the B-4 WebCodecs + WebGPU frame proof.
/// Live Conductor video is B-5.
///
/// PackageToJS executables use top-level entry (not `@main`) so the module
/// stays free of the parse-as-library / top-level-code conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
