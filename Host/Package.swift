// swift-tools-version:6.0
import Foundation
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
    .target(
        name: "HostCore",
        dependencies: [.product(name: "LyteCore", package: "Common")]
    ),
    .testTarget(
        name: "HostCoreTests",
        dependencies: [
            "HostCore",
            .product(name: "LyteCore", package: "Common"),
        ]
    ),
    // HS-5: encoded Annex-B frames → packetizer + FEC → paced datagram
    // blobs, plus the `lyte sniff` header formatter. Cross-platform on
    // purpose: the macOS integration test is this slice's gate.
    .target(
        name: "HostWire",
        dependencies: [
            "HostCore",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostWireTests",
        dependencies: [
            "HostWire",
            "HostCore",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
            .product(name: "LyteWireTestKit", package: "Wire"),
        ]
    ),
]

#if os(Linux)
products.append(.executable(name: "lyte-host", targets: ["lyte-host"]))
products.append(.executable(name: "lyte-eye", targets: ["lyte-eye"]))
products.append(.executable(name: "lyte-nvenc", targets: ["lyte-nvenc"]))

// E5: the vendored no-reset FFmpeg is GONE — the portal path it
// served is demolished. LYTE_FFMPEG_PREFIX is accepted-and-ignored
// so existing build recipes keep working; nothing links libav.

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
        name: "COpus",
        pkgConfig: "opus",
        providers: [.apt(["libopus-dev"])]
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
    // The direct eye (docs/20260801-105800-direct-eye-plan.md, E0): libdrm
    // imported straight into Swift — a module map, no .c files. The
    // KMS doorbell/capture organ is Swift-first; CNetIO-style shims
    // appear only if a macro wall does.
    .systemLibrary(
        name: "CDRM",
        pkgConfig: "libdrm",
        providers: [.apt(["libdrm-dev"])]
    ),
    // Direct-eye E0: GBM (headless GPU device), EGL+GL (the 3D engine
    // that reads CCS-compressed scanout the media engine's VPP cannot),
    // and libva (surface export to dmabuf) — all module maps, no .c.
    .systemLibrary(
        name: "CGBM",
        pkgConfig: "gbm",
        providers: [.apt(["libgbm-dev"])]
    ),
    .systemLibrary(
        name: "CEGL",
        pkgConfig: "egl",
        providers: [.apt(["libegl-dev", "libgl-dev"])]
    ),
    .systemLibrary(
        name: "CVA",
        pkgConfig: "libva",
        providers: [.apt(["libva-dev"])]
    ),
    // E6a: the NVENC SDK surface (vendored nvEncodeAPI.h — FFmpeg's
    // nv-codec-headers n12.2, MIT; runtime = the driver's own
    // libnvidia-encode) and the CUDA-context sliver it needs.
    .systemLibrary(name: "CNvEnc"),
    .systemLibrary(name: "CCuda"),
    // E6a milestone 1: the NVENC-native probe — infinite GOP, one
    // demanded IDR, mid-stream NvEncReconfigureEncoder with zero
    // reset — the two levers that retire the vendored no-reset patch.
    .executableTarget(
        name: "lyte-nvenc",
        dependencies: [
            "CNvEnc", "CCuda",
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // The eye's organs as a LIBRARY (E1): the doorbell/ticket DRM
    // layer, the EGL/GL import+blit, and the hevc_vaapi encoder wrap —
    // shared by the standalone lyte-eye and the host's direct backend.
    .target(
        name: "HostEye",
        dependencies: [
            // libav-free since the E6b demolition: the native encoder
            // feeds HostCore's pens (HevcParameterSets,
            // HevcSliceHeader) straight to the driver via libva.
            "CDRM", "CGBM", "CEGL", "CVA",
            "HostCore",
        ]
    ),
    // E0: the standalone eye — doorbell mode (milestone 1, unprivileged)
    // and capture mode (milestone 2: full loop → Annex-B file).
    .executableTarget(
        name: "lyte-eye",
        dependencies: [
            "HostEye", "CDRM",
            .product(name: "LyteIO", package: "Common"),
        ],
        linkerSettings: [
            .linkedLibrary("va"),
            .linkedLibrary("va-drm"),
        ]
    ),
    // C leaf: nonblocking UDP with sendmmsg/recvmmsg, per-packet TOS cmsgs,
    // and SO_TIMESTAMPING TX stamps (CMSG macros are unreachable from Swift;
    // plain Linux syscalls, no system library).
    .target(name: "CNetIO"),
    .testTarget(name: "CNetIOTests", dependencies: ["CNetIO"]),
    // C leaf (E2: the PRIMARY input injector): virtual evdev devices
    // over /dev/uinput — keyboard, relative mouse, absolute tablet.
    // The ioctl surface; policy stays in Swift. Compositor-agnostic
    // by construction (the Mutter RemoteDesktop injector is retired).
    .target(name: "CInputUinput"),
    // E2 verification harness: creates the three devices, reads them
    // back from their evdev nodes, and asserts routing, absolute
    // scaling/clamping, and v120 scroll accumulation byte-exact.
    // Exits nonzero on mismatch. Needs sudo (evdev read side only).
    .executableTarget(
        name: "lyte-uinput-check",
        dependencies: ["CInputUinput"]
    ),
    // HS-4 verification harness: loopback batch send with per-packet DSCP,
    // received-TOS readback, TX-timestamp drain. Exits nonzero on mismatch.
    .executableTarget(
        name: "lyte-netio-check",
        dependencies: [
            "CNetIO",
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // HS-6 verification harness: the pure Pacer schedule driving CNetIO
    // sendmmsg batches on loopback with per-class TOS; TX timestamps
    // measure batch spacing, IDR drain, and audio wait. Exits nonzero if
    // a gate bound is violated.
    .executableTarget(
        name: "lyte-pace-check",
        dependencies: [
            "HostCore", "CNetIO",
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // HS-14 verification harness: default-sink monitor → 5 ms Opus packets
    // → decode-back WAV; prints cadence/size/timestamp stats and exits
    // nonzero if the gate (200 pkt/s, monotonic graph-clock ts, clean loop
    // decode) is violated.
    .executableTarget(
        name: "lyte-audio-check",
        dependencies: [
            "CPipeWireAudio", "COpusEncode",
            .product(name: "LyteIO", package: "Common"),
        ],
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
            // HS-15: the audio leg — monitor capture + Opus encode
            // feeding the session's audio channel.
            "CPipeWireAudio",
            "COpusEncode",
            "CNetIO",
            "CInputUinput",
            // E5: the direct eye is THE capture organ — the portal
            // and mutter ScreenCast backends are demolished.
            "HostEye",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteIO", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
            // HS-10: one SHA-256 for the advertised identity hash
            // (IdentityHash.swift is the confined import site). Already
            // in the graph via Wire — no new external dependency.
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        linkerSettings: [
            .linkedLibrary("dbus-1"),
            .linkedLibrary("pipewire-0.3"),
            .linkedLibrary("opus"),
            .linkedLibrary("va"),
            .linkedLibrary("va-drm"),
        ]
    ),
]
#endif

var dependencies: [Package.Dependency] = [
    // First cross-package integration on the host side (HS-5): the
    // sans-IO protocol core every end codes against.
    .package(path: "../Wire"),
    .package(path: "../Common"),
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
