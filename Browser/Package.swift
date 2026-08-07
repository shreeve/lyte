// swift-tools-version:6.0
import PackageDescription

// LyteClientBrowser — browser platform adapter (B-3+).
// Builds to WebAssembly via the official Swift Wasm SDK + PackageToJS.
// Consumes IO-free LyteWire / LyteCore / LyteClientSession; owns the
// JS↔WASM boundary and the control-plane initiator for WT carriage.
// WebCodecs / WebGPU / AudioWorklet ports come later. Product composition
// (LyteBrowserApp) stays deferred under Applications/.

let package = Package(
    name: "LyteClientBrowser",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LyteClientBrowser", targets: ["LyteClientBrowser"]),
    ],
    dependencies: [
        .package(path: "../Wire"),
        .package(path: "../Common"),
        .package(path: "../Client"),
        .package(
            url: "https://github.com/swiftwasm/JavaScriptKit.git",
            from: "0.36.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LyteClientBrowser",
            dependencies: [
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteClientSession", package: "Client"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
    ]
)
