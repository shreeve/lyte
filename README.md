# Lyte

*Streaming at the speed of Lyte.*

Lyte is an MIT-licensed remote-desktop system that owns both ends of the
wire: a SwiftUI-native macOS client and a Swift Linux host speaking exactly
one protocol, **Lyte-UDP**, over plain UDP. There is no RTSP, RTP,
GameStream, Sunshine, or Moonlight compatibility layer in the product.
Every byte on the wire is ours: Noise-encrypted, paced, measured, and
repaired by Lyte's own transport.

The product goal is simple: use another computer as if it were local, with
game-streaming responsiveness and the conveniences expected from a remote
desktop.

## Product model

The user states intent; Lyte derives settings. Every streaming decision
falls on two axes:

| | **Local** | **Remote** |
|---|---|---|
| **Work** | native pixels, maximum text fidelity, free mouse | adaptive, resilient, legible desktop |
| **Play** | minimum latency, fullscreen, locked mouse | conservative latency-first stream |

The user chooses **Work** or **Play**. Local versus remote is detected from
address and measured RTT/jitter. Bitrate, resolution, buffer depth, chroma,
and other concrete values are policy results—not a preset farm.

The long-term product is one program named Lyte on each platform. It can be
a client, a host, or both; discovery, pairing, identity, and feature consent
remain coherent whichever role is active.

## Repository

Five SwiftPM packages keep protocol, policy, IO, roles, and composition
tests separate:

```text
Wire/         LyteWire — Foundation-free, sans-IO protocol core and vectors
Common/       LyteCore policy + LyteIO operating-system adapters
Host/         HostCore + HostAudio + HostWire + Linux hardware/OS leaves
Client/       LyteClientCore + LyteClientSession + LyteTransport + app/CLI
SystemTests/  cross-role composition tests; no production ownership
```

Swift owns everything above hardware and operating-system boundaries. C is
limited to narrow leaves such as DRM/EGL/VAAPI, PipeWire, the pinned Opus
codec, UDP syscalls, uinput, and the vendored Reed-Solomon implementation.
`LyteWire` and `LyteCore` are sans-IO and lint-guarded; committed vectors
under `Wire/Vectors/` are append-only wire contracts tested byte-for-byte
on macOS and Linux.

The direct media path avoids general-purpose transcoding stacks. The Linux
host reads KMS scanout, performs its color conversion on the GPU, and drives
native VAAPI with Lyte's Swift HEVC bitstream writers. The macOS client
hands compressed samples to VideoToolbox through
`AVSampleBufferDisplayLayer`. Static desktops are change-driven and become
nearly silent on the wire.

## Protocol and security

Lyte-UDP provides:

- Noise IK encryption for every accepted datagram;
- PIN pairing through a PAKE, followed by pinned static identities;
- adaptive Reed-Solomon FEC and targeted NACK repair;
- reliable control and feature messages beside low-latency media;
- explicit active, idle, frozen, and recovery behavior;
- per-packet traffic classes and application-level congestion control.

Encryption is always on. Viewing, input, clipboard text, clipboard images,
files, and future feature channels are capability-negotiated and separately
consented. Payload contents are never logged.

The protocol specification is the four dated pillar documents and their
overview, reconciled by the one-protocol decision:

- [`docs/20260720-191701-lyte-protocol-image-quality.md`](docs/20260720-191701-lyte-protocol-image-quality.md)
- [`docs/20260720-191702-lyte-protocol-timing.md`](docs/20260720-191702-lyte-protocol-timing.md)
- [`docs/20260720-191703-lyte-protocol-resiliency.md`](docs/20260720-191703-lyte-protocol-resiliency.md)
- [`docs/20260720-191704-lyte-protocol-transport.md`](docs/20260720-191704-lyte-protocol-transport.md)
- [`docs/20260720-193000-lyte-protocol-overview.md`](docs/20260720-193000-lyte-protocol-overview.md)
- [`docs/20260720-215100-lyte-udp-decision.md`](docs/20260720-215100-lyte-udp-decision.md)

[`docs/README.md`](docs/README.md) catalogs the living decisions, frozen
records, plans, and studies without duplicating them here.

## Platform direction

The macOS client and Linux host are live end-to-end: HEVC 4:2:0/4:4:4,
5 ms Opus audio, input, congestion control, targeted repair, clipboard,
and file transfer. Since the `self-hosted` milestone, the host captures and
encodes without portals, ffmpeg, or libav.

The order ahead is deliberate:

1. Commission and harden the macOS-client/Linux-host path.
2. Add the macOS host using ScreenCaptureKit and VideoToolbox leaves.
3. Add Windows and Linux client/host shells around the same shared cores.
4. Consider browser, mobile, and relay surfaces only after the native path
   earns them.

Remote v1 means direct UDP on the LAN and Tailscale or an explicit port
forward beyond it. Lyte does not ship a rendezvous or TURN fleet today.

## Non-goals

- No VNC, RDP, GameStream, Sunshine, or Moonlight compatibility modes.
- No codec zoo; HEVC is the live path and AV1 is a deliberately banked lane.
- No conferencing features.
- No plaintext mode.
- No encoder-knob farm in the primary UI.

## Building

Each package is built and tested independently. macOS commands require the
full Xcode toolchain:

```sh
cd Wire && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Common && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Host && DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift test --package-path Client --scratch-path .build
cd SystemTests && DEVELOPER_DIR=/Applications/Xcode.app swift test
```

Host deployment details are in [`Host/README.md`](Host/README.md). Stable
repository rules are in [`AGENTS.md`](AGENTS.md); current work and live rig
state are in [`HANDOFF.md`](HANDOFF.md); deliberately deferred work is in
[`TODO.md`](TODO.md).

## License

Lyte-authored code is MIT-licensed. Bundled third-party leaves retain their
upstream licenses and notices. See [`LICENSE`](LICENSE) and the
[`docs/THIRD-PARTY.md`](docs/THIRD-PARTY.md) catalog.
