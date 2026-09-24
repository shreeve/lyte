/// Browser entry: install the JS-callable bridge and paint the frozen wire
/// contract results. PackageToJS executables use top-level entry (not
/// `@main`) so the module stays free of the parse-as-library conflict.
BrowserBridge.install()
BrowserBridge.paintProofPage(results: BrowserBridge.runFrozenContracts())
