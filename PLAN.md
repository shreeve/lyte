# Lyte — Implementation Plan

*The detailed blueprint: what we're building, how the protocol works, how the app is
structured, and the order we build it in.*

Companion docs: [docs/DESIGN.md](docs/DESIGN.md) (product decisions),
[misc/COMMON.md](misc/COMMON.md) (protocol core analysis),
[misc/MACOS.md](misc/MACOS.md) (macOS client analysis). This plan assumes both
analyses; wire-format byte layouts not reproduced here live in the reference
checkouts under `misc/`.

---

## 1. What Lyte is

A **SwiftUI-native macOS client for Sunshine hosts** speaking the Moonlight
protocol. One window, one Work/Play toggle, a network doctor, and almost nothing
else to configure. GPLv3.

**What makes it different from every existing client:**

1. **Radical simplicity.** Two axes (Work/Play × auto-detected Local/Remote) replace
   the ~40 settings of moonlight-qt. Policies derive concrete numbers from live
   telemetry (docs/DESIGN.md D1–D2).
2. **The doctor.** Streaming clients stutter silently; Lyte continuously measures and
   *names the culprit* (AWDL, host power-save, shared Wi-Fi channel, uplink retries)
   — and fixes what it can (D4).
3. **Sunshine-first, modern-only.** We drop the GFE generation matrix (see §3.1) —
   the single biggest simplification available to a new client.
4. **Modern library architecture.** Session actor instead of C globals, async/await
   instead of blocking handshakes, structured errors, first-class stats — the
   improvement list from COMMON.md §15, applied to a Swift implementation of the
   *existing* wire protocol (we are wire-compatible with Sunshine; we are NOT
   designing a new protocol).

---

## 2. Scope decisions (the knife we cut with)

| Decision | Choice | Why |
|----------|--------|-----|
| Host support | **Sunshine only** (GFE dropped) | GFE is EOL; kills Gen 3–6 branches: ENet RTSP, TCP-47995 control, 47996 first-frame trigger, SHA1 pairing, unencrypted input. Detection: keep the negative `AppVersionQuad[3]` convention (COMMON.md §3). |
| Codecs | HEVC first, then AV1, H.264 fallback | M5-class VideoToolbox decodes all three; Sunshine VAAPI/NVENC encode all three. Negotiation priority AV1 → HEVC → H.264 (COMMON.md §8). |
| Gamepads | GameController.framework only at first | MACOS.md's 1850-line IOKit HID driver is the deep well we drink from *later* (M8). GCController covers Xbox/PS/Switch on modern macOS well. |
| Audio | Stereo + 5.1 from day one | The reference client decodes surround but hides it (MACOS.md §6 quirk); we won't repeat that. |
| Multi-controller | Deferred | Reference supports one HID pad anyway. |
| iOS/tvOS | Not now | Architecture keeps LyteKit platform-clean for later. |
| Min macOS | **15 (Sequoia)** | Frees us to use latest SwiftUI/CryptoKit; only costs old-Mac users a version we don't have hardware to test anyway. *(Open question #1.)* |

---

## 3. LyteKit — the protocol layer (Swift)

Swift package, no UI dependencies. One `Session` actor per connection — the C core's
biggest architectural sin is process-global single-session state (COMMON.md §10);
we don't repeat it.

### 3.0 Module map

```
LyteKit/
├── Discovery/      NWBrowser _nvstream._tcp, host reachability
├── Pairing/        PIN handshake, client cert (swift-certificates), keychain
├── HostAPI/        HTTPS 47984 / HTTP 47989: serverinfo, applist, launch, resume, cancel
├── Rtsp/           OPTIONS→DESCRIBE→SETUP×3→ANNOUNCE→PLAY, SDP builder/parser
├── Control/        ENet client (vendored C), channel map, encrypted NVCTL messages
├── Video/          UDP receive, RTP reorder, RS-FEC decode, depacketize → CMSampleBuffer
├── Audio/          UDP receive, RTP + 4+2 FEC, AES-CBC decrypt, Opus decode
├── Input/          Mouse/keyboard/scroll/pad event encoding, AES-GCM, send queue
├── Telemetry/      RTT, loss, FEC efficiency, decode latency — AsyncStream of stats
└── CVendor/        C targets: enet (cgutman fork), nanors (+ Nvidia audio parity matrix)
```

