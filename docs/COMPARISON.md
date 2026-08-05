# How Lyte Compares

*Where Lyte-UDP desktop streaming stands against conferencing screen share,
traditional remote desktop, and its own game-streaming lineage. Measured
figures are from the J-G1 gate runs of 2026-07-21, the H1/H2 joint gates
of 2026-07-22 (gate reports retired to git history:
`git show 4bb3e11:docs/20260722-132317-h2-joint-gate.md`), and the standing Beauty Bar rows of
2026-07-29 (HANDOFF.md, `quality-probe.sh`) — 2048×1280@60 real desktop,
the reference host → Mac client over LAN Wi-Fi, Noise encryption end to
end; competitor figures are typical published/observed ranges, not
lab-matched benchmarks.*

## The one-sentence summary

Lyte delivers **game-streaming latency at screen-sharing bandwidth with
remote-desktop idle behavior — and stronger encryption than all of them** —
with input, audio, honest congestion control, targeted loss repair,
clipboard (text and images, both ways), drag-and-drop file transfer, and
4:4:4 chroma now measured and landed, and the remaining gaps (WAN
traversal, browser client) scheduled work, not open questions.

## Measured gate baseline (encrypted, live)

These are dated end-to-end gate measurements, not a synthetic current-release
benchmark. The cited quality runs used the reference host's former NVENC seat;
the shipping direct-eye host now uses native Intel VAAPI while preserving the
same Lyte-owned capture, bitstream, transport, and glass contracts.

- **Bandwidth**: ~4.1 Mbps average for a working 2048×1280@60 desktop
  (169 MB over 330 s); near-zero between damage events on a static screen.
- **Latency**: first frame on glass 21.4 ms after the first datagram;
  fresh-frame capture→assembled ~16 ms; ~9 ms Wi-Fi RTT underneath.
- **Input**: keystrokes/mouse ride the sealed reliable stream —
  **input→photon p50 29–49 ms** measured end to end across the H2 gate's
  six runs (1,833 scripted events, 100% injected exactly-once with
  echoes; host receive→inject p50 ~1.2 ms). An input event in an idle
  session wakes it in ~20 ms (p50).
- **Audio**: desktop audio as 5 ms Opus packets under RS 4+2 FEC —
  emission cadence at the host NIC **p50 4.999 / p99 5.978 ms**, held
  through IDR bursts and a 90 s video squeeze (receiver concealment
  0.037% through the squeeze). Audio keeps flowing through idle and
  frozen states as the always-on path probe.
- **Quality**: damage-driven 60 fps HEVC (NVENC in the cited gate; native VAAPI
  on the current reference host); the quality ratchet
  converges static content to **52 dB luma PSNR** (visually lossless
  text) then goes silent; sustained heavy motion decodes at **61 fps
  p50 at the glass** with **0 frames lost in 150 s** (Beauty Bar row 4,
  2026-07-29). **4:4:4 chroma is served live** — a client asking Best
  gets an Rext yuv444 session end to end (measured **+22 dB on text at
  fewer bits** vs 4:2:0 in the V-3 race; hardware-decoded on the Mac).
- **Adaptation honesty** (2026-07-29): the estimator anchors every rate
  fall to a capacity belief built only from evidence a self-limited
  sender cannot fake — under a deliberate 25 Mbit squeeze it falls in
  ~0.5 s anchored at the shaper's true rate, and while sharing air with
  a 30 Mbps competing flood it holds ~40 Mbps at the glass instead of
  spiraling (the truth-probe legs, HANDOFF wave entries).
- **Resilience**: RS-FEC heals real Wi-Fi loss transparently; past
  parity, targeted NACK repair asks for exactly the missing shards (the
  H2 gate's 15%-loss leg: 71 asks ↔ 71 consumed, 1:1 on the wire, frames
  healed by repair with stale asks answered by IDR). Blackout recovery is
  measured: freeze pill within ~425 ms of the last arrival, cleared ≤1 ms
  after the first returning datagram. Connection migration with
  anti-amplification is built in.
- **Congestion control**: delivery-rate estimation from burst dispersion —
  rate falls anchor to *measured* delivery (never blind multiplicative
  guesses), loss in FEC's band is held rather than crashed, and the rate
  climbs back to ceiling on fresh evidence after squeezes and blackouts.
- **Security**: every datagram sealed under Noise IK with a 16-byte proof;
  **0 unseal failures across ~550k datagrams** of H2 gate evidence;
  PIN-pairing is a real PAKE (CPace); per-packet DSCP marking (40 video /
  48 audio+control) on the wire.

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
multi-party viewing — problems Lyte has not touched yet (v1 remote reach
is Tailscale or a port-forward; the browser bridge comes later).

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
animation. RDP's one former advantage — its 4:4:4 mode rendering
chroma-heavy text sharper than a 4:2:0 stream — fell with the H4 wave
(2026-07-29): Lyte now negotiates and serves **4:4:4 (HEVC Rext)** live,
measured +22 dB on text at fewer bits than the 4:2:0 recipe, hardware
decoded at the glass — while keeping the 60 fps motion pipeline RDP's
AVC444 cannot match.

