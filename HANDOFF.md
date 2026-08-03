# Lyte — Session Handoff

*Current as of 2026-08-02 (post-E5, tag `self-hosted`). The session
ledger — update freely; commit updates in the ledger voice. This file
carries ONLY what is live and actionable. Frozen history: the H2→H4
wave ledger and Beauty Bar forensics are
`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`; the
pre-overhaul file is commit `a54ab69`; the last pre-slim version of
THIS file (the 2026-07-30 pre-pivot resume, the portal-era live-ops
playbook, and the full Beauty Bar table with its eight dated rows) is
`git show 0753cbc:HANDOFF.md`.*

# SESSION RESUME — START HERE (2026-08-02: SELF-HOSTED)

**The direct-eye epoch is COMPLETE.** Phases E0–E6b all landed
(#45–#57 and friends), and the E5 portal demolition merged as **PR #72**
with the annotated tag **`self-hosted`** on merge `860369a`: the portal
and mutter ScreenCast backends, PipeWire video, the libav NVENC seat,
and the vendored no-reset FFmpeg are deleted. Capture is the direct
eye (KMS doorbell → EGL blit → native VAAPI through our own HEVC
pens); `ldd lyte-host` shows zero libav; a plain `swift build` (no
ffmpeg env) is itself a gate. The earlier tag `first-light` marks the
first NO-DROPS real session (cushion 0–150 ms slider, honest
link-health pill, avahi pinned to the wired NIC).

**Live ops:** pup runs a standing supervisor loop (`~/lyte-loop.sh`,
nohup) on `--backend direct --encoder native --wire-listen 41151
--ratchet --clipboard=images --advertise-interface enxf8e43b7ede7c`
(`--backend`/`--encoder`/`--ratchet` are accepted no-ops since E5) —
wired at 10.0.0.232. After EVERY rebuild:
`sudo -n setcap cap_sys_admin+ep .build/debug/lyte-host` (the loop's
next respawn execs the new binary). Never kill the owner's 41151 loop;
test hosts use fresh 41xxx ports with `--no-advertise`.

**Where the work lives now:** the v1-final ANALYSIS remainder is
**ESSENTIALLY CLOSED** (2026-08-02): every Tier-2 item done (eight in
the hardening waves #27/#30/#33/#38/#43, T2-10 → #75, T2-13 → #76)
and the A-train batch landed as #77 (bounded audio roundtrips +
atomic exit reason), #78 (init validation above allocations), #79
(clock-model anchor pairing + pinned order-invariance, decoy stamp
discarded by contract). Only TWO items remain in TODO.md, both
deliberately deferred to their proper homes: A-20 (channel-blind
trains → the direct-leg quality refinement) and A-26 (duplications →
the v2 Common/IO split). Suites at HEAD: Wire 517, root 287, host
290 pup / 289 Mac. docs/README.md is the doc catalog (twenty
finished records retired to git history 2026-08-02;
`git show 4bb3e11:docs/<name>`).

**The active track is the postures design**
(docs/20260802-013946-postures-design.md): audio first —
mute-at-source LANDED (#71, key 14, `streamOff` 0x04, WIRE strip
button); **tripwire + pre-roll LANDED (#80, 2026-08-02)**: capability
key 15 + CTRL 0x25 track-state, HostCore AudioTripwire (5 s hold /
100 ms trip / 200 ms ring / 5 s check-ins), client relaxes the 350 ms
detector on announced quiet and re-tightens on wake evidence; live
smoke 3572 encoded / 999 sent / 2573 gated. Deferred by design:
Settings dials, DTX warm rung, DSP fades. The REWIND was RE-SIZED by
the owner (2026-08-02): "more like 2–5 seconds" — an instant-replay
button, not a DVR; the tripwire's ring already banks the mechanism
(deepen to ~5 s ≈ 80 KB when demand shows up), so it's PARKED behind
demand, not next. **Video quiet posture LANDED (#81, 2026-08-02)**:
capability key 16 + CTRL 0x26 posture-state, HostCore VideoQuietPacer
(keepalive 1→2→4→8→16→30 s, one rung per 30 s stillness, each step
announced once; FB damage or client input IS the wake and collapses
to 1 s with one active announcement); client stores
announcedVideoPosture, drops unnegotiated 0x26 — no detector change
needed (#66 already gap-normalized video freshness). Live smoke:
`posture_announcements=0` at pup's 1 Hz clock repaint (honest —
ladder pinned by unit + in-vivo legs instead). **Native-seat quality
witness LANDED (#82, 2026-08-02)**: motion + quality-static legs read
the displayed buffer back from the GPU, decode the presenter's 24-bit
marker, regenerate the authored frame from the client twin
(SyntheticMotionReference), and PSNR/SSIM the glass; the three
renderers (GTK canvas / numpy twin / Swift mirror) are pinned
byte-identical by shared SHA-256 fixtures in both suites. Client
exports hostAnnouncedAudioQuiet so the analyzer books tripwire
stillness as announced_quiet_stillness, not blackout. **THE
CONDUCTOR's video part LANDED (#83, 2026-08-03)** — the model of
record is docs/20260803-050422-metronome-playout-design.md (owner
naming, use verbatim: the score, cue/beat/late/hole/slip/chain,
rubato filed): VideoBeatConductor replaced AdaptiveVideoPlayout
(retired outright; queue policies live on as RendererHandoffPolicy).
The grid advances ordinally (round(sourceStep/period) beats), late
parts keep their passed beat, holes re-cue whole beats once, the
ceiling cuts with whole-beat hysteresis (a pinned slider chattered
the grid — pinned by test), slip repays drift. Witness verdict PASS:
gap p50=p95=p99 = 16.667 ms EXACTLY, lateness p99 0.4–4.6 ms (bar 8,
was ~18), 30.76 dB / SSIM 0.9989, 29/29 phase-locked, 0 IDR — owner
confirmed by eye ("ABSOLUTELY SOLVED"). **The beat-skip hunt CLOSED
(#84, 2026-08-03, CaptureBeatBook):** the host grew a sans-IO beat
book (HostCore; every doorbell poll and flip stamped; gap ≥ 1.5
beats books a skip with a verdict — `source` when the doorbell
watched the FB hold still, `loop` when the doorbell went blind) plus
per-stage clocks in DirectEyeLeg (service/cursor/grab/blit/encode/
deliver, skip lines + closing beat-book books). Rig verdict: the
HOST LOOP IS EXONERATED in steady state (all stages < 9 ms; one
106 ms wire.service() stall at connect — audio-routing/clipboard
setup on the capture thread, inside client warm-up). The source
skips are a STRICT 10.000-second comb: GNOME Shell 50.1 itself burns
20–30 ms of flat-out CPU at monotonic X4.958 every 10 s — present on
an IDLE desktop, no presenter, no client, no encode (10 ms
schedstat sampler; python GC and every daemon acquitted). The
compositor misses two beats every ten seconds machine-wide: the
owner's residual "occasional shudder" is pup's shell housekeeping
(gjs full-GC signature), not Lyte. Mitigation is a system decision
(shell extension diet / newer shell / accept). **The janitor LANDED
(#85, 2026-08-03): wire.service() moved off the capture thread onto
"lyte-shell-service" (10 ms sweep, default priority, only caller of
service(), semaphore-joined through every exit door); live smoke on
a 41199 test host: loop skips 0 across 1495 flips, service_max
2.8 ms on the janitor (was a 106 ms capture-thread stall at
connect), remaining skips all source class (the shell's comb).**
Still filed: GNOME focus
denial still covers the witness marker after remote input
(benchmark needs a focus story; owner's desktop-click is the
workaround). **Conductor tier 2 LANDED (#86, 2026-08-03):
ConductorPrimitives.swift — BeatTailRing (video's private p99 ring
retired, parity-pinned), ProofCounter (one law, was four spellings:
video slip proof + audio decay hold/step/retarget cadence), audio's
private 5 ms constant now the wire's, LatencyHistogram rehomed.
Doctrine asymmetries KEPT and recorded: audio's clock = the DAC
(lattice detrend, never HostClockModel); audio's cushion statistic
= window spread, not p99 (p99 discarded exactly the late/PLC
events). Root suite 293 with every pre-existing audio/video pin
unchanged — nothing moved. Tier 3 = LyteCore module in v2.**
**E2 LANDED (#87, 2026-08-03): kernel uinput is the PRIMARY AND
SOLE input injector — MutterInputInjector deleted (~170 lines of
D-Bus choreography; --input mutter fails loudly at parse),
UinputInjector grew the release-all law (held-code set drained at
stop — the ⌘Tab latch) plus a 150 ms device-settle, and the new
lyte-uinput-check harness reads the three virtual devices back
from evdev — routing, absolute scaling/clamping, v120 half-detent
accumulation, ALL PASS on pup first run (run it under sudo). The
client already spoke evdev codes and monitor pixels on the wire,
so no translation layer anywhere; everything above the
InputInjector seam untouched. The clipboard's OWN RemoteDesktop
session survives by design (its Wayland helper stays filed —
now the LAST Mutter-session tenant in the process). Owner
feel-check PASSED (2026-08-03, live session on the uinput binary):
typing/⌘Tab/aim/scroll all felt normal — E2 is fully closed.** **REXT 4:4:4 LANDED — the Best tier
is LIVE (#89 + #90, 2026-08-03).** #89: the HEVC pens grew a
`chroma444` recipe (profile_idc 4, the §A.3.5 Main 4:4:4 constraint
row, SPS chroma_format_idc 3; BitReader pin tests walk every field,
4:2:0 oracle bytes proven untouched); the VAAPI encoder grew the
matching mode (VAProfileHEVCMain444 — Arc probe GREEN, std
entrypoint — packed AYUV surfaces, triple coded buffer, single-layer
export); EyeGL converts in ONE pass (AYUV imports as ARGB8888, the
byte layouts coincide: vec4(y,u,v,1) IS the AYUV plane), and
`lyte-eye capture --chroma 444` gates it: M5 decode-probe HARDWARE
5/5, '444v' output, frame eyeballed AS PIXELS (Chrome's four colors
in order, the red record pill red — no chroma swap). #90: the host
declares on PROOF — `probesMain444()` asks the silicon at startup,
green → declares [420, 444]; the agreement lands after the leg's
encoder opens, so the leg polls the agreed posture and flips ONCE
(Best agreement → NV12 targets destroyed, encoder reopened Rext
4:4:4, lastFB zeroed so a static desktop still delivers its IDR);
stats line reports the encoder that RAN. Live gate both ways:
`wire-view --chroma 444` → agreed [2], client SPS audit of the
received stream read "stream chroma 4:4:4", 16 decoded / 0 skipped /
first frame 19.2 ms; `--chroma 420` stayed 4:2:0, zero flips. NO
Wire changes — the rails (yuv444 id, ChromaTier UI/persistence/
re-dial/fallback, ChromaPosture) shipped earlier and lit up
unchanged. OWNER VERDICT (2026-08-03, live session at Best from the
app): "Screen crispness is undeniable!" — the eyeball gate is
PASSED; the Best tier is the rig's daily posture. SccMain444 follow-up
CLOSED RED (2026-08-03): the Arc encodes it but NO Mac can decode it —
JCT-VC conformance streams (IBC/palette/4:4:4, Apple's own HT
contributions beside them) all fail on M5 VideoToolbox with -12909
per access unit, and ffmpeg's software decoder doesn't implement SCC
either; probe-both-ends-first saved the pens a wasted day.**
**E6a NVENC PARKED BEHIND HARDWARE (2026-08-03):** pup is verified
no-MUX Optimus (the RTX 4050 owns zero connectors), the
cross-adapter copy stays rejected, no NVIDIA-panel box exists →
no gate is possible; the full productionize scoping is banked in
TODO.md (encoder seam, zero-copy registration, recipe revival,
scanout-CRTC ordinal mapping, topology doctor). **THE QUALITY
BLOCK LANDED (#91 + #92, 2026-08-03):** the A/B measurement
rewrote A-20 — Best tier reads 57.6 dB static / 56.8 dB motion
min-channel (SSIM 0.99999+) at zero cadence cost, converged from
the FIRST observation, so the explicit QP ratchet is obsolete for
stills; #91 made the witness grade PER TIER (streamChroma in the
benchmark sample, 4:4:4 floors 45/50 dB + SSIM 0.9995, pinned
both directions, live Best run passed under its own floors), #92
reshaped the overlay into the two-column ledger (owner's
stats-for-nerds steal: dimmed right-aligned labels, ruled grammar
intact, session row now says "hevc 4:4:4", glass row gains the
conductor's cushion ms). Owed: owner's visual on the ledger
overlay. Then: E4 packaging aimed at Lyte OS (first measured
requirement banked 2026-08-03: no stop-the-world runtime in the
display path — the shell's 10 s comb is the evidence). AV1 stays
a 4:2:0 lane (no 4:4:4 hardware encoders exist anywhere,
2026-08).

**Suites at HEAD:** Wire 513, root client 284, host 300 on pup / 299
Mac — all green (host grew the Rext pen pins and the E2 harness).

# STANDING RULINGS (owner decisions of record — do not re-litigate)

- **Chroma**: three-tier control, Good = 4:2:0 / Better = 4:2:2
  (DORMANT — no reference hardware encodes 4:2:2; grayed "not offered
  by this host") / Best = 4:4:4; flip = clean reconnect. A `yuv422` id
  is a contract-safe append when hardware exists (wire today:
  `CapabilityChroma` yuv420 = 1, yuv444 = 2). Post-E5 status: the
  native pens serve 4:2:0 only — Best is dormant until Rext lands in
  the pens (queued on the postures track).
- **Color path**: `rgb_mode` 601-limited ships (glass-correct,
  quality-equal); gbrp is OUT (CoreMedia has no identity-matrix
  vocabulary — structural); the full-range row is named-and-queued,
  not gating.
- **FEC ceiling**: keep the capped-CQ posture (conform IDRs to the
  ceiling; the ratchet heals). Banked: the fec group-index rides the
  pre-written wire-v2 batch (ceiling dies free if v2 ships);
  intra-refresh is the named experiment if ceiling-IDR quality ever
  bothers the eyeball.
- **P-2 (monitor selection) and P-3 (resolution change): DROPPED
  outright** (2026-07-30). P-2 revives with no wire debt if a
  multi-monitor host ever exists; P-3's law is chroma's law — fixed
  at ANNOUNCE, change = clean reconnect. The residual belt's code
  half LANDED (PR #24: a mid-session geometry change fails the
  session with a typed teardown); the remaining half is the live
  watch in TODO.md — one deliberate monitor-mode flip.
- **Split-groups wire contract**: don't re-litigate multi-group
  frames without a wire-v2 discussion first (finding in the archived
  HS-25 wave entry).
- **Reconfigure-IDR family: CLOSED** (HS-33). Rate moves apply with
  zero reset and zero IDR. The law was proven on the vendored
  no-reset libavcodec (the twin `--no-vbv-reconfigure` control leg:
  glass frozen without the directives); since E5 the property is
  STRUCTURAL — our own pens simply never emit a reset — but the
  ruling stands: nobody gets to "simplify" rate-change handling into
  something that mints IDRs.

# LIVE OPS — the owner's rig (direct-eye era)

- **pup standing host is a SYSTEMD SERVICE since E4 (2026-08-03)**:
  `lyte-host.service` (system unit, `User=shreeve`,
  `AmbientCapabilities=CAP_SYS_ADMIN`, `Restart=always`) on port
  **41151** — the owner's eyeball host; leave it alive. The bash
  `~/lyte-loop.sh` supervisor is RETIRED. Config:
  `/etc/lyte/lyte-host.conf` (operator-owned; `LYTE_HOST_BIN` points
  at the build tree, `LYTE_HOST_ARGS` is the old loop command line).
  Session log: `/tmp/lyte-host-session.log` unchanged (the redirect
  rides inside the unit's shell — Ubuntu's fs.protected_regular
  forbids root append: into another user's /tmp file). **The deploy
  loop is now: `swift build` then `sudo -n systemctl restart
  lyte-host` — NO setcap step**: the capability is ambient on the
  service (gate-proven on a caps-stripped binary). setcap remains
  ONLY for hand-run hosts (test ports, lyte-eye probes:
  `sudo -n setcap cap_sys_admin+ep .build/debug/lyte-eye`).
  Restart/status: `systemctl is-active lyte-host`,
  `sudo -n journalctl -u lyte-host` for unit lifecycle. Install/
  repair: `bash ~/src/lyte-host/Scripts/install-host.sh`
  (idempotent; never overwrites the conf).
- **The owner's client** is the app bundle at `.build/Lyte.app` —
  launch with `open .build/Lyte.app` (NEVER run the raw binary under
  a parent process; it needs its own bundle for a proper macOS
  window/menu bar). Client & host are PAIRED (client static
  `357a83cc…`) — a healthy reconnect shows **no PIN**. If a 6-digit
  pairing box appears, the client lost its pinned identity: restart
  the host loop with `--pair` so it mints+prints a PIN to the session
  log (3 wrong guesses burn it).
- **Secrets law**: NEVER touch pup's
  `~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`.
  sha-verify around live runs: `noise_static.key 72860390…cfed`,
  `paired_clients 8dc1f88a…55fd` must stay byte-identical;
  `portal_token` is a portal-era leftover, inert but protected.
- **Harness discipline**: test lyte-hosts MUST run `--no-advertise`
  on fresh 41xxx ports — an advertised test host is a second "pup"
  in discovery and the owner's app WILL connect to it. Never kill or
  connect to the owner's 41151 loop. When a slice runs live legs on
  pup while the owner might connect, both hosts capture the same
  physical screen — tell the owner BEFORE the leg, not after they
  report black.
- *(The portal-wedge black-screen playbook and the
  `MUTTER_DEBUG_PAINT=disable-direct-scanout` flag died with E5 — the
  direct eye reads the scanout itself, wedge-proof; `setup-host.sh`
  now REMOVES the leftover env flag. The old playbook is in the
  pre-slim file, `git show 0753cbc:HANDOFF.md`.)*

# BUILD/TEST RECIPES (the law — deviations lose builds silently)

- Mac tests need `DEVELOPER_DIR=/Applications/Xcode.app swift test`
  (xcode-select points at CLT, which lacks XCTest). Capture exit
  codes as `rc=$?` after a redirect — never pipe `swift test` to
  grep directly (masks the code; `status` is zsh read-only).
- pup host build/test: rsync `Wire/` → `pup:src/Wire/` and `Host/` →
  `pup:src/lyte-host/` (exclude `.build`), then on pup:
  `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build` (or
  `test`). No ffmpeg env exists anymore — a plain build succeeding is
  itself an E5 gate. Then setcap (see live ops). Good-build marker in
  any host run: the session books print
  `encoder 4:2:0 (native VAAPI)`.
- Wire/ vectors are frozen contracts — append-only, never mutate.
- Stage per package (`git add Wire/`, `git add Host/`), never
  `git add -A`. No AI-attribution trailers in commits, ever.

# WORKERS (background subagents)

Session-bound: a subagent from a previous chat CANNOT be resumed from
a new chat — relaunch a fresh worker with a full task prompt. Its file
edits, commits, and pup-side state persist on disk regardless; only
the live agent handle is lost. Resuming = inspect what the stopped
worker left on disk, keep or revert it, relaunch fresh. Standing infra
that is NOT a worker and stays up: the pup 41151 loop and the owner's
client app bundle.

# THE BEAUTY BAR — the standing quality gate, new instrument era

The instrument is `Scripts/benchmark-app.sh` (#82): GPU readback of
the displayed buffer, marker-locked against the byte-pinned authored
frame. The old corpus-era bars (static ≥ 50 dB · motion ≥ 55 dB) do
NOT carry over. FLOORS ARE PER CHROMA TIER since 2026-08-03 (the
sample's `streamChroma` = the wire's SPS-audit truth; absent = a
pre-tier recording, graded 4:2:0):
  · 4:2:0 — min-channel 28 dB active / 30 dB converged / SSIM 0.995
    (the synthetic pattern is chroma-adversarial: thin saturated
    lines pin R/B near 31 dB at 4:2:0 regardless of encoder health)
  · 4:4:4 — 45 dB active / 50 dB converged / SSIM 0.9995 (the
    Best-tier commissioning, below)
Pin the leg's tier with `LYTE_BENCHMARK_CHROMA_TIER=good|best`
(empty = the pinned host's persisted tier — ambiguous for an A/B).
Baseline rows (panel at 60 Hz — REQUIRED for motion legs; at 120 Hz
Mutter presents the 60 fps pattern unevenly and the preflight
refuses): 4:2:0 at `0410e16` (2026-08-02): quality-static PASS
31.2 dB / SSIM 0.9991, 29/29 phase-locked; motion PASS at `61fb56b`
(#83's metronome): gap p50=p95=p99 16.667 ms exactly, lateness p99
1.68 ms, 30.76 dB / SSIM 0.9989, 59.5 fps, 0 IDR. 4:4:4 BEST-TIER
COMMISSIONING (2026-08-03, post-#90): quality-static 57.6 dB
min-channel / SSIM 0.999994; motion 56.8 dB / SSIM 0.99999 at
59.97 fps, gap 16.667 ms exact, lateness p99 1.92 ms — +26 dB over
4:2:0 at zero cadence cost. RATCHET FINDING (closes the A-20
quality-refinement ambition for stills): Best-tier static quality
converges from the FIRST observation — the VBR envelope at
keepalive cadence already floors QP, so the portal-era explicit
QP-descent ratchet has nothing left to fetch; the refinement work
became these floors. ENVIRONMENT WART on the books: macOS
resurrects awdl0 mid-run (~1×/30 s some days); the helper's
re-engage costs a ~100 ms audio window → `audio_steady_state_late_
or_plc` FAILs that are tier-independent and environmental — check
stderr for "awdl0 UP while streaming" before blaming the wire.
The libav-era eight-row table with footnotes:
`git show 0753cbc:HANDOFF.md`; per-row forensics:
`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`.
Never massage a red cell: a FAIL at HEAD is a finding.