### 3.1 What we implement vs skip

Implement (Sunshine/Gen-7+ paths only):

- TCP RTSP on 48010, CSeq starting at 0 (host-bug workaround, COMMON.md §6)
- SETUP audio → video → control; `X-SS-Ping-Payload`, `X-SS-Connect-Data`
- Client SDP: encoder bitrate = 80% of user bitrate, FEC 20%, `x-ss-*`/`x-ml-*`
  attributes, `&corever=1` launch hint
- ENet control on UDP 47999, 48 channels (map in COMMON.md §7.3)
- Video UDP 47998: RTP + multi-block RS-FEC, `NV_VIDEO_PACKET` parse, Annex-B →
  AVCC length-prefix conversion, IDR request after gap; AES-128-GCM when negotiated
- Audio UDP 48000: ping-before-PLAY (hard requirement), drop first ~500 ms,
  4+2 FEC shards, AES-128-CBC with `BE32(riKeyId + seq)` IV, Opus 48 kHz 5/10 ms
- Input: AES-128-GCM encrypted events on control channels (keyboard 0x02, mouse
  0x03, UTF-8 0x06, pads 0x10+)
- Loss stats every ~50 ms; periodic ping; `SS_PING` 16-byte + BE32 seq every 500 ms
- Pairing: 4-digit PIN, SHA-256 challenge flow (5 stages, MACOS.md §8), client cert
  via **swift-certificates + swift-crypto**; private key in Keychain

Skip entirely: ENet RTSP (`rtspru://`), TCP 47995/47996, SHA-1 pairing, GFE audio
`0.0.0.0` URL trick, GFE 4K FEC special cases, STUN (until Remote support lands).

### 3.2 Crypto inventory (no OpenSSL anywhere)

| Need | API |
|------|-----|
| AES-128-GCM (video/control/input, encrypted RTSP) | CryptoKit `AES.GCM` |
| AES-128-CBC (audio) | CommonCrypto `CCCrypt` |
| AES-128-ECB (pairing challenge) | CommonCrypto `CCCrypt(kCCOptionECBMode)` |
| SHA-256, HMAC | CryptoKit |
| Client certificate + RSA/EC key | swift-certificates / swift-crypto, Security.framework for Keychain |
| TLS with pinned peer cert | `URLSession` delegate trust override (MACOS.md §8 pattern) |

### 3.3 The C we keep (and why)

Two leaf libraries are vendored as SPM C targets, everything above them is Swift:

- **enet (cgutman fork)** — a full reliable-UDP protocol; the fork is
  ABI-incompatible with stock libenet and battle-tested against Sunshine's copy.
  Reimplementing reliability protocols is where schedules go to die. Revisit a
  Swift port post-1.0.
- **nanors + the Nvidia audio parity matrix** — Reed-Solomon with a hardcoded
  host-specific matrix (COMMON.md §14.6). Bit-exact compatibility beats purity.

Everything else — RTSP, SDP, depacketizer, FEC orchestration, queues, crypto,
input encoding — is new Swift. Reference C stays open on the other monitor (GPL).

### 3.4 Session lifecycle (async replacement for LiStartConnection)

```swift
let session = LyteSession(host: host, app: app, policy: resolvedPolicy)
for await event in session.events {          // AsyncStream<SessionEvent>
    // .stage(_), .connected, .stats(_), .rumble(_), .hdrChanged(_),
    // .terminated(reason: TerminationReason)
}
```

- Stages mirror the C core's 11 (COMMON.md §5) for familiar diagnostics, but start
  is cancellable and non-blocking; teardown is `await session.stop()` — no
  interrupt-then-join dance, no detached-thread termination hack.
