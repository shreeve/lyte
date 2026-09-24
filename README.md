# Lyte

*Streaming at the speed of Lyte.*

Lyte is an MIT-licensed remote-desktop system that owns both ends of the
wire: a SwiftUI macOS client and a Swift Linux host that speak one
protocol, **Lyte-UDP**, over plain UDP. There is no RTSP, RTP, GameStream,
Sunshine, Moonlight, VNC or RDP compatibility path. After a Noise
handshake every datagram is encrypted, paced, measured and repaired by
Lyte's own transport.

The goal: use another computer as if it were local, with game-streaming
responsiveness and the conveniences of a remote desktop.

## What works today

- **Linux host** (Ubuntu, GNOME/Mutter, Intel GPU): captures the KMS
  scanout directly, converts color on the GPU, and encodes HEVC with VAAPI
  through Lyte's own Swift bitstream writers. No portal, ffmpeg or libav.
  Static screens are change-driven and nearly silent on the wire.
- **macOS client**: VideoToolbox decode through
  `AVSampleBufferDisplayLayer`, one Conductor timing video and audio, 5 ms
  Opus audio, keyboard and mouse input, clipboard text and images, file
  transfer, PIN pairing, and roaming when the host moves or restarts.
- **Transport**: Noise IK sealing every session datagram, adaptive
  Reed-Solomon FEC, targeted NACK repair, reliable control beside
  low-latency media, application-level congestion control,
  capability-negotiated and consent-gated feature channels.
- **Browser**: a Chrome proof harness (Swift WebAssembly + WebTransport +
  WebCodecs + WebGPU) against a DRM-free test peer. It is not yet a product
  client; see [docs/BROWSER.md](docs/BROWSER.md).

Remote use beyond the LAN means Tailscale or an explicit port forward;
Lyte ships no rendezvous or relay service.

## Architecture

Six SwiftPM packages:

```text
Common/       LyteCore (sans-IO shared policy, the Conductor) · LyteIO · COpus
Wire/         LyteWire — the protocol: codecs, crypto, FEC, ARQ, frozen vectors
Host/         HostCore · HostSession · HostWire · HostIO · HostAudio · HostEye · lyte-host
Client/       LyteClientCore · LyteClientSession · LyteTransport · Lyte.app · lyte-cli · lyte-helperd
Browser/      LyteClientBrowserCore · LyteClientBrowser (WASM) · page and harness
SystemTests/  real client and host composed in one test process
```

```text
host (Linux)                                         client (macOS)
KMS scanout → GPU fingerprint/blit → VAAPI HEVC      UDP → unseal → assemble → Conductor → display
PipeWire → Opus 5 ms              ┐                  UDP → unseal → jitter buffer → AVAudioEngine
                                  ├→ packetize, FEC, pace, seal → UDP ⇄
uinput ← input, clipboard, files  ┘                  ← input, feedback, clipboard, files
```

Swift owns everything above hardware and OS boundaries; C is limited to
narrow leaves (DRM/EGL/VAAPI, PipeWire audio, pinned Opus, UDP syscalls,
uinput, vendored Reed-Solomon). `LyteWire`, `LyteCore` and the role
policy targets are sans-IO and lint-guarded. Committed vectors under
`Wire/Vectors/` are append-only wire contracts, checked byte-for-byte on
macOS, Linux and WebAssembly.

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Quickstart

Requirements: macOS with full Xcode (Command Line Tools lack XCTest); for
the host, a Linux machine as described in
[Host/INSTALL.md](Host/INSTALL.md).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Test a package (the gate adds --scratch-path <Pkg>/.build)
swift test --package-path Wire -Xswiftc -warnings-as-errors

# Every macOS gate at once
Scripts/CI/test-all-macos.sh

# Build, sign and launch the client (quit a running Lyte first)
Scripts/make-app.sh
Scripts/launch-app.sh
```

Client binaries that talk to a host must be signed with a stable identity
so the Keychain grant for the pairing key survives rebuilds; see
[docs/MACOS-SIGNING.md](docs/MACOS-SIGNING.md). Released apps install with
Homebrew and update themselves with Sparkle; cutting a release is in
[docs/RELEASING.md](docs/RELEASING.md). To install a host, follow
[Host/INSTALL.md](Host/INSTALL.md), then
[pair a client](docs/OPERATIONS.md#pairing-a-client).

## Documentation

| Read | For |
|---|---|
| [AGENTS.md](AGENTS.md) | Repository law: ownership, doctrine, safety, change discipline |
| [HANDOFF.md](HANDOFF.md) | Current branch, live rig state, what is next |
| [TODO.md](TODO.md) | Deferred work |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Packages, targets, data flow, threads |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The Lyte-UDP contract and its vectors |
| [docs/TESTING.md](docs/TESTING.md) | Every gate and its exact commands |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | The reference rig, deploy, rollback, pairing, safety |
| [docs/BROWSER.md](docs/BROWSER.md) | The browser client |
| [docs/DESIGN.md](docs/DESIGN.md) | Product and interaction decisions |
| [docs/GLOSSARY.md](docs/GLOSSARY.md) | Slice ids and project vocabulary |
| [docs/README.md](docs/README.md) | Catalog of every document, with the dated decisions and history |

## Direction

1. Make the browser client a real client: live Direct Eye against a real
   host, a persistent session, Safari.
2. A macOS host (ScreenCaptureKit and VideoToolbox leaves).
3. Windows and Linux client and host shells around the same cores.
4. Mobile and relay surfaces once the peer platforms earn them.

The intended product model resolves policy from intent (Work or Play) and
network (Local or Remote); the app does not expose it yet. See
[docs/DESIGN.md](docs/DESIGN.md).

## Non-goals

- VNC, RDP, GameStream, Sunshine or Moonlight compatibility modes.
- A codec zoo: HEVC is the live path; AV1 is a deliberately banked lane.
- Conferencing features.
- A plaintext mode.
- An encoder-knob farm in the primary UI.

## License

Lyte-authored code is MIT-licensed. Bundled third-party leaves keep their
upstream licenses and notices: [LICENSE](LICENSE) and
[docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).
