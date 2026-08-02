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

**Where the work lives now:** TODO.md carries the ANALYSIS live
remainder — re-verified at code level 2026-08-02, and **every Tier-2
item is now CLOSED**: eight had landed in the hardening waves
(#27/#30/#33/#38/#43) and the last two landed today (T2-10 → #75
pinned audio horizon, T2-13 → #76 configLock publication). SEVEN
A-class items remain, fronted by A-19 (restore roundtrip untimed) /
A-24 (audio quit flag races) / A-23 (init throw ordering) — plus the
audit caveats and the banked AV1 decision record. docs/README.md is the doc catalog (twenty
finished records retired to git history 2026-08-02;
`git show 4bb3e11:docs/<name>`).

**The active track is the postures design**
(docs/20260802-013946-postures-design.md): audio first —
mute-at-source LANDED (#71, key 14, `streamOff` 0x04, WIRE strip
button); NEXT = tripwire + pre-roll (capture never stops, transmission
gates, ~200 ms pre-roll ring saves onsets), then the REWIND (opt-in
host-MEMORY ring, never disk). After audio: video quiet posture +
posture announcement messages, direct-leg quality refinement
(ratchet's successor), the native-seat benchmark quality witness, E6a
NVENC productionize (lyte-nvenc probe banked), Rext 4:4:4 in the
native pens (returns the Best tier), E2 uinput-primary, E4 packaging
aimed at Lyte OS.

**Suites at HEAD:** Wire 512, root client 283, host 281 on pup — all
green.

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

- **pup standing host**: `bash ~/lyte-loop.sh` (nohup, `while true`
  respawn) runs `~/src/lyte-host/.build/debug/lyte-host` on port
  **41151** — the owner's eyeball host; leave it alive. Session log:
  `/tmp/lyte-host-session.log` on pup. It respawns onto whatever was
  last built, so a rebuild + setcap migrates the loop on its next
  cycle. The direct eye needs CAP_SYS_ADMIN on the binary — after
  EVERY rebuild: `sudo -n setcap cap_sys_admin+ep
  .build/debug/lyte-host` (a capless binary fails loudly at startup).
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

# THE BEAUTY BAR — the standing quality gate, between instruments

The per-release quality bar (static ≥ 50 dB · motion ≥ 55 dB · fps
p50 ≥ 55 · IDR ≤ 2/min · churn 0 · loss ≤ 1/150 s) reached its first
all-green row at `f63587c` (2026-07-30, IDR 1.6/min on verified-clean
air). Its instruments (`quality-probe.sh`, `encoder-ab.sh`) measured
the libav seat and were deleted with it in E5; the successor is
`Scripts/benchmark-app.sh` plus the FILED native-seat quality witness
(GPU readback — see the postures queue). The full eight-row table
with footnotes: `git show 0753cbc:HANDOFF.md`; per-row forensics:
`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`.
Never massage a red cell: a FAIL at HEAD is a finding.
