# LYTE-PLAN — The Overall Strategy

*The one linear plan: what Lyte is becoming, why we're building both ends in
Swift, and the order we get there. This is the strategy document; the client
implementation blueprint lives in [PLAN.md](PLAN.md) and product decisions in
[docs/DESIGN.md](docs/DESIGN.md).*

---

## 1. Executive summary

Lyte began as a native macOS client for Sunshine hosts speaking the Moonlight
protocol. That client now works end-to-end (pairing, encrypted session, HEVC
video, Opus audio, input, app shell, network doctor — M0–M6 core, all verified
live against a real Sunshine host).

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
latency-optimized protocol that carries negotiated payloads — we do not
implement VNC or RDP compatibility, ever.

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
   2026-06-16 (PR #4965). It hasn't appeared in a release yet, but `pop`
   could serve 4:4:4 today from a source build — so the host is not the
   only road to crisp text, and honesty says so. What owning the host
   actually buys is the feature channel (points 1 and 3) and roadmap
   ownership: chroma fidelity becomes a capability negotiation on our
   schedule rather than a wait on someone's tag — the accelerant, not the
   reason. (Protocol note: the wire offers exactly two chroma modes —
   `chromaSamplingType` 0 = 4:2:0, 1 = 4:4:4; there is no 4:2:2 — and it is
   fixed at ANNOUNCE, so switching means a reconnect, not a midstream
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
| Chroma | **4:4:4 as a first-class negotiated capability** | The desktop-text differentiator. Client decode path already targets it (Local·Work policy, D2). Connect-time only in the Moonlight lineage (fixed at ANNOUNCE; a chroma change = reconnect) — policy must treat it as a session parameter, not a live dial. Full color fidelity also needs the CSC upgrade: the client still requests Rec.601 limited (`encoderCscMode 0`), the likely cause of the "washed out" look — BT.709/full-range is a cheap client-side fix independent of the host work. |
| Audio | **Opus over RTP, 4+2 FEC, AES-CBC** | Shipping today; host side mirrors it. Mic-back channel is a future message type, not v1. |
| Transport | **One UDP-first, latency-optimized transport; payload-agnostic** | Codec negotiated at connect; feature channels independent of video. No VNC mode, no RDP mode — policy ("text sharpness vs bandwidth") replaces transport switching. |
| Encryption | **On by default, everywhere, no cell exceptions** | Locked decision. CryptoKit/CommonCrypto/swift-certificates; no OpenSSL anywhere. |
| Discovery | **Bonjour on LAN** | Shipping in the client today. Host advertises; clients see it appear in the connect empty-state. |
| Remote reach | **Rendezvous + STUN hole punching, direct P2P only** | A tiny rendezvous service brokers introductions; media always flows peer-to-peer. **No TURN relay in v1** — if hole punching fails, the network is unsupported. The protocol reserves room (relay address family in the handshake) so a relay can be added later *without protocol surgery*. |
| UI | SwiftUI on macOS; thin native shells elsewhere | The host role needs almost no UI — a toggle, a pairing approval, a status pill. |

---

## 5. Protocol strategy — evolve, don't big-bang

Owning both ends does *not* mean a day-one clean-slate protocol. The client's
Moonlight-compatible implementation is tested, hardened, and talks to a
known-good host (Sunshine) — that interop is our permanent test oracle and
the user's bridge during the transition.

**Stage 1 — Moonlight-compatible base (where we are).**
Client speaks Sunshine's dialect: HTTPS pairing, encrypted RTSP, ENet
control, RTP video/audio with RS-FEC. This never breaks; Sunshine hosts
remain supported.

**Stage 2 — Lyte extension channel over the same wire.**
When both ends are Lyte, capability negotiation (the same connect-time
mechanism that picks codecs) opens an authenticated, encrypted **feature
channel**: a generic bidirectional message stream multiplexed alongside
media. Clipboard, file transfer, printing, cursor metadata, display control —
all just message types on this channel. The client connecting to plain
Sunshine simply never negotiates it. This stage delivers the headline
features without forking the media path.

**Stage 3 — Lyte protocol v2.**
Once the Lyte host is the primary host and the extension channel is proven,
we are free to diverge: collapse the pairing/RTSP legacy into a single
handshake, unify session control, tighten framing. v2 is earned by running
code, not designed in advance. Nothing in stages 1–2 may paint us out of it.

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

Prior art worth a deliberate look before freezing the clipboard framing: the
Foundation-Sunshine / Moonlight-VPlus fork ecosystem already runs a private
clipboard extension as control packet `IDX_CLIPBOARD` (0x5508) with v1 text
frames and capability bits. We owe them nothing wire-wise, but if their
framing is sane, matching it buys interop with forked hosts for free; if
not, we diverge knowingly rather than accidentally.

---

## 6. The Lyte host (Linux first)

Linux is the first host target because that's the machine on the other end
today (`pop`), and because it's the platform where owning the host pays off
immediately (Wayland clipboard, 4:4:4 via NVENC on `pop`).

Implementation detail and evidence for these choices:
[docs/SERVER-PATH.md](docs/SERVER-PATH.md) (recommendation + adopted review
amendments).

### Architecture

```
lyte (host role)
├── Advertise/      Bonjour _lyte._tcp; identity, capabilities
├── PairServer/     PIN approval, client cert pinning (mirror of client Pairing/)
├── SessionServer/  RTSP/control server side; one session per display, N feature channels
├── Capture/        Linux: PipeWire/portal (Wayland), KMS; macOS: ScreenCaptureKit
├── Encode/         NVENC / VAAPI / VideoToolbox behind one Swift facade; HEVC⇄H.264; 4:4:4
│                   (NVENC is the `pop` path and the 4:4:4-capable one; VAAPI banked for Intel hosts)
├── AudioCap/       PipeWire capture → Opus encode → RTP+FEC
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

- **H0a — Spike: first pixels.** Portal/PipeWire capture → NVENC HEVC (a
  libavcodec leaf) → RTP with our FEC → a *debug-mode* client renders it
  (client-side gating relaxed for the spike). Hardcoded everything; success
  = a client window showing the live `pop` desktop.
- **H0b — Honest handshake.** Serverinfo identity, canned RTSP with the
  Session header and `X-SS-Ping-Payload`, SS_PING-gated sending, and a
  minimal ENet control-v2 host — the shipping client hard-requires
  control-v2 and fails the session without it, so it cannot wait for H1.
  Acceptance: the **unmodified shipping client** renders the live `pop`
  desktop. H0a+H0b together are a 4–8 week build, not a weekend spike.
- **H1 — Session server.** Pairing (PIN + cert pinning), encrypted RTSP
  server side, full ENet control host side — the client connects to a Lyte
  host exactly as it does to Sunshine. The client's own protocol code
  reviewed from the other side. Acceptance is byte-exact: `rtspenc://`
  end-to-end; SS_PING payload matching; SCM bits per docs/sunshine-v2026.715.205118.md §4;
  golden-transcript pairing tests; audio timestamps in Sunshine's
  packetDuration units.
- **H2 — Input + audio.** Keyboard/mouse injection via portal RemoteDesktop
  as primary (we already hold that portal session open for capture; no udev
  rule on the happy path), uinput as fallback; PipeWire monitor capture of
  the real desktop → Opus → RTP. Bar: a full working session
  indistinguishable from Sunshine for daily driving — plus idle silence as
  an acceptance gate: static desktop ≤ ~1 fps keepalive, measured (pending
  the TODO.md verification that the shipping client tolerates long frame
  gaps).
- **H3 — Feature channel + clipboard.** Stage-2 negotiation; bidirectional
  text clipboard with the loop-prevention discipline above. The first thing
  Sunshine can't do.
- **H4 — 4:4:4 + policy integration.** 4:4:4 lands NVENC-first — the
  RGB→YUV444 conversion is the real work item; VAAPI-444 is banked for
  Intel hosts. Chroma negotiation wired into Local·Work; encoder rate
  control tuned for static-desktop-with-bursts; loss-driven adaptation (the
  client already reports loss every ~50 ms and both incumbents ignore it)
  and pacing to the negotiated bitrate, not an assumed gigabit; host-side
  telemetry feeding the client's doctor (encoder stalls become a named
  culprit, like AWDL is today).
- **H5 — Desktop conveniences.** File transfer channel; printing v1
  (intercept host print jobs → deliver as PDF → print locally on the
  client). Drag-and-drop rides the file channel when it lands — nice, not
  critical.
- **H6 — Single-binary distribution + host toggle UX.** One copyable Linux
  executable; "Be a host" toggle in the macOS app (ScreenCaptureKit +
  VideoToolbox encode — the same H0–H2 ladder, much shorter on home turf).

Each H-milestone is verified live against the shipping client before the
next begins — the same discipline that carried M0–M6.

### Client milestones (continuing, in parallel)

The existing ladder stands: **M5.5** (policy engine full), **M6 remainder**
(preflight, SSH host probes, WoL, one-session guard, DSCP), **M7** (profiles,
frame pacing, AV1, HDR, reconnect/resume). Client work
that touches the wire keeps Stage-1 compatibility as its contract.

**Freeze rule:** M5.5–M7 are paused during H0–H2, critical fixes excepted.
One maintainer, one front at a time.

---

## 7. Networking beyond the LAN

- **v1 is LAN + direct P2P.** Bonjour finds local hosts. For remote hosts, a
  minimal rendezvous service (stateless introduction + STUN-style address
  discovery) lets both ends hole-punch UDP. Most home/small-office NATs
  allow this; where they don't, we say "unsupported" plainly rather than
  ship a relay fleet.
- **The rendezvous service never sees media.** It brokers a handshake;
  encryption is end-to-end between paired devices; pairing trust is
  cert-pinning established on first PIN exchange, same as today.
- **Relay-shaped hole in the protocol, no relay in the product.** The
  connection setup enumerates candidate paths (local, reflexive, *relay*);
  v1 simply never produces relay candidates. Adding TURN later is a service
  decision, not a protocol change.

---

## 8. Security model

- **Pairing is the root of trust**: PIN once, mutual certificate pinning
  forever after (shipping). The host role reuses the identical model in
  reverse — a host approves a client once.
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
5. **iOS/tvOS client** — architecture stays clean for it (LyteKit has no UI
   dependencies); not scheduled.

---

## 10. Non-goals

- **No VNC or RDP compatibility modes.** One transport; policy replaces
  protocol switching. Compatibility would add enormous surface for a worse
  experience.
- **No MJPEG**, except possibly as a debug tool, never a product path.
- **No TURN/relay service in v1** (see §7).
- **No GFE/GeForce-Experience support** — Sunshine-generation hosts only,
  and eventually Lyte hosts primarily.
- **No conferencing features.** Lyte is not a meeting tool.
- **No settings sprawl.** The 2×2 policy grid and one dial survive the host
  expansion; the host role gets the same treatment (capabilities on/off,
  not encoder knob farms).

---

## 11. Risks, honestly

| Risk | Mitigation |
|------|-----------|
| Wayland capture/input fragmentation across distros/compositors | Target PipeWire + portals + libei (the modern common path); study Sunshine's fallbacks; state supported environments explicitly rather than chasing every compositor. |
| COSMIC portal immaturity — Pop!_OS is migrating from GNOME to COSMIC, whose ScreenCast/RemoteDesktop portals are young | Pin H0–H2 to GNOME/Mutter on `pop`; COSMIC and non-NVIDIA are explicitly unsupported at that stage, failing loudly rather than silently; KMS stays the documented fallback backend for later. |
| Login-screen blackout — portal capture needs a logged-in session, so a rebooted host is dark until someone logs in | A stated limitation and a named doctor diagnosis until a KMS/login-manager story exists — never a silent capture failure. |
| Hardware encoder variance (VAAPI quirks, NVENC licensing surface, hybrid-GPU traps) | One Swift encode facade with capability probes; the `pop` case study already caught the hybrid-GPU silent-fallback trap — probe results become doctor diagnoses. |
| Swift-on-Linux ecosystem gaps (no Foundation surprises, C interop volume) | The client already proved the pure-Swift + C-leaf pattern; keep the C boundary at hardware libraries only. |
| Two-ends scope creep | The H-ladder is strictly serial; a milestone ships only when verified live against the shipping client; features land as negotiated channels, never as forks of the media path. |
| Solo-maintainer bandwidth | Stage 1 compatibility means Sunshine keeps working the whole time — there is never a broken middle where nothing streams. |

---

## 12. The linear path, in one breath

Client works (done) → keep Sunshine compatibility as the permanent baseline →
stand up a narrow Swift Linux host that the existing client can stream from
(H0–H2) → open the negotiated feature channel and ship clipboard, the first
impossible-with-Sunshine feature (H3) → land 4:4:4 and host telemetry (H4) →
files and printing (H5) → macOS host + one-binary UX (H6) → rendezvous +
hole-punched P2P for remote reach → then, with both ends ours and proven,
collapse the legacy into Lyte protocol v2 — and somewhere along the way, the
product stops being "a Moonlight client" and becomes what it was always
aimed at: **your other computers, one click away, indistinguishable from
local.**
