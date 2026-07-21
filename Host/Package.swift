// swift-tools-version:6.0
import PackageDescription

// HostCore (pure Swift bitstream helpers) and its tests build everywhere,
// including macOS, so the Annex-B contract is testable without a Linux GUI.
// The capture/encode leaves exist only on Linux: they bind PipeWire, D-Bus,
// and libavcodec through pkg-config system libraries.

var products: [Product] = [
    .library(name: "HostCore", targets: ["HostCore"]),
]

var targets: [Target] = [
    .target(name: "HostCore"),
    .testTarget(name: "HostCoreTests", dependencies: ["HostCore"]),
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
    .executableTarget(
        name: "lyte-host",
        dependencies: ["HostCore", "CDBus", "CPipeWireCapture", "CHevcEncode"],
        linkerSettings: [
            .linkedLibrary("dbus-1"),
            .linkedLibrary("pipewire-0.3"),
            .linkedLibrary("avcodec"),
            .linkedLibrary("avutil"),
        ]
    ),
]
#endif

let package = Package(
    name: "LyteHost",
    products: products,
    targets: targets
)
