# Lyte — Design Decisions

Decisions settled 2026-07-14/15, motivated by a real diagnosis session (see Case Study).

## D1. Two axes, one question

Settings are resolved from a 2×2 grid: **intent × network**.

- **Intent — Work or Play.** The only choice the user makes, one visible toggle.
- **Network — Local or Remote.** Detected: host address in a private range *and*
  RTT/jitter consistent with LAN ⇒ Local; otherwise Remote. Re-evaluated during the
  session (a VPN can make Remote look Local — telemetry breaks the tie).

An earlier three-mode sketch (Work / Play / Away) was rejected: "Away" conflated
network location with intent. Location is a fact, not a mode.

## D2. Policies, not presets

A cell never stores numbers. It stores *goals*, resolved against live measurement:

| Cell        | Optimizes for            | Derived behavior (examples)                          |
|-------------|--------------------------|------------------------------------------------------|
| Local·Work  | static-image fidelity    | 1:1 host resolution, bitrate = f(measured headroom), free mouse, windowed, 4:4:4 if host supports, audio buffers padded |
| Local·Play  | motion latency           | fullscreen, locked mouse, frame pacing, min buffers, max fps, HDR, bitrate yields to latency |
| Remote·Work | resilient legibility     | encryption required, capped resolution, aggressive ABR, auto-reconnect w/ resume |
| Remote·Play | playable latency         | conservative start bitrate, latency-first ABR, encryption required |

Same cell, different network conditions ⇒ different numbers. That is the point.

- Auto-select intent when possible: launching "Desktop" ⇒ Work; a game/Big Picture ⇒ Play.
  Show the choice as a dismissible pill, never a dialog.
- At most one user-visible dial: quality ⇄ latency bias within the active cell.

## D3. Expert profiles are forks of policies

- Clone any cell ⇒ named profile; override individual knobs; save/share as JSON.
- Overridden values render next to the policy-derived value; one-click reset.
- Profiles are per-host-per-cell selectable.

## D4. Network doctor is a first-class subsystem

Continuous lightweight probing (RTT/jitter to gateway and host), plus host-side checks
over SSH when authorized. Known culprit signatures:

| Symptom signature                         | Culprit                            | Fix                                   |
|-------------------------------------------|------------------------------------|---------------------------------------|
| client→gateway spikes 60–100 ms, awdl0 up | AWDL (AirDrop/AirPlay) radio share | suppress awdl0 during stream (helper) |
| host→gateway spikes, power_save on        | host Wi-Fi power save              | `iw set power_save off` + NM config   |
| both ends wireless, same channel          | double airtime                     | halve bitrate target; suggest wire    |
| host tx MCS far below rx MCS              | host uplink retries                | lower bitrate; reposition/wire        |

Prior art: moonlight clients ship AWDL helpers on macOS — validates the concept.

## D5. Stack: Swift throughout, GPL, reference-code informed

- **License: GPLv3, whole repo** — deliberately. It grants full freedom to read,
  port, and link the ecosystem's battle-tested GPL code (moonlight-common-c,
  moonlight-macos and derivatives) instead of re-deriving a decade of protocol
  hardening from scratch. An MIT clean-room variant was considered and rejected:
  the isolation cost (no reference code anywhere in the workflow) outweighed the
  commercial optionality for an open project.
- **LyteKit** is new Swift code implementing the protocol — pairing (HTTPS + PIN,
  client certs), RTSP negotiation, ENet control/input, RTP + Reed-Solomon FEC —
  written with the C reference open on the other monitor, and linking C pieces
  (enet, FEC) where rewriting adds risk without value.
- Reference checkouts live untracked in `misc/`; study summaries are committed:
  `docs/COMMON.md` (protocol core), `docs/MACOS.md` (macOS client patterns).
  Wolf's MIT protocol docs remain a good written spec.
- Framework map (extracted from the shipping client binary): SwiftUI/Combine,
  VideoToolbox, CoreMedia/CoreVideo, Metal(+FX/Kit), CoreHID, GameController,
  CoreHaptics, CoreWLAN (Wi-Fi introspection for the doctor), ServiceManagement
  (privileged helper), Security. Lyte uses CryptoKit/Security instead of bundling
  OpenSSL, and drops SDL2 entirely.
- VideoToolbox decode (H.264/HEVC/AV1) → `CAMetalLayer`, zero-copy.
- AudioUnit + Opus; buffer depth is policy-derived.
- CoreHID mouse path (relative + absolute), GameController for pads.

## D6. Interaction model: the window is the app (decided 2026-07-15)

No splash, no launcher, no hosts screen gating the product. The stream window
is the unit of everything; the M5 "Hosts/Apps/Stream" screens collapse into
*states of one window type*.

- **Launch → window.** ⌘N makes another. Each window is one connection to one
  host. Multiple windows = multiple hosts (Sunshine allows one streaming
  session per host; the UI should make that constraint feel natural).
- **The gate is the empty state.** A new window shows a quiet connect state
  inside itself: Bonjour-discovered hosts, recents first, then the chosen
  host's app list. Pick an app → the picker melts away and the window becomes
  pure stream. First-run pairing (PIN) lives in the same empty state.
  Safari's new-tab page, not a login wall.
- **Relaunch = resume.** Each window remembers its host and reconnects at
  launch. Daily experience: click Dock icon → your desktop appears. Beats the
  M5 "<60 s cold start" metric by an order of magnitude.
- **Toolbar as a whisper.** Slim title-bar accessory, hidden by default while
  streaming (chrome-less look is the default), toggleable. Carries only live
  state: host name, Work/Play toggle, network-health dot, mute. Choices live
  in menus; derived numbers stay invisible (D2).
- **Menus stay minimal** (shipped in M4): app menu = identity + housekeeping
  only; a single Actions menu = every command with its shortcut, doubling as
  the shortcut cheat-sheet.

## Case study (motivating session, 2026-07-14)

Stock Sunshine (Linux, hybrid Intel/NVIDIA laptop "ice") + moonlight-qt on an M5 Mac
looked terrible. Root causes found by hand, in order:

1. Moonlight default ~7.3 Mbps auto bitrate; 720p-class default resolution rescaled
   from a 2048×1280 16:10 host panel, then upscaled to a 5K client display.
2. NVENC probe fails on hybrid graphics (display on iGPU) — VAAPI on Intel Arc is fine,
   but silent fallback hid the fact; pinned `encoder = vaapi`.
3. Choppy audio = jitter, not codec: host Wi-Fi power save (fixed, persisted) +
   client AWDL spikes to ~85 ms (fixed; ~7× jitter reduction) + both ends sharing one
   6 GHz channel (bitrate halved 80→40 Mbps).
4. Double cursor in absolute mouse mode: host composites its cursor into KMS capture
   (no Sunshine option); client-side hide-local-cursor is the only lever.

Every one of these becomes either a policy input (1, 3) or a doctor signature (2, 3, 4).
