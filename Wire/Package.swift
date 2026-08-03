// swift-tools-version:6.0
import PackageDescription

// LyteWire is the sans-IO protocol core both ends import: pure codecs and
// vocabulary types that consume bytes and emit bytes. No Foundation, no
// sockets, no threads — Scripts/lint-no-foundation.sh enforces the import
// rule and runs as part of `swift test`. LyteWireTestKit (which may use
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
            targets: ["LyteWireVectorGen"]
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
        // The vendored nanors RS-FEC leaf (W1), copied from the root
        // package's Vendor/nanors. Module name CNanorsWire — distinct from
        // the root package's CNanors target — so both packages can coexist
        // in one build graph until the root drops its copy (CL-2 era).
        // Confinement: only NanorsBackend.swift imports it.
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
        // Authoring tool for Vectors/ — run once, commit, freeze. See
        // Vectors/README.md for the regeneration policy.
        .executableTarget(
            name: "LyteWireVectorGen",
            dependencies: [
                "LyteWire", "LyteWireTestKit",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
        .testTarget(
            name: "LyteWireTests",
            dependencies: [
                "LyteWire", "LyteWireTestKit",
                .product(name: "LyteCore", package: "Common"),
            ]
        ),
    ]
)
