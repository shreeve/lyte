// swift-tools-version:6.0
import PackageDescription

// The pure targets (HostCore, HostSession, HostAudio, HostWire, HostIO)
// and their tests build everywhere, macOS included. The capture, encode
// and IO leaves exist only on Linux: they bind PipeWire, D-Bus,
// DRM/GBM/EGL/VAAPI, uinput and UDP through narrow C or system-library
// targets.

var products: [Product] = [
    .library(name: "HostCore", targets: ["HostCore"]),
    .library(name: "HostSession", targets: ["HostSession"]),
    .library(name: "HostAudio", targets: ["HostAudio"]),
    .library(name: "HostWire", targets: ["HostWire"]),
    // Test equipment for other packages' gates; only test targets link it.
    .library(name: "HostWireTestKit", targets: ["HostWireTestKit"]),
    // A DRM-free HostWire peer over UDP, the browser proof's host.
    .executable(name: "lyte-control-peer", targets: ["lyte-control-peer"]),
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
    .target(
        name: "HostSession",
        dependencies: [
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostSessionTests",
        dependencies: [
            "HostSession",
            .product(name: "LyteWire", package: "Wire"),
            .product(name: "LyteWireTestKit", package: "Wire"),
        ]
    ),
    // Host audio codec policy in Swift over the one pinned COpus mechanism.
    // This stays platform-neutral; PipeWire capture remains a Linux C leaf.
    .target(
        name: "HostAudio",
        dependencies: [
            .product(name: "COpus", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostAudioTests",
        dependencies: ["HostAudio"]
    ),
    // Sans-IO session execution: encoded frames → packetizer + FEC →
    // sealed, paced datagrams, plus the sniff header formatter.
    .target(
        name: "HostWire",
        dependencies: [
            "HostCore",
            "HostSession",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    // The host's cross-platform OS adapters over HostWire's seams (the
    // file-drop store); keeps HostWire itself IO-free.
    .target(
        name: "HostIO",
        dependencies: [
            "HostWire",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
    // Test-only: a shipping Session on an outbox and virtual time, plus
    // the settle loop every HostWire gate drives its fake client through.
    .target(
        name: "HostWireTestKit",
        dependencies: [
            "HostWire",
            "HostSession",
            .product(name: "LyteWire", package: "Wire"),
            .product(name: "LyteWireTestKit", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostWireTests",
        dependencies: [
            "HostWire",
            "HostWireTestKit",
            "HostIO",
            "HostSession",
            "HostCore",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
            .product(name: "LyteWireTestKit", package: "Wire"),
        ]
    ),
    .testTarget(
        name: "HostLayoutTests",
        dependencies: [
            .product(name: "LyteTestKit", package: "Common"),
        ]
    ),
    // Real HostWire Noise, pairing and capabilities (optionally a video
    // corpus and an Opus tone) over UDP, with no Direct Eye.
    .executableTarget(
        name: "lyte-control-peer",
        dependencies: [
            "HostSession",
            "HostWire",
            "HostAudio",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteIO", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
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
    // C leaf: pw_stream capture of the default sink's monitor
    // (stream.capture.sink), F32 48 kHz stereo, graph-clock timestamps.
    .target(
        name: "CPipeWireAudio",
        dependencies: ["CPipeWire"]
    ),
    .testTarget(
        name: "CPipeWireAudioTests",
        dependencies: [
            "CPipeWireAudio",
            .product(name: "LyteIO", package: "Common"),
        ],
        linkerSettings: [.linkedLibrary("pipewire-0.3")]
    ),
    // libdrm imported straight into Swift: a module map, no C sources.
    .systemLibrary(
        name: "CDRM",
        pkgConfig: "libdrm",
        providers: [.apt(["libdrm-dev"])]
    ),
    // GBM (the headless GPU device), EGL+GL (the 3D engine that reads
    // CCS-compressed scanout) and libva (encode, surface export): module
    // maps, no C sources.
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
    // The Direct Eye as a library: the DRM ticket layer, GPU pixel
    // observation, EGL import and blit, and the VAAPI seat that feeds
    // HostCore's pens to the driver.
    .target(
        name: "HostEye",
        dependencies: [
            "CDRM", "CGBM", "CEGL", "CVA",
            "HostCore",
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // HostEye bookkeeping (GEM-handle and cursor-plane transitions) and
    // render-node naming. They never take a card node or its master; the
    // render-node test opens a render node when one exists, which touches
    // no display state.
    .testTarget(name: "HostEyeTests", dependencies: ["HostEye"]),
    // C leaf: nonblocking UDP with sendmmsg/recvmmsg, per-packet TOS and
    // TX timestamps (CMSG macros are unreachable from Swift).
    .target(name: "CNetIO"),
    .testTarget(name: "CNetIOTests", dependencies: ["CNetIO"]),
    // C leaf, the only input injector: virtual evdev devices over
    // /dev/uinput (keyboard, relative mouse, absolute tablet). Policy
    // stays in Swift.
    .target(name: "CInputUinput"),
    // Harness: creates the three devices, reads them back from their
    // evdev nodes, and checks routing, absolute scaling and v120 scroll
    // byte-exact. Needs sudo for the evdev read side.
    .executableTarget(
        name: "lyte-uinput-check",
        dependencies: ["CInputUinput"]
    ),
    // Harness: loopback batch send with per-packet DSCP, received-TOS
    // readback and the TX-timestamp drain.
    .executableTarget(
        name: "lyte-netio-check",
        dependencies: [
            "CNetIO",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // Harness: the Pacer schedule driving CNetIO batches on loopback; TX
    // timestamps bound batch spacing, IDR drain and audio wait.
    .executableTarget(
        name: "lyte-pace-check",
        dependencies: [
            "HostCore", "CNetIO",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteIO", package: "Common"),
        ]
    ),
    // Harness: default-sink monitor → 5 ms Opus packets → decode-back
    // WAV; checks 200 packets/s, monotonic graph-clock stamps and a clean
    // decode.
    .executableTarget(
        name: "lyte-audio-check",
        dependencies: [
            "HostCore", "HostAudio", "CPipeWireAudio",
            .product(name: "LyteIO", package: "Common"),
        ],
        linkerSettings: [
            .linkedLibrary("pipewire-0.3"),
        ]
    ),
    .executableTarget(
        name: "lyte-host",
        dependencies: [
            "HostCore",
            "HostSession",
            "HostWire",
            "HostIO",
            "CDBus",
            "CPipeWireAudio",
            "HostAudio",
            "CNetIO",
            "CInputUinput",
            "HostEye",
            .product(name: "LyteCore", package: "Common"),
            .product(name: "LyteIO", package: "Common"),
            .product(name: "LyteWire", package: "Wire"),
        ],
        // CPipeWireAudio is C, so nothing autolinks libpipewire for it;
        // the Swift-imported module maps link their own libraries.
        linkerSettings: [.linkedLibrary("pipewire-0.3")]
    ),
    .testTarget(
        name: "LyteHostIntegrationTests",
        dependencies: [
            "lyte-host",
            "CDBus",
            "CNetIO",
            "HostCore",
            "HostIO",
            "HostSession",
            "HostWire",
            .product(name: "LyteWire", package: "Wire"),
        ]
    ),
]
#endif

let dependencies: [Package.Dependency] = [
    .package(path: "../Wire"),
    .package(path: "../Common"),
]

let package = Package(
    name: "LyteHost",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
