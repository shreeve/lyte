/// Browser entry: load LyteWire under Chrome, install a JS-callable bridge,
/// exercise frozen wire contracts, prove opaque WebTransport carriage (B-2),
/// then drive a control-only session (B-3: Noise / pair / capabilities).
/// No media — that is B-4+.
///
/// PackageToJS executables use top-level entry (not `@main`) so the module
/// stays free of the parse-as-library / top-level-code conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
