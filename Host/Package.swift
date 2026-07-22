// swift-tools-version:6.0
import PackageDescription

// HostCore (pure Swift bitstream helpers), HostWire (the wiring layer that
// marries HostCore mechanisms to LyteWire codecs — HS-5), and their tests
// build everywhere, including macOS, so the Annex-B contract and the video
// channel pipeline are testable without a Linux GUI. The capture/encode
// leaves exist only on Linux: they bind PipeWire, D-Bus, and libavcodec
// through pkg-config system libraries.

var products: [Product] = [
    .library(name: "HostCore", targets: ["HostCore"]),
    .library(name: "HostWire", targets: ["HostWire"]),
]

var targets: [Target] = [
    .target(name: "HostCore"),
    .testTarget(name: "HostCoreTests", dependencies: ["HostCore"]),
    // HS-5: encoded Annex-B frames → packetizer + FEC → paced datagram
    // blobs, plus the `lyte sniff` header formatter. Cross-platform on
    // purpose: the macOS integration test is this slice's gate.
    .target(
        name: "HostWire",
        dependencies: [
            "HostCore",
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostWireTests",
        dependencies: [
            "HostWire",
            "HostCore",
            .product(name: "LyteWire", package: "Wire"),
            .product(name: "LyteWireTestKit", package: "Wire"),
        ]
    ),
]

#if os(Linux)
products.append(.executable(name: "lyte-host", targets: ["lyte-host"]))

targets += [
    .systemLibrary(
        name: "CDBus",
        pkgConfig: "dbus-1",
        providers: [.apt(["libdbus-1-dev"])]
    ),
    .systemLibrary(
        name: "CPipeWire",
        pkgConfig: "libpipewire-0.3",
        providers: [.apt(["libpipewire-0.3-dev"])]
    ),
    .systemLibrary(
        name: "CLibAV",
        pkgConfig: "libavcodec",
        providers: [.apt(["libavcodec-dev", "libavutil-dev"])]
    ),
    .systemLibrary(
        name: "COpus",
        pkgConfig: "opus",
        providers: [.apt(["libopus-dev"])]
    ),
    // C leaf: PipeWire stream consumption (SPA pod construction is macro-based
    // and unreachable from Swift; this is the hardware/OS boundary).
    .target(
        name: "CPipeWireCapture",
        dependencies: ["CPipeWire"]
    ),
    // C leaf: libavcodec hevc_nvenc with Sunshine's low-latency recipe.
    .target(
        name: "CHevcEncode",
        dependencies: ["CLibAV"]
    ),
    // C leaf: pw_stream capture of the default sink's monitor
    // (stream.capture.sink), F32 48 kHz stereo, graph-clock timestamps.
    .target(
        name: "CPipeWireAudio",
        dependencies: ["CPipeWire"]
    ),
    // C leaf: libopus pinned to the dialect (CELT restricted-lowdelay,
    // 48 kHz stereo, 5 ms frames, DTX off) + the loop-decode half.
    .target(
        name: "COpusEncode",
        dependencies: ["COpus"]
    ),
    // C leaf: nonblocking UDP with sendmmsg/recvmmsg, per-packet TOS cmsgs,
    // and SO_TIMESTAMPING TX stamps (CMSG macros are unreachable from Swift;
    // plain Linux syscalls, no system library).
    .target(name: "CNetIO"),
    // C leaf (HS-13, fallback only): virtual evdev devices over
    // /dev/uinput — keyboard, relative mouse, absolute tablet. The
    // ioctl surface; policy stays in Swift.
    .target(name: "CInputUinput"),
    // HS-4 verification harness: loopback batch send with per-packet DSCP,
    // received-TOS readback, TX-timestamp drain. Exits nonzero on mismatch.
    .executableTarget(
        name: "lyte-netio-check",
        dependencies: ["CNetIO"]
    ),
    // HS-6 verification harness: the pure Pacer schedule driving CNetIO
    // sendmmsg batches on loopback with per-class TOS; TX timestamps
    // measure batch spacing, IDR drain, and audio wait. Exits nonzero if
    // a gate bound is violated.
    .executableTarget(
        name: "lyte-pace-check",
        dependencies: ["HostCore", "CNetIO"]
    ),
    // HS-14 verification harness: default-sink monitor → 5 ms Opus packets
    // → decode-back WAV; prints cadence/size/timestamp stats and exits
    // nonzero if the gate (200 pkt/s, monotonic graph-clock ts, clean loop
    // decode) is violated.
    .executableTarget(
        name: "lyte-audio-check",
        dependencies: ["CPipeWireAudio", "COpusEncode"],
        linkerSettings: [
            .linkedLibrary("pipewire-0.3"),
            .linkedLibrary("opus"),
        ]
    ),
    .executableTarget(
        name: "lyte-host",
        dependencies: [
            "HostCore",
            "HostWire",
            "CDBus",
            "CPipeWireCapture",
            "CHevcEncode",
            "CNetIO",
            "CInputUinput",
            .product(name: "LyteWire", package: "Wire"),
            // HS-10: one SHA-256 for the advertised identity hash
            // (IdentityHash.swift is the confined import site). Already
            // in the graph via Wire — no new external dependency.
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        linkerSettings: [
            .linkedLibrary("dbus-1"),
            .linkedLibrary("pipewire-0.3"),
            .linkedLibrary("avcodec"),
            .linkedLibrary("avutil"),
        ]
    ),
]
#endif

var dependencies: [Package.Dependency] = [
    // First cross-package integration on the host side (HS-5): the
    // sans-IO protocol core every end codes against.
    .package(path: "../Wire"),
]

#if os(Linux)
// Only the Linux-only lyte-host target consumes this directly (HS-10's
// identity hash), so macOS resolution stays exactly as before. Same
// version pin as Wire's — one swift-crypto in the graph.
dependencies.append(
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0")
)
#endif

let package = Package(
    name: "LyteHost",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
