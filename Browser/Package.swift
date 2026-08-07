// swift-tools-version:6.0
import PackageDescription

// LyteClientBrowser — browser platform adapter (B-5+).
// Builds to WebAssembly via the official Swift Wasm SDK + PackageToJS.
// Consumes IO-free LyteWire / LyteCore / LyteClientSession; owns the
// JS↔WASM boundary, control-plane initiator for WT carriage, video
// assemble + Conductor/handoff policy, and Annex-B classification
// (page JS owns WebCodecs decode + WebGPU present). AudioWorklet /
// product composition stay deferred (B-6).

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
