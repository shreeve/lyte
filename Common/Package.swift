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
        // One pinned, statically propagated Opus leaf for every product.
        // Generic upstream C keeps the build offline and platform-neutral;
        // codec policy remains in the Swift role layers above it.
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: [
                "UPSTREAM.md",
                "Upstream/opus-1.6.1/COPYING",
            ],
            sources: [
                "Upstream/opus-1.6.1/celt",
                "Upstream/opus-1.6.1/silk",
                "Upstream/opus-1.6.1/src",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/opus"),
                .headerSearchPath("Upstream/opus-1.6.1"),
                .headerSearchPath("Upstream/opus-1.6.1/celt"),
                .headerSearchPath("Upstream/opus-1.6.1/silk"),
                .headerSearchPath("Upstream/opus-1.6.1/silk/float"),
                .define("OPUS_BUILD"),
                .define("USE_ALLOCA"),
                .define("DISABLE_DEBUG_FLOAT"),
                .define("PACKAGE_VERSION", to: "\"1.6.1\""),
                .define(
                    "OPUS_WILL_BE_SLOW",
                    .when(configuration: .debug)
                ),
            ],
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux])),
            ]
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
        .testTarget(name: "COpusTests", dependencies: ["COpus"]),
    ]
)