## Vs. Sunshine / GameStream (Moonlight)

Our true lineage — and, as of the H2 exit (2026-07-22), a system Lyte has
**fully replaced**: Sunshine is uninstalled from the reference box and the
client's GameStream stack is deleted. These rows describe what we measured
while both ran side by side, and what the lineage never had.

- **Bandwidth**: GameStream is constant-bitrate. Configure 20 Mbps and it
  burns ~20 Mbps forever, re-encoding a static desktop at 60 fps. Lyte
  averaged **~4 Mbps for the same desktop** — a ~5× saving that grows the
  more idle the desktop is — and goes near-silent between damage events.
- **Latency**: same class (~5–20 ms LAN glass-to-glass). Neither side has
  a meaningful edge here; both use hardware-encoded UDP video with FEC.
- **Input and audio**: at parity, measured (input→photon p50 29–49 ms;
  5 ms audio cadence held at p99 under load) — on the sealed wire, which
  GameStream's never were.
- **Security**: GameStream's video RTP flies **unencrypted** (only control
  and audio are encrypted). Every Lyte datagram — video shards, audio,
  input, beacons, challenges — rides sealed under Noise, and pairing is a
  real PAKE instead of certificate exchange.
- **Extras GameStream lacks**: measured congestion control (GameStream
  streams blind at its configured bitrate), targeted NACK repair,
  per-packet DSCP, connection migration with path validation, a
  clock-beacon layer for honest latency accounting, idle silence, and the
  quality ratchet.

## Quick reference

| Axis | Lyte (measured) | Meet/Zoom/GTM | VNC | RDP (AVC444) | Sunshine/GameStream |
|---|---|---|---|---|---|
| Glass-to-glass latency | ~20 ms | 200–500+ ms | 100–300 ms | 50–100 ms | 5–20 ms |
| Frame rate (desktop) | 60 fps (61 p50 sustained heavy motion, at the glass) | 5–15 fps | varies, poor | 30–60 fps | 60 fps |
| Bandwidth (working desktop) | ~4 Mbps, ~0 idle | 1–4 Mbps, constant | spiky | low idle, poor motion | ~20 Mbps constant |
| Static-content quality | ratchets to ~lossless; **4:4:4 live** (52 dB text) | lossy | exact but slow | sharp (4:4:4, but ≤30–60 fps) | fixed QP, lossy, 4:2:0 only in HW decode |
| Encryption | everything (Noise IK) | TLS/SRTP | usually weak/none | TLS | video unencrypted |
| Motion/video content | good (HEVC 60) | poor | very poor | fair | good |
| Congestion control | honest capacity-belief CC (falls ~0.5 s on real squeezes, no self-spiral) | yes | none | fair | none (CBR) |
| Clipboard | text + images, both ways, sealed | partial | text | yes | no |
| File transfer | drag-and-drop client→host, sealed wire | varies | no | yes | no |
| WAN/NAT story | Tailscale/port-forward (bridge later) | excellent | poor | fair | fair (manual) |
| Input + audio | yes (29–49 ms photon; 5 ms audio) | n/a / yes | yes | yes | yes |

## Where this gets awesome (roadmap features that widen the gap)

The comparison above began as Lyte at H2 — full streaming parity on our
own wire — and the ladder has since delivered two rungs into the measured
column:

- **H3 — LANDED**: clipboard both ways, drag-and-drop file transfer
  (client→host v1), and connection roaming, all riding the sealed ARQ
  sublayer. Files-over-the-streaming-wire with E2E crypto is territory
  none of the compared products occupy cleanly.
- **H4 — LANDED**: 4:4:4 chroma served
  live as a three-tier negotiated session posture, clipboard images (PNG,
  byte-exact both directions, measured), and the estimator-honesty
  reform that took the Beauty Bar to five-of-six green.
- **H5**: **printing** and file features — the classic "corporate RDP"
  differentiators, on a modern wire.
- **H6+**: one `lyte` binary, macOS host, and the WASM/browser client via
  the datagram-relay bridge — the conferencing tools' "join from
  anywhere" convenience, without their latency. (The scoping doc already
  proved LyteWire cross-compiles to wasm32 with zero source changes,
  400/400 tests under wasmtime.)

*Keep this document honest: update the measured column when new gate
evidence lands, and mark competitor numbers as ranges unless they come
from a matched benchmark.*
