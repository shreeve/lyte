# Lyte

*Streaming at the speed of Lyte.*

A GPLv3 remote-desktop system that owns both ends of the wire: a
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

Three SwiftPM packages:

```
Wire/     LyteWire — the sans-IO protocol core both ends import
            envelope codec · Noise IK + CPace PAKE · ARQ sublayer
            RS-FEC · capabilities · session state machine · frozen vectors
Host/     LyteHost — the Linux host (lyte-host)
            PipeWire capture · NVENC HEVC · Opus · congestion control
            Avahi discovery · Mutter/uinput input injection
(root)    the macOS client
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

## Status

H2 functional parity: video, 5 ms audio, input injection, congestion
control, loss repair, and blackout recovery all live end-to-end
(`docs/20260722-h2-joint-gate.md`). The client's original GameStream stack
— its bootstrap scaffolding against Sunshine hosts — was deleted at the H2
exit, as designed. See [LYTE-PLAN.md](LYTE-PLAN.md) for strategy and
`docs/20260720-222500-lyte-build-plan.md` for the slice ladder.

## License

GPLv3 — kept gladly from the Moonlight family Lyte grew up reading.
