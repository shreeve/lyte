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
products.append(.executable(name: "lyte-eye", targets: ["lyte-eye"]))
products.append(.executable(name: "lyte-nvenc", targets: ["lyte-nvenc"]))

// HS-33: the vendored no-reset FFmpeg (Vendor/ffmpeg/README.md — rate
// reconfigures without resetEncoder/forceIDR). Env-gated: with
// LYTE_FFMPEG_PREFIX set (the canonical build exports it alongside
// PKG_CONFIG_PATH — see the README's one recipe), the libav consumers
// link the static archives BY PATH. `-lavcodec` + a `-L` prepend is
// not enough here: the distro .pc files of the other leaves (pipewire,
// dbus) inject `-L/usr/lib/<triple>` ahead of any vendored dir, so
// search order resolves the shared lib; a direct archive path has no
// search order to lose. Unset (fresh checkout, CI): distro libav via
// -l flags, exactly as before. Set-but-missing fails LOUDLY — never a
// silent fallback to distro.
let ffmpegVendorPrefix =
    ProcessInfo.processInfo.environment["LYTE_FFMPEG_PREFIX"]
let libavLinkerSettings: [LinkerSetting]
if let prefix = ffmpegVendorPrefix {
    guard FileManager.default.fileExists(
        atPath: "\(prefix)/lib/libavcodec.a")
    else {
        fatalError("LYTE_FFMPEG_PREFIX=\(prefix) but "
            + "\(prefix)/lib/libavcodec.a is missing — run "
            + "Scripts/vendor-ffmpeg.sh (or unset the env)")
    }
    libavLinkerSettings = [.unsafeFlags([
        "\(prefix)/lib/libavcodec.a",
        "\(prefix)/lib/libavutil.a",
        // The vendored libavcodec.pc's own Libs tail (the .a carries
        // no DT_NEEDED): atomics beyond the inlined ones, and — since
        // the direct eye enabled hevc_vaapi in the vendor recipe —
        // libva for the VAAPI hwcontext the archive now references.
        "-latomic",
        "-lva", "-lva-drm",
    ])]
} else {
    libavLinkerSettings = [
        .linkedLibrary("avcodec"),
        .linkedLibrary("avutil"),
    ]
}

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
    // The direct eye (docs/20260801-direct-eye-plan.md, E0): libdrm
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
        dependencies: ["CNvEnc", "CCuda"]
    ),
    // The eye's organs as a LIBRARY (E1): the doorbell/ticket DRM
    // layer, the EGL/GL import+blit, and the hevc_vaapi encoder wrap —
    // shared by the standalone lyte-eye and the host's direct backend.
    .target(
        name: "HostEye",
        dependencies: [
            "CDRM", "CGBM", "CEGL", "CVA", "CLibAV",
            // E6b: the native encoder feeds HostCore's pens
            // (HevcParameterSets, HevcSliceHeader) to the driver.
            "HostCore",
        ]
    ),
    // E0: the standalone eye — doorbell mode (milestone 1, unprivileged)
    // and capture mode (milestone 2: full loop → Annex-B file).
    .executableTarget(
        name: "lyte-eye",
        dependencies: ["HostEye", "CDRM", "CLibAV"],
        linkerSettings: libavLinkerSettings + [
            .linkedLibrary("va"),
            .linkedLibrary("va-drm"),
        ]
    ),
    // C leaf: nonblocking UDP with sendmmsg/recvmmsg, per-packet TOS cmsgs,
    // and SO_TIMESTAMPING TX stamps (CMSG macros are unreachable from Swift;
    // plain Linux syscalls, no system library).
    .target(name: "CNetIO"),
    .testTarget(name: "CNetIOTests", dependencies: ["CNetIO"]),
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
    // HS-24 A/B harness: deterministic raw frames through the exact
    // CHevcEncode leaf with recipe knobs on the CLI; the ladder script
    // (Scripts/encoder-ab.sh) pairs its Annex-B output with ffmpeg PSNR.
    .executableTarget(
        name: "lyte-encode-check",
        dependencies: ["HostCore", "CHevcEncode"],
        linkerSettings: libavLinkerSettings
    ),
    .executableTarget(
        name: "lyte-host",
        dependencies: [
            "HostCore",
            "HostWire",
            "CDBus",
            "CPipeWireCapture",
            "CHevcEncode",
            // HS-15: the audio leg — monitor capture + Opus encode
            // feeding the session's audio channel.
            "CPipeWireAudio",
            "COpusEncode",
            "CNetIO",
            "CInputUinput",
            // E1: the direct eye as a capture backend (--backend direct).
            "HostEye",
            .product(name: "LyteWire", package: "Wire"),
            // HS-10: one SHA-256 for the advertised identity hash
            // (IdentityHash.swift is the confined import site). Already
            // in the graph via Wire — no new external dependency.
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        linkerSettings: libavLinkerSettings + [
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
