// swift-tools-version:6.0
import PackageDescription

// Cross-end composition only: this package is the one build graph allowed to
// import both real roles. It is macOS-only until an IO-free client session
// target earns Linux and Windows execution.
let package = Package(
    name: "LyteSystemTests",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Client"),
        .package(path: "../Common"),
        .package(path: "../Host"),
        .package(path: "../Wire"),
    ],
    targets: [
        .testTarget(
            name: "LyteClientHostTests",
            dependencies: [
                .product(name: "LyteTransport", package: "Client"),
                .product(name: "LyteClientTestKit", package: "Client"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteTestKit", package: "Common"),
                .product(name: "HostWire", package: "Host"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ]
        ),
    ]
)
