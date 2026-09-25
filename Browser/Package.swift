// swift-tools-version:6.0
import PackageDescription

// LyteClientBrowser — the browser platform adapter.
//
// LyteClientBrowserCore is sans-IO policy over LyteWire / LyteCore /
// LyteClientCore / LyteClientSession: the control-plane initiator for
// WebTransport carriage, feedback and repair, video assemble +
// Conductor/handoff policy, audio depacketize, input and clipboard on
// sealed CTRL. It has no JavaScriptKit dependency, so it builds
// and tests natively on macOS and Linux as well as for WebAssembly.
//
// LyteClientBrowser is the thin executable that owns the JS↔WASM boundary
// (built with the Swift Wasm SDK + PackageToJS). Page JavaScript owns
// WebCodecs decode, WebGPU present and the AudioWorklet PCM ring.
//
// The Host dependency is for tests only: the core tests drive a real
// in-process HostWire.Session, the same engine lyte-control-peer serves to
// Chrome. No product target links Host.

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
        .package(path: "../Host"),
    ],
    targets: [
        .target(
            name: "LyteClientBrowserCore",
            dependencies: [
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteClientCore", package: "Client"),
                .product(name: "LyteClientSession", package: "Client"),
            ]
        ),
        .executableTarget(
            name: "LyteClientBrowser",
            dependencies: [
                "LyteClientBrowserCore",
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
        .testTarget(
            name: "LyteClientBrowserCoreTests",
            dependencies: [
                "LyteClientBrowserCore",
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteWireTestKit", package: "Wire"),
                .product(name: "HostWire", package: "Host"),
                .product(name: "HostWireTestKit", package: "Host"),
                .product(name: "HostSession", package: "Host"),
            ]
        ),
    ]
)

// Off macOS only the core and its tests exist. The page is built from a Mac
// (the manifest is evaluated on the build host even with --swift-sdk), so a
// Linux machine never resolves JavaScriptKit or cross-builds the page.
#if !os(macOS)
package.targets.removeAll { $0.name == "LyteClientBrowser" }
package.products.removeAll()
#else
package.dependencies.append(
    .package(
        url: "https://github.com/swiftwasm/JavaScriptKit.git",
        .upToNextMinor(from: "0.57.0")))
#endif
