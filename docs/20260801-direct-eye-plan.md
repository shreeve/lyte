# The Direct Eye — Lyte's capture rearchitecture (2026-08-01)

Owner-directed ("PROCEED!" / "let's begin the effort to sort of start
over"), following the portal freeze crisis (three at the glass in one
evening) and the same-night feasibility probes (Host/Probes/kms-eye/).
This plan supersedes the capture-organ options list in TODO.md: the
decision is made — option A, direct KMS capture, Swift-first.

## 1. The verdict on the portal era

The portal → Mutter ScreenCast → PipeWire path was chosen deliberately
and for good reasons (HOST-PLAN.md §"Why portal": consent model, no
privileges, damage-driven idle silence, dmabuf zero-copy, RemoteDesktop
input in the same session). It delivered a working v1. Its cost has now
materialized on the owner's screen: the compositor holds VETO POWER
over frame delivery. Mutter wedged three times in one evening (577
clean frames then 1 fps keepalive while the demo painted at 83–89%
CPU), the portal needed restart playbooks, and the benchmark rig
already distrusted the whole organ (SyntheticMotionSource exists to
bypass it). A capture path that can sulk is not a foundation for
"flawless, buttery" — the owner's standing bar.

## 2. What the probes proved (2026-08-01, on pup, live session)

1. **Doorbell**: polling the primary plane's FB_ID recovers damage
   detection from below — 1.00 flips/s idle, 61.00/s under 60 fps
   motion, 4 µs/poll, UNPRIVILEGED, cannot wedge (register read).
   Hardware cursor lives on its own plane (cursor ≠ damage).
2. **Encoders**: the Arc media engine encodes HEVC and AV1 today
   (iHD 26.1.2); NVENC remains for NVIDIA-panel desktops.
3. **Format bridge**: MTL scanout is XR30 + CCS compression (3-plane);
   the media engine's VPP refuses it, the 3D engine imports it in
   0.04 ms via EGL with explicit modifiers. GPU-side blit to NV12 is
   the (Sunshine-proven) bridge. No CPU pixels anywhere.

## 3. The new architecture

    doorbell (FB_ID poll, ≤4 µs)          [Swift, libdrm via modulemap]
      └─ changed? → GETFB2 + dmabuf export  [Swift, privileged fd]
           └─ EGL import (modifier-aware)    [Swift, EGL/GBM modulemap]
                └─ GL blit RGB→NV12          [one tiny shader]
                     └─ VAAPI / NVENC encode  [vendored libavcodec]
                          └─ existing wire    [UNCHANGED: VideoChannel,
                             pacer, FEC, NACK, Noise, governor, lanes]

Cadence is a consequence of content: 0 fps blank → ~1 fps caret →
60 fps video, capped at panel rate. Encoder skip-size is the backstop
detector for FB-churn-without-change. IDR on demand (0x0302) and at
stream start, exactly as today.

**Swift-first, no .c files**: libdrm/GBM/EGL/GL are imported through
SwiftPM systemLibrary module maps (CNetIO-style shims only if a macro
wall appears). The probes stay in C as proof artifacts only.

**Doctor rules** (host auto-detects, per TODO.md):
- Desktop, panel on NVIDIA → NVENC zero-copy on card0.
- pup (no MUX, verified) → Arc media engine on card1; the
  Intel→NVIDIA copy path is REJECTED (power, wonk, no quality win).

## 4. The simplification — what dies with the portal era

Deleted outright once E5 lands (this is the "massively simplify"):
- The portal D-Bus dance: session negotiation, restore tokens,
  consent-dialog choreography, drop-caps-and-dumpable caveats.
- PipeWire VIDEO consumption: SPA format negotiation, stream states,
  starvation tripwires, STARVED counters, keepalive interpretation.
- The Mutter dependency for video: wedge playbooks (portal restarts),
  MUTTER_DEBUG_PAINT env archaeology, damage-delivery forensics.
- The auto-heal seam (recreate-screencast-on-starvation) — moot.
- The 1 fps keepalive special-casing in cadence logic.

Kept, explicitly:
- The ENTIRE transport and its test fleet (frozen wire, vectors).
- Audio capture via PipeWire (the audio path is healthy; PipeWire
  stays for sound only).
