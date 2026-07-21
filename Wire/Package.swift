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
    ],
    targets: [
        .target(name: "LyteWire"),
        .target(name: "LyteWireTestKit", dependencies: ["LyteWire"]),
        // Authoring tool for Vectors/ — run once, commit, freeze. See
        // Vectors/README.md for the regeneration policy.
        .executableTarget(
            name: "lyte-wire-vectorgen",
            dependencies: ["LyteWire", "LyteWireTestKit"]
        ),
        .testTarget(
            name: "LyteWireTests",
            dependencies: ["LyteWire", "LyteWireTestKit"]
        ),
    ]
)