- Errors are typed: `stage + underlying + portHint + isRecoverable` (COMMON.md §15.8).
- Frame delivery: `AsyncStream<CMSampleBuffer>` — LyteKit produces *decode-ready*
  sample buffers (format descriptions built from VPS/SPS/PPS, length-prefixed,
  timestamps from the 90 kHz RTP clock via `CMTimeMake(ts, 90000)`).
- No auto-reconnect at the wire level (host requires re-`/launch`), but `Session`
  exposes `resumeToken` so the app layer can offer one-click resume (D2 Remote·Work).

### 3.5 Timeouts & recovery we must honor

- 10 s no-video-traffic / no-complete-frame → terminate −100/−101
- ~120 consecutive drops → request IDR; decoder can answer `needsIDR`
- Connection quality: sample 3 s; POOR ≥30% once or ≥15% twice; OKAY ≤5%
  (feeds the doctor, not an overlay nag)

---

## 4. Media pipelines

### 4.1 Video: two-stage plan

- **Stage 1 (M3): `AVSampleBufferDisplayLayer`** hosted in an NSView. Proven path
  (MACOS.md §5), minimal code: enqueue CMSampleBuffers with DisplayImmediately for
  Play-mode latency; recreate layer off-main on failure + request IDR.
- **Stage 2 (M7): `VTDecompressionSession` → IOSurface → `CAMetalLayer`** for
  zero-copy, EDR/HDR control, and MetalFX upscaling headroom. The framework map of
  the shipping enhanced client (SwiftUI, Metal+FX, CoreHID — extracted via otool)
  confirms this is the endgame.
- **Frame pacing** (the thing the reference stores but never wired, MACOS.md §14.7):
  CVDisplayLink (later `CADisplayLink` on macOS 15) tied to the stream window's
  screen; pull loop keeps ≤1 queued frame when refresh ≈ stream fps; Work mode
  biases to smoothness (2-frame cushion), Play mode to immediacy (0–1).

### 4.2 Audio

Opus (SPM libopus build) → **`AVAudioEngine` + `AVAudioSourceNode`**, float PCM.
- Buffer depth is *policy-derived*: Play·Local ~10–20 ms; Work modes 40–60 ms —
  not the reference's fixed 80 ms iPod-heritage ring (MACOS.md §6).
- Underrun counter feeds the doctor (audio chop was the original sin that started
  this project — see DESIGN.md case study).
- 5.1/7.1 exposed when the host offers it; channel remap per COMMON.md §6 quirks.

### 4.3 Input

- **Free Mouse (Work):** absolute-position events (`LiSendMousePosition` semantics);
  local cursor visible; pointer escapes window edges naturally.
- **Locked (Play):** `CGAssociateMouseAndMouseCursorPosition(false)` + `NSCursor.hide`
  + warp-to-center — the proven capture recipe (MACOS.md §7), with the same
  release chord (⌃⌥ together) and the ⌘-shortcut passthrough list (⌘W, ⌘H, ⌘F,
  ⌃⌘F, ⌘Tab never leak to the host).
- Keyboard: Carbon `kVK_*` → Windows VK table (port the ~80-entry map);
  `flagsChanged` sends left/right modifier VKs; release-all-modifiers on uncapture.
- Scroll: high-resolution scroll events, natural-direction aware.
- Pads: GCController extended profile → multi-controller events; CoreHaptics rumble.
- Display sleep blocked during stream via IOPMAssertion; re-capture after
  fullscreen/Space transitions (observer pattern from MACOS.md §7).

---

## 5. The app (SwiftUI)

### 5.1 Design principles

**Pretty, calm, almost setting-less.** If a screen needs explanation, it's wrong.
Every number the user could dial is derived by policy; the visible controls are:

1. **Work / Play** — one segmented toggle, always visible
2. **Quality ⇄ Latency** — one slider *within* the mode, default center
3. **The doctor** — status pill; expands to diagnosis cards

That is the entire day-to-day surface. (Expert profiles: JSON files in
`~/Library/Application Support/Lyte/Profiles/`, hidden behind ⌥-click on the mode
toggle. No preference labyrinth. See DESIGN.md D3.)

### 5.2 Screens

