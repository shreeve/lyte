/// Browser entry: load LyteWire under Chrome, install a JS-callable bridge,
/// exercise frozen wire contracts, then let page JS prove opaque WebTransport
/// datagram carriage (B-2). No session/media — that is B-3+.
///
/// PackageToJS executables use top-level entry (not `@main`) so the module
/// stays free of the parse-as-library / top-level-code conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
