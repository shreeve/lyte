# How Lyte compares

*Living product positioning, kept separate from protocol law and benchmark
records.*

## Scope

Lyte combines the responsiveness of game streaming, the idle efficiency of a
remote desktop, and the convenience features expected from both. It does not
yet match mature products in platform coverage, WAN traversal, deployment, or
multi-user infrastructure.

The Lyte figures below are dated commissioning evidence, not a matched current
release benchmark. They came from the July 2026 J-G1, H1/H2, and Beauty Bar
runs at 2048×1280 over a LAN with Noise encryption enabled. The quality runs
used pup's former NVENC seat; the shipping direct-eye path now uses native
Intel VAAPI while preserving Lyte's capture, bitstream, transport, and glass
contracts. Competitor descriptions are qualitative product-shape comparisons,
not laboratory measurements.

## Measured Lyte baseline

- A working desktop averaged approximately 4.1 Mbps over 330 seconds and
  approached zero video traffic between damage events.
- First glass arrived 21.4 ms after the first video datagram. Measured
  input-to-photon p50 was 29–49 ms across six runs and 1,833 exactly-once
  injected events.
- Five-millisecond Opus emission held p50 4.999 ms and p99 5.978 ms through
  IDR pressure and a 90-second video squeeze.
- Sustained motion decoded at 61 fps p50 with no lost frames during one
  150-second Beauty Bar leg. The quality ratchet converged static text to
  52 dB luma PSNR and then became quiet.
- HEVC 4:4:4 produced a measured 22 dB text improvement over 4:2:0 in its
  commissioning race. A host offers that posture only after its current
  hardware probe proves the complete path.
- Reed-Solomon FEC absorbed in-band loss; beyond parity, targeted repair asked
  for specific missing shards. A 15% loss leg produced 71 repair asks and 71
  consumed repairs.
- Every accepted datagram is Noise-sealed. The cited H2 evidence observed zero
  unseal failures across roughly 550,000 datagrams.

These numbers describe those exact runs. They remain useful architectural
evidence, but new public performance claims require a fresh, reproducible
commissioning record on the current encoder seat.

## Structural comparison

| Axis | Lyte | Conferencing share | VNC | RDP | Game streaming |
|---|---|---|---|---|---|
| Primary goal | local-computer feel | WAN meetings and many viewers | simple remote pixels | managed desktop work | low-latency games |
| Media path | damage-driven HEVC | buffered adaptive video | region/pixel updates | mixed graphics and video | continuous hardware video |
| Static desktop | converges, then becomes quiet | continues sending | efficient | efficient | usually continues encoding |
| Motion | hardware 60 fps path | trades cadence for reach | often degrades sharply | capable, workload-dependent | excellent |
| Loss response | FEC plus targeted shard repair | transport-managed | commonly TCP-bound | transport-managed | FEC, usually coarse recovery |
| Application security | Noise on every Lyte datagram | mature service security | implementation-dependent | mature enterprise security | protocol-dependent |
| Desktop features | input, audio, clipboard, files | meeting-oriented | basic | broad enterprise set | usually input and audio |
| Reach today | LAN, Tailscale, or explicit forwarding | global service | deployment-dependent | mature remote access | commonly manual/direct |

The important distinction is architectural rather than a claim that one tool
wins every row. Conferencing products own rendezvous and group communication.
RDP owns decades of enterprise integration. VNC is exceptionally deployable.
Game streaming has broad hardware and client coverage. Lyte is narrower and
optimizes for one encrypted, damage-driven desktop session whose timing and
recovery policy it owns end to end.

## Current differentiators

- One independently owned protocol, with no GameStream, RTP, RTSP, VNC, or RDP
  compatibility path.
- Noise encryption, PIN-PAKE pairing, congestion evidence, FEC, targeted
  repair, traffic classes, and connection migration in the same wire design.
- One Conductor owns playout timing. Corrected disturbances remain silent;
  only terminal playback failures reach the user.
- Static-desktop silence and hardware video share one path instead of switching
  between a remote-GUI mode and a video mode.
- Clipboard text and images, file transfer, input, and audio use negotiated,
  consent-gated Lyte channels.

## Honest gaps

The shipping combination is a macOS client and Linux host. Native packaging,
the macOS host role, Windows/Linux role shells, printing, and managed remote
reach remain future work. The browser client is also future work: its wire
contracts pass 511 tests under WebAssembly, but WebTransport, browser runtime
integration, WebCodecs/WebGPU rendering, and AudioWorklet playout are not yet
commissioned. See [BROWSER.md](BROWSER.md) for that boundary.

Keep this page short and honest. Product direction belongs in `README.md` and
`DESIGN.md`; protocol law belongs in the frozen specification; detailed gate
history belongs in Git and dated records.
