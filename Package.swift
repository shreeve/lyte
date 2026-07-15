// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lyte",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LyteKit", targets: ["LyteKit"]),
        .executable(name: "lyte-cli", targets: ["lyte-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "LyteKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .executableTarget(
            name: "lyte-cli",
            dependencies: [
                "LyteKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "LyteKitTests", dependencies: ["LyteKit"]),
    ]
)
