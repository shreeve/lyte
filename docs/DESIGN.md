# Lyte — Design Decisions

This living document records Lyte's current product decisions. The original
direction came from the diagnosis session summarized in the case study; later
commissioning replaced the bootstrap implementation details with the owned
architecture described here.

## D1. Two axes, one question

Streaming policy is resolved from a 2×2 grid: **intent × network**.

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
- The Conductor derives playout reserve from observed holes and clean beats.
  Cushion is not a user setting and is never stored as milliseconds or frames.

## D3. Declarations are not tuning knobs

- Users declare intent and, where the hardware offers a real choice, a named
  posture such as chroma quality. Lyte derives bitrate, resolution, pacing,
  repair, and reserve from those declarations plus live evidence.
- Diagnostic surfaces may expose derived values and the evidence behind them,
  but the primary product does not offer an encoder-knob farm or expert
  profiles that override automatic policy.
- Chroma changes are session postures and therefore reconnect cleanly; they
  are not mid-stream encoder controls.

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

## D5. Stack: Swift throughout, MIT, independently owned

- **License: MIT for all Lyte-authored code.** Bundled third-party leaves retain
  their upstream licenses and notices.
- **LyteWire** owns the sans-IO protocol. **LyteCore** owns shared sans-IO
  policy and **LyteIO** owns shared OS adapters. **LyteClientCore** and
  **LyteClientSession** own pure client policy; **HostCore**, **HostSession**,
  and **HostAudio** own pure host policy. **LyteTransport** and **HostWire**
  execute those decisions at the role boundaries.
  The system speaks only Lyte-UDP; no GameStream, Sunshine, or Moonlight source
  remains in the product.
- Bootstrap-era compatibility code and reference studies were retired to git
  history at the H2 exit. They are not dependencies of the current system.
- The shipping client uses SwiftUI/AppKit for its shell and input forwarding,
  CoreMedia/VideoToolbox through `AVSampleBufferDisplayLayer` for HEVC glass,
  AudioUnit plus pinned Opus for audio, Network.framework for UDP, and a
  narrowly authenticated ServiceManagement helper for radio posture.
- Swift Crypto is LyteWire's sole external Swift dependency and is confined
  to its crypto leaf; Keychain and code-signing operations use Security.
- The Linux host uses native KMS/DRM capture, GPU color conversion, VAAPI HEVC,
  PipeWire audio, uinput, and the narrow UDP syscall leaf.

## D6. Interaction model: the window is the app (decided 2026-07-15)

No splash, no launcher, no hosts screen gating the product. The stream window
is the unit of everything; the M5 "Hosts/Apps/Stream" screens collapse into
*states of one window type*.

- **Launch → window.** ⌘N makes another. Each window is one connection to one
  host. Multiple windows can represent multiple independent host sessions.
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
  state such as host identity, intent, health, and mute. Derived transport and
  playout numbers stay out of the primary interaction (D2).
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
