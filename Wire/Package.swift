// swift-tools-version:6.0
import PackageDescription

// LyteWire is the sans-IO protocol core both ends import: pure codecs and
// vocabulary types that consume bytes and emit bytes. No Foundation, no
// sockets, no threads — Common's SansIOArchitectureTests enforces the import
// allowlist and the IO-free vocabulary. LyteWireTestKit (which may use
// Foundation for file IO) ships the vector loaders so host and client test
// suites verify against the same Vectors/ artifacts.

let package = Package(
    name: "LyteWire",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LyteWire", targets: ["LyteWire"]),
        .library(name: "LyteWireTestKit", targets: ["LyteWireTestKit"]),
        .executable(
            name: "lyte-wire-vectorgen",
            targets: ["LyteWireVectorGenTool"]
        ),
    ],
    dependencies: [
        // Shared sans-IO utilities live beside the frozen wire contract.
        .package(path: "../Common"),
        // The ONE sanctioned external dependency (core plan §1): swift-crypto's
        // `Crypto` module is the crypto provider on ALL platforms — a thin
        // CryptoKit shim on Apple, vendored BoringSSL on Linux — so the
        // same Noise code compiles everywhere. Never import CryptoKit
        // directly. Confinement: `import Crypto` appears only under
        // Sources/LyteWire/Crypto/ (lint-enforced).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
    ],
    targets: [
        // The vendored nanors RS-FEC leaf (W1). Confinement: only
        // Fec/NanorsBackend.swift imports it.
        .target(name: "CNanorsWire", publicHeadersPath: "include"),
        .target(
            name: "LyteWire",
            dependencies: [
                "CNanorsWire",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "LyteWireTestKit",
            dependencies: [
                "LyteWire",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
        // The builders that author every Vectors/ file. The test suite
        // rebuilds each committed file from them, so they cannot drift
        // from the frozen bytes. See Vectors/README.md for the freeze
        // policy.
        .target(
            name: "LyteWireVectorGen",
            dependencies: [
                "LyteWire", "LyteWireTestKit",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
        // The `lyte-wire-vectorgen` CLI: writes one builder's file.
        .executableTarget(
            name: "LyteWireVectorGenTool",
            dependencies: [
                "LyteWire", "LyteWireTestKit", "LyteWireVectorGen",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
        .testTarget(
            name: "LyteWireTests",
            dependencies: [
                "LyteWire", "LyteWireTestKit", "LyteWireVectorGen",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
    ]
)
