// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lyte",
    platforms: [.macOS(.v15)],
    products: [
        // Pure client-role policy, exported for future cross-platform
        // composition without importing the macOS transport shell.
        .library(name: "LyteClientCore", targets: ["LyteClientCore"]),
        .library(name: "LyteClientSession", targets: ["LyteClientSession"]),
        // The real client role, exported for the repository's cross-end
        // SystemTests composition package. Shipping products remain below.
        .library(name: "LyteTransport", targets: ["LyteTransport"]),
        .library(name: "LyteClientTestKit", targets: ["LyteClientTestKit"]),
        .executable(name: "lyte-cli", targets: ["lyte-cli"]),
        .executable(name: "Lyte", targets: ["Lyte"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The sans-IO wire core (envelope, channels, vocabulary) shared with
        // the host; the frozen Vectors/ files are the contract.
        .package(path: "../Wire"),
        // Shared operating-system adapters used by both client and host.
        .package(path: "../Common"),
    ],
    targets: [
        // Pure client-role policy: injected time, value-state decisions,
        // and no platform frameworks or IO.
        .target(
            name: "LyteClientCore",
            dependencies: [
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // IO-free initiator/session orchestration over LyteWire. Platform
        // shells inject clocks and execute the returned decisions.
        .target(
            name: "LyteClientSession",
            dependencies: [
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // The Lyte-UDP client: owns the receive socket,
        // decodes envelopes via LyteWire, demuxes (chan, seq), renders
        // video/audio, sends input — the client's entire protocol stack.
        .target(
            name: "LyteTransport",
            dependencies: [
                "LyteClientCore",
                "LyteClientSession",
                .product(name: "COpus", package: "Common"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteIO", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // The corpus/diagnostic harness: authored corpus
        // frames, gate math (PSNR/SSIM/patch/grating), PNG IO, the
        // VTDecompressionSession readback tap, and the quality-readback
        // scorer. Diagnostic surfaces only — lyte-cli's corpus commands,
        // the app's diagnostic-build benchmark, and the gate tests. Kept out of
        // LyteTransport so the production streaming stack carries no
        // harness code.
        .target(name: "LyteCorpus"),
        .target(name: "LyteUI"),
        .target(name: "LyteHelperProtocol"),
        .target(
            name: "LyteHelperSecurity",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "LyteClientTestKit",
            dependencies: [
                "LyteTransport",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteTestKit", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ]
        ),
        .executableTarget(
            name: "lyte-helperd",
            dependencies: ["LyteHelperProtocol", "LyteHelperSecurity"]
        ),
        .executableTarget(
            name: "lyte-cli",
            dependencies: [
                "LyteUI",
                "LyteClientCore",
                "LyteClientSession",
                "LyteTransport",
                "LyteCorpus",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteIO", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "Lyte",
            dependencies: [
                "LyteClientCore", "LyteUI", "LyteHelperProtocol",
                "LyteHelperSecurity", "LyteClientSession", "LyteTransport",
                // The diagnostic-build benchmark's quality scorer and
                // synthetic motion reference — an explicit dependency; the
                // streaming stack itself carries no corpus code.
                "LyteCorpus",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteIO", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // The app's policies and lifecycle under injected services, plus
        // LyteUI's control-strip ergonomics in virtual time.
        .testTarget(
            name: "LyteAppTests",
            dependencies: [
                "LyteUI", "Lyte", "LyteClientCore", "LyteTransport",
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        .testTarget(
            name: "LyteHelperTests",
            dependencies: ["LyteHelperSecurity", "lyte-helperd"]
        ),
        // lyte-cli's argument contracts, parsed as the shell parses them.
        .testTarget(
            name: "LyteCLITests",
            dependencies: [
                "lyte-cli",
                "LyteCorpus",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LyteClientCoreTests",
            dependencies: [
                "LyteClientCore",
                .product(name: "LyteTestKit", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ]
        ),
        .testTarget(
            name: "LyteClientSessionTests",
            dependencies: [
                "LyteClientSession",
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // The corpus harness, quality scorer and synthetic motion
        // reference — the slow diagnostic legs, apart from the transport's.
        .testTarget(
            name: "LyteCorpusTests",
            dependencies: [
                "LyteCorpus",
                "LyteTransport",
                "LyteClientTestKit",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LyteTransportTests",
            dependencies: [
                "LyteClientCore",
                "LyteClientSession",
                "LyteTransport",
                "LyteClientTestKit",
                // The Opus leaf round-trip generates real packets
                // with libopus' encoder (test-only; production encodes
                // nothing client-side).
                .product(name: "COpus", package: "Common"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ]
        ),
    ]
)

// Off macOS only the IO-free client policy and its suites exist; every
// other target needs AppKit, AVFoundation or Network.framework.
#if !os(macOS)
let portableTargets: Set<String> = [
    "LyteClientCore", "LyteClientSession",
    "LyteClientCoreTests", "LyteClientSessionTests",
]
package.targets = package.targets.filter { portableTargets.contains($0.name) }
package.products = package.products.filter { portableTargets.contains($0.name) }
#endif
