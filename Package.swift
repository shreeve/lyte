// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lyte",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LyteKit", targets: ["LyteKit"]),
        .executable(name: "lyte-cli", targets: ["lyte-cli"]),
        .executable(name: "Lyte", targets: ["Lyte"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CEnet",
            path: "Vendor/enet",
            exclude: ["include/enet/win32.h"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAS_FCNTL"),
                .define("HAS_IOCTL"),
                .define("HAS_POLL"),
                .define("HAS_GETADDRINFO"),
                .define("HAS_GETNAMEINFO"),
                .define("HAS_INET_PTON"),
                .define("HAS_INET_NTOP"),
                .define("HAS_MSGHDR_FLAGS"),
                .define("HAS_SOCKLEN_T"),
            ]
        ),
        .target(
            name: "CNanors",
            path: "Vendor/nanors",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LyteKit",
            dependencies: [
                "CEnet",
                "CNanors",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .target(
            name: "LyteUI",
            dependencies: ["LyteKit"]
        ),
        .target(name: "LyteHelperProtocol"),
        .executableTarget(
            name: "lyte-helperd",
            dependencies: ["LyteHelperProtocol"]
        ),
        .executableTarget(
            name: "lyte-cli",
            dependencies: [
                "LyteKit",
                "LyteUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "Lyte",
            dependencies: ["LyteKit", "LyteUI", "LyteHelperProtocol"]
        ),
        .testTarget(name: "LyteKitTests", dependencies: ["LyteKit"]),
    ]
)
