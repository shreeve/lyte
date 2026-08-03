// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lyte",
    platforms: [.macOS(.v15)],
    products: [
        // The real client role, exported for the repository's cross-end
        // SystemTests composition package. Shipping products remain below.
        .library(name: "LyteTransport", targets: ["LyteTransport"]),
        .executable(name: "lyte-cli", targets: ["lyte-cli"]),
        .executable(name: "Lyte", targets: ["Lyte"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The sans-IO wire core (envelope, channels, vocabulary) shared with
        // the host; the frozen Vectors/ files are the contract CL-1 codes to.
        .package(path: "../Wire"),
        // Shared operating-system adapters used by both client and host.
        .package(path: "../Common"),
        // Test-only cross-end composition: the shipping client target does
        // not depend on Host, but LyteTransportTests drive both real cores.
        .package(path: "../Host"),
    ],
    targets: [
        // The Lyte-UDP client (CL-1..CL-12): owns the receive socket,
        // decodes envelopes via LyteWire, demuxes (chan, seq), renders
        // video/audio, sends input — the client's entire protocol stack.
        .target(
            name: "LyteTransport",
            dependencies: [
                .product(name: "COpus", package: "Common"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteIO", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // The corpus/diagnostic harness (H4 V-2/V-3): authored corpus
        // frames, gate math (PSNR/SSIM/patch/grating), PNG IO, the
        // VTDecompressionSession readback tap, and the quality-readback
        // scorer. Diagnostic surfaces only — lyte-cli's corpus commands,
        // the app's env-gated benchmark, and the gate tests. Kept out of
        // LyteTransport so the production streaming stack carries no
        // harness code (the v1-final review's named boundary).
        .target(name: "LyteCorpus"),
        .target(name: "LyteUI"),
        .target(name: "LyteHelperProtocol"),
        .executableTarget(
            name: "lyte-helperd",
            dependencies: ["LyteHelperProtocol"]
        ),
        .executableTarget(
            name: "lyte-cli",
            dependencies: [
                "LyteUI",
                "LyteHelperProtocol",
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
                "LyteUI", "LyteHelperProtocol", "LyteTransport",
                // The env-gated diagnostic benchmark's quality scorer
                // (VideoQualityReadback) — an explicit, honest dependency;
                // the streaming stack itself carries no corpus code.
                "LyteCorpus",
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteIO", package: "Common"),
                .product(name: "LyteWire", package: "Wire"),
            ]
        ),
        // CL-18: the control strip's ergonomics policy (StripRevealPolicy,
        // StripPreferences) lives in LyteUI so the feel is virtual-time
        // testable without the app shell.
        .testTarget(
            name: "LyteUITests",
            dependencies: ["LyteUI"]
        ),
        .testTarget(
            name: "LyteTransportTests",
            dependencies: [
                "LyteTransport",
                "LyteCorpus",
                // CL-11: the Opus leaf round-trip generates real packets
                // with libopus' encoder (test-only; production encodes
                // nothing client-side).
                .product(name: "COpus", package: "Common"),
                .product(name: "LyteCore", package: "Common"),
                .product(name: "LyteTestKit", package: "Common"),
                .product(name: "HostWire", package: "Host"),
                .product(name: "LyteWire", package: "Wire"),
                .product(name: "LyteWireTestKit", package: "Wire"),
            ],
            exclude: ["Fixtures"]
        ),
    ]
)