- The client, untouched.
- The benchmark rig (analyzer, motion ladder, SLO gates) — it judges
  the glass and doesn't care who supplies frames.
- Noise pairing — which BECOMES the consent model (see §6).

## 5. New obligations (the honest bill)

- **Privileges**: GETFB2/dmabuf export needs CAP_SYS_ADMIN. Ship as a
  systemd service with a tight capability set (or setcap on the
  binary). This replaces the portal's consent gating — see §6.
- **Input**: uinput injection (udev rule; the plan's original fallback
  becomes primary). Kills the Mutter RemoteDesktop dependency.
- **Cursor**: hardware cursor plane → position + image as METADATA to
  the client, rendered client-side. Kills the double-cursor artifact
  class and makes cursor motion free (no repaints, no encodes).
- **Clipboard**: the one genuinely session-coupled feature. A tiny
  UNPRIVILEGED helper inside the user session (Wayland clipboard
  protocols) speaking to the host over a local socket. Deferred to
  its own phase; portal-clipboard may serve as a stopgap.
- **Login screen**: KMS sees GDM — the portal era's blackout
  limitation becomes a FEATURE (unlock your machine remotely).
  Explicitly out of scope until the core lands; noted as a prize.

## 6. Consent posture

The portal asked "may this app record the screen?" per session. Lyte's
answer: consent is PAIRING. A host only streams to Noise-authenticated,
explicitly paired clients (existing paired_clients store); installing
and pairing the host IS the owner's consent, exactly as with every
remote-desktop product that owns its host (and as Sunshine's KMS path
works). Document it; no dialog theater.

## 7. Phases (each lands as its own PR train)

- **E0 — the Swift eye, standalone**: `lyte-eye` executable target:
  doorbell → GETFB2 → EGL import → NV12 blit → VAAPI encode → Annex-B
  to file. Gates: sustained 61 fps under motion with p99 frame time
  under budget; true 0-encode idle; `lyte decode-probe` validates the
  bitstream; runs on pup against the live session.
  **LANDED 2026-08-01** (m1 doorbell #45; m2 full loop): capture mode
  measured on pup's live session — motion 611 frames / 61.08 fps /
  0 missed grabs / blit 0.85 ms + encode 0.47 ms per frame / 24.8
  KB-frame at qp24; idle 1.37 fps ≈ 82 kbit/s, same binary, no modes
  (cadence IS content). Bitstream: HEVC Main yuv420p tv/bt709;
  Mac M5 `lyte decode-probe`: 611/611 access units HARDWARE decoded,
  0 failed, BT.709 attachments intact. Vendored libavcodec grew
  hevc_vaapi (still no-reset-patched, encoders=2 proof in
  vendor-ffmpeg.sh). Swift-only held: libdrm/GBM/EGL/GL/libva/libav
  all module maps; the two documented unsafeties are the
  AVVAAPIDeviceContext.display first-field read and the
  VADRMPRIMESurfaceDescriptor raw-offset parse (its anonymous-struct
  arrays defeat the Swift importer; the export call takes void*).
- **E1 — the graft**: a CaptureSource seam in the host (DirectEye |
  PortalEye, env-selected; portal remains fallback). Full pipeline to
  the real Mac client. Gates: motion-pipeline benchmark ≥ current
  all-green verdict; a soak leg (30+ min) with zero freezes — the
  test the portal path kept failing at the glass.
  **E1 LIVE RESULTS (2026-08-01, owner at the glass, sanctioned):**
  the takeover leg (Scripts/benchmark-direct.sh — pauses the standing
  loop, stands a direct host on 41151, restores via EXIT trap) ran the
  REAL-capture motion benchmark end to end: 1810 frames / 30 s to the
  owner's M5, presentation-gap p99 **17.6 ms** at the glass, 16
  on-demand IDRs, 0 missed grabs, clean teardown. **The accidental
  A/B**: the identical leg against the standing PORTAL host, minutes
  later, returned `no_frames` — the portal wedged again under
  controlled conditions while the direct eye streamed butter. Thesis
  proven. Remaining red before E1 closes (the honest butter ledger):
  (1) audio gate — 4700 SAMPLES (~98 ms, 0.35%) of declick-protected
  concealment across the leg; packets arrived clockwork (±0.7 ms,
  6023/6023), ring depth healthy (~93 ms ≈ 20-packet target), so it's
  playout-tuning vs the new cadence, not transport — needs the audio
  pump/jitter interrogation; (2) rate directives deferred (CQP) until
  E6-VAAPI; (3) chroma: direct leg negotiates 4:2:0 (NV12 blit) — the
  4:4:4 text-crispness tier needs an Arc Rext-444 leg; (4) cursor is
  ABSENT from KMS primary-plane capture (hardware cursor plane) — E3
  is now user-visible, not theoretical; (5) 30-min soak still owed.
  Environment facts learned: pup's panel is 120 Hz native (benchmark
  corpus + preflight math assume 60 — leg ran with a session-temporary
  60 Hz switch via Mutter DisplayConfig; make the rig refresh-aware);
  a cap_sys_admin binary is ptrace-guarded (provenance witness read
  via sudo -n in the rig) and non-dumpable (re-armed via prctl leaf
  for coredumps); Mutter refuses display reconfig with the lid closed.
