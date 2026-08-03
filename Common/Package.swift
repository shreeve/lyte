// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyteCommon",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LyteCore", targets: ["LyteCore"]),
        .library(name: "LyteIO", targets: ["LyteIO"]),
        .library(name: "COpus", targets: ["COpus"]),
    ],
    targets: [
        // One libopus module for both products. pkg-config supplies the
        // platform-specific include directory; policy stays out of this leaf.
        .systemLibrary(
            name: "COpus",
            path: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"]), .apt(["libopus-dev"])]
        ),
        // Shared policy stays sans-IO and WASM-buildable. The lint moves
        // here with the first extracted policy utility.
        .target(name: "LyteCore", path: "Core"),
        // Shared OS adapters only: both ends consume every admitted organ.
        .target(
            name: "LyteIO",
            dependencies: ["LyteCore"],
            path: "IO"
        ),
        .testTarget(
            name: "LyteCoreTests",
            dependencies: ["LyteCore"],
            path: "Tests/LyteCoreTests"
        ),
        .testTarget(
            name: "LyteIOTests",
            dependencies: ["LyteIO"],
            path: "Tests/LyteIOTests"
        ),
    ]
)
