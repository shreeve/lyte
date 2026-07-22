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
        // The sans-IO wire core (envelope, channels, vocabulary) shared with
        // the host; the frozen Vectors/ files are the contract CL-1 codes to.
        .package(path: "Wire"),
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
        // C leaf (CL-11): libopus for the client audio receiver — decode
        // + PLC (the system AudioConverter has neither; LyteKit's
        // OpusDecoder documents the gap). Mirrors Host/'s COpus
        // system-library posture; brew supplies opus on the Mac.
        .systemLibrary(
            name: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"]), .apt(["libopus-dev"])]
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
        // The Lyte-UDP client shell (CL-1): owns the receive socket, decodes
        // envelopes via LyteWire, demuxes (chan, seq). Grows into the module
        // that replaces the frozen GameStream stack; never imports LyteKit.
        .target(
            name: "LyteTransport",
            dependencies: [
                "COpus",
                .product(name: "LyteWire", package: "Wire"),
                // The sanctioned crypto provider, for exactly one digest:
                // LyteDiscovery's pkh identity hash (LyteWire's SHA-256 is
                // internal to its Crypto/ leaf).
                .product(name: "Crypto", package: "swift-crypto"),
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
                "LyteHelperProtocol",
                "LyteTransport",
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "Lyte",
            // LyteTransport joins at CL-5 for the dual-browse (Lyte hosts
            // beside Sunshine hosts in ConnectView); LyteWire at CL-8 for
            // the session vocabulary (wire modes, teardown reasons) the
            // Lyte path surfaces. LyteKit leaves at the H2 demolition;
            // LyteTransport + LyteWire are what remain.
            dependencies: [
                "LyteKit", "LyteUI", "LyteHelperProtocol", "LyteTransport",
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        .testTarget(name: "LyteKitTests", dependencies: ["LyteKit"]),
        .testTarget(
            name: "LyteTransportTests",
            dependencies: [
                "LyteTransport",
                // CL-11: the Opus leaf round-trip generates real packets
                // with libopus' encoder (test-only; production encodes
                // nothing client-side).
                "COpus",
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ]
        ),
    ]
)
