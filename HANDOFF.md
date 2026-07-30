# Lyte — Session Handoff

*Current as of 2026-07-30 (post-audit-sweep overhaul). The session
ledger — update freely; commit updates in the ledger voice. This file
carries ONLY what is live and actionable. Everything historical — the
post-H2 state block, every wave entry from the H2 demolition through
H4, and the Beauty Bar's full per-row forensics — is frozen verbatim in
`docs/20260730-handoff-archive-h2-h4.md` (and in git history; the
pre-overhaul file is commit `a54ab69`).*

# SESSION RESUME — START HERE (2026-07-30)

**One-paragraph state.** The host ladder stands **H0a ✓ H0b ✓ H1 ✓
H2 ✓ H3 ✓ H4 ✓, H5 half-landed** (files/drag-and-drop shipped;
printing open) — see LYTE-PLAN.md §6 for the ladder. H4 closed with
the Beauty Bar's **first all-green row** (`f63587c`, IDR 1.6/min on
verified-clean air; table below) and 4:4:4 + clipboard images (P-1)
live. Since then, the **19-PR audit sweep landed whole**: three
read-only auditors (host perf, client perf, cleanup/debt) filed 19
findings, every one became a merged PR (**#1–#19, zero closed** — this
repo squash-merges; PR association is the `(#N)` subject suffix), and
a five-agent verification pass confirmed every landing against main.
Highlights: fall-repricing purge + IDR re-anchor (#6), VBV
exact-tighten (#7), session-lock log buffering (#8), SCHED_RR
drain/audio threads (#9), VideoAssembler sweep gating (#10), estimator
stretched-train guard (#16), idle-floor resend off the encoder's
retained AVFrame (#17), adaptive audio pump (#18). REMAINING.md served
as the sweep ledger and was retired after verification; the sweep's
advisory caveats and owed live watches live in **TODO.md** ("Audit-sweep
verification caveats"). **Suites at HEAD: Wire 486/486, root 218/218,
host 236/236 on Mac AND pup.** Tree clean, everything pushed.

**Actionable queue (rough order):**
1. **Owner eyeballs closing H4** (the only H4 remainder): the
   Wi-Fi-hop leg, the five-minute UI verbs (Chroma tiers, photo
   toggle, banners — `open .build/Lyte.app`, connect to pup 41151, it
   agrees at 444), and the fresh quit-relaunch-reconnect ride (the
   respawn-gap patience, `f63587c`).
2. **Evening-air live watches** (the sweep's owed halves): watch the
   host log for `rate: fall purge` behavior at genuine falls (PR #6)
   and the estimator line's `hole-recused` count + honest medians
   (PR #16) on the next real evening session before calling the
   microstall rung closed.
3. **H5's open half**: printing v1 (intercept host print jobs →
   deliver as PDF → print locally on the client).
4. **H6**: single-binary Linux distribution + the "Be a host" toggle
   on macOS.
5. **Named-but-not-blocking** (carry until claimed): wholly-lost
   frames mint no client IDR demand (pre-existing gap unmasked at the
   HS-33 row; the client's whole-loss counter fix rode `f63587c` —
   verify the demand half on a lossy leg); no [420]-only host exists
   for a live chroma-fallback leg (wants a pre-V-4 build or a
   probe-forced-off host); the HS-26 baseline leg's `throttled 1364`
   at the 50 Mbps recipe (steady-state saturation headroom — eye on
   the next fps leg); browser-viewer B-2+ waits on the owner's QUIC
   posture decision; TODO.md's six sweep caveats (each armed only by
   a future change to its seam); optional rtprio grant on pup
   (`Host/README.md` machine prerequisites item 3).
6. **Parked deliberately**: browser client + Caddy bridge, `lyte
   sniff` decrypt half — both in TODO.md with revive conditions.

**Standing rulings (owner decisions of record — do not re-litigate):**
- **Chroma**: three-tier control, Good = 4:2:0 / Better = 4:2:2
  (DORMANT — Ada NVENC has no 4:2:2 encode; grayed "not offered by
  this host") / Best = 4:4:4; flip = clean reconnect. A `yuv422` id
  is a contract-safe append when hardware exists (wire today:
  `CapabilityChroma` yuv420 = 1, yuv444 = 2).
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
  at ANNOUNCE, change = clean reconnect. Residual belt (named, not
  blocking): verify a live host geometry change produces a clean
  typed teardown, not a hang.
- **Split-groups wire contract**: don't re-litigate multi-group
  frames without a wire-v2 discussion first (finding in the archived
  HS-25 wave entry).
- **Reconfigure-IDR family: CLOSED** (HS-33). The vendored no-reset
  libavcodec applies rate moves with zero reset, zero IDR; the twin
  `--no-vbv-reconfigure` control leg proves the directives are
  load-bearing (glass frozen without them) — nobody gets to
  "simplify" them away.

**LIVE OPS RIGHT NOW.**
- **pup standing host**: `bash ~/lyte-loop.sh` respawns `lyte-host
  --backend portal --wire-listen 41151 --ratchet --clipboard=images
  --seconds 7200` on port **41151** (`while true` loop). Leave it
  alive; it's the owner's eyeball host. Session log:
  `/tmp/lyte-host-session.log` on pup. It launches
  `~/src/lyte-host/.build/debug/lyte-host` — respawns onto whatever
  was last built there (the post-sweep build, 236/236, since
  2026-07-30). The log shows the Rext self-probe passing and chroma
  **[420, 444]** declared: a Best connect agrees at 444.
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
  `portal_token` rotates by design.
- **Black-screen playbook (battle-tested):** (1) portal wedges after
  many rapid short lyte-host runs → `ssh pup 'systemctl --user
  restart xdg-desktop-portal-gnome xdg-desktop-portal'`; (2) the app
  silently not running → relaunch the bundle; (3) **fullscreen `-fs`
  ffplay starves the Mutter screencast** (direct scanout — the portal
  grants the node but PipeWire delivers ZERO frames; portal restarts
  don't help). Same mechanism froze the owner's fullscreen YouTube.
  The DURABLE fix is the `MUTTER_DEBUG_PAINT=disable-direct-scanout`
  login-env flag — a documented machine prerequisite
  (`Host/README.md`, provisioned by `Host/Scripts/setup-host.sh`;
  lyte-host prints `capture: WARNING` at startup while gnome-shell
  lacks it, and `capture: STARVED` if an active session stops
  receiving frames). Until a box has it: run test patterns WINDOWED
  at full size, Wayland-native (`XDG_RUNTIME_DIR=/run/user/1000
  WAYLAND_DISPLAY=wayland-0 SDL_VIDEODRIVER=wayland ffplay -f lavfi
  -i "testsrc2=size=1920x1080:rate=60"`); Xwayland-over-ssh renders
  ~5 fps and fakes a static leg. ALWAYS kill ffplay when done.
  (4) **harness lyte-hosts MUST run `--no-advertise`** on fresh 41xxx
  ports — an advertised test host is a second "pup" in discovery and
  the owner's app WILL connect to it. Never kill or connect to the
  owner's 41151 loop. (5) When a slice runs live legs on pup while
  the owner might connect, both hosts capture the same physical
  screen — tell the owner BEFORE the leg, not after they report
  black.

**Build/test recipes (the law — deviations lose builds silently):**
- Mac tests need `DEVELOPER_DIR=/Applications/Xcode.app swift test`
  (xcode-select points at CLT, which lacks XCTest). Capture exit
  codes as `rc=$?` after a redirect — never pipe `swift test` to
  grep directly (masks the code; `status` is zsh read-only).
- pup host build/test (REQUIRED or the HS-33 no-reset encoder is
  silently lost): rsync `Wire/` → `pup:src/Wire/` and `Host/` →
  `pup:src/lyte-host/` (exclude `.build`,
  `Vendor/ffmpeg/{build,prefix}`), then on pup:
  `VP=$PWD/Vendor/ffmpeg/prefix LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat
  LYTE_FFMPEG_PREFIX=$VP PKG_CONFIG_PATH=$VP/lib/pkgconfig swift build`
  (or `test`). Good-build marker in any host run:
  `encoder: vendored no-reset libavcodec`.
- Wire/ vectors are frozen contracts — append-only, never mutate.
- Stage per package (`git add Wire/`, `git add Host/`), never
  `git add -A`. No AI-attribution trailers in commits, ever.

# RESTARTING WORKERS IN A NEW CHAT (read before resuming)

**The worker model.** "Workers" are background subagents. They are
**session-bound: a subagent from a previous chat CANNOT be resumed
from a new chat** — you relaunch a FRESH worker with a full task
prompt. Their file edits, commits, and pup-side state persist on disk
regardless; only the live agent handle is lost. So resuming =
(a) inspect what the stopped worker left on disk, (b) keep or revert
it, (c) relaunch a fresh worker to finish.

**State (2026-07-30):** NO workers in flight. The tree is clean and
fully pushed (audit sweep #1–#19 merged, ledger commits included).

**To re-arm the 5-minute worker-liveness loop** (optional; only if the
owner wants the auto-watchdog cadence). Start ONE background shell,
unique sentinel, and monitor its stdout:
```
while true; do sleep 300; echo 'AGENT_LOOP_TICK_WORKER_LIVENESS {"prompt":"Confirm all Lyte workers alive: check subagent transcript growth + corroborate against work products (pup processes, git commits); interrupt+resume any worker stalled >15 min with no live work; message the owner only on a fix or completion."}'; done
```
Arm it with a `notify_on_output` watcher on
`^AGENT_LOOP_TICK_WORKER_LIVENESS`. Track the PID so it can be killed
on request. **Do not start a second copy** — check `ps` for an
existing loop first. (An unrelated `AGENT_LOOP_TICK_devendor` loop
from a different project's chat may also be running — leave it alone.)

**Standing infra that is NOT a "worker" and should stay up:** the pup
host loop `bash ~/lyte-loop.sh` (port 41151) and the owner's client
app bundle. Do not kill these when stopping workers.

# THE BEAUTY BAR — standing video-quality gate (Q-1, the plan's R5)

*The per-release quality numbers with pass bars — one dated row per
measurement, at the named build. `Host/Scripts/quality-probe.sh` (run
from the Mac; it orchestrates pup over ssh) produces the whole row
mechanically and prints it verbatim as "BEAUTY BAR ROW". Never massage
a red cell: a FAIL at HEAD is a finding — report it loudly in the wave
entry that dated the row. Companion instrument:
`Host/Scripts/encoder-ab.sh` answers "which recipe" (rerun it per
recipe question, ALWAYS with the desk/text corpus in the race — the
HS-24 rule); this bar answers "did the glass get better".*

The bars: **static** converged luma PSNR ≥ 50 dB (file-mode ratchet
leg, series max vs the LYTE_DUMP_RAW reference) · **motion**
last-frame PSNR ≥ 55 dB at the recipe cap (median of 12 runs) ·
**fps** heavy-motion sustained ≥ 55 at the glass (p50 of per-second
decodes, clean LAN) · **IDR** ≤ 2/min under motion on the clean path ·
**churn** = 0 standing-rate directives (HS-22a's silence-above-the-
boundary, mechanized: a directive with no estimator move since the
previous one) · **loss** ≤ 1 wire frame per 150 s leg.

| date @ build | static dB | motion dB | fps p50 | IDR/min | churn | loss |
|---|---|---|---|---|---|---|
| 2026-07-28 @ 8dc049a | 51.27 PASS | 59.75 PASS | 47 FAIL¹ | 3.9 FAIL¹ | 0 PASS | 0 PASS |
| 2026-07-29 @ 932a4c3 | 52.03 PASS | 59.73 PASS | 58 PASS² | 15.2 FAIL² | 0 PASS | 0 PASS |
| 2026-07-29 @ 8e1e8ca | 52.03 PASS | 59.72 PASS | 61 PASS³ | 6.8 FAIL³ | 0 PASS | 6 FAIL³ |
| 2026-07-29 @ be60e92 | 52.03 PASS | 59.73 PASS | 61 PASS⁴ | 6.4 FAIL⁴ | 0 PASS | 0 PASS⁴ |
| 2026-07-29 @ db84c1b | 53.85 PASS | 59.72 PASS | 61 PASS⁵ | 8.4 FAIL⁵ | 0 PASS | 0 PASS⁵ |
| 2026-07-29 @ ce952ec | 53.85 PASS | 59.73 PASS | 61 PASS⁶ | 8.4 FAIL⁶ | 1 FAIL⁶ | 0 PASS |
| 2026-07-29 @ 7a4ee2a | 55.02 PASS | 59.70 PASS | 59 PASS⁷ | 3.2 FAIL⁷ | 0 PASS | 0 PASS |
| 2026-07-30 @ f63587c | 55.43 PASS | 59.71 PASS | 55 PASS⁸ | 1.6 PASS⁸ | 0 PASS | 0 PASS |

*Condensed footnotes — the full per-row forensics are frozen in
`docs/20260730-handoff-archive-h2-h4.md`:*
¹ The bar's first row; both reds later fixed (fps: HS-26's sender
thread; IDR: the hunt + HS-33). ² fps red retired at the glass; the
freed appetite made the IDR hunt louder — spawned HS-27/28/30.
³ Edge-riding bought a loss red; named cap-aware probe damping.
⁴ Loss red retired; burst-train belief pollution named (HS-30's
brief). ⁵ The HS-30 leak row; the refine caps every belief raise at
the pace behind it. ⁶ Choppy-air row (FEC healed all 101 missing);
churn 1 was the first nonzero since HS-22a — one-session watch if it
recurs. ⁷ The HS-33 no-reset row: ZERO reconfigure-minted IDRs — the
reconfigure-IDR family closes; the owner's verdict at the glass:
"WOW! It looks amazing!" ⁸ **The first all-green row** on
verified-clean air (iperf 0/38849, no contention); the twin control
leg restates the law (`--no-vbv-reconfigure` → 47.3 IDR/min at
fps p50 1). The rotted `receipts` grep named there has since been
fixed and guarded (sweep PR #1).
