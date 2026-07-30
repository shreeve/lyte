# LYTE-PLAN — The Overall Strategy

*The one linear plan: what Lyte is becoming, why we're building both ends in
Swift, and the order we get there. This is the strategy document; the living
build plan is [docs/20260720-222500-lyte-build-plan.md](docs/20260720-222500-lyte-build-plan.md)
(with its client/host companions) and product decisions live in
[docs/DESIGN.md](docs/DESIGN.md). The GameStream-era client blueprint this
header once pointed at is archived as
[docs/20260722-gamestream-client-plan-historical.md](docs/20260722-gamestream-client-plan-historical.md).*

---

## 1. Executive summary

Lyte began as a native macOS client for Sunshine hosts speaking the Moonlight
protocol. That client worked end-to-end (pairing, encrypted session, HEVC
video, Opus audio, input, app shell, network doctor — M0–M6 core, all verified
live against a real Sunshine host) and served as the bootstrap scaffolding
until the H2 exit (2026-07-22), when it was deleted in favor of the pure
Lyte-UDP client.

The strategy now extends to the other end of the wire: **a Lyte host, written
in Swift, so we own both ends.** Owning both ends is what unlocks everything
Sunshine cannot or will not give us:

- **Shared clipboard** (upstream Sunshine explicitly declined this as a
  protocol extension — "not planned")
- **YUV 4:4:4** chroma for pixel-crisp desktop text, on our schedule, not
  upstream's release cadence
- **File transfer, drag-and-drop, printer redirection** — remote-desktop
  conveniences layered on a game-streaming transport
- **A single coherent product**: one app per OS that can be a client, a host,
  or both, discovered over Bonjour, connected with one click

The end state: **a modern, low-latency remote workstation platform** — the
responsiveness of game streaming with the conveniences of a remote desktop.
Not a conferencing tool, not another VNC. Using another computer as if it were
local.

Everything is Swift. Everything is GPLv3. The transport is one
latency-optimized protocol that carries negotiated payloads — **Lyte-UDP,
our own protocol, the only one either end speaks** (decision of 2026-07-20:
[docs/20260720-215100-lyte-udp-decision.md](docs/20260720-215100-lyte-udp-decision.md)).
We do not implement VNC, RDP, or GameStream compatibility, ever.

---

## 2. Why own both ends

The client alone, however good, is capped by what Sunshine ships. Concretely:

1. **Clipboard sync requires host cooperation.** The video stream reveals
   nothing about what a Linux app placed on its clipboard; something on the
   host must watch the clipboard and speak a channel the client understands.
   Upstream closed the proposal for exactly this feature. A separate
   side-car agent (`lyte-agent`) was considered and **rejected** — we don't
   want users installing an extra piece. The host itself must be ours.
