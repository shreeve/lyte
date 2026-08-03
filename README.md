# Lyte

*Streaming at the speed of Lyte.*

An MIT-licensed remote-desktop system that owns both ends of the wire: a
SwiftUI-native macOS client and a Swift Linux host, speaking exactly one
protocol — **Lyte-UDP**, our own datagram protocol over plain UDP. No RTSP,
no RTP, no third-party dialect: every byte on the wire is ours, end-to-end
encrypted with Noise, paced and repaired by our own congestion machinery.

Designed around one idea: **the user states intent, the client derives the settings.**

## The model: one toggle, two axes

Every streaming decision falls on a 2×2 grid:

|            | **Local** (same LAN)                  | **Remote** (over the internet)          |
|------------|---------------------------------------|-----------------------------------------|
| **Work**   | 1:1 pixels, max crispness, free mouse | encrypted, adaptive, resilient desktop  |
| **Play**   | fullscreen, min latency, locked mouse | conservative latency-first game stream  |

The user picks **Work or Play**. That's the entire settings UI.
**Local vs Remote is detected, not asked** — private-subnet check plus measured RTT/jitter.
Every concrete number (bitrate, resolution, buffer depth, codec) is *derived* from the
active cell plus live network telemetry, never frozen into a preset.

## Architecture

Four SwiftPM packages:

```
Wire/     LyteWire — the sans-IO protocol core both ends import
            envelope codec · Noise IK + CPace PAKE · ARQ sublayer
            RS-FEC · capabilities · session state machine · frozen vectors
Common/   LyteCommon — shared code beside the frozen wire contract
            LyteCore sans-IO policy · LyteIO operating-system adapters
Host/     LyteHost — the Linux host (lyte-host)
            direct KMS capture · our own HEVC bitstream pens on VAAPI
            Opus · congestion control · Avahi discovery
            Mutter/uinput input injection
Client/  the macOS client
            Lyte.app (SwiftUI) + lyte-cli
            LyteTransport — socket, demux, video/audio render, input send
```

`LyteWire` is Foundation-free and sans-IO (lint-enforced) — the same core a
future browser client compiles to WASM. The committed test vectors under
`Wire/Vectors/` are frozen wire contracts, byte-exact on macOS and Linux.

## Protocol

The spec lives in the four pillar docs plus the overview
(`docs/20260720-1917*`, `docs/20260720-193000`), reconciled by the decision
record (`docs/20260720-215100-lyte-udp-decision.md`). The short version:
24-byte envelopes over UDP, Noise IK for every datagram, PIN-pairing as a
real PAKE, per-frame adaptive RS-FEC with targeted NACK repair, an
ACTIVE/IDLE/FROZEN/RECOVERY session machine with idle silence, per-packet
DSCP, and app-level congestion control fed by burst dispersion.

## The media path: hardware at both ends

The hard work of video never touches a CPU. On the host, the **direct eye**
reads the display's live scanout straight from the kernel (KMS) — below the
compositor, no portals, no screen-share dialogs — imports it into the GPU's
3D engine for a colorspace blit, and hands it to the **dedicated encode
silicon** (VAAPI on the GPU that owns the panel; NVENC banked for
NVIDIA-panel hosts) driven by our own HEVC bitstream writers. On the
client, compressed samples are handed to `AVSampleBufferDisplayLayer`,
which drives **VideoToolbox** — the dedicated decode engine on Apple
Silicon — through decode, color conversion, and display timing. The CPUs at
both ends do only the light work: packetizing, ChaCha20-Poly1305 sealing,
RS-FEC parity and repair, and pacing.

The same class of dedicated silicon used by modern streaming systems — but
Lyte owns the media path and decides exactly what to ask of it.
Lyte's encoding is **change-driven**: a doorbell on the kernel's
framebuffer ID means nothing is captured or encoded unless the screen
actually changed, so a still desktop costs near-zero bandwidth at full
sharpness, while fixed-cadence streamers re-encode every frame whether
pixels moved or not.

## Status

Live end-to-end since 2026-07-22 (the H2 joint gate): video, 5 ms audio,
input injection, congestion control, loss repair, blackout recovery. Since
then: bidirectional clipboard with images, file transfer with
drag-and-drop, the quality ratchet, adaptive playout cushion — and as of
2026-08-02 (tag `self-hosted`) the host captures and encodes with **no
third-party media stack at all**: kernel scanout in, our own HEVC
bitstream out, zero ffmpeg/libav anywhere in the binary. The client's
original GameStream bootstrap scaffolding was deleted at the H2 exit, as
designed. See [LYTE-PLAN.md](LYTE-PLAN.md) for strategy.

## License

MIT — see [LICENSE](LICENSE).
