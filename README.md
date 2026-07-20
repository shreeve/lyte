# Lyte

*Streaming at the speed of Lyte.*

A SwiftUI-native macOS streaming client for [Sunshine](https://github.com/LizardByte/Sunshine)
hosts, speaking the Moonlight protocol. **GPLv3**, proudly in the same family as the
reference implementations it learns from:
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and
[moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos).

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

Superusers get named **profiles**: clone a cell's derived policy, override any knob,
save/share as JSON. Overrides display alongside what the policy would have chosen,
and "reset to policy" is always one click.

## The network doctor

Streaming clients stutter silently; Lyte diagnoses. The client continuously measures
path jitter and knows the usual suspects on macOS and Linux hosts:

- AWDL (AirDrop/AirPlay) radio-sharing jitter on the client
- Wi-Fi power-save latency spikes on the host
- same-channel double-airtime when both ends are wireless
- rate-control downshift (retries) on the host uplink

When quality degrades, Lyte names the culprit and — where possible — fixes it.

## Architecture

```
SwiftUI app (settings, hosts, policy engine, network doctor)
  └─ LyteKit (Swift)
       ├─ Pairing        … HTTPS + PIN handshake, client certs
       ├─ Session        … RTSP negotiation
       ├─ Control        … ENet reliable-UDP control + input channel
       └─ Media          … RTP depacketization + Reed-Solomon FEC
  └─ VideoToolbox → CAMetalLayer   … zero-copy hardware decode/render
  └─ AudioUnit + Opus               … low-latency audio
  └─ CoreHID / GameController       … input, free/locked mouse
```

## References

Being GPL, Lyte reads, ports, and — where it beats rewriting — links the ecosystem's
battle-tested code. Study summaries live in [docs/moonlight-common-c.md](docs/moonlight-common-c.md)
(protocol core) and [docs/moonlight-macos.md](docs/moonlight-macos.md) (macOS client frameworks and
patterns); the reference checkouts sit in `misc/` (untracked).
The [Wolf protocol docs](https://games-on-whales.github.io/wolf/stable/protocols/index.html)
remain a useful written spec.

## Status

Pre-alpha. See [docs/DESIGN.md](docs/DESIGN.md) for the decisions and
[LYTE-PLAN.md](LYTE-PLAN.md) for the strategy and milestones.

## License

GPLv3 — the license of the Moonlight family, kept gladly.