2. **4:4:4 arrives with or without us — the moat is elsewhere.** Windows
   NVENC 4:4:4 shipped in 2025; Linux NVENC 4:4:4 (CUDA/CUDA-GL, fixing
   the silent 4:2:0 fallback of #4836) merged to Sunshine's master on
   2026-06-16 (PR #4965). It hasn't appeared in a release yet, but the
   reference host could serve 4:4:4 today from a source build — so the host is not the
   only road to crisp text, and honesty says so. What owning the host
   actually buys is the feature channel (points 1 and 3) and roadmap
   ownership: chroma fidelity becomes a capability negotiation on our
   schedule rather than a wait on someone's tag — the accelerant, not the
   reason. (Protocol note, updated 2026-07-30: the wire's capability list
   carries two chroma modes — `CapabilityChroma` yuv420 = 1, yuv444 = 2,
   both served live since H4; a 4:2:2 id is addable as a contract-safe
   append but stays unminted while the reference hardware (Ada NVENC) has
   no 4:2:2 encode — the UI's "Better" tier is dormant. Chroma is fixed at
   session start, so switching means a clean reconnect, not a midstream
   change.)
3. **Every future desktop feature** (file channels, printing, cursor
   metadata, display control, mic forwarding) becomes a message type on a
   connection we control — no forks to rebase, no private patches to a C++
   codebase we don't own.
4. **The effort math is favorable.** The client was the deceptively hard
   part — protocol reverse-engineering, jitter buffering, zero-copy decode,
   adaptive audio — and it's built. Realistic split: the client is ~35–45% of
   the total lift, the host ~55–65%. Not a 20/80 split. The host is more
   surface area but much of it is gluing proven components (capture APIs,
   hardware encoders) rather than inventing anything.
5. **All the reference code is GPL and we are GPL.** Sunshine's solutions to
   Linux capture/encode/input quirks are open for study, exactly as
   moonlight-common-c was for the client (D5).

What we explicitly do **not** do: chase 1:1 Sunshine parity. The Lyte host
starts narrow — stream one desktop, well — and grows by capability
negotiation.

---

## 3. Product identity

**One program called Lyte per platform.** No separate daemon-plus-client
install. Run it and it lives quietly (menu bar on macOS, tray on
Windows/Linux). From there:

- **Be a client:** open a window, pick a discovered host, stream.
  (This is today's shipping D6 model — the window is the app.)
- **Be a host:** flip one toggle and this machine advertises itself and
  accepts paired connections.
- **Be both.** Same binary, same identity, same Keychain-backed credentials.

Deployment on a host machine should feel like: *copy one file, run it, it
advertises over Bonjour, done.* Native packaging (app bundle, deb/rpm/Flatpak,
MSI) comes later; a single self-contained executable is the bar for v1 on
Linux (system pieces like GPU drivers and PipeWire stay system-provided, by
design).

**Positioning.** Against the neighbors:

- *Moonlight/Sunshine*: our latency lineage — but they are gaming-first;
  desktop conveniences are out of scope upstream.
- *RustDesk / VNC / RDP*: remote-desktop-first; their transports collapse
  under motion or add latency. We are a media transport first, with desktop
  conveniences as channels on top.
- *Meet-style screen share*: conferencing tools where sharing is incidental;
  no control, no fidelity guarantees.

Lyte's niche is the gap between Moonlight-level latency and remote-desktop
convenience. Hit that and there's a clear reason to switch.

---

## 4. Technology commitments

| Area | Commitment | Notes |
|------|-----------|-------|
| Language | **Swift, both ends** | Client proven pure-Swift + two vendored C leaf libs (enet, nanors). Host follows the same rule: Swift core, C only at hardware/OS leaves (VAAPI/NVENC/PipeWire bindings). Swift is official on Linux and Windows. |
| License | **GPLv3, whole repo** | Deliberate (D5): full freedom to study GPL reference code. Relicensing later remains legally ours to decide (single copyright holder) — but GPLv3 is the working assumption, not a placeholder. |
| Video codecs | **HEVC primary, H.264 fallback; AV1 as a negotiated hook, later** | No MJPEG, no codec zoo. Modern hardware HEVC compresses static desktops to near-nothing and handles motion instantly — it beats VNC at VNC's own game once tuned (4:4:4 + rate control), and does full-motion video for free. |
| Chroma | **4:4:4 as a first-class negotiated capability** | The desktop-text differentiator — **landed and measured** (H4, 2026-07-29: a client asking Best gets an Rext yuv444 session end to end, +22 dB on text at fewer bits vs 4:2:0). Surfaced as the owner's three-tier "Chroma" control (Good = 4:2:0 / Better = 4:2:2, dormant / Best = 4:4:4); a flip is a clean reconnect — a session parameter, not a live dial. Color path: rgb_mode 601-limited ships (glass-correct, quality-equal); the full-range row is named-and-queued, not gating. |
| Audio | **Opus, 4+2 RS FEC, Lyte-UDP datagrams** | Payload framing carries over from the proven client path; envelope and crypto are Lyte-UDP's (Noise AEAD). Mic-back channel is a future message type, not v1. |
| Transport | **Lyte-UDP: our own protocol over plain UDP; payload-agnostic** | The only protocol either end speaks (2026-07-20 decision). Codec negotiated at connect; feature channels independent of video. No VNC mode, no RDP mode — policy ("text sharpness vs bandwidth") replaces transport switching. |
| Encryption | **On by default, everywhere, no cell exceptions** | Locked decision. Noise-based end-to-end per the transport pillar; CryptoKit/swift-crypto family; no OpenSSL anywhere. |
| Discovery | **Bonjour on LAN** | Shipping in the client today. Host advertises; clients see it appear in the connect empty-state. |
| Remote reach | **v1: Tailscale or port-forward; LAN is direct UDP** | Plain UDP traverses Tailscale natively — that is the v1 remote answer (2026-07-20 decision). No rendezvous service, no TURN relay in v1; a rendezvous/hole-punching layer remains a later option, addable *without protocol surgery*. |
| UI | SwiftUI on macOS; thin native shells elsewhere | The host role needs almost no UI — a toggle, a pairing approval, a status pill. |

---

## 5. Protocol strategy — one protocol, ours

*(The staged evolve-don't-big-bang plan that previously lived here — Stage 1
Moonlight-compatible base, Stage 2 extension channel over the GameStream
wire, Stage 3 divergence — is superseded by
[docs/20260720-215100-lyte-udp-decision.md](docs/20260720-215100-lyte-udp-decision.md).)*

**Lyte speaks exactly one protocol: Lyte-UDP.** Homegrown, over plain UDP
datagrams, specified by the four pillar docs (image quality, timing,
resiliency, transport — `docs/20260720-19170*.md`) as reconciled by the
capstone overview (`docs/20260720-193000`), with the QUIC and compat-dialect
assumptions in those docs overridden by the decision record. lyte-host never
implements the GameStream dialect — no RTSP, no ENet, no GameStream RTP, no
HTTPS pairing, no Moonlight compatibility. The end state is pure Lyte-UDP
everywhere, client included: no long-term dual-protocol ambition.

Lyte-UDP v1 is a **new skeleton around proven organs**: the envelope,
handshake (Noise + PIN-PAKE), channels, and reliable sublayer are new; the
media payload interiors — the client's soak-tested HEVC depacketization
layout, the Reed-Solomon FEC math (nanors-compatible), the Opus audio
framing — carry over intact. Idle silence and damage-only video (reliable
sparse idle frames, IDR-on-wake) are default behavior, not negotiated
extras. Feature channels (clipboard, files, printing, cursor metadata,
display control) are message streams on the same connection, gated by
capability negotiation.

**The transition — COMPLETE (2026-07-22).** The client's GameStream stack
was frozen scaffolding: zero new work, kept compiling only as the working
streaming path against Sunshine while Lyte-UDP came up. It was deleted at
the H2 exit, and Sunshine — the bootstrap crutch on the host machine —
was uninstalled in the same series, exactly as planned here.
Rationale (as it stood): dual support is a split brain — the two envelopes
share the media-pipeline interior, so every refactor and bug carries double
surface. One protocol, one host, one client per platform is the product.

**Feature-channel message discipline** (learned from the clipboard design
work, applies to every channel):

- Capability-gated: nothing flows unless both ends negotiated it *and* the
  user enabled it.
- Origin IDs + content hashes for anything reflective (clipboard loop
  prevention: suppress the local change event you yourself caused; dedupe
  identical payloads regardless of sequence number).
- Size ceilings from day one (clipboard v1: 256 KiB; raise deliberately).
- Session-scoped: state clears when the stream ends.
- Never log payload contents.

*(A prior-art note on the Foundation-Sunshine `IDX_CLIPBOARD` fork framing
stood here; with GameStream interop dropped there is no forked-host interop
to buy, so the clipboard framing is designed on our own wire without
reference to it — superseded by
docs/20260720-215100-lyte-udp-decision.md.)*

---

## 6. The Lyte host (Linux first)

Linux is the first host target because that's the machine on the other end
today (the reference host), and because it's the platform where owning the
host pays off immediately (Wayland clipboard, 4:4:4 via NVENC).

Implementation detail and evidence for these choices:
[docs/HOST-PLAN.md](docs/HOST-PLAN.md) (recommendation + adopted review
amendments; its Sunshine-dialect wire mandate is superseded by
[docs/20260720-215100-lyte-udp-decision.md](docs/20260720-215100-lyte-udp-decision.md) —
the capture/encode/input recommendations stand).

### Architecture

```
lyte (host role)
├── Advertise/      Bonjour _lyte._udp; identity, capabilities
├── PairHost/       PIN-PAKE approval, Noise static-key pinning (per the transport pillar)
├── SessionHost/    Lyte-UDP session/control host side; one session per display, N feature channels
├── Capture/        Linux: PipeWire/portal (Wayland), KMS; macOS: ScreenCaptureKit
├── Encode/         NVENC / VAAPI / VideoToolbox behind one Swift facade; HEVC⇄H.264; 4:4:4
│                   (NVENC is the reference-host path and the 4:4:4-capable one; VAAPI banked for Intel hosts)
├── AudioCap/       PipeWire capture → Opus encode → Lyte-UDP datagrams + FEC
├── InputInject/    portal RemoteDesktop primary, uinput fallback — keyboard, mouse, scroll
├── Features/       clipboard watcher/setter, print interception, file channel
└── Telemetry/      encoder queue depth, capture latency, per-client loss — feeds the doctor
```

The session-context lesson from the agent design carries over: the host role
runs **inside the logged-in graphical session** (access to `WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`), not as a root daemon.
Privileged bits, if ever needed, follow the client's helper pattern
(smallest possible privileged surface, version-probed XPC/IPC).

### Host milestones

*(This ladder was rewritten 2026-07-20 when the GameStream dialect was
dropped from the host roadmap — decision and rationale in
[docs/20260720-215100-lyte-udp-decision.md](docs/20260720-215100-lyte-udp-decision.md).
Status 2026-07-30: **H0a ✓ H0b ✓ H1 ✓ H2 ✓ H3 ✓ H4 ✓, H5 half-landed**
— gate reports in `docs/20260722-h{1,2}-joint-gate.md` and the H4 wave
entries; what remains below is printing (H5's second half) and H6.)*

- **H0a ✓ — Spike: first pixels into a file.** Portal/PipeWire capture →
  NVENC HEVC (a libavcodec leaf) → Annex-B file, proven headless on the
  host, plus the quality-ratchet prototype. The formerly planned
  "Sunshine-dialect RTP+FEC into the debug client" slice was dropped.
- **H0b ✓ — First pixels, Lyte-UDP.** Envelope v1 + the video datagram
  channel + RS FEC on the host; a Lyte-UDP receive module in the client
  (debug mode) rendering the live desktop. Acceptance held: the client
  renders lyte-host's desktop over the LAN, Noise end to end (J-G1).
- **H1 ✓ — Honest session.** Noise handshake, PIN-PAKE pairing, discovery
  (Bonjour + manual host:port), session lifecycle, the control channel on
  the reliable sublayer, the idle/active state machine — idle silence,
  reliable sparse idle frames, IDR-on-wake — and the liveness beacon.
- **H2 ✓ — Parity.** Input injection (Mutter internal RemoteDesktop as
  primary — the portal path proved hostile headless — uinput as
  fallback); PipeWire monitor capture of the real desktop → Opus, with
  the audio-continuity doc's send pacing and per-packet DSCP (48 audio /
  40 video); the congestion/resiliency machinery (app-level CC, NACK,
  FROZEN/RECOVERY). Exit criteria met 2026-07-22: Sunshine uninstalled
  from the host box, the client's GameStream stack deleted.
- **H3 ✓ — Feature channel + clipboard.** Capability-negotiated feature
  channel over Lyte-UDP; bidirectional text clipboard with the
  loop-prevention discipline above (CL-15), grown to clipboard images
  (P-1, key 12, 2026-07-29). The first thing Sunshine can't do — shipped.
- **H4 ✓ — 4:4:4 + policy integration.** Landed NVENC-first and measured
  live (V-1…V-5, 2026-07-29): Rext yuv444 end to end, +22 dB on text at
  fewer bits vs 4:2:0, surfaced as the three-tier Chroma control; the
  quality ratchet converges static content to ~52 dB then goes silent;
  rate control rides the delivery-rate estimator with VBV exact-tighten.
  VAAPI-444 stays banked for Intel hosts.
- **H5 (half ✓) — Desktop conveniences.** File transfer channel with
  drag-and-drop: **landed** (bulk channel, `--accept-files`). Printing v1
  (intercept host print jobs → deliver as PDF → print locally on the
  client): **open** — the remaining H5 work.
- **H6 — Single-binary distribution + host toggle UX.** One copyable Linux
  executable; "Be a host" toggle in the macOS app (ScreenCaptureKit +
  VideoToolbox encode — the same H0–H2 ladder, much shorter on home turf).

All of H3–H6 rides Lyte-UDP feature channels. Each H-milestone is verified
live against the Lyte client before the next begins — the same discipline
that carried M0–M6, with the Lyte-UDP client path replacing the GameStream
one as the verifier from H0b on.

### Client milestones (continuing, in parallel)

The existing ladder stands: **M5.5** (policy engine full), **M6 remainder**
(preflight, SSH host probes, WoL, one-session guard, DSCP), **M7** (profiles,
frame pacing, AV1, HDR, reconnect/resume) — all on the Lyte-UDP path.

**The GameStream stack was frozen scaffolding** (per the 2026-07-20
decision): zero new work, kept compiling only as the working path against
Sunshine during the transition — and deleted at the H2 exit (2026-07-22),
as scheduled.

**Freeze rule:** M5.5–M7 are paused during H0–H2, critical fixes excepted.
One maintainer, one front at a time.

---

## 7. Networking beyond the LAN

*(Posture updated 2026-07-20 with the Lyte-UDP decision.)*

- **LAN: direct UDP.** Bonjour finds local hosts; manual host:port works
  everywhere.
- **Remote, v1: Tailscale or a port-forward.** Plain UDP is exactly what
  these carry best; no rendezvous service, no STUN, no relay fleet ships in
  v1. Where neither is available, we say "unsupported" plainly.
- **Browsers, future: a dumb datagram relay.** The Caddy bridge
  (docs/20260720-184200) becomes a WebTransport-datagram ↔ UDP-packet relay
  (CONNECT-UDP shape). End-to-end Noise encryption means the bridge — like
  any future rendezvous or relay — never sees plaintext; it is untrusted by
  construction.
- **Relay-shaped hole in the protocol, no relay in the product.** A
  rendezvous/hole-punching layer remains addable later as a service
  decision, not a protocol change.

---

## 8. Security model

- **Pairing is the root of trust**: PIN once, mutual key pinning forever
  after. On Lyte-UDP that means PIN-as-PAKE and pinned static Noise keys
  (transport pillar §4) — same UX as the shipping cert-pinning model, better
  crypto. The host role reuses the identical model in reverse — a host
  approves a client once.
- **Everything encrypted, always** (locked decision). No plaintext cells, no
  "LAN is safe" exceptions.
- **Per-feature consent, per session.** View-only vs. control is an explicit
  host-side toggle. Clipboard is `Off / Text only / Text + images` — user
  chooses, and the toggle is visible during a session because clipboards
  carry passwords and tokens. File and print channels are individually
  gated. Defaults favor privacy; enabling is one click, never buried.
- **Keys live in platform stores** (Keychain today; Linux equivalent chosen
  when H1 lands). The macOS in-Keychain generation quirk is documented and
  must not be "simplified" away.

---

## 9. Platform sequence

1. **macOS client** — shipping (M0–M6 core).
2. **Linux host** — H0–H5. The pairing that matters most: Mac on your lap,
   Linux box doing the work.
3. **macOS host** — H6. Same Swift core, ScreenCaptureKit/VideoToolbox
   leaves; makes any Mac reachable from any other.
4. **Windows** — later, deliberately. Swift runs there officially; the core
   (protocol, session, features) ports; capture/encode/input get thin
   platform layers (DXGI/Media Foundation/SendInput) and the UI is a tray
   shell, not SwiftUI. Sequenced after the Linux host proves the
   architecture, not before.
5. **iOS/tvOS client** — architecture stays clean for it (LyteTransport
   has no UI dependencies); not scheduled.

---

## 10. Non-goals

- **No VNC or RDP compatibility modes.** One transport; policy replaces
  protocol switching. Compatibility would add enormous surface for a worse
  experience.
- **No MJPEG**, except possibly as a debug tool, never a product path.
- **No TURN/relay service in v1** (see §7).
- **No GameStream/Moonlight compatibility, either direction.** lyte-host
  speaks only Lyte-UDP; no Moonlight client ever connects to it unless a
  compat leaf is deliberately added later (2026-07-20 decision — the honest
  cost is recorded there). The client's GameStream stack was transition
  scaffolding, deleted at the H2 exit — never a supported mode.
- **No conferencing features.** Lyte is not a meeting tool.
- **No settings sprawl.** The 2×2 policy grid and one dial survive the host
  expansion; the host role gets the same treatment (capabilities on/off,
  not encoder knob farms).

---

## 11. Risks, honestly

| Risk | Mitigation |
|------|-----------|
| Wayland capture/input fragmentation across distros/compositors | Target PipeWire + portals + libei (the modern common path); study Sunshine's fallbacks; state supported environments explicitly rather than chasing every compositor. |
| COSMIC portal immaturity — Pop!_OS is migrating from GNOME to COSMIC, whose ScreenCast/RemoteDesktop portals are young | Pin H0–H2 to GNOME/Mutter on the reference host; COSMIC and non-NVIDIA are explicitly unsupported at that stage, failing loudly rather than silently; KMS stays the documented fallback backend for later. |
| Login-screen blackout — portal capture needs a logged-in session, so a rebooted host is dark until someone logs in | A stated limitation and a named doctor diagnosis until a KMS/login-manager story exists — never a silent capture failure. |
| Hardware encoder variance (VAAPI quirks, NVENC licensing surface, hybrid-GPU traps) | One Swift encode facade with capability probes; the reference-host case study already caught the hybrid-GPU silent-fallback trap — probe results become doctor diagnoses. |
| Swift-on-Linux ecosystem gaps (no Foundation surprises, C interop volume) | The client already proved the pure-Swift + C-leaf pattern; keep the C boundary at hardware libraries only. |
| Two-ends scope creep | The H-ladder is strictly serial; a milestone ships only when verified live against the Lyte client; features land as negotiated channels, never as forks of the media path. |
| Solo-maintainer bandwidth | Sunshine stayed installed as the bootstrap crutch until Lyte↔Lyte streamed — there was never a broken middle where nothing streamed. The client's frozen GameStream path was that bridge; both were retired at the H2 exit once Lyte-UDP was load-bearing. |
| Owning the wire ourselves (post-2026-07-20) | The reliable sublayer's ARQ correctness and the pre-handshake DoS posture are ours alone — no RFC 9000 lineage. Mitigations: the sublayer's scope is deliberately tiny (control, sparse idle frames, final ratchet frame); adversarial/netem tests are acceptance gates; the `LyteTransport` facade keeps QUIC re-adoptable if the ecosystem matures. Debugging has no off-the-shelf dissector — a small `lyte sniff` tool is the ledgered answer. |

---

## 12. The linear path, in one breath

Client works (done) → keep Sunshine as the bootstrap crutch while the host
comes up on Lyte-UDP, our own and only protocol (H0a capture/encode is
proven; H0b puts first pixels on the new wire; H1 makes the session honest) →
reach parity, retire Sunshine, delete the client's GameStream scaffolding
(H2 — **done 2026-07-22**) → open the negotiated feature channel and ship
clipboard, the first impossible-with-Sunshine feature (H3 — **done, text
and images**) → land 4:4:4 and the quality ratchet (H4 — **done and
measured, 2026-07-29**) → files (**done**) and printing (H5, the open
half) → macOS host + one-binary UX (H6) → remote
reach via Tailscale/port-forward today, a browser bridge and rendezvous
later — and somewhere along the way, the product stops being "a Moonlight
client" and becomes what it was always aimed at: **your other computers, one
click away, indistinguishable from local.**