- **E2 — input**: uinput primary, RemoteDesktop retired. Gates:
  existing input round-trip tests against the new injector; the ⌘Tab
  latch and release-all semantics preserved.
- **E3 — cursor metadata**: cursor plane watcher → wire message →
  client-side cursor. Gate: cursor motion produces zero video frames.
- **E4 — privilege & packaging**: systemd unit, capability set,
  install story, consent documentation. Gate: fresh-machine install
  runs E0–E3 gates without hand-tuning.
- **E5 — demolition**: delete the portal path and its playbooks;
  strike the residues from TODO/ANALYSIS ledgers. Tag the removal.
- **E6 — encoder independence (owner-approved 2026-08-01)**: retire
  libavcodec by talking to the encoder APIs directly in Swift.
  Order matters: (a) **NVENC-native first** — the SDK writes its own
  SPS/PPS and exposes NvEncReconfigureEncoder directly, so the
  no-reset patch AND vendor-ffmpeg.sh die at the root (Sunshine's
  native NVENC backend is the existence proof); (b) **VAAPI-native
  second** — the real project is the H.265 header serializer
  (exp-Golomb VPS/SPS/PPS + VUI, ~500 lines; HostCore's bitstream
  helpers are home turf), validated by byte-diffing against
  libavcodec's headers on identical frames and by decode-probe.
  Quirk-armor stance: we shield with the doctor's NAMED hardware
  list, not ffmpeg's decade of workarounds. libavcodec stays as
  scaffolding until per-leg parity is proven, then exits entirely.
- **Then**: AV1 negotiation (the recorded four seams), login-screen
  capture, multi-monitor.

## 8. Risks, named

- **NVIDIA desktops unproven**: GETFB2+EGL on nvidia-drm (card0-class
  scanout) not yet probed — E0 tests on pup only; the desktop leg
  needs its own probe before E1 declares the doctor rules complete.
- **Modifier zoo**: other GPUs/compositors scan out other exotic
  formats; the EGL-with-modifiers import is the general answer, but
  each family gets probed before support is claimed.
- **Compositor swapchain lifetime**: the fb we import can be released
  mid-use (suspected cause of the kmsgrab I/O errors). The organ must
  import-and-blit promptly and tolerate EBUSY/stale-fb gracefully —
  a correctness requirement, not a rarity.
- **Multi-monitor / rotation / VRR / fractional scaling**: one CRTC
  first (pup's panel), the rest staged later; plane transforms must
  be read, not assumed.
- **Secure environments**: CAP_SYS_ADMIN may be unacceptable somewhere;
  the portal path's deletion in E5 is contingent on the direct eye
  serving every supported environment; if not, PortalEye survives as
  a doctor-selected fallback (and the E5 demolition shrinks).

## 9. Why this is not "becoming Sunshine"

Sunshine's KMS capture is its one proven organ; its deaf transport,
firehose pacing, and game-tuned encoding are why it lost the owner's
trust (see the pre-Lyte study). Lyte keeps its own transport — loss-
driven, NACK-repairing, concealment-gated, benchmark-judged — and
bolts the proven eye onto it. The skeleton is borrowed; every muscle
is ours, already built, already tested.
