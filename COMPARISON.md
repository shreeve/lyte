# How Lyte Compares

*Where Lyte-UDP desktop streaming stands against conferencing screen share,
traditional remote desktop, and its own game-streaming lineage. Measured
figures are from the J-G1 gate runs of 2026-07-21 (2048×1280@60 real
desktop, the reference host → Mac client over LAN Wi-Fi, Noise encryption
end to end); competitor figures are typical published/observed ranges, not
lab-matched benchmarks.*

## The one-sentence summary

Lyte already delivers **game-streaming latency at screen-sharing bandwidth
with remote-desktop idle behavior — and stronger encryption than all of
them** — with the remaining gaps (input, audio on the wire, WAN hardening)
scheduled work, not open questions.

## Our measured baseline (J-G1, encrypted, live)

- **Bandwidth**: ~4.1 Mbps average for a working 2048×1280@60 desktop
  (169 MB over 330 s); near-zero between damage events on a static screen.
- **Latency**: first frame on glass 21.4 ms after the first datagram;
  fresh-frame capture→assembled ~16 ms; ~9 ms Wi-Fi RTT underneath.
- **Quality**: damage-driven 60 fps HEVC (NVENC); the quality ratchet
  converges static content to ~50 dB luma PSNR (visually lossless text)
  in under a second, then goes silent.
- **Resilience**: RS-FEC healed real Wi-Fi loss transparently (0.001%
  loss in the sign-off run; 5% induced loss healed via FEC + coalesced
  IDR requests in the gate runs). Connection migration with
  anti-amplification is built in.
- **Security**: every datagram sealed under Noise IK with a 16-byte proof;
  0 unseal failures across ~300k datagrams of gate evidence; per-packet
  DSCP marking (40 video / 48 control) on the wire.

## Vs. conferencing screen share (Google Meet, Zoom, GoToMeeting)

Their bandwidth is similar or lower (1–4 Mbps) — but that is where the
comparison ends. Conferencing tools are built for WAN traversal and many
viewers, so they buffer aggressively:

- Glass-to-glass latency is typically **200–500+ ms** (vs our ~20 ms).
- Screen-share frame rates routinely drop to **5–15 fps** (vs steady 60).
- Text is smeared by motion-adaptive compression and 4:2:0 chroma; there
  is no ratchet-to-lossless behavior, and they never stop sending on a
  static screen.

We deliver 60 fps at conferencing-class bandwidth *because* we are
damage-driven. The honest caveat: they solve NAT traversal, relays, and
multi-party viewing — problems Lyte has not touched yet (WAN/congestion
work lands with H2's CC and the later bridge work).

## Vs. VNC

VNC is pixel-region copying with CPU codecs. Fine for a static form; it
collapses under motion — full-screen video either spikes to tens of Mbps
or degrades to a slideshow — and typical interactive latency is
**100–300 ms**. Lyte is roughly **10× lower latency** with hardware HEVC
absorbing motion gracefully. VNC's only structural kinship with us is
that it, too, is damage-driven.

## Vs. RDP

The strongest traditional competitor. Modern RDP with AVC444 is genuinely
good for office work: low bandwidth on static content, ~50–100 ms LAN
latency, sharp text. Lyte deliberately steals its best property — send
nothing when nothing changes — but marries it to a game-streaming video
pipeline, so quality does not degrade when the content becomes video or
animation. The one axis where RDP currently beats us: its 4:4:4 mode
renders chroma-heavy text sharper than our 4:2:0 stream. That is exactly
the H4 4:4:4 work on the roadmap.

## Vs. Sunshine / GameStream (Moonlight)

Our true lineage, and the most direct comparison — the same reference box
runs both today.

- **Bandwidth**: GameStream is constant-bitrate. Configure 20 Mbps and it
  burns ~20 Mbps forever, re-encoding a static desktop at 60 fps. Lyte
  averaged **~4 Mbps for the same desktop** — a ~5× saving that grows the
  more idle the desktop is — and goes near-silent between damage events.
- **Latency**: same class (~5–20 ms LAN glass-to-glass). Neither side has
  a meaningful edge here; both are NVENC-fed UDP with FEC.
- **Security**: GameStream's video RTP flies **unencrypted** (only control
  and audio are encrypted). Every Lyte datagram — video shards, beacons,
  challenges — rides sealed under Noise.
- **Extras GameStream lacks**: per-packet DSCP, connection migration with
  path validation, a clock-beacon layer for honest latency accounting,
  and the quality ratchet.
- **What it still has that we don't (yet)**: input, audio on the wire, and
  congestion control — the H1→H2 ladder, in order.

## Quick reference

| Axis | Lyte (measured) | Meet/Zoom/GTM | VNC | RDP (AVC444) | Sunshine/GameStream |
|---|---|---|---|---|---|
| Glass-to-glass latency | ~20 ms | 200–500+ ms | 100–300 ms | 50–100 ms | 5–20 ms |
| Frame rate (desktop) | 60 fps | 5–15 fps | varies, poor | 30–60 fps | 60 fps |
| Bandwidth (working desktop) | ~4 Mbps, ~0 idle | 1–4 Mbps, constant | spiky | low idle, poor motion | ~20 Mbps constant |
| Static-content quality | ratchets to ~lossless | lossy | exact but slow | sharp (4:4:4) | fixed QP, lossy |
| Encryption | everything (Noise IK) | TLS/SRTP | usually weak/none | TLS | video unencrypted |
| Motion/video content | good (HEVC 60) | poor | very poor | fair | good |
| WAN/NAT story | not yet (H2+) | excellent | poor | fair | fair (manual) |
| Input + audio | not yet (H2) | n/a / yes | yes | yes | yes |

## Where this gets awesome (roadmap features that widen the gap)

The comparison above is Lyte at H0b — pixels only. The ladder ahead adds
the capabilities that make a remote desktop feel local, each riding the
same encrypted, paced, FEC-protected wire:

- **H2**: input (Mutter RemoteDesktop injection, ~18 ms proven) and audio
  (5 ms Opus at a rock-steady 200 pkt/s, capture pipeline already gated),
  plus congestion control — parity with GameStream, at which point the
  scaffolding is deleted and Sunshine uninstalled.
- **H3**: the feature channel — **clipboard** both ways, then
  **drag-and-drop file transfer**, riding the ARQ reliable sublayer.
  RDP has clipboard; conferencing tools mostly don't; GameStream never
  did. Files-over-the-streaming-wire with E2E crypto is territory none
  of the compared products occupy cleanly.
- **H4**: 4:4:4 chroma + the full quality-ratchet policy — removing RDP's
  last text-sharpness advantage while keeping 60 fps motion.
- **H5**: **printing** and file features — the classic "corporate RDP"
  differentiators, on a modern wire.
- **H6+**: one `lyte` binary, macOS host, and the WASM/browser client via
  the datagram-relay bridge — the conferencing tools' "join from
  anywhere" convenience, without their latency.

*Keep this document honest: update the measured column when new gate
evidence lands, and mark competitor numbers as ranges unless they come
from a matched benchmark.*
