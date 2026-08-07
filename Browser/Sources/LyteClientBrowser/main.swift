/// B-1 browser entry: load LyteWire under Chrome, install a JS-callable
/// bridge, and exercise frozen wire contracts across the JavaScript
/// boundary. No networking, no WebCodecs — that is B-2+.
///
/// PackageToJS executables use top-level entry (not `@main`) so the module
/// stays free of the parse-as-library / top-level-code conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