```
LyteApp (SwiftUI @main, MenuBarExtra while streaming)
├── HostsView          discovered + manual hosts, pair flow
├── AppsView           box-art grid (Desktop, Steam, …), search, ⌘± scale
├── StreamWindow       Window group per session; StreamSurfaceView (NSViewRepresentable)
│   └── HUD overlay    mode pill · doctor pill · stats (⌃⌥⇧S)
├── SettingsScene      one pane: mode, dial, host row (encryption ⋅ wake ⋅ unpair)
└── DoctorView         live jitter sparkline, culprit cards, "Fix it" buttons
```

- **HostsView:** `NWBrowser` for `_nvstream._tcp`, 5 s refresh while visible;
  cards show state (online / paired / asleep with Wake-on-LAN). Pairing sheet
  shows the 4-digit PIN **and a "open Sunshine web UI" button** (`https://host:47990/pin`)
  — the two-machine PIN dance is the worst first-run moment; we hold the user's hand.
- **AppsView:** box art via host asset API, cached; Enter streams, right-click
  quit/resume. Auto-selects intent: Desktop ⇒ Work, game/Big Picture ⇒ Play
  (dismissible pill, never a dialog — D2).
- **StreamWindow:** native window (windowed by default in Work, fullscreen in Play),
  tabbing disabled, frame autosaved per host+app, dark chrome.
- **MenuBarExtra during stream:** disconnect, mute, mode switch, doctor status —
  reachable even when the stream window is fullscreen on another Space.
- **DoctorView** is also the *first-run experience*: before the first stream we run
  a preflight (gateway RTT/jitter, Wi-Fi vs wired, AWDL state, host reachability)
  so expectations are set before pixel one.

### 5.3 State & persistence

- `@Observable` app model; per-host state in one **SwiftData** store (hosts, pairing
  identity refs, per-host-per-cell profile overrides). *One* source of truth — the
  reference app's triple settings system (UserDefaults + Core Data + MASPreferences,
  MACOS.md §9) is the anti-pattern we're burying.
- Client cert/key in Keychain; per-install random `uniqueId` (drop the shared
  `"0123456789ABCDEF"`, accept that only our client quits our sessions).

### 5.4 Policy engine

```
PolicyInput  = mode(Work|Play) × network(Local|Remote) × dial(−1…+1)
Telemetry    = { rtt, jitter, lossRate, linkType, wifiChannelShared, headroomEstimate }
PolicyOutput = { w, h, fps, bitrate, codecPrefs, bufferMs, mouseMode,
                 windowMode, encryption, fecTolerance, pacing }
```

- Local/Remote: RFC1918/ULA match **and** RTT+jitter sane ⇒ Local; re-evaluated
  live (VPN tie-break, D1).
- Resolution: Work·Local = host-native 1:1 (query serverinfo/display); Play = min
  (host panel, client panel aspect-fit); Remote caps at 1080p-class until measured
  headroom proves more.
- Bitrate: derived from measured headroom (start conservative, probe up), biased by
  the dial; never a bare user number outside expert profiles.
- Every derived decision is *inspectable*: the doctor pane shows "chose 41 Mbps
  because: 6 GHz link, shared channel, 78 Mbps headroom × 0.55 safety" — settings
  you can interrogate instead of settings you must set.

### 5.5 The doctor (M6, the signature feature)

- **Probes:** ICMP (SimplePing-style) to gateway + host at 5 Hz during streams,
  1/min idle; interface type + Wi-Fi channel/band via CoreWLAN; `awdl0` state watch;
  in-stream loss/FEC/underrun counters from Telemetry.
- **Signatures** (D4 table): AWDL spikes; host power-save (via optional SSH probe);
  shared-channel double airtime; host uplink MCS collapse.
- **Fixes:** privileged helper (SMAppService, the enhanced client validates this
  pattern) to down `awdl0` during streams and restore after; SSH-authorized host
  fixes (`iw power_save off`) with one-click apply; otherwise plain-language advice
  ("wire either end and this doubles").
- Every diagnosis renders as a card: symptom → evidence → one button.

