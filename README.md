# Lyte

*Streaming at the speed of Lyte.*

Lyte is an MIT-licensed remote-desktop system that owns both ends of the
wire: a SwiftUI-native macOS client and a Swift Linux host speaking exactly
one protocol, **Lyte-UDP**, over plain UDP. There is no RTSP, RTP,
GameStream, Sunshine, Moonlight, VNC, or RDP compatibility path. Every byte
on the wire is ours — Noise-encrypted, paced, measured, and repaired by
Lyte's own transport.

The product goal is simple: use another computer as if it were local, with
game-streaming responsiveness and the conveniences expected from a remote
desktop.

## Product model

The long-term model is that the user states intent and Lyte derives
settings. Policy falls on two axes:

| | **Local** | **Remote** |
|---|---|---|
| **Work** | native pixels, maximum text fidelity, free mouse | adaptive, resilient, legible desktop |
| **Play** | minimum latency, fullscreen, locked mouse | conservative latency-first stream |

The shipping app does not yet expose Work/Play. It connects directly to a
host and keeps explicit controls to real declarations and consent, while
rate, repair, pacing, and Conductor reserve already derive from live
evidence. See [`docs/DESIGN.md`](docs/DESIGN.md) for shipping versus
directional boundaries.

Long-term, one program named Lyte on each platform can be a client, a host,
or both; discovery, pairing, identity, and feature consent stay coherent
whichever role is active.

## Repository

Five SwiftPM packages keep protocol, policy, IO, roles, and composition
tests separate:

```text
Wire/         LyteWire — Foundation-free, sans-IO protocol core and vectors
Common/       LyteCore policy + LyteIO operating-system adapters
Host/         HostCore + HostSession + HostAudio + HostWire + Linux OS leaves
Client/       LyteClientCore + LyteClientSession + LyteTransport + app/CLI
SystemTests/  cross-role composition tests; no production ownership
```

Swift owns everything above hardware and OS boundaries. C is limited to
narrow leaves (DRM/EGL/VAAPI, PipeWire, pinned Opus, UDP syscalls, uinput,
vendored Reed-Solomon). `LyteWire` and `LyteCore` are sans-IO and
lint-guarded; committed vectors under `Wire/Vectors/` are append-only wire
contracts tested byte-for-byte on macOS, Linux, and WebAssembly.

The Linux host reads KMS scanout, converts color on the GPU, and drives
native VAAPI with Lyte's Swift HEVC bitstream writers. The macOS client
hands compressed samples to VideoToolbox through
`AVSampleBufferDisplayLayer`. Static desktops are change-driven and nearly
silent on the wire.

## Protocol and security

Lyte-UDP provides Noise IK encryption for every accepted datagram; PIN
pairing through a PAKE with pinned static identities; adaptive Reed-Solomon
FEC and targeted NACK repair; reliable control beside low-latency media;
explicit active / idle / frozen / recovery behavior; and application-level
congestion control. Encryption is always on. Feature channels are
capability-negotiated and separately consented. Payload contents are never
logged.

The protocol specification is the four dated pillars plus overview,
reconciled by the one-protocol decision — catalogued in
[`docs/README.md`](docs/README.md). Start with
[`docs/20260720-215100-lyte-udp-decision.md`](docs/20260720-215100-lyte-udp-decision.md)
and
[`docs/20260720-193000-lyte-protocol-overview.md`](docs/20260720-193000-lyte-protocol-overview.md).

## Platform direction

The macOS client and Linux host are live end-to-end: HEVC 4:2:0/4:4:4,
5 ms Opus audio, input, congestion control, targeted repair, clipboard, and
file transfer. Since the `self-hosted` milestone, the host captures and
encodes without portals, ffmpeg, or libav. The harsh-path control plane and
Conductor Wi‑Fi bars are closed; that path has earned peer-platform work.

The order ahead:

1. **Browser client platform** — B-1 green in Chrome (`Browser/`): Swift
   WASM + JS bridge exercises frozen envelope and Noise IK vectors. Next is
   WebTransport (B-2), then session/media up the ladder in
   [`docs/BROWSER.md`](docs/BROWSER.md). B-0 freeze:
   [`docs/20260807-021425-browser-client-platform-slice.md`](docs/20260807-021425-browser-client-platform-slice.md).
   The wasmtime Wire suite remains a separate portability attestation.
2. Add the macOS host (ScreenCaptureKit + VideoToolbox leaves).
3. Add Windows and Linux client/host shells around the same shared cores.
4. Mobile and relay surfaces after the peer platforms earn them.

Remote v1 means direct UDP on the LAN and Tailscale or an explicit port
forward beyond it — Lyte does not ship a rendezvous or TURN fleet today.
The browser path adds an opaque WebTransport ↔ UDP adapter; it does not
replace Lyte-UDP.

## Non-goals

- No VNC, RDP, GameStream, Sunshine, or Moonlight compatibility modes.
- No codec zoo; HEVC is the live path and AV1 is a deliberately banked lane.
- No conferencing features.
- No plaintext mode.
- No encoder-knob farm in the primary UI.

## Building

Each package builds and tests independently. macOS requires the full Xcode
toolchain (`DEVELOPER_DIR=/Applications/Xcode.app`). Canonical package test
commands, pup deploy, signing, and safety rules live in
[`AGENTS.md`](AGENTS.md). Host install notes are in
[`Host/README.md`](Host/README.md). Client binaries that contact a host use
`Scripts/build-cli.sh` / `Scripts/make-app.sh` and `Scripts/launch-app.sh`
(see [`docs/MACOS-SIGNING.md`](docs/MACOS-SIGNING.md)).

Current work and live-rig state: [`HANDOFF.md`](HANDOFF.md).
Deferred actionable work: [`TODO.md`](TODO.md).

## License

Lyte-authored code is MIT-licensed. Bundled third-party leaves retain their
upstream licenses and notices. See [`LICENSE`](LICENSE) and
[`docs/THIRD-PARTY.md`](docs/THIRD-PARTY.md).
