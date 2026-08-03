// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyteCommon",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LyteCore", targets: ["LyteCore"]),
        .library(name: "LyteIO", targets: ["LyteIO"]),
        .library(name: "COpus", targets: ["COpus"]),
        .library(name: "LyteTestKit", targets: ["LyteTestKit"]),
    ],
    targets: [
        // One libopus module for both products. pkg-config supplies the
        // platform-specific include directory; policy stays out of this leaf.
        .systemLibrary(
            name: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"]), .apt(["libopus-dev"])]
        ),
        // Shared policy stays sans-IO and WASM-buildable. The lint moves
        // here with the first extracted policy utility.
        .target(name: "LyteCore"),
        // Shared OS adapters only: both ends consume every admitted organ.
        .target(
            name: "LyteIO",
            dependencies: ["LyteCore"]
        ),
        // Reusable test equipment. Production targets never depend on it.
        .target(name: "LyteTestKit"),
        .testTarget(
            name: "LyteCoreTests",
            dependencies: ["LyteCore", "LyteTestKit"]
        ),
        .testTarget(
            name: "LyteIOTests",
            dependencies: ["LyteIO", "LyteTestKit"]
        ),
        .testTarget(
            name: "LyteTestKitTests",
            dependencies: ["LyteTestKit"]
        ),
    ]
)
