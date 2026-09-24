/// Browser entry: install the JS-callable bridge. PackageToJS executables
/// use top-level entry (not `@main`) so the module stays free of the
/// parse-as-library conflict.
BrowserBridge.install()