---

## 6. Milestones (each ends runnable against `ice`)

| # | Name | Deliverable | Acceptance |
|---|------|-------------|------------|
| M0 | Scaffold | this plan, repo, references | ✅ done |
| M1 | Pairing | LyteKit: discovery, cert gen, PIN pair, serverinfo/applist. CLI: `lyte-cli pair`, `lyte-cli apps` | Pairs with Sunshine on ice; applist prints; identity survives relaunch (Keychain) |
| M2 | Session | RTSP handshake + control ENet connect + launch/resume/quit | `lyte-cli launch Desktop` reaches PLAY; control channel stays up 10 min; clean teardown |
| M3 | Pixels | Video UDP → FEC → depacketize → ASBDL in a bare window | 2048×1280@60 HEVC ≥5 min, zero visible corruption on clean LAN; IDR recovery works under induced 5% loss |
| M4 | Hands & ears | Input (free+locked mouse, keyboard, scroll) + Opus audio | Type/scroll/click in Work mode; play a game in Play mode; A/V sync ±40 ms; audio survives induced jitter |
| M5 | App shell | SwiftUI Hosts/Apps/Stream/Settings, mode toggle, policy engine v1 | Cold start → paired → streaming in <60 s of user time; zero settings touched |
| M6 | Doctor | probes, signatures, awdl helper, SSH host checks | Reproduce the case study on demand: doctor names AWDL + power-save + shared-channel correctly, fixes the first two |
| M7 | Polish | Metal/VTDecompression path, AV1, HDR, frame-pacing dial, MenuBarExtra, reconnect/resume | Play·Local end-to-end latency ≤ moonlight-qt on same hardware; HDR round-trips |
| M8 | Deep input | IOKit HID module (port MACOS.md §7 knowledge), multi-pad, side buttons | DualSense + Xbox BT with rumble simultaneously |

Ship signal: M5 is daily-drivable for Steve; M6 is the public-release bar.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| ENet fork subtleties (channel config, MTU) | Vendor the exact fork; integration-test against Sunshine nightly + `ice` |
| Audio FEC parity matrix mismatch | Vendor matrix verbatim; golden-packet tests captured from real sessions |
| Depacketizer edge cases (multi-FEC blocks, frame-header variants) | Sunshine-only trims variants; fuzz the parser (COMMON.md §15 quality bar); capture-replay corpus from ice |
| Pairing crypto byte-exactness | Golden transcripts captured from reference client ↔ Sunshine; unit-test each stage |
| VideoToolbox HEVC quirks (parameter-set changes mid-stream) | Rebuild format description on VPS/SPS/PPS change (reference behavior); test host resolution changes |
| Sandbox + UDP + ICMP + helper | Prototype entitlements in M1 CLI (network.client/server); SMAppService helper spike early in M6 |
| Scope creep (the 40-settings gravity well) | D2 is law: new knob ⇒ policy input or expert-profile field, never a checkbox |

---

## 8. Open questions

1. **Min macOS:** 15-only proposed (newest SwiftUI, `CADisplayLink`). OK, or must we reach 14?
2. **Gamepads at M4 or M8?** Plan says GCController basics at M4, deep HID at M8 — right priority for a Work-heavy user?
3. **Encryption default for Local:** Sunshine LAN default is off; Lyte could default
   Work·Local encrypted anyway (~free with AES-NI/FEAT_AES). Proposed: **on**.
4. **App identity:** bundle id `dev.shreeve.Lyte`? Needed before Keychain/helper work.
5. **Telemetry retention:** doctor keeps rolling 24 h of session stats locally (never leaves the machine) — right?

---

## 9. Source-of-truth map

| Topic | Authority |
|-------|-----------|
| Product decisions | docs/DESIGN.md |
| Wire protocol details | misc/COMMON.md → misc/moonlight-common-c/src |
| macOS platform tricks | misc/MACOS.md → misc/moonlight-macos/Limelight |
| Written protocol spec (second opinion) | Wolf docs (games-on-whales.github.io/wolf) |
| Milestones & status | this file §6 |
