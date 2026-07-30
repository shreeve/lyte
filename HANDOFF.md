# Lyte — Session Handoff

*Current as of 2026-07-29 ~10:55 MDT. The session ledger — tracked in the
repo since `8da50bf` (the .gitignore entry is vestigial; the file is
tracked). Update freely; commit updates in the ledger voice.*

# SESSION RESUME — START HERE (2026-07-29 ~10:55 MDT)

**One-paragraph state.** The H4 4:4:4 wave is CODE-COMPLETE up to the
joint gate: V-1…V-5 all landed, the owner's bar recalibration is applied
(`fecd646`/`f783006`), and the 444 harness leg reads **PASS on all seven
rows** (`a53737f`). Since then THREE more waves landed (wave entries at
the bottom of the wave block): **HS-26** (`f00d2a9`) fixed the fps red —
capture-thread pacer drain moved to a sender thread, ingest 48.5 →
60.8 fps live; **the IDR hunt** (`5ea92ba` books + `c2b58f1` dwell
deferral) fixed the IDR red — 7.42 → 0.34 IDR/min on the synthetic dwell
leg with the honesty leg intact; and **P-1 clipboard images** landed
whole (`69cf895` Wire / `c4fae97` Host / `85571e2` root — key 12, CTRL
0x22, new frozen `clipboard-images-v1.json`). J-G4's two required halves
(4:4:4 core + P-1) are both CODE-AND-GATES DONE. The H4 plan is
`3b118ba` (`docs/20260728-194226-lyte-h4-plan.md`). Suites at HEAD:
Wire **475/475**, Host **192/192 Mac AND pup**, root **193/193** (older
counts in wave entries are historical).

**H4 §0 OWNER DECISIONS — ANSWERED (2026-07-29 ~00:52, with both
probes' data on the table):**
1. **Mode selection**: declaration-as-choice mechanics (client declares
   the one chroma it wants; empty intersection → typed failure →
   auto re-dial at 4:2:0 + banner), surfaced NOT as the plan's
   Work/Play binary but as the owner's **three-tier "Chroma" control**
   on the strip: **Good = 4:2:0 / Better = 4:2:2 / Best = 4:4:4**
   (flip = clean reconnect). The 4:2:2 tier is DORMANT — Ada NVENC
   has no 4:2:2 encode (Blackwell 9th-gen only) — grayed as "not
   offered by this host"; wire grows `yuv422 = 3` as a contract-safe
   append. Full record in the ANSWERED block below the playbook.
2. **Color path**: **rgb_mode 601-limited ships** — free,
   glass-correct, quality-equal (48.2 vs 47.8 dB text); gbrp is OUT
   (V-2: CoreMedia has no identity-matrix vocabulary — renders as
   601-full garbage; structural, not fixable on the display-layer
   path); the full-range row is named-and-queued, not gating.
3. **FEC ceiling posture**: Work mode KEEPS the HS-25 capped-CQ
   ceiling posture — ceiling-conformed IDRs legal but structurally
   rare (V-1: 20/30 natural text IDRs exceed it; deltas never close).
4. **J-G4 gate**: 4:4:4 core + P-1 (clipboard v2) only; P-2/P-3 stay
   pre-declared droppable to H5.

**THE BEAUTY BAR'S FIRST ROW IS IN — and its two reds are named
findings, not noise. ⚠️ BOTH REDS ARE NOW FIXED at the decomposed
quantity (HS-26 for fps, the IDR hunt for IDR — wave entries at the
bottom); the bar row itself awaits RE-MEASUREMENT at the glass once
the Keychain grant exists** (full decomposition in the Q-1 drain
addendum):
`2026-07-28 @ 8dc049a | static 51.27 PASS | motion 59.75 PASS |
fps 47 FAIL | IDR 3.9/min FAIL | churn 0 PASS | loss 0 PASS`.
- **fps p50 47 (bar ≥55)**: NOT the wire (0 loss / 5178 frames), NOT
  the compositor (file-mode captures the full 60) — under full session
  load the host's capture→encode path ingests only ~48/s. **The
  session pipeline is now the fps bottleneck**; HS-23's cap lift alone
  did not buy 55+. This is the top open competitive row.
- **IDR 3.9/min (bar ≤2)**: zero client requests, zero loss — all 10
  IDRs host-originated (opening + the estimator's cold-start evidence
  climb spending 4 directive-IDRs + a dip/recover spending 3 + 2 idle
  wakes). Every rate reconfigure forces an IDR, so the RAMP alone busts
  the bar. Estimator-territory follow-on to HS-22c's coalescing.
- Bonus live proof from the twin leg: `--no-vbv-reconfigure` collapsed
  to 1368 kbps with 304 client IDR requests and a frozen glass — the
  VBV directives are load-bearing; nobody gets to "simplify" them away.

**LIVE OPS RIGHT NOW.**
- pup standing host: `bash ~/lyte-loop.sh` respawns `lyte-host --backend
  portal --wire-listen 41151 --ratchet --clipboard=images --seconds 7200`
  on port **41151**. Leave it alive; it's the owner's eyeball host. The
  session log is `/tmp/lyte-host-session.log` on pup. The loop launches
  `~/src/lyte-host/.build/debug/lyte-host` — the P-1 build (192/192).
  REWRITTEN 2026-07-29 ~10:50: `while true` (the finite-60 self-expiry
  bit twice — retired) and the clipboard tier raised to Text + images
  for J-G4a (backup: `~/lyte-loop.sh.bak-20260729`). LIVE — the log
  shows the Rext self-probe passing and chroma **[420, 444]** declared:
  a Best connect here AGREES AT 444 and takes the owner's session over.
- The owner's client is the app bundle at
  `.build/Lyte.app` — launch with `open .build/Lyte.app` (NEVER run the
  raw binary under a parent process; it needs its own bundle for a proper
  macOS window/menu bar). Client & host are PAIRED (paired_clients from
  Jul 22 intact, client static `357a83cc…`) — a healthy reconnect shows
  **no PIN**. If a 6-digit pairing box appears, the client lost its pinned
  identity: restart the host loop with `--pair` so it mints+prints a PIN
  to `/tmp/lyte-host-session.log`, read it off for the owner (3 wrong
  guesses burn it).
- **Black-screen playbook (battle-tested today):** (1) portal wedges
  after many rapid short lyte-host runs → `ssh pup 'systemctl --user
  restart xdg-desktop-portal-gnome xdg-desktop-portal'`; (2) the app
  silently not running → relaunch the bundle; (3) ~~the FEC giant-frame
  crash~~ — FIXED at `e82e88a` and the standing host runs the fixed
  build; (4) NEW (HS-25 live find): **fullscreen `-fs` ffplay starves
  the Mutter screencast** (direct scanout — portal grants the node but
  PipeWire delivers ZERO frames; portal restarts don't help). Run test
  patterns WINDOWED at full size, Wayland-native
  (`XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
  SDL_VIDEODRIVER=wayland ffplay -f lavfi -i
  "testsrc2=size=1920x1080:rate=60"`); Xwayland-over-ssh renders ~5 fps
  and fakes a static leg. ALWAYS kill ffplay when done. (5) NEW (HS-25
  live find): **harness lyte-hosts MUST run `--no-advertise`** — an
  advertised test host is a second "pup" in discovery and the owner's
  app WILL connect to it (it did; their glass went black mid-slice).

**A STANDING WORKER-LIVENESS LOOP IS ARMED** (background shell, sentinel
`AGENT_LOOP_TICK_WORKER_LIVENESS`, every 5 min): it checks subagent
transcript growth, corroborates against work products (pup processes, git
commits) when a transcript looks stalled, and interrupt+resumes any worker
stalled >15 min with no live work. If you start a fresh chat, that loop's
shell does NOT survive — re-arm it if the owner still wants the 5-min
cadence, and don't leave a duplicate running.

**H4 §0 OWNER DECISIONS — ANSWERED (2026-07-29 ~01:05 MDT, with V-1 +
V-2 data on the table).** All four are settled:
1. **Mode selection: declaration-as-choice, surfaced as a TIERED
   control** — the owner's design (from the Streamline discussion):
   a **"Chroma"** control on the control strip (Actions-menu fallback
   per the strip convention) with **Good = 4:2:0 / Better = 4:2:2 /
   Best = 4:4:4**. Naming decided: "Chroma" (matches the wire's
   `chromaModes` vocabulary; "Color" was runner-up). The 4:2:2 tier is
   DORMANT hardware-wise (Ada NVENC has no 4:2:2 encode — that's
   Blackwell 9th-gen NVENC; SDK app-note table confirms N for Ada) and
   renders grayed/"not offered by this host"; capability negotiation
   handles presence naturally. Wire: append `yuv422 = 3` to
   `CapabilityChroma` (non-breaking — unknown values in id lists are
   ignored by contract). Flip = clean reconnect, per the plan's V-5.
2. **Conversion path: rgb_mode (601-limited)** — free, measured
   equal-or-better (48.2 vs 47.8 dB text), gbrp struck by V-2's glass
   verdict. The full-range row stays NAMED-AND-QUEUED (a host
   conversion leaf can be added later if banding ever shows at the
   glass; the deferred 10-bit rung moots the concern when it lands).
3. **The FEC ceiling: keep the HS-25 capped-CQ posture** (conform
   IDRs to 223,380 B, ratchet heals). Plus two banked notes: add the
   **fec group-index to the pre-written wire-v2 batch** (so the
   ceiling dies free if v2 ever ships), and **intra-refresh** (rolling
   keyframe stripes — no giant frames ever) is the named H5
   experiment if ceiling-IDR quality ever bothers the eyeball.
4. **J-G4 = 4:4:4 core + P-1 (clipboard v2) only**; P-2/P-3 stay
   pre-declared droppable to H5.

**IMMEDIATE RESUME POINT (updated 2026-07-29 ~11:15): J-G4a is
UNDERWAY and its first three rungs are DONE** (full entry at the end
of the wave block):
1. ~~The Keychain grant~~ — **EXISTS**; wire-view runs from any shell
   with zero wedge. The blocker is retired.
2. ~~The 444 warmup leg~~ — **PASSED live** (41201: negotiated 4:4:4,
   67,937/67,937 ok, clean teardown; the owner's unprompted verdict:
   "MASSIVELY improved").
3. ~~P-1's live clipboard-image legs~~ — **BOTH DIRECTIONS PASS
   BYTE-EXACT** (wl-copy PNG → Mac pasteboard sha-identical; Mac
   screenshot → pup wl-paste sha-identical; loopEcho suppressed
   live; the Mutter mime question answered — image/png, first try).
4. ~~The beauty-bar re-measurement~~ — **RAN at `932a4c3`** (row +
   footnote ² in the bar table): **fps 47 → 58 PASS (HS-26 confirmed
   at the glass; that red is retired)**; static/motion/churn/loss all
   PASS; **IDR 15.2/min FAIL, LOUDER** — the freed 60 fps appetite
   saturates the path, the estimator saw-tooths (15 falls / 242
   rises), every rc delta still mints an IDR (books: rung 17 +
   tighten 13 + restore 1 + client 7 + opening 1). Two named slices:
   non-IDR reconfigure (intra-refresh) in the encode leaf, and
   near-ceiling hunt damping in the estimator (footnote ² is the
   brief).
5. **REMAINING**: the owner's UI eyeball (Chroma tiers, photo
   toggle, banners: `open .build/Lyte.app`, connect to pup 41151 —
   it agrees at 444), then the IDR slice(s) above — the last red
   between H4 and a clean bar.
Named-but-not-blocking: a genuine squeeze still costs 3 IDRs (every
nvenc rc delta forces one — intra-refresh / non-IDR reconfigure is
the candidate slice); no [420]-only host exists anywhere for a live
fallback leg (wants a pre-V-4 build or probe-forced-off host); the
HS-26 baseline leg's `throttled 1364` at the 50 Mbps recipe (steady-
state saturation headroom — eye on the next fps leg); browser-viewer
B-2+ still waits on the owner's QUIC posture decision (§6 of the
scoping doc). The standing 41151 loop is `while true` now and
declares [420, 444] + clipboard images — the live-ops block above is
current.

# RESTARTING WORKERS IN A NEW CHAT (read before resuming)

**The worker model.** "Workers" are background subagents launched via the
Task tool. They are **session-bound: a subagent from a previous chat CANNOT
be resumed from a new chat** — you relaunch a FRESH worker with a full task
prompt. Their file edits, commits, and pup-side state persist on disk
regardless; only the live agent handle is lost. So resuming = (a) inspect
what the stopped worker left on disk, (b) either keep or revert it, (c)
relaunch a fresh worker to finish.

**State (2026-07-28 ~18:10 MDT).** NO workers in flight. The HS-25
finisher ran to completion this session: live repro at the pre-fix HEAD
(threw `unprotectableDataShardCount(230)` at packet 106, exit 1), proof
at the fix (79.6 s, 1268 frames, 137 MB, zero unprotectable drops),
secrets byte-identical throughout, commit `e82e88a` in Host/. The
working tree is clean apart from any live coordinator edits to this
file. HS-23 `11f058f`, HS-24 `1d65bad`, HS-25 `e82e88a` are all in
Host/ and NOT pushed. The split-groups wire-contract finding lives in
the HS-25 wave entry — don't re-litigate multi-group frames without a
wire-v2 discussion first.

**Mid-slice ops lesson (cost the owner two black-screen scares):** the
HS-25 live legs collided with the owner's session twice — once via an
advertised harness host (now playbook rule 5: `--no-advertise` always)
and once via fullscreen ffplay starving the screencast (now playbook
rule 4: windowed patterns only). When a slice runs live legs on pup
while the owner might connect, expect their glass to show the test
pattern (both hosts capture the same physical screen) and tell them
before the leg, not after they report black.

**To re-arm the 5-minute worker-liveness loop** (optional; only if the
owner wants the auto-watchdog cadence). Start ONE background shell, unique
sentinel, and monitor its stdout:
```
while true; do sleep 300; echo 'AGENT_LOOP_TICK_WORKER_LIVENESS {"prompt":"Confirm all Lyte workers alive: check subagent transcript growth + corroborate against work products (pup processes, git commits); interrupt+resume any worker stalled >15 min with no live work; message the owner only on a fix or completion."}'; done
```
Arm it with a `notify_on_output` watcher on `^AGENT_LOOP_TICK_WORKER_LIVENESS`.
Track the PID so it can be killed on request. **Do not start a second copy**
— check `ps` for an existing `AGENT_LOOP_TICK_WORKER_LIVENESS` loop first.
(NOTE: an unrelated `AGENT_LOOP_TICK_devendor` loop from a different
project's chat may also be running on this machine — leave it alone.)

**Standing infra that is NOT a "worker" and should stay up:** the pup host
loop `bash ~/lyte-loop.sh` (port 41151) and the owner's client app bundle.
Do not kill these when stopping workers.

# CURRENT STATE — post-H2

**Where things stand.** H2 FUNCTIONAL PARITY IS CLOSED (joint gate passed
2026-07-22 ~13:15 MDT, report `docs/20260722-h2-joint-gate.md`) and the H2
EXIT demolition is DONE (commits `2018f6d` → `d5de430` → `9e1cd27`): the
client's GameStream stack (LyteKit/CEnet/CNanors, ~14.3k lines) is deleted,
Sunshine is uninstalled from pup, and both ends speak exactly one protocol —
Lyte-UDP. H1 closed earlier the same day (`docs/20260722-h1-joint-gate.md`).
Suites at HEAD: Wire **402/402**, Host **142/142 Mac AND pup**
(HS-22b, 2026-07-27 late evening, drained the HS-22a live ledger —
first Linux compile+green since HS-21; results in the wave entry),
root **142/142** on
Mac (grown through HS-22a — the quality-hunt wave, entry in the wave
block); `build-cli.sh` + `make-app.sh` release green. A live post-demolition proof
ran at the H2-exit HEAD (60 s: 48,474/48,474 datagrams ok, 0 unseal
failures, render + audio + input + clean teardown).

**CODEC PROMOTION LANDED Mac-side** (`65f56d0` Wire / `d98e154` Host /
`1b63a4f` root) — the H2 mirrors (CTRL 0x15/0x16/0x17, TLV 0x03, CTRL
0x18/0x19, capability key 9, the audio interior) live canonically in
LyteWire now, both end-side copies deleted, new frozen vector file
`control-v1.json`; full entry in the wave block, pup leg deferred.

**HS-18 LANDED on the Mac gates** (`6b5a78e`, Host/) — host audio routing:
hostMuted virtual-sink capture + exact default-sink restore (crash paths
included), capability key 9 on the W7 spine, HOST-PINNED CTRL 0x18/0x19.
Host suite 104 → **110/110 Mac**. Its pup legs are **DEFERRED-PENDING-HOST**
(pup shut down mid-slice; the full leg list — pup build/suite, hostMuted
silence proof, restore on teardown + after kill -9, virtual-sink NIC
cadence, hostAudible regression, secrets shas — is in the wave entry
below; port 41121 reserved). NOTE: the Linux-only C leaf changes are
uncompiled anywhere yet — run the pup build FIRST when it returns.

**CL-13 LANDED on the Mac gates** (root) — the stream-window control
strip + the client half of host-audio routing: key 9 declared client-side
(byte-equal to HS-18's encoding, frozen-bytes proof mirrored), CTRL
0x18/0x19 client codecs cross-pinned against the host's test arrays, the
negotiated flip + session-start posture on `LyteUdpSessionCore`, per-host
"start muted" defaults on the pinned store, the auto-hiding strip in the
app, `wire-view --host-audio audible|muted`. Root suite 104 → **113/113
Mac**; build-cli.sh + make-app.sh release green. Its live legs are
**DEFERRED-PENDING-HOST** (full list in the wave entry below — they run
TOGETHER with HS-18's a–g on pup's return; port 41121 stays reserved for
the pair).

**THE WIRE IS CLEAN NOW (2026-07-28 ~15:40 MDT) — supersedes every
earlier Wi-Fi caveat.** The owner moved the client Mac off the weak 6 GHz
band (was -65 dBm, MCS 2) onto 5 GHz ch 44 (-60 dBm, MCS 7) and disabled
the Mac-side scan triggers; the gateway's 6 GHz network is disabled.
Measured after the change: Mac↔pup full path p50 7.6 ms / p99 18 ms /
max 23 ms with ZERO >50 ms samples in 30 s; bulk ~160 Mbps pup→Mac and
~175 Mbps Mac→pup (through ssh crypto). The scan-stall trains (70–100 ms
dark every ~500 ms), the 13–17 Mbps real-time pin, and HS-23's observed
1–2 s full-dark outages are all artifacts of the OLD wire — re-baseline
before attributing tail latency to the radio. pup's link was already
clean (5 GHz, -57 dBm, ~1 Gbps bitrates, power save off).

**pup status: BACK ONLINE (2026-07-27 ~21:20, HS-22b ran against it).**
pup rebooted ~11:35 this morning — the reboot healed the NVENC driver
mismatch exactly as the catch-up doc predicted (userspace AND kernel
both 595.84; the /tmp/nv571 shim died with /tmp and is correctly
GONE — no LD_LIBRARY_PATH on any lyte-host run tonight; the
`~/.local/lib/swift-compat` libxml2 BUILD shim is untouched by
reboots and still wraps `swift build`/`swift test`). The earlier
~00:57 catch-up window did happen: leg (s), live end-to-end
clipboard, is CLOSED — HS-19 (`73e5cdb`); verdict + evidence in the
CL-15 wave entry. **HS-22b (this session) drained the HS-22a live
ledger on port 41163** — per-leg verdicts at the end of the HS-22a
wave entry; the owner's eyeball (leg e) is the one leg still open,
and the host is up on 41151 at tonight's build waiting for it.

**RESTART / RESUME PROTOCOL (updated 2026-07-27 late evening):** The
**Mac-local half of HS-22 landed as HS-22a** (`17810b8` Host /
`36f1dce` root) and **the LIVE half is DONE — HS-22b ran the whole
deferred ledger on pup tonight** (port 41163; per-leg verdicts +
numbers at the end of the HS-22a wave entry). Headlines: pup suite
**142/142**, the 1 Hz pulse is RETIRED live (183 → 3 IDRs over
5 min-scale runs, 36.6 → 0.5 IDR/min), the B2 squeeze signature
stays retired with the k-ladder visible in the books, and clean-path
silence holds exactly as specified — zero directives while the
ceiling-rate holds ≥ 90% of the recipe. What remains:
1. **The owner's eyeball (leg e)** — the host is UP on 41151 at
   tonight's build (relaunch loop fresh, 60 iterations, NO nv571
   shim — the reboot healed the driver mismatch, both 595.84).
   Connect and judge a clean-path session vs the trip-era
   "moderate" verdict; the 1 Hz blur should be gone at the glass.
2. **Two named policy findings for the next rung (HS-22c
   candidate?)**, evidence in the wave entry: (i) the recovery
   climb out of a squeeze emits a directive — now a KNOWN forced
   IDR — per ~10% rung every rise-hold, so a single dip-and-recover
   cycle costs ~8–10 IDRs (26 directives in a 150 s clean-path run
   whose only sin was three Wi-Fi weather dips; 105 in the
   saturated mild-band run); consider coalescing within-squeeze
   loosenings (longer rise hold, or restore-only). (ii) One run's
   dip fed on itself to the 500 kbps floor: ≥8-packet trains under
   a squeezed pacer measure OUR OWN pacing, each directive-IDR
   bumps the queue right when the estimator is touchy, and overuse
   re-anchors to 0.85× of self — the min-train gate stopped garbage
   anchors (the squeeze leg proves it: falls stop at 0.85× the true
   shaper rate now) but not self-reference. Estimator territory.
3. **HANDOFF.md commits are the coordinator's job**; workers edit only
   their own wave entries and leave the file uncommitted.

**RESTART ADDENDUM — RESOLVED (2026-07-28 morning): both queued
launches ran overnight and COMPLETED.** (Earlier corrections in this
block's history: HS-22b had run all along — the "never started" audit
read the wrong transcripts folder.) Results:
1. **W10 (F-2 bulk channel) — LANDED** as `7455911`; full wave entry
   at the end of the wave block (chan 8, priority `.bulk` = 7,
   sextet 0x1C–0x21, capability key 11, sans-IO engines both roles,
   frozen `bulk-v1.json` with 68 vectors, Wire 402 → 450/450).
   **F-3 (host end) and F-4 (client end) are UNBLOCKED** — both code
   against the frozen vectors, launchable in parallel (Host/ vs root
   territories); the wave entry's "WHAT F-3/F-4 DRIVE" paragraph is
   their contract.
2. **Browser-viewer scoping — LANDED** as `b0b9c75`
   (`docs/20260728-054139-lyte-browser-viewer-scoping.md`). Headline:
   LyteWire cross-compiles to wasm32 with ZERO source changes
   (CNanorsWire and BoringSSL included), 400/400 tests pass under
   wasmtime, all 13 vector files byte-exact — wasm is a de-facto
   third attested platform. Recommends WebTransport/H3 (in-process
   lsquic leaf behind `--browser`), codec offer [hevc, av1] (no
   H.264), ladder B-1…B-6 with the H3 cut line after B-4 (video).
   **Four NEW owner decisions pend** (§6 of the doc): (A) QUIC
   posture in-process-leaf vs sidecar, (B) browser codec profile,
   (C) certificate/page UX, (D) confirm the B-4 cut line. B-slices
   wait on these; F-3/F-4 do not.

**RESTART ADDENDUM 2 (2026-07-28 afternoon): the F-3×F-4×F-5 JOINT
GATE is DRAINED — full verdict table in the JOINT-GATE wave entry.**
Nine of ten legs PASS live; leg (i)'s real Wi-Fi hop is OWNER-PENDING
(steps in the entry), and a five-minute owner eyeball remains for the
UI verbs the headless harness can't touch (real mouse drag with the
toggle ON, drag-during-captured-input, Disconnect mid-hunt, banners
at the glass). One REAL host bug found by leg (h) and FIXED:
`fea9149` (Host/) — a relaunched host latched its socket onto the
dead session's feedback spray and could never hear the client's
re-dial; suites 161/161 both platforms after. pup rebooted
~14:03 mid-session (owner-initiated) — the standing session ended
with a clean typed teardown (good SIGTERM behavior, noted in the
entry); secrets byte-identical through everything. Next per the H3
ladder: browser-viewer slices (owner decisions answered) + the
wire-v2 design doc; HS-23 should read the entry's wire note
(~150 Mbps bulk Wi-Fi 6E path, micro-stalls; bulk transfer
Wi-Fi-shaped at ~1 Mbps effective under the 4 Mbps host cap).

**H3 §0 OWNER DECISIONS — ANSWERED (2026-07-27 ~21:22).** The seven
decisions in `docs/20260723-051223-lyte-h3-plan.md` §0 are settled:
1. **File-transfer consent**: standing per-host toggle, **client→host
   only in v1** (per recommendation).
2. **Clipboard v2 (images/rich)**: **deferred to H4** (not even an H3
   stretch — drop it from the H3 ladder).
3. **Browser client (WASM viewer)**: **PULLED INTO H3** (against the
   doc's recommendation — the owner wants it this wave; scoping doc
   commissioned, then slices).
4. **Non-LAN reach**: LAN-first stands; F-5 roaming attacks the pain
   (per recommendation).
5. **Wire-version 2 batch**: design-discussion doc only in H3, no
   bytes change (per recommendation).
6/7. **Printing → H5, multi-monitor + dynamic resolution → H4**:
   confirmed.
The H3 ladder is therefore: F-2 bulk channel (IN FLIGHT as of ~21:25)
→ F-3/F-4 file drop (client→host v1) → F-5 roaming → browser-viewer
slices (post-scoping) + the wire-v2 design doc; J-G3 exit criteria
adjust to drop clipboard-v2 and add the browser viewer's minimal bar
(scoping doc to propose it).

**UX INVESTIGATION CONCLUDED (2026-07-27 ~01:37) — fix items 1–4 LANDED
(CL-16 `73ccd46`, ~01:47; details at the end of this block).**
The owner's trip-era complaints ("can't control the host, duplicated
audio, choppy") diagnosed via code audit + an AppKit hit-test probe:
- **CONFIRMED REGRESSION (CL-13, `d11dba3`)**: `landsOnOverlay`'s
  ancestor-stays-captured walk (`Sources/Lyte/LyteInputCapture.swift`
  ~115–120) misclassifies strip points — `NSHostingView.hitTest` returns
  the hosting view (an ancestor of `VideoLayerView`) for SwiftUI content,
  so **all control-strip buttons are dead and strip clicks leak to the
  host cursor**. Video-surface capture itself is INTACT (probe-proven).
  Workaround until fixed: drive everything from the Actions MENU
  (⌘⇧M/⌘⇧H/⌘⌥I/⌘D) — the menu bypasses capture and works.
- **"Can't control" root cause**: host-side/operational (no lyte-host
  running at the 01:30 attempt; a dead host leaves a frozen frame ~30 s
  = "no control"). The client input path has no regression; client
  bundle is HEAD-equivalent (mtime = CL-15c minute).
- **"Duplicated audio" fully explained**: pup still runs the pre-HS-18
  demolition binary — never declares key 9, so host-mute can't exist
  anywhere. Remedy arrives with the catch-up deploy + menu ⌘⇧H (or the
  per-host "start muted" default).
- **"Choppy" inventory**: ~~encoder-VBV debt~~ and ~~repair-lane DSCP
  debt~~ — **both retired by HS-20 (`084e826`)**, wave entry below;
  remaining: hotel-Wi-Fi clumping (video has no jitter buffer by
  design), WAKE-ratchet pulsing, and minor CL-13 per-mouse-event
  reveal churn.
- Latent (pre-CL-13): one-shot capture install in `StreamView` with no
  retry/telemetry; stats hides the input line while eventsSent==0 —
  exactly the datum that discriminates capture-vs-host failure.
Fix list (ordered, sized) is in the investigator's report; items 1–4
were the dispatched fix worker's scope — **DONE, one root commit CL-16
`73ccd46`**: (1) `landsOnOverlay` rewritten as `landsOnVideoSurface` —
CAPTURED iff the hit view is VideoLayerView or a descendant, anything
else (the hosting-view ancestor included) returns to AppKit; the
investigator's probe re-run with the corrected rule embedded asserts
all four classifications (video/upper-right captured, strip
pass-through, allowsHitTesting(false) stats stays captured-transparent)
— PASS. (2) The stats input line is unconditional and carries the
capture verdict ("input 0 sent · capture INACTIVE"), formatter
extracted to `InputSenderStats.overlayLine` and contract-pinned in
virtual time. (3) StreamView's capture install polls 50 ms up to ~4 s,
NSLogs the verdict either way (attempt count on success, loud
gave-up), and the overlay renders capture active/INACTIVE live off
`model.lyteInputCapture`. (4) The strip's reveal is one standing fade
task fed by a reference-typed last-activity timestamp (plain class in
@State — pointer-rate events invalidate nothing); behavior kept:
reveal on activity, fade ~2 s after the last, never while hovered.
Root suite 122 → **124/124 Mac**; build-cli.sh + make-app.sh release
green. STILL OPEN: the CL-13 human leg (l) — hand-test the strip
(reveal/fade feel, buttons CLICK now, no leakage to the host cursor,
stats legibility) at or past `73ccd46`. ~~VBV + DSCP stay H3 debt
rungs~~ — paid as HS-20 (`084e826`).

**CL-18 LANDED (`ae91be0`, root) — ⚠️ USER-VISIBLE DEFAULT FLIPPED:
new sessions against a key-9 host now START WITH THE HOST MUTED**
(the Sunshine/Moonlight posture — sound follows the viewer; the
owner's direct ask after this morning's hand-test). A fresh config
desires hostMuted, so one [0x18 0x02] leaves after the host's first
0x19; the per-host "Start with Host Muted" preference is now the
"start audible" OPT-OUT (nil/true → muted, explicit false → audible —
migration by construction: CL-13's setters never wrote false, so
stored prefs keep their meaning and only the unset default flips).
Unnegotiated hosts unchanged (no 0x19, no ask — the host plays);
wire-view stays neutral unless `--host-audio` says otherwise, so
scripted runs keep their wire shape. The same slice reworked the
strip's ergonomics off the hand-test feedback: dwell-to-reveal
(~200 ms in a 90 pt edge zone — a Dock-bound flick reveals nothing),
the fullscreen system-edge sliver stays macOS's, window-exit and
edge-push hide instantly, a persisted bottom/top edge preference, a
"Hide Control Strip" mode with the Actions menu as the full fallback,
and unmistakably distinct mute buttons (HOST hifispeaker cabinet vs
MAC headphones, captions + machine-naming tooltips/menu titles).
Root suite 131 → **141/141**; both release builds green. The owner
hand-test checklist is in the wave entry — it SUPERSEDES the CL-13
leg-l list.

**Landed since the trip started (all Mac-local, wave entries below):**
CL-13's follow-through books (`ab4f905`), the codec promotion
(`65f56d0`/`d98e154`/`1b63a4f`), CL-15 clipboard sync across all three
packages (`ce50a20`/`c16ff91`/`2f5f2f1` — new frozen `clipboard-v1.json`,
key 10, CTRL 0x1A/0x1B), and the **H3 wave plan**
(`docs/20260723-051223-lyte-h3-plan.md`, `557bba0`) — its §0 holds
SEVEN OWNER DECISIONS (file-transfer consent UX, clipboard v2 scope,
WASM timing, non-LAN reach, wire-version batch, printing at H5,
multi-monitor at H4) that gate the H3 feature ladder.

**Queued next (in order):**

1. ~~Tonight's catch-up worker~~ — **IN FLIGHT** (see above).
2. **UX-complaint fixes** — whatever the investigator's report names
   (input regression suspicion first), sized and dispatched before
   feature work.
3. ~~Linux portal clipboard leaf~~ — **DONE as HS-19 (`73e5cdb`)**;
   leg (s) PASSED live (evidence in the CL-15 wave entry). Live
   copy/paste is real: `lyte-host --clipboard` + the app/wire-view
   client half.
4. **H3 ladder** per `docs/20260723-051223-lyte-h3-plan.md` — debt
   rungs first (~~VBV, repair-lane DSCP~~ — **DONE as HS-20
   (`084e826`)**; ~~cookie dial~~ — **DONE as HS-21 (`ede7d49`)**;
   ~~M7 audio~~ — **DONE as CL-17 (`3a58fb6`)**), then F-1 clipboard
   completion → F-2 bulk channel → F-3/F-4 file drop → F-5 roaming;
   gated on the §0 owner decisions.

**Standing deferred seams** (named at their slices, none blocking):
reconnect/takeover UX (needs a host session-busy story), app
human-at-glass legs (Keychain zero-UI dial +
stream-window visual from a real GUI session). New from HS-20 (details
in its wave entry): estimator overuse-fall anchor wants windowed-max
robustness against garbage delivery samples (HS-16 territory), and the
deep-floor rung below ~1.5 Mbps needs resolution/fps shedding — the
QP-51 damage-frame minimum (~10.3 kB at 2048×1280) can't fit the
500 kbps floor's frame ceiling, VBV or no VBV. (Encoder VBV and
repair-lane DSCP themselves: retired, HS-20 `084e826`.)

## The two joint-gate verdicts

- **H1 — PASSED; H1 CLOSED** (2026-07-22 ~09:00 MDT,
  `docs/20260722-h1-joint-gate.md`, commits `b87234c`/`ce051e1`): one
  coherent live run — discovery, zero-UI paired Noise IK, fresh PIN-PAKE
  pairing, capabilities both ways, idle cycles, input wake, teardown with
  reason both directions, 5% loss + 5 s blackout adversity. Every
  decision-record H1 criterion passed.
- **H2 — PASSED; FUNCTIONAL PARITY CLOSED** (2026-07-22 ~13:15 MDT,
  `docs/20260722-h2-joint-gate.md`, commits `21b0f71`/`67b3649`):
  everything-at-once steady state; input 1,833 events 100% exactly-once
  (host rx→inject p50 ~1.2 ms); 5 ms audio at the NIC (p50 4.999 / p99
  5.978 ms); estimator falls anchored to measured delivery; targeted
  repair with 1:1 wire correlation; blackout FROZEN→RECOVERY on real
  estimator verdicts; ~550k sealed datagrams of session hygiene. The
  demolition followed the same afternoon (full entry in the CURRENT WAVE
  block below).

## Historical ledger — H0→H1, slice → commit → one line

Detail lives in git history (`git show <commit>`) and the gate reports;
these lines are pointers, not the record.

**H0a/H0b (2026-07-20/21).** Host bring-up: portal capture → NVENC HEVC
(`4619121`), idle-floor steady supply (`f529c57`), quality-ratchet
prototype (`493b6bd`), CNetIO DSCP/TX-stamps (`84dd823`), HostCore pacer,
HS-14 audio capture + Opus, HS-5/HS-12/HS-7 video channel + migration +
session stub; Wire envelope/FEC/video/beacon/Noise codecs with frozen
vectors; client receive/render + real Noise IK (CL-1..3, `c8635f6`,
`0443beb` — the one-verbatim-msg1 retry lesson). **J-G1 first-pixels gate
PASSED encrypted** (5.5-min soak, ~154k datagrams, 0 unseal failures, 5%
netem healed by the coalescing IDR loop, DSCP on the wire, human visual
2026-07-21 22:26 MDT — "absolutely beautiful"). CP-5 verdict: portal
RemoteDesktop is hostile headless; **Mutter internal RemoteDesktop is the
input primary**, uinput the fallback.

**H1 wave (2026-07-21/22), gated by the H1 joint gate above:**

- **W3** ARQ `002cc72` (Wire) — exactly-once in-order reliable sublayer;
  165k exhaustive interleavings + 1M seeded storms both platforms;
  arq-v1.json frozen.
- **HS-10** discovery `1b499e7` (Host) — Avahi over D-Bus, `_lyte._udp` +
  v/pkh TXT; live dns-sd gate.
- **CL-10** clock `d16dbc1` (root) — HostClockModel, min-RTT-gated offset +
  skew; live residual rms ~300–380 µs.
- **CL-5** discovery `233e403` (root) — NWBrowser browse + pinned-key
  recognition, live against the host's advertisement.
- **HS-8** `830b44e` (Host) — CTRL rides the ARQ sublayer (0x07/0x08);
  exempt classes pinned (beacons, path, handshake, IDR).
- **CL-7** `a5a4794` (root) — the client ARQ leg; joint <1 ms
  beacon-residual gate PASSED live.
- **W4b** `fd69ee4` (Wire) — SessionStateMachine (ACTIVE/IDLE wire modes,
  FROZEN/RECOVERY local overlay); lifecycle-v1.json frozen.
- **W6** `f6f9358` (Wire) — CPace PIN-PAKE vs the draft's own vectors;
  pure-Swift Field25519/Elligator2; pairing-v1.json frozen.
- **W7** `421feef` (Wire) — capabilities on deterministic CBOR;
  intersection IS the agreement; capabilities-v1.json frozen.
- **HS-9** `4b9e82e`+`7f02972` (Host) — pairing responder; 3 guesses burn
  the PIN; keystore + `--require-paired`; five live legs incl. a 500-msg1
  flood.
- **CL-6** `6166b12` (root) — client pairing end to end; Keychain-backed
  identity + pinned_hosts.json; live pair/wrong-PIN/1-RTT-reconnect legs.
- **W8** `bca9b8d` (Wire) — stateless HMAC retry cookie (0x13/0x14);
  retry-v1.json frozen.
- **HS-11** `ceb5176`+`37fc10a` (Host) — session lifecycle: ack-gated idle
  flips via the host-pinned 0x15 IdleFrame, W7 exchange as first reliable
  word, clean ECONNREFUSED close; 10 live idle cycles.
- **CL-8** `0965ea2` (root) — LyteUdpSession behind wire-view AND the app;
  13 live idle cycles; the WAKE-ratchet observation (a "static" GNOME
  desktop holds ~1.9 Mbps because each 1 Hz clock wake re-runs the full
  ratchet — damage-vs-wake policy revisit still owed data).
- **W9** `9775258` (Wire) — pre-H1 Crypto/ review: constant-time fixes +
  two impossibility proofs, zero wire bytes moved; all vector shas held.

**H2 wave, pre-gate slices (2026-07-22, summarized — full text in git;
the later H2 slices keep their full entries in the CURRENT WAVE block):**

- **HS-13** input injection `18afe77` (Host) — Mutter RemoteDesktop
  primary + CInputUinput fallback leaf; host-pinned 0x16/0x17 + TLV 0x03;
  live rx→inject p99 1.4 ms; pixel-proof cursor moves; `--input
  auto|mutter|uinput|off`.
- **CL-9** input sender `1a8dff7` (root) — capture → seq/stamp → ARQ
  ordered stream + latency books; live input→inject p50 6.1 ms,
  input→photon p50/p99 28.9/35.7 ms; `--input-script` gating surface.
- **HS-15** audio on the wire `a0d92cf` (Host) — 5 ms Opus on chan 1 under
  RS 4+2 + DSCP 48, one shared pacer schedule; NIC cadence p99 5.446 ms
  through IDR bursts; the force-quantum=240 capture fix; audio flows in
  every state but `closed`.

## Operational facts (still true — keep)

- **pup build recipe** (Wire must be a sibling of the host checkout):

  ```
  rsync -a --delete --exclude .build Wire/ pup:src/Wire/
  rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
  ssh pup 'cd ~/src/lyte-host && LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build'
  ```

  The `LD_LIBRARY_PATH` shim is pup-local (libxml2.so.2 → the system
  .so.16). For live gates while working trees are dirty, build from `git
  archive` of committed HEAD on pup (the h1gate/h2gate/demolition
  pattern) — never rsync a tree another worker is editing.
- **Portal capture**: lyte-host must run inside the logged-in, unlocked
  graphical session; the persisted restore token makes runs headless
  (first run = one-time consent on the physical screen). Host static
  pubkey today: `10e0f084…6201` (full hex printed in the run banner).
- **Secrets are sacred**: never touch pup's
  `~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`;
  sha-verify before/after any run that goes near them (current shas:
  portal_token `dadf9a66…37cf`, noise_static.key `72860390…cfed`,
  paired_clients `8dc1f88a…55fd`).
- **Keychain/signing**: client binaries that contact a host must be built
  via `Scripts/build-cli.sh` / `Scripts/make-app.sh` (the stable "Lyte
  Dev" signature keeps Keychain authorization — `docs/MACOS-SIGNING.md`).
  The Keychain zero-UI dial is unusable from a headless/dark-wake shell
  (OSStatus −25320): scripted runs use the `--host-key` debug posture;
  the Keychain path itself is live-gated (CL-6 + the H1 gate).
- **netem discipline**: scope impairment to the specific Lyte port
  (prio+u32 — `Scripts/netem/lo-netem.sh`,
  `Scripts/netem/h2gate-netem.sh`); remove after; verify `noqueue`.
- **Live-run cautions**: `wire-view --audio` orphaned into the background
  died silently 3× (CL-11) — run live legs in the FOREGROUND. Scripted
  input probes click/type into whatever is focused on pup's real desktop —
  moves-only + background coordinates is the clean-evidence recipe
  (HS-13). Ports: 41000-range by convention; pick a fresh one per run.
- **macOS client lessons that outlive the old stack**: an AppKit CLI must
  run `NSApplication.run()` on the raw C main thread (black window
  otherwise); the stream view must accept first responder or unhandled
  keys NSBeep; X25519 Keychain items can only be minted via `SecItemAdd`
  behind the stable signature (`SecKeyCreateRandomKey` can't do X25519).
- **Subagent watchdog**: worker stalls persist — a ~7-min watchdog +
  interrupt-kick works (W4b needed two kicks). Check a silent worker's
  transcript mtime before assuming death; long live runs legitimately
  look idle.
- pup has dropped off-network spontaneously before (usually recovers in
  minutes; twice needed a physical power/Wi-Fi check). Post-travel, see
  the hotel-network note in CURRENT STATE first.

---

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

² Post-HS-26/IDR-hunt re-measurement (row printed by quality-probe.sh
at `932a4c3`; logs pup `~/qprobe/`, local `/tmp/qprobe-local`).
**fps 47 → 58 PASS — HS-26's fix is confirmed AT THE GLASS**; the
fps red is RETIRED. **The IDR red got LOUDER (3.9 → 15.2/min) and
the cause-tagged books name it exactly**: 38 IDRs = vbv-rung 17 +
vbv-tighten 13 + vbv-restore 1 + client-request 7 + opening 1, over
15 overuse falls / 242 evidence rises in 150 s. The freed 60 fps
appetite (~43 Mbps at the recipe) saturates the delivered ~20 Mbps
path, so the estimator hunts a saw-tooth the whole leg — and every
nvenc rc delta still forces an IDR, so the hunt's frequency
multiplies the known per-reconfigure cost. NOT the dwell bug
returning (churn 0, loss 0 — the deferral held where it applies) and
NOT deletable machinery (twin `--no-vbv-reconfigure` leg: glass
FROZEN, fps p50 0, 30.2 IDR/min of client begging — directives stay
load-bearing). Two named slices fall out: (a) a non-IDR rate
reconfigure path in the encode leaf (intra-refresh — kills the
multiplier); (b) near-ceiling hunt damping in the estimator (kills
the frequency). Also eye-on: delivered ~20 Mbps on the post-move
clean wire that bulk-tested ~160 Mbps — whether that's real airtime
under 43 Mbps appetite or the HS-22b self-reference seam is part of
slice (b)'s brief.

⁷ THE HS-33 ROW (probe at `7a4ee2a`, the vendored no-reset encoder
live): five green, static at an all-time 55.02, churn healed — and
the IDR cell's composition is TRANSFORMED even where it stays red:
**zero reconfigure-minted IDRs** (13 directives, all applied
no-reset; the same night's A/B: control 24 = 9.59/min with 14
reconfigure-minted vs no-reset **1 = 0.40/min, opening only** — the
bar's ≤2 is GREEN on clean air). The official row's 3.2 = opening +
client requests across three real evening-air loss episodes —
repair-lane/weather territory now, not encoder territory. Named at
the row: wholly-lost frames mint no client IDR demand (pre-existing
gap, newly unmasked); the evening-air microstall forensics (honest
medians ~5 M on iperf-clean 45 M air); the probe's rotted `receipts`
grep. The reconfigure-IDR family of findings — HS-22b's dip cost,
HS-22c's coalescing, the IDR hunt, HS-27's rungs, HS-30's cadence —
CLOSES here: every rate move since HS-16 cost a keyframe, and none
do now.

⁶ The refined build's official row (probe at `ce952ec`) — and the
run drew CHOPPY AIR again (101 missing datagrams vs the clean
manual leg's 0), which is the whole story of its IDR cell: the toll
is weather-proportional (books: rung 8 + tighten 6 + client 4 +
restore 1 + stale-nack 1 + opening — ~5 dip episodes × the 2-IDR
rung crossing). Same build in clean air measured 4.26 (footnote ⁵).
The IDR row's remaining fix is the rung-crossing toll, not the
estimator — unchanged from ⁵'s naming. NEW FINDING, unexplored:
**churn 1** (one directive with no estimator move since the last) —
first nonzero churn since HS-22a; plausibly the vbv-restore
interacting with the cadence hold; needs one session of books
before it's called a bug. Loss stayed green THROUGH the chop —
FEC healed all 101.

⁵ HS-30 row AT THE LEAKED BUILD (probe at `db84c1b`) — recorded
un-massaged per the bar's law, and its red taught the fix. Static
improved (53.85), loss held green through visibly worse air (56
missing datagrams, FEC healed every frame), fps 61 — but IDR ROSE to
8.4 because mechanism 1's drains-only cap LEAKED: samples at
1.0–1.25× pace slip the drain classification and raised the belief
to 61 Mbps over the 50 cap, so the probe ceiling never bound while
the cadence (545 held rises) worked alone. The refine (`3f6fcf1`):
**every** belief raise caps at the pace behind it — no arrival
outruns its sending. At the refined build (155 s armed leg, not yet
an official row): belief an honest 50000, **IDR 4.26/min** (rung 4 +
tighten 4 + client 2 + opening 1), 6 falls, 307 cadence-held rises.
Honesty leg at the refine: fall **519 ms** after a 25 Mbit tbf
onset, anchored 27.2 Mbps ≈ the shaper, full recovery to ceiling.
THE REMAINDER, NAMED: each genuine weather dip deep enough to cross
an HS-27 rung costs 2 IDRs (tighten down + rung back up) — ~4
episodes in the leg. The endgame candidates: wider rung 0 /
dip-scoped rung hysteresis (Host/, cheap), or the true kill — a
non-IDR encoder reconfigure path (the FFmpeg wall, HS-27's named
remainder). Official probe row for `3f6fcf1` queued.

⁴ Post-HS-29 row (probe at `be60e92`; logs pup `~/qprobe/`). **The
loss red is RETIRED — 1 datagram missing in 117,192, 0 frames lost**
(row ³'s 102/6 was the climb slamming the cap; the damped probe
ceiling stopped buying loss at the top) and fps holds 61. The IDR
residue (6.4/min, books: rung 8 + tighten 6 + client 1 + opening 1)
now has a NAMED cause in the armed leg's own estimator line: **burst
trains pollute the belief** — compressed drains raised it to
207 Mbps (contaminated legs: 266 Mbps, 1.18 Gbps), so the probe
ceiling `min(50M, belief×1.1)` almost never bound (2 damped rises
all leg) and the climb still slammed the ~45 Mbps air 12 times.
HS-30's brief: (i) split sustainable-vs-burst belief — drains purge
mid-hole votes (HS-28's insight, keep) but must not set the probe
ceiling; (ii) near-ceiling probe CADENCE (BBR PROBE_BW's shape) in
place of continuous climb pressure. Honesty leg at this build:
fall 517 ms after a 25 Mbit tbf onset, honest anchor, full recovery
to the 50 Mbps ceiling after release, 0 self-ref holds, qdisc
removed. Bonus: the owner live-stress-tested one leg (YouTube window
dragged across the screen mid-squeeze) — same burst-pollution
signature in those forensics, independently corroborated.

³ Post-HS-27/HS-28 row (probe at `8e1e8ca`; logs pup `~/qprobe/`).
The composition flip is the story: the leg now RIDES THE AIR'S TRUE
EDGE — 210,941 datagrams (2.4× row ²'s 85,958) at fps 61 — because
the honest belief chases the ~45 Mbps the air offers instead of
spiraling. IDR halves again (15.2 → 6.8/min; twin overhead −14, bar
≤3 held) and churn stays 0, but edge-riding buys a NEW red: 102
missing datagrams (0.048%) cost 6 unrepaired frames (bar ≤1/150 s),
and those losses also feed the remaining IDR count (client requests
+ genuine probe cycles into the 50 Mbps recipe cap that exceeds the
air). Both reds now share one cause — probing into the wall — and
one named fix: **cap-aware probe damping** (probe ceiling ≈
min(cap, belief×1.1), HS-28's named next rung), which stops the
estimator from repeatedly testing a ceiling the belief already
locates. Row ²'s clean loss cell was the self-limited estimator
barely using the link — a PASS bought dishonestly.

¹ The two reds are FINDINGS, dated at HEAD and reported loudly in the
Q-1 wave entry (ledger-drain addendum): **fps** — the glass ran a
steady 46–49 through the leg's healthy window and never touched 55;
file mode captures the full 60 (367 damage per 6.1 s motion run), so
the ceiling is the host's capture→encode path UNDER FULL SESSION LOAD,
not the wire (0 loss, decode kept pace) and not the compositor.
**IDR** — 0 client IDR requests, 0 loss; all 10 IDRs are
host-originated (1 opening + 7 VBV-directive IDRs + 2 post-idle
wakes) — every rate reconfigure forces an IDR, so the estimator's
cold-start climb alone busts ≤2/min. HS-22c's armed-overhead bar is a
different measurement and passed huge (armed 10 vs twin 64).

---

# CURRENT WAVE — H2 close-out + demolition (2026-07-22, full entries)

*The current wave's full record — do not compress yet. (HS-13/CL-9/HS-15
landed pre-H1-gate and are summarized in the ledger above.) HS-18 appends
its entry at the marker at the end of this block.*

- **HS-16 congestion estimator** (`44b39ab`, Host/): the wire listens
  back — the last host H2 slice. RateEstimator (HostWire, sans-IO,
  injected clock): a send ledger tapped at the pacer's sink (channel,
  seq → send-ns, wire bytes; 8192-deep ring) matches the chan-3
  reports' dispersion samples into TRAINS split by send spacing (gap
  scales with the standing rate — a fixed gap starved the climb at
  the floor, caught live) → delivery-rate samples (10 s windowed MAX,
  <8-packet trains weighted ×0.5); queuing delay = per-CHANNEL
  min-baseline inflation (per-channel deliberately: a DSCP fast lane
  for audio must not mask a growing video queue; GCC's trendline
  swapped for min-baseline inflation — same sensor family, fewer
  moving parts, flagged for revisit); loss = ledger deltas over a
  rolling 1 s window, PRE-FEC (the wire's post-FEC evidence is the
  NACK section, empty until HS-17). Control law: overuse (2
  consecutive inflated reports > 15 ms) → 0.85 × MEASURED delivery,
  ≤1 fall/500 ms; loss in GCC's three bands — <2% clean, **2–10%
  HELD (FEC's band; resiliency G1 says a 5% path keeps streaming —
  crashing on it would be dishonest)**, >10% falls ×(1−loss/2); rises
  ONLY on fresh delivery evidence ≤10%/s toward the ceiling (= the
  session config rate; W7 carries no bitrate key in v1), 1 s
  hold-down after falls, floor 500 kbps. Note at the seam: the
  standing rate deliberately rides ABOVE btlRate×0.8 on clean paths —
  paced sends self-limit the measurement to ≈R, so a standing 0.8 cap
  would spiral; 0.85×delivery applies at the overuse fall, where the
  pillar needs it. Seams closed: W4b's 25 ms RECOVERY window STUB
  retired — the estimator judges windows (loss inside a window HOLDS
  RECOVERY where presence used to graduate; lifecycle test now sends
  real empty FeedbackReports); IdrPacing has NUMBERS (WAKE =
  min(btlRate, lastGoodRate), RECOVERY = max(floor, ½ stale), applied
  to the shared pacer inside `execute` the moment the machine
  demands); frameByteCeiling(fps) = R×B/8 − reserves at the LIVE rate
  (59,937 B @ 20 Mbps/60 fps — the HS-6 figure), exposed on Session +
  the final stats line. New: SessionEvent.rateChanged(reason:
  overuse/loss/evidence/idrPacing), counters feedbackReportsParsed/
  Malformed/rateChanges, drop reason .malformedFeedback (hostile
  chan-3 still feeds the blackout detector, never the estimator).
  Gate: Host 81 → **93/93 Mac AND pup** (RateEstimatorGateTests: 10
  legs — measured-not-hoped delivery, short-train downweight,
  unmatched-sample refusal, 5%-held/20%-falls loss bands, floor/
  ceiling pins, floor-climb evidence, overuse anchored to delivery,
  IdrPacing numbers, recovery-verdicts-through-Session, R-G8 cadence
  re-run WITH a mid-stream crash: p99 deviation 0.024 ms). LIVE on
  pup :41041 (loopback, portal, probe ~/src/hs16-probe sending REAL
  FeedbackReports — ledgers + dispersion — every 30 ms, IDR chirp
  every 2 s): (A) 800 ms probe blackout → FROZEN → RECOVERY with
  `rate: → (IDR pacing halfStaleEstimate)` on the pacer → blackout
  gap read as loss (honest: those datagrams died) → falls → climbed
  back to the 20 Mbps ceiling, graduated ACTIVE on estimator
  verdicts; (B) video-scoped netem 6 Mbit squeeze (tos 0xa0 + dport
  filter) 30 s → 4 overuse falls anchored at measured delivery
  (~4.9–5.2 Mbps × 0.85 shapes), evidence climbs between, full
  re-convergence after release; (C) 20 s of 20% netem loss → 12+
  multiplicative falls (~×0.9 each), then climbed back to 15.6 Mbps
  by run end (still climbing at horizon); audio inter-arrival p50
  4.7 / p99 5.9 ms in runs A+B (through squeeze AND blackout;
  run C's p99 16 ms is the netem dropping audio datagrams — arrival
  gaps, not send cadence; host max audio queue delay ≤ 0.76 ms in
  A/B), 0 unseal failures anywhere (51k/85k/58k datagrams). Cleanup
  verified: no lyte-host/probe/tcpdump, 41041/41061 free, lo noqueue,
  Sunshine active, all three config shas byte-identical. Logs
  pup:/tmp/hs16-host{A2,B,C,C2}.log + /tmp/hs16-probe{A2,B,C,C2}.log.
  Deferred: encoder VBV doesn't consume frameByteCeiling yet (no
  NVENC reconfig call in CHevcEncode — the number is computed, logged,
  and test-pinned; wire it when the encoder leaf grows reconfigure),
  post-FEC loss + FEC-regime step on rung 3 (needs HS-17's NACK
  consumption + a per-frame regime switch on VideoChannel), pacer
  audio-cadence physics below ~4.6 Mbps (a full-size video datagram
  occupies >2 ms of wire there; smaller video datagrams via DPLPMTUD-
  down is the fix if a real path ever pins us that low — audio+control
  reserves fit under the 500 kbps floor by construction), estimator
  wants a client-clock skew term if reports ever ride >10 s baselines
  (50 ppm bounds it <1 ms today). WIRE WANTS (deferred, no bytes
  moved): an RFC 8888-style per-report ECN/marking field and an
  explicit receive-window/buffer-fill hint would sharpen verdicts —
  both are wire-version items, parked.

- **CL-11 client audio receiver** (`90f178d`, root): the last client
  H2 slice — the Mac plays pup's desktop audio. AudioDepacketizer
  (LyteTransport, sans-IO): HS-15's HOST-PINNED layout byte-MIRRORED
  (frame = group id = first packet number; packet n = frame +
  shardIndex; data shards carry their own graph-clock capture µs,
  parity the group's first, recovered stamps derive firstTs + i×5 ms),
  layout pinned against the SAME hand-built byte arrays as the host
  gate's leg 1 (the cross-pin) — promotion into Wire/ still joint with
  the host copy. FEC recovery client-side through the frozen
  FecDecoder, eager at any k-of-6 (any-2-losses tested exhaustively,
  15/15 patterns byte-exact). AudioJitterBuffer: the audio-continuity
  doc's percentile controller at packet granularity — target covers
  the ~2.6 s skew window's (p99 − min) spread (floor 5 pkts/25 ms so
  the hold-until-dry gap policy always outlasts the ≤3-packet FEC
  repair trail; found live: per-pair deviation statistics MISS Wi-Fi
  clump bursts, lattice-skew spread sees them), PLC verdicts only when
  due-and-dry, late arrivals dropped, stall backlogs re-centered
  (counted content skip — WSOLA accelerate stays M7's). Playback:
  COpus system-library leaf (pkg-config opus; libopus decode + PLC —
  AudioConverter has no PLC entry point, LyteKit untouched/frozen) →
  lock-free SPSC ring → AVAudioSourceNode; pacing locks to the DAC
  (pump refills to the adaptive target; render thread lock-free,
  §5.1). DETECTOR TIGHTENED (CL-8's promised deviation closes): first
  authenticated chan-1 arrival rebuilds the receiver machine at 350 ms
  (wire-mode transplanted; evidence-gated — W7 has no audio-presence
  key, only the reserved audioExpress, so a --no-audio host keeps
  2.5 s; config-injected, Wire/ untouched). Surfaces: wire-view
  --audio + audio stats line (FEC/PLC/late/recenter, depth p50/p99,
  jitter σ, above-floor pipe latency, ring ms, underrun, live RMS
  dBFS + zero-crossing Hz); the app plays by default, mute toggle
  wired to the Lyte path. Gate: root 84 → **103/103** (layout
  cross-pins; any-2-of-6; hostile shards counted-never-fatal;
  virtual-time jitter legs steady/±15 ms/FEC-healed-5%-ish/true-gap→
  exactly-4-PLC/late-discipline/stall-recenter; detector legs incl.
  wire-mode preservation + nil-config off; Opus leaf tone round-trip
  −27 dBFS RMS/440 Hz + PLC interpolates + garbage→counted silence).
  LIVE vs pup :41051 (committed-HEAD ce051e1 host via git archive;
  HS-16 was landing in Host/ concurrently — never touched): 125 s
  clean leg — **440 Hz pw-play tone at −24 dBFS measured at the
  decoded output: −27.0 dBFS RMS / ~440 Hz (sine's 3 dB RMS offset,
  exact)**, 10,441 audio dg → 6,961 pkts, PLC 6 (all in opening
  adaptation), depth p50/p99 18/24 pkts STABLE over the run, 0 video
  missing; 5% netem scoped to udp dport 41051 (105 s): **1,016
  packets FEC-rebuilt across 965 groups, PLC only for the 26
  fec-impossible packets**, stream continuous, 95,555 datagrams ALL
  ok / 0 unseal failures, video 3,525 missing healed by 77 IDR
  requests, layer .rendering. LATENCY HONESTY: audio capture stamps
  are the PipeWire GRAPH clock (epoch unmappable client-side), so the
  books report ABOVE-FLOOR pipeline latency (min capture→feed delta
  subtracted): pipe p50/p99 ~98–102/127 ms — this Wi-Fi path's
  arrival clumping drove the adaptive target to 18–24 pkts (90–120
  ms); silence-free playout bought with latency, the doc's honest
  trade (M7's accelerate lowers equilibrium). Cleanup verified: netem
  removed (noqueue), no lyte-host, 41051 free, Sunshine active, all
  three config shas byte-identical. Logs /tmp/cl11-client{D,F}.log
  (Mac), pup:/tmp/cl11-host{D,F}.log. OPERATIONAL CAUTION: wire-view
  --audio runs ORPHANED into the background (subshell + redirect)
  died silently mid-run 3× (no crash report, no stderr; legs A/B/E) —
  every FOREGROUND run completed clean; suspect the headless-shell
  process-lifetime class of CL-8's Keychain caveat, not a code path a
  real GUI session hits. Deferred: audio-interior promotion into
  Wire/ (with the host copy), app human-at-glass listen (audio
  default-on in the app path awaits CL-8's deferred human leg),
  background-run death root-cause if it ever shows in a real session.
  (WSOLA accelerate + skew-term + device-change handling themselves:
  retired, CL-17 `3a58fb6`.)

- **HS-17 NACK consumption / targeted repair** (`96b1a89`, Host/):
  the H2 resiliency close-out — client NACKs are honored, closing §4.7's
  deferred half. NACK RESPONDER (resiliency §1.1 rules 3–4 as written):
  the chan-3 report's NACK section (frozen W4a codec — ZERO wire bytes
  moved, everything composes through existing codecs) is consumed at
  Session.ingestFeedback → per-entry verdicts. VideoChannel grew the
  repair store — every packetized shard (plaintext + fec field + TLV
  stamps) retained per frame, ≥4 s ring (build-plan row) + 16 MB byte
  cap, oldest-first eviction — and `enqueueRepair`: each honored shard
  is a FRESH datagram (fresh seq, fresh seal — the W3/W9 rule; the
  original frame/fec/timestamp/lastInputSeq TLVs ride verbatim) on
  `.videoTail` (overview conflict 13 — below fresh video, structurally
  below audio). Staleness ruling: honor iff `rtt + retxSerialization <
  remainingFreezeBudget` (budget = 2 frame intervals, 33 ms default —
  Work mode has no video jitter buffer; anchor = the frame's LAST shard
  release instant, pacer queue time never charged) AND frame not older
  than the last IDR (the IDR itself stays repairable, §5.2's burst
  rationale); ONE attempt per shard ever; stale verdicts that leave the
  client stuck (budget gone / store evicted) arm the SAME coalesced
  keyframe latch client 0x10s pull (IDR-on-stale = the existing
  requester, no new pathway); olderThanIdr refuses silently (the newer
  IDR is the heal); FROZEN/closed suppress repairs (§4 freeze rule).
  RTT term = SRTT (new RFC 6298 EWMA off beacon echoes) capped at
  2×min-RTT — the beacon SRTT double-counts both ends' receive-loop
  wake latency (~7–14 ms measured on a 0.3 ms loopback), which a repair
  datagram never pays. POST-FEC LOSS → ESTIMATOR (HS-16's named seam):
  NACKed shards, deduped (frame,shard) over the rolling 1 s window,
  over the video ledger's attempted deltas = post-FEC loss; > 2%
  (rung 3) → ×0.85 fall (same 500 ms limiter, NOT the held 2–10% band
  — this is precisely what FEC failed to absorb; new verdict/reason
  `.postFecLoss`) + FEC-REGIME STEP: estimator latches §5.2 clean→lossy
  (fires with the downshift), lossy→clean after 5 s (config) with no
  post-FEC evidence; Session applies each step to VideoChannel's NEW
  `setRegime` per-frame switch (HS-16's deferred item, closed). NACK
  evidence inside a RECOVERY window holds RECOVERY (sawLoss). Gate:
  Host 93 → **104/104 Mac AND pup** (NackRepairGateTests, 11 legs:
  repair round-trip — 6 shards past parity healed byte-exact via
  loop-decode, fresh seqs pinned; olderThanIdr dead + IDR-repairable;
  budget-stale arms the coalesced latch exactly once; no-RTT refused;
  evicted → unavailable → IDR; closed suppressed; store age/cap laws +
  channel-level one-attempt; estimator post-FEC downshift + regime
  step/step-down + re-NACK dedupe; NACK-holds-RECOVERY; regime step
  lands on next frame's geometry 28+5 → 28+10; R-G8 CADENCE UNDER
  REPAIR STORM — 199 NACKs honored → 398 videoTail repairs in 5 s
  virtual, audio inter-send p99 deviation 0.026 ms). LIVE on pup
  :41071 (probe ~/src/hs17-probe :41072 — the hs16 probe grown the
  client NACK half: VideoAssembler's exact packet-threshold-3
  presumption, immediate NACK flush, repair verification by
  loop-decode, rule-4 escalation to 0x10 after 250 ms): run E, 15%
  netem loss VIDEO-scoped (tos 0xa0 + dport 41072, removed at t≈27 s):
  1,365 video datagrams dropped → 304 frames FEC-recovered and, past
  parity, **7 frames HEALED BY REPAIR (47 fresh-seq repair shards
  received, byte-exact by loop-decode) — targeted repair healing what
  FEC can't**; host honored 7/13 entries → 52 repair datagrams, 6
  honestly stale (5 budget, 1 olderThanIdr) → IDR alternative; **14
  rung-3 downshifts (20000→17000→14450… kbps) + 4 regime steps —
  probe watched the §5.2 column flip on the wire (k=75 m=19 lossy) and
  step BACK to clean after the quiet hold**; audio inter-arrival p50
  4.74 / p99 5.98 ms (within 5±2 ms) THROUGH loss+repair; 0 unseal
  failures (23,365 dg). Run F (stale mode, clean path): 16 deliberately
  stale NACKs → **0 retransmits, 16 stale verdicts (12 olderThanIdr
  refused dead, 4 budgetExceeded → 4 IDR-armed, exact 1:1), staleness
  answered with IDR** (15 IDRs encoded, probe decoded 14 IRAP frames);
  audio p99 5.89 ms. Cleanup verified: netem removed (noqueue), no
  lyte-host/probe, 41071/41072 free, Sunshine active, all three config
  shas byte-identical. Logs pup:/tmp/hs17-{hostE,hostF,probeE,probeF}.log
  (A–D = earlier iterations: A found the pacer-queue-time budget bug,
  C/D found the probe's false-NACK timer + the SRTT wake-latency
  distortion). Deferred: client-side NACK emission in LyteTransport
  (root territory — the probe proved the wire contract; CL's
  FeedbackSender routes assembler nackCandidates into the section it
  already encodes), VideoAssembler acceptance of fresh-seq repair
  shards (Wire/ territory: the group-consistency check drops a repair
  whose seq sits outside the original range — the ONE seam the probe
  had to model around; flag for the promotion slice), retransmit-lane
  DSCP (repairs ride 0xA0 with video today; a tail-class marking is a
  wire-policy call), per-NACK-entry pacing if a hostile client ever
  matters (today bounded by store size + one-attempt).

- **CL-12 client targeted repair** (`63924d5` Wire/ + `3552091` root):
  HS-17's other half — the H2 CC/NACK parity item closes. WIRE SEAM
  (the deferred ledger's named item): VideoAssembler now ACCEPTS
  fresh-seq repair shards — matching geometry under a foreign seq base
  slots in by FEC shard index (`.repairShardAccepted`) and completes
  the group byte-exact; only a GEOMETRY lie stays `.inconsistentGroup`;
  the group's own seq base keeps anchoring presumption, and a
  repairs-only group can still open and complete (base then anchors to
  the repair — under-presumes, documented, W-G3's shape check still
  gates every byte). `nackCandidates` grew the whole per-frame picture
  (all missing indices, parityShards, frame age) so the client policy
  never duplicates assembler state. RECEIVE-SIDE ONLY: zero codec
  bytes moved, no vector regenerated — all 11 vector shas byte-
  identical Mac AND pup (a326b835…, a902805d…, 7b81dab0…, etc.); Wire
  suite 366 → **372/372 Mac AND pup**. CLIENT POLICY (root): NackPolicy
  (sans-IO, injected clock) runs §1.1 as written — rule 1: ask only
  PAST PARITY (missing > m; below it FEC owns the frame); rule 3
  mirrored: ask iff frameAge + minRTT < the assembler's 250 ms stale
  horizon (a repair landing after group eviction is wasted), refusal
  permanent; rule 4: asked-but-uncompleted frames escalate to the
  EXISTING coalesced IdrRequester after 250 ms (fec-impossible
  verdicts DEFER while an ask is live — without that, threshold-10
  fires before any repair's RTT and the IDR always wins); dedupe
  once-EVER per (frame, shard) — a lost report is answered by rule 4,
  never re-asked. Asks ride W4a's NACK section: FeedbackSender grew
  the pending queue (6-entry bound, spill next beat) + an immediate
  out-of-cadence report per emission (the host's 33 ms freeze budget
  is tighter than the 25–50 ms cadence). Pipeline forwards enriched
  events through a repair-signal seam; wire-view grew the nack line.
  Gate root 103 → **109/109**: past-parity → real chan-3 NACK →
  HS-17-shaped repairs → byte-exact through the real receive path,
  zero IDRs; stale → no ask + IDR; policy discipline pinned; section
  bounds/spill; seeded 12% SimNet storm heals with zero duplicate
  asks. LIVE vs pup :41081 (host at committed HEAD `4b93e7e` via git
  archive at ~/src/cl12gate; 15% netem VIDEO-scoped — dsfield 0xa0 +
  dport 41081 on wlp0s20f3 egress, removed after): 75 s wire-view
  --audio run, handshake 17.0 ms, 33,069 datagrams ALL ok / **0
  unseal failures both ends**; video 15.5% delivered loss (1,971
  missing) — **client emitted 64 NACK entries (251 shards) and the
  host consumed EXACTLY 64 entries / counted EXACTLY 251 post-FEC
  shards (1:1 wire correlation); host honored 20 → 54 videoTail
  repair datagrams, judged 44 stale (40 budgetExceeded, 4
  olderThanIdr) → 40 IDR-armed; client accepted 17 repair shards → 7
  frames HEALED BY REPAIR; 2 asks rule-3-suppressed client-side, 28
  rule-4 expiries → IDR; 129 IDR requests sent = 129 seen on the
  host, video continuously .rendering (700 frames decoded)**. Honest
  dynamics on this run's rough Wi-Fi (host SRTT 47.7 ms vs the 33 ms
  budget): most asks fell to rule 3 and IDR-healed — the pillar's
  designed degradation ("on a 50 ms path the gate usually fails …
  degrades gracefully to FEC+IDR"); sustained 15% also drove 35
  rung-3 downshifts to the 500 kbps floor (final regime lossy), so
  late repairs queued behind the squeezed pacer and dropped stale
  client-side (17 of 54 accepted). Audio concurrent throughout:
  22,234 dg → 14,826 pkts, PLC 113 (0.76%), depth p50/p99 21/41 pkts
  (target 20), stream continuous through loss + repair + floor.
  Cleanup verified: netem removed (noqueue), no lyte-host, 41081
  free, Sunshine active, portal_token/noise_static/paired_clients
  shas byte-identical. Logs /tmp/cl12-client.log (Mac),
  /tmp/cl12-host.log (Mac copy + pup). Operational note: pup dropped
  off-network ~1 min AFTER the run's clean close (known pattern, no
  reboot — back in ~7 min; evidence unaffected, cleanup done after).
  Deferred: repair-lane DSCP (HS-17's row — under a floor squeeze the
  videoTail queue is where repairs die; a tail-class marking or
  repair-priority call would change the 17/54 figure), client
  ask-budget awareness of the HOST's srtt (the client's min-RTT mirror
  passed while the host's 47 ms SRTT refused — harmless asks today at
  ~40 B each, revisit only if ask volume ever matters), promotion
  slice items unchanged (0x15/0x16/0x17/TLV-0x03/audio interior).

- **H2 JOINT GATE — PASSED; H2 FUNCTIONAL PARITY IS CLOSED** (2026-07-22
  ~13:15 MDT, report `docs/20260722-h2-joint-gate.md`): one coherent live
  session shape against pup, both ends at committed HEAD `f9ca59c` (host
  from git archive at `pup:~/src/h2gate`), port 41091, `wire-view --audio`
  + `--input-script` every leg. Steady state everything-at-once (190 s):
  video + 5 ms audio + 38 scripted inputs + estimator at the 20 Mbps
  ceiling + 45 idle cycles, audio full-rate through every idle window,
  detector tightened to 350 ms on first chan-1 arrival. Input: 1,833
  events across six runs, 100% exactly-once with echoes, host rx→inject
  p50 ~1.2 ms / p99 1.8 ms clean; input-wake attributed 15/15 (IDLE →
  ACTIVE +7…+108 ms, IDR pacing exactly 1/wake, 34/34). Audio cadence at
  pup's NIC p50 4.999 / p99 5.978 ms (0.34% outside 5±2); receiver PLC
  0.037% THROUGH a 90 s 6 Mbit video squeeze (receiver-side raw arrival
  p99 13–20 ms on every leg incl. clean — Wi-Fi clumping, CL-11's
  finding; the 5±2 bound holds at the NIC). Congestion: overuse falls
  anchored at measured delivery, floor 500 kbps held; full re-convergence
  to ceiling post-blackout (run G) — B2's post-release tail floor-pinned
  under sustained 250 ms damage because the encoder doesn't consume
  frameByteCeiling yet (HS-16's deferred VBV row, named in the report).
  Loss/repair (15% video-scoped): client 71 NACK entries / 345 shards ↔
  host consumed EXACTLY 71 / 345 (1:1), 36 honored → 62 repairs → 7
  frames repair-healed, 35 stale → IDR, video .rendering throughout.
  Blackouts (13 s + 10.2 s): pill +425 ms of last arrival (pcap-timed),
  cleared ≤1 ms on first returning datagram; host FROZEN at 350 ms →
  RECOVERY on first evidence + halfStaleEstimate IDR pacing → active in
  ≤153 ms on real estimator verdicts. Hygiene: ~550k sealed datagrams,
  0 unseal failures both ends in 6/7 runs (run F: 4 = 0.005%,
  stale-straggler replay discipline during a >2 s queue flush, not auth
  failures). Cleanup verified: netem removed (noqueue), iptables clean,
  41091 free, Sunshine ACTIVE, all three secret shas byte-identical.
  Harness committed: `Scripts/netem/h2gate-netem.sh`. Logs
  /tmp/h2gate-* (Mac + pup). **REMAINING FOR H2 EXIT (the human's call,
  J-G2/CP-2): demolition — Sunshine uninstall + LyteKit/CEnet/CNanors
  deletion as one reviewed series. Explicitly NOT done by this gate;
  Sunshine untouched and active.**

- **H2 EXIT — THE DEMOLITION, DONE** (2026-07-22 ~14:05 MDT, human's
  explicit go: "full demolition the moment the gate passes"; commits
  `2018f6d` → `d5de430` → `9e1cd27`, CL-14 / checklist §6 of
  20260720-221103): the GameStream stack is GONE and Sunshine is
  UNINSTALLED. Series: (I `2018f6d`) app/CLI surfaces rewired pure
  Lyte-UDP — NvApp picker, NVstream PIN flow, doctor pill + Diagnosis
  plumbing, GameStream recents/resume/headroom, old-session Actions
  items, Sunshine-era CLI subcommands (discover/info/pair/apps/launch/
  stream/quit/unpair + their AppKit window), LyteUI's Windows-VK
  InputCapture all deleted; app Bonjour declaration now `_lyte._udp`
  only. (II `d5de430`) all 30 LyteKit sources + Vendor/enet + Vendor/
  nanors + CEnet/CNanors targets + swift-certificates/swift-asn1 deps +
  PairingCryptoTests deleted — 12,801 lines; root products now just
  Lyte.app + lyte-cli over LyteTransport/LyteUI/COpus. (III `9e1cd27`)
  AGENTS.md retires the "never disturb Sunshine" rule + 47998–48010
  exclusion + frozen-stack repo map; README tells the one-protocol
  story; PLAN.md banner-marked historical; MACOS-SIGNING names the
  Noise static; netem comments de-Sunshined (h2gate-netem.sh kept
  verbatim as a gate record). Checklist notes: item 3's goldens were
  already re-pointed in LyteTransportTests (nothing preserved from
  LyteKitTests beyond history); item 5 (ClientStore migration)
  completed by supersession — PinnedHostStore has owned Lyte identity
  since CL-6, GameStream recents deleted rather than migrated. Suites:
  root 109 → **104/104** (−5 = PairingCryptoTests), Wire **372/372**,
  Host **104/104**, build-cli.sh + make-app.sh release green. LIVE
  PROOF at the new HEAD (pup host from git archive `~/src/demolition`,
  port 41111, --ratchet): 60 s session — handshake, 48,474/48,474
  datagrams ok, 0 unseal failures both ends, 1,780 frames rendered
  (first frame 25.9 ms), audio 17,874 dg → 11,916 pkts (PLC 0.64%),
  9/9 scripted inputs injected exactly-once with echoes (host
  rx→inject p50 1.16 ms), clock residual rms 354 µs, typed 0x0A
  teardown clean. SUNSHINE UNINSTALL (pup): was deb `sunshine
  2026.516.143833` (/usr/bin/sunshine, user unit
  app-dev.lizardbyte.app.Sunshine.service); user config archived to
  pup:/tmp/sunshine-config-backup.tar.gz (~/.config/sunshine also left
  in place, inert); service disabled+stopped (user-unit symlinks
  removed), package PURGED — no binary/process/unit/udev rule/
  autostart remains, ports 47984–48010 silent. The uinput seat-access
  line from 60-sunshine.rules (the CInputUinput fallback's ACL,
  HS-13) was carried over as `/etc/udev/rules.d/60-lyte-uinput.rules`
  under Lyte's own name BEFORE the purge; udev reloaded. Secrets
  verified byte-identical before/after (portal_token dadf9a66…37cf,
  noise_static.key 72860390…cfed, paired_clients 8dc1f88a…55fd).
  Post-uninstall live leg re-proved the host (18 s: 9,389/9,389 ok,
  render + audio + 3/3 inputs + clean teardown); no lyte-host left,
  41111 free. Logs: Mac /tmp/demolition-client.log,
  pup:/tmp/demolition-host{,2}.log.

- **HS-18 host audio routing** (`6b5a78e`, Host/): the host learns to
  hold its tongue — the human's direct ask after hearing the same
  audio on both machines. TWO POSTURES: hostAudible (unchanged
  default — HS-14's default-sink monitor capture) and hostMuted —
  CPipeWireAudio creates a "Lyte Audio" null sink
  (adapter/support.null-audio-sink via pw_core_create_object, so the
  sink is CONNECTION-OWNED and a SIGKILL can never leak it), saves
  the original `default.configured.audio.sink` metadata value, sets
  the default to the Lyte sink (the wpctl-set-default key), and
  captures ITS monitor (stream.capture.sink + target.object pinned to
  the sink) — sound flows only to the wire. RESTORE LADDER: clean
  stop/free restores the metadata exactly (or clears it when it was
  unset) while the connection is whole; SIGINT/SIGTERM raise a flag
  the capture tick reads → normal teardown path (Signals.swift); the
  ONE thing kill -9 can strand (the metadata) is persisted to
  `~/.config/lyte-host/audio_default_sink.prev` BEFORE the switch and
  swept at the next session start (`AudioWire.sweepLeftoverRouting` →
  standalone `lyte_pw_audio_restore_default` one-shot; hostMuted is
  REFUSED if the state file can't be written). Cadence discipline:
  both modes run the identical 5 ms pipeline — same node.latency
  240/48000, same node.force-quantum=240, same framer/pacer path;
  virtual-sink graph cadence is a named live leg (measure, don't
  assume). CARRIAGE (zero frozen bytes, pinned as data): capability
  key 9 `hostAudioRouting` rides W7's forward-compat spine through
  unknownEntries — the declaration is wireDefault's exact frozen
  encoding plus one appended `09 F5` entry (gate-pinned byte-exact),
  survives intersection only on mutual byte-equal declaration, so the
  client's auto-hiding control strip gates its mute button truthfully
  (the human's design note). Host declares key 9 whenever the audio
  leg is on (--no-audio doesn't). Mid-session flip: HOST-PINNED CTRL
  **0x18 AudioRoutingRequest** (`type ‖ mode u8`; 0x01 audible / 0x02
  muted, client→host) and **0x19 AudioRoutingStatus** (same layout,
  host→client — the posture that ACTUALLY stands, sent at capability
  agreement and after every applied flip; a failed flip reports the
  OLD posture), both on the ARQ ordered stream, both gated on the
  agreed set (unnegotiated 0x18 → new drop reason
  `.audioRoutingNotNegotiated`, loud; 0x19-at-host → role-confusion
  drop). PROMOTE with 0x15/0x16/0x17 (registry appends: CapabilityKey
  9 + the two CTRL types). Shell: `--host-audio audible|muted` seeds
  the posture; SessionWire drains flip requests OFF the session lock
  (a flip is a PipeWire connect — the audio leaf is stopped and
  rebuilt in the other mode by main's handler; one leaf owns the
  quantum forcing so two never overlap); new
  events .audioRoutingRequested/.audioRoutingStatusSent + counters +
  the audio-routing final-stats line. Gate: Host 104 → **110/110 Mac**
  (AudioRoutingGateTests: 0x18/0x19 byte-pins + hostile rejects;
  declaration = frozen bytes + `09 F5` and nothing else moved;
  intersection both orders + false-not-equal-true; in-vivo negotiated
  flip both directions with byte-exact 0x19; rule-3 gate: refusal
  loud, status never volunteered, role confusion dropped).
  **PUP LEGS a–g ALL PASSED (2026-07-27 ~01:10–01:55 MDT catch-up,
  port 41121, host at `71d936b` via rsync; full report
  `docs/20260727-015500-pup-catchup.md`):** (a) the C leaf's FIRST
  compile anywhere was CLEAN — zero code changes needed, pup build
  green, Host suite **115/115 on pup** (count includes the later
  clipboard slice); (b) hostMuted silence proof: default flipped to
  "Lyte Audio" (metadata `{"name":"lyte-audio-sink"}`), a −24 dBFS
  pw-play tone into the default landed on the Lyte sink's playback
  ports, the PHYSICAL Speaker monitor recorded **Peak −inf / RMS −inf
  dBFS** (pw-record `stream.capture.sink=true`, 4 s) while the client
  measured the tone crossing at **~440 Hz** (sig −48.1 dBFS — pw-play's
  remembered stream volume attenuates ~21 dB; the frequency is the
  identity proof); (c) clean-end restore EXACT (`--seconds` expiry →
  Lyte sink gone from the sinks list, default back to
  `…HiFi__Speaker__sink`, metadata value byte-identical to the pre-run
  dump) AND the SIGTERM path (`audio: routing restored — original
  default sink back` + typed 0x0A + `teardown acknowledged — clean
  close` on a mid-session kill); (d) kill -9 mid-session: the Lyte sink
  AUTO-GONE (connection-owned), the metadata STRANDED at
  `lyte-audio-sink` (the one strandable thing, exactly as designed),
  `audio_default_sink.prev` held the Speaker name from BEFORE the
  switch — the next start printed `audio: swept a dirty previous run —
  default sink restored to {…Speaker…}`, metadata byte-exact, state
  file consumed; (e) NIC cadence (tcpdump inter-send at pup's NIC, data
  shards only per the AudioGateTests rule, 25 s windows): **hostMuted
  p50 4.996 / p99 5.321 ms, deviation p99 0.354 ms, 0 of 4,997 deltas
  outside 5±2**; **hostAudible p50 4.998 / p99 5.374 ms, deviation p99
  0.407 ms, 1 of 4,393 outside (0.02%)** — the virtual-sink topology
  holds the bound; (f) hostAudible regression unchanged: default-sink
  monitor capture (`< Speaker:monitor` pinned in the streams listing),
  tone crossed at ~440 Hz, 8,970 packets ≈ 200/s over the run, max
  audio queue delay 0.56 ms; (g) all three secrets byte-identical after
  everything (portal_token dadf9a66…37cf, noise_static.key
  72860390…cfed, paired_clients 8dc1f88a…55fd; the config dir ends the
  night holding exactly those three files). TWO ENVIRONMENTAL FINDINGS
  (report §3–4, neither a code defect): (1) pup's unattended upgrade
  moved NVIDIA userspace to 595.84 at 00:42 TONIGHT while the loaded
  kernel module stayed 595.71.05 — NVENC refused every session
  (`OpenEncodeSessionEx: unsupported device (2)`) until the host ran
  against extracted 595.71.05 libs (Launchpad debs →
  `/tmp/nv571/ext/usr/lib/x86_64-linux-gnu` on LD_LIBRARY_PATH;
  compute+encode alone were NOT enough — `libnvidia-gpucomp` must
  match too). The shim is pup-local and process-scoped; the next
  REBOOT both clears /tmp and heals the mismatch, after which drop it;
  (2) a live YouTube playback (Chrome) on pup's desktop degraded
  AUDIBLE-mode capture cadence catastrophically while it played
  (474 stream xruns/25 s, capture callback 1.4 ms busy vs the normal
  0.2–0.5 ms, 35–79% of sends outside 5±2, ~25% packet shortfall) and
  recovered when the media stopped; ladder-tested NOT a regression
  (pre-HS-18 / HS-18 / promotion / HEAD builds all measure clean
  after) — and hostMuted's graph-clocked null sink was IMMUNE even
  during the bad window, an argument for the muted posture while
  streaming; capture-thread RT priority filed as a deferred seam.
  Client follow-up CL slice (flagged): declare key 9 + send 0x18 +
  render 0x19 in the control strip; promotion slice grows by key 9 +
  0x18/0x19. (Both since landed — CL-13 and the promotion, below.)

- **CL-13 control strip + client audio routing** (root): HS-18's other
  half — the stream window grows its verbs and the client learns to
  ask the host to hold its tongue. WIRE MIRROR (LyteTransport/
  AudioRouting.swift, the 0x15/0x16/0x17 mirror-then-promote
  precedent): CTRL 0x18 AudioRoutingRequest / 0x19 AudioRoutingStatus
  (`type ‖ mode u8`), byte-pinned against the SAME hand-built arrays
  as Host/Tests' AudioRoutingGateTests leg 1 (the cross-pin); key 9
  on the W7 spine with the frozen-bytes proof repeated client-side
  (wireDefault's bytes + map-head 0xA8→0xA9 + `09 F5` appended,
  nothing else moves); both copies delete together at the promotion
  slice. SESSION CORE: the DEFAULT client declaration now carries
  key 9 (the client can always render the control; the intersection
  decides existence), `requestHostAudioRouting` sends 0x18 on the ARQ
  ordered stream and is refused BEFORE a byte leaves when key 9 never
  survived intersection (AudioRoutingAskError.notNegotiated — the
  host would only drop it loud); the 0x19 consumer is gated on the
  agreed set (unnegotiated status → loud drop + counter; a
  role-confused 0x18 at the client likewise), updates the confirmed
  posture (`hostAudioRoutingPosture`, nil until the host's first
  status — NEVER optimistic) and fires `.hostAudioRoutingStatus` on
  every 0x19 including a failed flip's old-posture re-report (the ask
  was answered; the answer is "nothing changed" — the UI toggle
  snaps back). SESSION-START POSTURE: config
  `desiredHostAudioRouting` — the host's FIRST 0x19 (its own default,
  sent at capability agreement per HS-18) is compared and exactly one
  0x18 leaves when they differ; at most once per session by design (a
  failing host re-asked forever would loop; the strip is the live
  override). PER-HOST DEFAULT: `PinnedHost.startHostAudioMuted`
  (optional — pre-CL-13 pinned_hosts.json decodes unchanged; a
  re-pair refreshes dial hints WITHOUT resetting it), applied at
  connect by the app; settable from the host row's context menu and
  the Actions menu. THE STRIP (ControlStrip.swift, the human's
  recorded design): auto-hiding, video-player style — reveals on
  mouse movement (the input capture pings the reveal clock, since it
  consumes moves over the video and SwiftUI hover alone goes blind;
  onContinuousHover is the not-key-window backup), fades after ~2 s
  idle, never while hovered, always one wiggle away. Buttons
  CAPABILITY-GATED: Mute Host Audio EXISTS only when key 9 survived
  intersection, renders the 0x19-confirmed posture, disabled until
  the first status; client-side mute (CL-11 mixer); stats readout
  toggle (compact overlay off the session's existing books:
  datagrams ok/unseal, mode + posture, input inject p50/p99, audio
  depth/PLC/FEC, 1 Hz TimelineView refresh); fullscreen; Disconnect
  (the typed 0x0A). The Actions menu drives the SAME ConnectionModel
  verbs (menu and strip cannot disagree; both existing items kept
  their Lyte meaning — nothing left to delete post-demolition).
  Input-capture seam: mouse events HIT-TEST first — strip/stats
  clicks never reach the host cursor; key events never reveal the
  strip. wire-view: `--host-audio audible|muted` seeds the
  session-start posture, capabilities line + session stats line grew
  the posture (`host-audio MUTED/audible/pending/unnegotiated`), 0x19
  events print — tonight's worker drives the whole negotiation live
  without the app. Gate: root 104 → **113/113 Mac**
  (AudioRoutingClientGateTests, 9 legs: codec cross-pins + hostile
  rejects; frozen-bytes spine proof + core-default-declares;
  intersection both orders + false-not-equal-true; in-vivo negotiated
  flip vs a scripted key-9 host in virtual time — starting 0x19 →
  ask [0x18 0x02] byte-exact → 0x19 → callback, failed flip reports
  old posture; session-start ask exactly-once-when-differing +
  quiet-when-matching + never-re-triggered; rule-3 gate — ask refused
  pre-wire, hostile 0x19 + role-confused 0x18 dropped loud; per-host
  default decode/re-pair/refusal plumbing). Harness lesson worth
  keeping: the stand-in host MUST queue its declaration at
  establishment, before consuming any client word — lazily queued, the
  agreement's 0x19 jumps ahead of the declaration on the ordered
  stream and the client rightly drops it loud (HS-11's first-word
  rule is load-bearing, not ceremony). Release builds green
  (build-cli.sh + make-app.sh). **PUP LEGS h–k PASSED, j's app half +
  l REMAIN FOR THE HUMAN (2026-07-27 catch-up, port 41121, report
  `docs/20260727-015500-pup-catchup.md`):** (h) PASSED in both
  directions via the session-start ask (wire-view carries no
  mid-session flip surface — the strip/menu drive rides leg l):
  audible→muted (run A: starting 0x19 AUDIBLE → exactly one
  `[0x18 0x02]` → 0x19 MUTED confirmed; client `routing 1 asks/2
  statuses` ↔ host `1 flip requests, 2 statuses sent` — 1:1) and
  muted→audible (run C: starting 0x19 muted → one 0x18 audible → flip
  applied MID-SESSION — Lyte sink destroyed + Speaker default restored
  while the session kept streaming — → 0x19 audible; counters 1:1
  again); the wire-view posture line tracked every step; (i) PASSED —
  run A is the leg verbatim: `session-start posture: asked host for
  hostMuted (host default hostAudible)` printed, exactly one 0x18
  after the starting 0x19, host speakers silent from the flip onward
  (leg b's −inf monitor proof); (j) the WIRE MECHANISM is proven by
  (i) — the app's `startHostAudioMuted → desiredHostAudioRouting`
  connect seeding is the same config path wire-view's flag drives, and
  the store plumbing is gate-pinned — but the at-glass half (set
  "Start with Host Muted" in the app, fresh connect starts muted with
  zero strip interaction) has NO scripted surface and rides the leg-l
  checklist; (k) PASSED vs a `--no-audio` host: capabilities line
  `hostAudioRouting no, clipboard no`, session line `host-audio
  unnegotiated`, ZERO 0x18 on the wire (client 0 asks ↔ host `0 flip
  requests, 0 statuses sent`), 16,955 datagrams / 0 unseal failures —
  wire-view's `--host-audio muted` correctly never asked (the ask
  triggers on the host's first 0x19, which a no-key-9 host never owes;
  nothing left the client, which is the criterion) and the truthful
  `unnegotiated` posture is exactly what gates the strip button's
  existence; (l) STILL OPEN — the human checklist, to be run at or
  past CL-16 `73ccd46` (the strip hit-test fix): reveal/fade feel,
  buttons actually click, no strip-click leakage to the host cursor,
  stats legibility over live video, ⌘⇧H/⌘⇧M/⌘⌥I/⌘D, fullscreen
  round-trip, PLUS leg j's fresh-connect-starts-muted confirmation.
  HS-18's own legs (a–g) are recorded in ITS entry — referenced here,
  not duplicated. Deferred (non-live): the strip is flat buttons-in-a-
  capsule v1 (no volume slider, no latency badge — H3-era polish);
  posture-pending UX shows a disabled button (fine while the first
  0x19 arrives inside the agreement round-trip; revisit only if a
  real path shows a visible pending window); promotion slice items
  unchanged (key 9 + 0x18/0x19 ride with 0x15/0x16/0x17/TLV-0x03 +
  audio interior).

- **CODEC PROMOTION — the mirrors come home** (`65f56d0` Wire /
  `d98e154` Host / `1b63a4f` root): the flag-flip the mirror-and-flag
  precedent promised, all three territories in one slice. Everything
  invented end-side during H2 moved to Wire/Sources/LyteWire VERBATIM
  — IdleFrame 0x15 (HS-11/CL-8), InputEvent 0x16 + InputEcho 0x17 +
  lastInputSeq TLV 0x03 (HS-13/CL-9), AudioRoutingRequest/Status
  0x18/0x19 + capability key 9 (HS-18/CL-13), and the HS-15/CL-11
  audio interior (AudioFramer + AudioDepacketizer + the AudioWire
  ground-truth constants) — registry appends on CtrlMessageType /
  WireExtension.ReservedType / CapabilityKey, zero wire bytes changed.
  Key-9 ruling: registered as `CapabilityKey.hostAudioRouting = 9` but
  deliberately NOT a typed set field in v1 — it keeps riding the
  forward-compat spine through unknownEntries exactly as it shipped
  (declaration = wireDefault's frozen bytes + `09 F5`, gate-pinned),
  so capabilities-v1.json never moves; the typed-field fold-in is a
  wire-version discussion. NEW VECTOR FILE `control-v1.json` (34
  vectors: every InputEvent kind, both routing codecs' whole mode
  spaces per the lifecycle discipline, the TLV on whole datagrams per
  the conn-id precedent, the key-9 spine as data; vectorgen grew the
  `control` subcommand), anchored by ControlCodecTests carrying the
  SAME hand-built arrays the end gates pinned; the audio interior
  composes frozen envelope/fec formats so it carries no vector file
  (the Noise-carriage precedent) — its layout pins live in
  AudioInteriorTests (hand-built envelope bytes + any-2-of-6 byte-exact
  + CBR loudness). BOTH mirror copies DELETED on both ends — no flags,
  no shims, no aliases; the only non-delete text was pinned-enum names
  giving way to the registry (Host/Client CtrlMessageType →
  CtrlMessageType etc.), explicit LyteWire imports where nothing
  re-exports (lyte-host's InputInject/AudioWire shell files, the app's
  input capture, the Opus leaf pair), and AudioRoutingAskError staying
  behind on LyteUdpSession (client rule-3 policy, not wire
  vocabulary). EVERY byte-pin assertion in Host/Tests and root Tests
  is UNTOUCHED — the arrays that pinned the mirrors now prove both
  integrations speak the canonical bytes. Suites: Wire 372 →
  **388/388 Mac** (+10 ControlCodecTests incl. a registry-number pin,
  +3 AudioInteriorTests, +3 ControlVectorFileTests incl. a
  value-space-coverage leg), Host **110/110 Mac** (unchanged),
  root **113/113 Mac** (unchanged); all 11 pre-existing vector files
  byte-identical; no-Foundation lint green; build-cli.sh release
  links + signs. **PUP LEGS m–n PASSED (2026-07-27 catch-up; the
  counts had grown to CL-15's by run time):** (m) BOTH packages
  rsynced as siblings, Wire suite on pup **402/402** (24.4 s) — the
  388 expected here plus CL-15's 14 — with ALL THIRTEEN vector files
  byte-identical Mac ↔ pup by sha256, control-v1.json (a0e3c398…) and
  clipboard-v1.json (41aef674…) included alongside the 11 pre-existing
  (a326b835…, a902805d…, 7b81dab0…, full table in
  `docs/20260727-015500-pup-catchup.md`) — the W-G1 cross-platform
  gate for the promoted codecs holds; (n) Host build + suite on pup
  **115/115** over the flipped imports (with HS-18's C leaf compiling
  clean on its first pass, zero fixes); (o) no root leg (macOS-only
  client) — and the live legs a–k/p above exercised the promoted
  codecs end-to-end on the wire tonight (0x15 idle frames, 0x16/0x17
  input + echoes, 0x18/0x19 routing, TLV 0x03 stamps, the audio
  interior at 200 pkts/s).

- **CL-12 FOLLOW-THROUGH — repair-answer books** (`ab4f905`, root):
  commissioned in the wave plan as "CL-14: client NACK emission +
  repair-shard acceptance" — the worker's finding, recorded for
  honesty: that scope had ALREADY LANDED as CL-12 (`63924d5` Wire /
  `3552091` root — gap detection via the assembler's enriched
  nackCandidates, NackPolicy running resiliency §1.1 as written, W4a
  NACK-section emission through FeedbackSender, fresh-seq repair
  acceptance in Wire's VideoAssembler, counters + the wire-view nack
  line, and a LIVE leg on :41081 before pup left). The CL-14 label
  also collides with the build plan's own CL-14 (the demolition,
  done). The genuine residual, now closed: the books said nothing
  about answers a frame NO LONGER NEEDS — a repair landing after FEC
  or a straggler already fixed the frame, a wire-duplicated copy, or
  an answer for a frame the holdback abandoned all vanished into the
  pipeline's anonymous shardsDropped tally (the no-op discipline
  itself was always Wire-guaranteed; zero Wire changes here). Now:
  LyteVideoPipeline forwards the two drop reasons an answer can land
  as (satisfied slot → `.satisfiedShardDropped`, passed turn →
  `.staleShardDropped`) through the CL-12 repair-signal seam, and
  NackPolicy classifies against its own ask books — asked + repair
  already accepted = **repairsDuplicate**; asked + frame decoded
  without it = **repairsLate** (a straggling ORIGINAL for an asked
  shard counts the same — the seam carries no seq, and it is equally
  an answer the frame never needed; documented honesty caveat); asked
  + frame skipped/evicted/rule-4-escalated = **repairsSuperseded**
  (frame FATE replaces the boolean settle so late-vs-superseded
  follows how the story ended; escalation rules .gone — the IDR owns
  the heal). wire-view's nack line grew `answers unneeded N late/N
  dup/N superseded`. Gate: root 113 → **116/116 Mac** (three new legs
  through the REAL receive path in virtual time: straggler-heal-then-
  answers → all late, zero re-delivery, rule 4 quiet; wire-duplicated
  accepted repair → counts exactly once, frame still heals byte-exact;
  holdback-abandoned frame → answers superseded, asks provably
  stopped, samples never move — plus per-branch policy pins incl.
  never-asked frames touching no book). build-cli.sh release green.
  Harness lesson: corpus frames run ~23 shards, so a straggler held
  past TWO follow-on frames falls off the 64-seq replay window and the
  demux rightly eats it — the leg keeps one follow-on frame and the
  caveat is written in the test. **PUP LEG p PASSED (2026-07-27
  catch-up, port 41139, 85 s wire-view --audio FOREGROUND; 15%
  video-scoped netem — the h2gate prio+u32 pattern, dsfield 0xa0 +
  dport 41139 on wlp0s20f3 egress — held 40 s mid-run, removed,
  `noqueue` verified):** the 1:1 correlation EXTENDED to the
  wasted-answer classes exactly as commissioned — client **58 asks
  (253 shards) ↔ host 58 NACK entries consumed / 253 post-FEC shards
  counted (exact)**; host honored 27 → **85 repair datagrams**, judged
  31 stale → 30 IDR-armed; the client's answer books name **76 of the
  85 by bucket: 28 accepted → 15 frames HEALED BY REPAIR, 48 late,
  0 dup, 0 superseded** — the missing 9 died inside the netem band
  itself (repairs ride 0xA0/videoTail THROUGH the impairment;
  9/85 ≈ 10.6% ≈ the loss rate — the honest remainder); 28 rule-4
  expiries → IDR client-side, **81 IDR requests sent = 81 seen by the
  host (1:1)**; estimator: 33 rung-3 downshifts to the 500 kbps floor
  + 3 regime steps (final lossy — the run ended before the quiet
  hold); **46,369 datagrams ALL ok / 0 unseal failures both ends**,
  video .rendering throughout, audio continuous (PLC 11 = 0.06%).
  dup/superseded stayed ZERO on this path — with a 20 ms SRTT the
  host's budget gate refuses early and late dominates; both buckets'
  mechanics stay virtual-time-pinned in the Mac gate. Incidental
  evidence for the CL-16-era input question: 5/5 scripted moves
  exactly-once with echoes, host rx→inject p50 1.15 / p99 1.27 ms —
  the wire/inject layer is clean. Logs
  /tmp/pupcatch-{clientP2,hostP2}.log (Mac + pup).

- **CL-15 clipboard sync — the first H3 feature, Mac-local end to end**
  (`ce50a20` Wire / `c16ff91` Host / `2f5f2f1` root; design record
  `docs/20260722-231500-lyte-clipboard.md`, written BEFORE the code):
  copy on either machine, paste on the other — v1 scoped to UTF-8 text.
  WIRE (born in the registry, not promoted): CTRL **0x1A ClipboardSet**
  (client→host) and **0x1B ClipboardAnnounce** (host→client), both
  `type ‖ UTF-8 text` (text the sole trailing field — the ARQ message
  boundary is the length), riding the ARQ ordered CTRL stream
  exactly-once in-order with NO clipboard-layer chunking (the ARQ
  reassembles whole messages); **65,536-byte ceiling** (the ARQ
  receive window describes 256 segments and the stream is shared with
  input — the old 256 KiB sketch would stall keystrokes ~4× longer;
  over-ceiling local copies suppress as counted weather, over-ceiling
  wire bytes reject); invalid UTF-8 and empty text reject (v1 does not
  sync clearing). **Capability key 10 `clipboardText`** on the W7
  spine exactly as key 9 (one canonical `0A F5` entry through
  unknownEntries, mutual byte-equal survival, capabilities-v1.json
  untouched) — deliberately NOT featureChannels id 1, which stays
  reserved for the real chan ≥ 8 feature-channel architecture (new
  semantics, new key). LOOP PREVENTION: `ClipboardSyncBook` (LyteWire,
  sans-IO, both ends run it verbatim) — remote applies pre-arm a
  consume-once echo ring, duplicates dedupe against the last share, a
  genuine share clears stale entries; the boomerang proof (a set must
  not echo back as a fresh change) is pinned on ALL THREE levels.
  VECTOR RULING: new frozen file **clipboard-v1.json** (17 vectors;
  vectorgen grew the `clipboard` subcommand) rather than appending to
  control-v1.json — appending is legal under the freeze policy, but
  control-v1.json's byte-exact pup verification is already queued on
  the deferred ledger, so the existing 12 files stay untouched;
  anchored by hand-computed bytes in ClipboardCodecTests, coverage
  discipline (every error case, the exact ceiling legal, the spine
  pinned declared+absent) asserted by ClipboardVectorFileTests. HOST:
  Session consumes 0x1A behind the rule-3 gate (unnegotiated →
  `.clipboardNotNegotiated` loud; 0x1B-at-host → role-confusion drop),
  pre-arms the book BEFORE the shell applies, and
  `noteHostClipboardChanged` judges agreement → book → ceiling before
  a 0x1B leaves (never volunteered to a no-key-10 client; suppressions
  surfaced as `.clipboardAnnounceSuppressed` loopEcho/duplicate/
  overBudget + counters); **`HostClipboardLeaf`** (ClipboardWire.swift)
  is the seam the real Wayland/portal leaf will drive — the gate runs
  a scripted leaf; lyte-host grew ONLY the event-switch arms
  (byte-count logs, payloads never printed) and does NOT declare
  key 10 until the real leaf exists. CLIENT: policy all in the sans-IO
  core — `shareLocalClipboard` returns a typed verdict (negotiated →
  enabled → book → ceiling), the 0x1B consumer gates on agreement
  (loud drop) AND on consent (counted-ignored, never applied, no
  event); CONSENT POSTURE: key 10 always declared (dialect, not
  consent — the key-9 rule), per-host `PinnedHost.shareClipboard`
  default OFF (clipboards carry passwords; pre-CL-15 files decode
  unchanged, re-pair preserves it), the control-strip toggle
  (capability-gated, ⌘⇧C in the Actions menu, per-host default in the
  host row's context menu) flips sharing live — while off the
  pasteboard is never even read. GLUE (thin by design): LyteUI's
  `PasteboardSync` — 200 ms changeCount poll, apply-and-swallow-own-
  bump, shared by the app and wire-view; wire-view grew `--clipboard`
  (real pasteboard glue for the live legs), the key-10 capabilities
  line, and clipboard books on the stats line — byte counts only,
  payloads never log anywhere. Gates: Wire 388 → **402/402 Mac**
  (+11 ClipboardCodecTests incl. registry pins + the book's laws,
  +3 ClipboardVectorFileTests), Host 110 → **115/115 Mac**
  (ClipboardGateTests: cross-pins; spine; in-vivo set → apply → echo
  suppressed with NOTHING returning on the wire + genuine copy →
  byte-exact 0x1B + dedupe; rule-3 legs; ceiling-is-weather + exact
  ceiling flows), root 116 → **122/122 Mac** (ClipboardClientGateTests
  vs a scripted key-10 host in virtual time: byte-exact 0x1A incl. the
  full 64 KiB ceiling through real ARQ segmentation, announce →
  event → echo suppressed, consent off = quiet AND deaf + live toggle,
  rule-3 refusal pre-wire + hostile/role-confused loud drops,
  over-budget verdict, pinned-store plumbing); no-Foundation lint
  green; build-cli.sh + make-app.sh release green.
  **PUP LEGS q–r PASSED, (s) STAYS OPEN (2026-07-27 catch-up):**
  (q) PASSED — the promotion entry's m/n numbers ARE this slice's
  counts: Wire **402/402 on pup** with all THIRTEEN vector files
  byte-exact by sha256 (clipboard-v1.json 41aef674… in the set), Host
  **115/115 on pup** (the new lyte-host switch arms took their first
  compile alongside HS-18's C leaf — zero fixes); (r) PASSED vs the
  real leafless host (`--no-audio`, key 10 never declared; port
  41135): wire-view --clipboard read **`clipboard no`** on the
  capabilities line and `clipboard unnegotiated` on the session line,
  two live pbcopy markers (32 B and 28 B) each printed **`local copy
  (N B) — notNegotiated`**, ZERO 0x1A on the wire (no clipboard
  counters on either end's final, no drops at the host), the Mac
  pasteboard saved before and restored after the probe; the app strip
  toggle's non-existence is UI-gated by the same negotiated flag
  proven false here (eyeball rides CL-13 leg l); **(s) PASSED
  (2026-07-27 ~02:20 MDT, HS-19 `73e5cdb`, port 41153, wire-view
  --clipboard vs lyte-host --clipboard)** — key 10 AGREED both ends
  (`clipboard yes (key 10)`); Mac→host: 25 B pbcopy marker → `local
  copy (25 B) — shared` → host `0x1A set received (25 B)` → wl-paste
  on pup returned it byte-exact, and the leaf's own SetSelection echo
  came back through the REAL Mutter signal path and was suppressed
  (`announce suppressed (loopEcho)`) — boomerang ZERO; host→Mac: 28 B
  wl-copy → `announce sent (28 B, 0x1B)` → Mac pasteboard byte-exact,
  2 SelectionTransfers served to host-side pastes, 0 failed; ceiling
  BOTH directions: a 70000 B Mac copy died client-side pre-wire
  (`overBudget(70000)`, pup's clipboard kept the 28 B marker) and a
  70000 B pup copy died at the host seam (`announce suppressed
  (overBudget)`, Mac pasteboard untouched); counters reconciled 1:1
  (host `1 sets received, 1 announces sent, 2 suppressed` ↔ client
  `clipboard ON (1 sent/1 recv)`); PLUS the consent discovery — Mutter
  replays the STANDING selection owner right after EnableClipboard, so
  the leaf drains that replay window (`1 baseline replay(s) skipped`)
  and a pre-seeded pre-session secret provably never crossed while a
  fresh mid-session copy still announced (24 B); negotiated-off
  re-proven at the same build (bare host: `clipboard no`, client
  `clipboard unnegotiated`, markers both ways did NOT cross, host
  `leaf none, 0/0/0`). The consent toggle mid-session flip stays
  covered by CL-15's Mac-local in-vivo tests (live re-run not repeated).
  **QUEUED FOLLOW-UP — DONE as HS-19 (`73e5cdb`):** MutterClipboardLeaf
  drives the RemoteDesktop-session selection API directly
  (org.gnome.Mutter.RemoteDesktop — the sanctioned portal wraps exactly
  this interface but auto-denies headless Start, the CP-5 verdict; own
  bus connection + own RD session, mirroring injector-vs-capture
  separation), SelectionOwnerChanged/SelectionRead inbound,
  SetSelection + SelectionTransfer/SelectionWrite serial dance
  outbound, fd state machines O_NONBLOCK on the video-loop tick, NO new
  C shim (CDBus already decodes fd replies); ClipboardTextMime pins the
  text-flavor policy cross-platform; `--clipboard` default-OFF gates
  both the leaf AND key 10. Host suite 115 → **117/117 Mac AND pup**.
  Live findings inked in the leaf's comments: mime-types rides a
  struct-wrapped variant `((as))`, and the EnableClipboard baseline
  replay above. Deferred (non-live, named): a
  mid-session "stop announcing" courtesy message is a v2 wire item
  (today a disabled end just ignores inbound announces); images/files/
  rich flavors and the chan ≥ 8 feature-channel carriage are the
  design doc's named non-goals; the glue's accepted race (a user copy
  landing inside the same 200 ms poll window as an inbound apply is
  superseded at the OS clipboard) is documented in PasteboardSync.

- **HS-20 — Wave 0's two named choppiness owners: encoder VBV consumes
  frameByteCeiling, repairs ride the protected lane** (`084e826`,
  Host/ only; Wire and root untouched at `69f1812`). **D-1 (encoder
  VBV):** the B2 dynamic the H2 gate named — rate drops the encoder
  never heard about, ceiling-sized frames pouring into a squeezed
  pacer, the post-release tail cycling 500→~900 kbps — gets its
  reconfigure path. `EncoderVbvPolicy` (HostWire, sans-IO): the
  ceiling C alone derives the posture (vbv = 8×C bits, rate = 8×C/B
  over the HS-6 budget window, `RateEstimator.frameBudgetNS` now the
  shared definition), always CAPS against the opening recipe (CBR
  keeps min=avg=max; capped-CQ keeps its nil average — pushing one
  would flip the rc mode — and, opening with NO VBV at all, gets the
  ceiling imposed at first look); hysteresis is the least-thrash
  ruling written down — 10% deadband on every effective param, a
  tightening applies before the very next frame (the estimator's own
  ≥15%/500 ms downshift limiter bounds the cadence), a loosening
  additionally waits 500 ms. The leaf grows `lyte_hevc_enc_set_rate`
  (assignment IS the API: FFmpeg's nvenc wrapper folds changed rc
  fields into one NvEncReconfigureEncoder on the next send_frame — no
  IDR, no reset); SessionWire arms/polls the policy under its lock and
  the Sink applies the directive beside the forced-IDR poll; 5 s
  frame-size percentile books print next to the live ceiling + pacer
  rate. Gate: Host 117 → **127/127 Mac AND pup** (8 EncoderVbvGateTests
  legs — budget-window pins, CBR-stricter-stays-silent, capped-CQ
  first-look imposition, exact 5 Mbps mapping incl. the min=avg=max
  CBR contract, floor never degenerate, deadband, falls-now/rises-wait,
  recovery-returns-exactly-to-baseline — plus 2 WireTosTests).
  **LIVE D-1 PASSED (pup :41155, 155 s wire-view --audio, moves every
  250 ms, 6 Mbit video-scoped netem squeeze t+50→t+110 — the B2
  shape):** clean phase at the 20,000 kbps ceiling (frames p50
  7,700 B / p95 9,934 B under ceiling 59,937 B); the squeeze fall to
  5,682 kbps carried `encoder: rate reconfigure — avg 4,862 kbps, vbv
  15,195 B` and every later move tracked (**89 directives = 89
  applied, 0 rejected**); deep falls PROVE emission obeys the ceiling
  — at pacer 1,803 kbps/ceiling 3,072 B the next window read p50
  2,257 / p95 4,345 B, and at pacer ~1,273 kbps/ceiling ~1,300 B the
  window read **p50 623 B / p95 1,265 B at 50 fps** (vs 7.7 kB clean);
  post-release the tail is NOT floor-pinned: climbed back to the FULL
  20,000 kbps by run end (final window p50 7,429 B at ceiling
  59,937 B), FEC regime ended clean, **3 IDR requests and 5 NACK asks
  in the whole 155 s**, 131,464 dg / 0 unseal failures, client
  9,303/9,310 frames decoded. Even a late-run garbage-anchored crash
  to 810 kbps (encoder followed to 368 kbps/1,152 B) recovered to the
  ceiling within ~30 s — the B2 signature (falls stick, tail pins) is
  retired at squeeze rates. **D-2 (repair-lane DSCP):** `WireTos`
  (HostCore) is now the ONE product marking policy — SessionWire and
  lyte-pace-check both apply it, Mac-pinned — and `videoTail` (the
  NACK-repair class) moves to **CS6/0xC0** beside control and audio,
  per the Lyte-UDP decision's per-packet-DSCP ruling and the priority
  ladder's "retransmits above refinement" intent; the pacer's strict
  priority still holds repairs below fresh video at OUR NIC (R-G8
  untouched — audio max queue delay 5.3 ms in the loss leg), the mark
  protects them at bottleneck queues we don't own. **LIVE D-2 (pup
  :41157, 85 s wire-view --audio, 15% video-scoped loss t+20→t+60 —
  leg p's shape), books side by side:** baseline leg p (41139, at
  `71d936b`): 58 asks/253 shards 1:1; **85 repairs sent = 28 accepted
  + 48 late + 0 dup + 0 sup + 9 netem-eaten** (10.6% ≈ the loss rate);
  15 frames healed; 81 IDR asks; 33 rung-3 falls to the FLOOR, regime
  ended lossy. HS-20 leg R: 53 asks/201 shards 1:1 both ends; host
  honored 20 → **54 repair datagrams = 21 accepted + 38 late + 0 dup +
  0 sup + 0 netem-eaten** — every repair crossed the impaired band
  (P(0 of 54 at 15%) ≈ 1.6·10⁻⁴: the 0xC0 escape past the dsfield-0xA0
  filter is conclusive), 9 frames healed by repair; **21 IDR asks ↔ 21
  seen**; estimator ended AT the 20,000 kbps ceiling with regime CLEAN
  (13 loss + 10 rung-3 falls mid-window, recovered); 58,231 dg / 0
  unseal failures (1,861 video datagrams died in the band — the
  impairment was real). HONEST READING: accepted-of-sent moved 33%→39%
  and eaten→0, but the LATE fraction did not fall (38/54 vs 48/85) —
  at ~18 ms SRTT under pure loss (no queue to die in) lateness is the
  client's rule-4 expiry racing the NACK round trip, not a lane
  problem; the queue-death scenario the marking chiefly protects
  (CL-12's squeeze: 17 of 54) now barely GENERATES repairs at all,
  because D-1 keeps frames conforming (V2's whole 60 s squeeze: 5
  asks, 0 honored). The marking's session-level win rode both fixes:
  81 → 21 IDR asks, floor-pinned-lossy → ceiling-clean. Client-book
  quirk for root territory: the answer buckets named 59 of 54 sent
  (over-named by 5; leg p under-named 76 of 85) — accounting, not
  wire. **Hygiene:** netem applied/removed per window, `noqueue`
  verified after each; secrets shas byte-identical start AND end
  (72860390…cfed / 8dc1f88a…55fd / dadf9a66…37cf); no strays, 41155/
  41157 free; owner relaunch loop restored FRESH (60 iterations, nv571
  shim) and awaiting handshake on 41151 at the HS-20 build. Logs:
  pup /tmp/hs20-host{V,V2,R}.log, Mac /tmp/hs20-client{V,V2,R}.log +
  /tmp/hs20-netem{V2,R}.log. **MORNING EYES (three findings):**
  (1) the Mac was screen-LOCKED all night — Keychain refused the
  client identity (OSStatus −25320), so the live legs ran `--host-key`
  with throwaway client statics (hosts not --require-paired; pairing
  store untouched), AND App Nap throttled wire-view into garbage
  evidence (first attempt: audio recentered 6,183×, delivery samples
  nonsense, estimator crashed to the floor pre-netem) until
  `NSAppSleepDisabled` was set for the run (deleted after — consider
  pinning it for scripted runs); (2) estimator anchor fragility,
  HS-16 territory: overuse falls anchor to the LAST raw delivery
  sample, and one garbage short-train sent a clean 20 Mbps path to
  810 kbps (V2) / straight to the 500 kbps floor (V1) in a single
  step — recovery is fast now that frames conform, but the anchor
  wants windowed-max robustness; (3) the QP-floor vs rate-floor
  mismatch, seen when the first attempt's degraded client pinned the
  loop at 1.5 fps: damage-accumulated 2048×1280 frames bottom out
  ~10.3 kB at nvenc's QP ceiling — no VBV can fit that into the
  500 kbps floor's 1,152 B ceiling, so the deep-floor rung eventually
  needs resolution/fps shedding (the H3 ladder's territory; VBV owns
  everything above ~1.5 Mbps and proved it).

- **HS-21 — Wave 0's last two debt rungs: the cookie dial goes live, and
  the overuse anchor stops trusting one sample** (`ede7d49`, Host/ only;
  Wire and root untouched at `5006c02`). **D-3 (cookie-mode escalation):**
  W8 landed the retry-cookie codec (0x13/0x14) and the client's answer
  path, but the HOST never escalated — no dial had ever drawn a 0x13.
  `HandshakeGate` grows a second posture beside the HS-9 token bucket:
  once the msg1 arrival rate crosses `cookieEnterThreshold` in a
  `floodWindowNS` (default 20 arrivals / 1 s) it flips to require-cookie
  mode, answering an un-cookied msg1 with a stateless `RetryChallenge`
  (one HMAC over source-tuple‖msg1‖now, a reply SMALLER than the request,
  no Noise, no per-client state); a client echoing a verifying cookie in a
  `RetryHandshake1` is admitted (the cookie is judged in EITHER posture,
  ahead of the bucket); the dial clears with hysteresis at
  `cookieExitThreshold` (default 5). OFF entirely without a `cookieSecret`,
  so the pure H1 posture — and every pre-HS-21 test — is byte-identical.
  `Session` decodes 0x05 vs 0x14, mints/verifies through the gate before
  any Noise allocation, and surfaces `handshakeCookieModeChanged` +
  `handshakeChallenged` as events; `SessionWire` logs them, `main` arms
  the dial behind `--require-cookie/--cookie-enter/--cookie-exit` (a fresh
  random secret per process, never persisted — secrets untouched). **The
  live leg found the real gap:** `awaitClient` never pumped, so a challenge
  enqueued into the pacer pre-establishment sat there forever (msg 2
  escapes later via the streaming service loop's pump, but a flood never
  establishes) — the fix is one pre-establishment `session.pump()` per
  await pass so the 0x13 actually leaves the box. **D-1 (overuse anchor):**
  pays HS-20 morning-eyes finding (2). The overuse fall anchored to the
  LAST raw delivery sample; one garbage short-train reading took a clean
  20 Mbps path to 810 kbps in a single step. The fall now anchors to the
  MEDIAN of the last `overuseAnchorSampleCount` raw samples (default 3):
  overuse fires on `overuseConsecutiveReports` (2) consecutive inflated
  reports, so by fire time two recent samples already reflect a genuine
  sustained drop and dominate a 3-median (a real squeeze falls exactly as
  the one-deep anchor did) while a lone outlier is outvoted 2-to-1 and
  cannot move it. Median, not windowed-max: a max would reject a low
  outlier but blunt a genuine sustained drop until the pre-drop samples
  age out. **Gate: Host 127 → 136/136 Mac AND pup** (7 CookieGateTests:
  no-secret-is-the-token-bucket, flip/clear hysteresis, bounded verifiable
  challenge, valid-admits/forged-stale-wrong-tuple-wrong-msg1-drops, plus
  the two Session-level legs — flood engages then a legit client
  establishes on one extra round trip, and the dial clears when pressure
  lifts; 2 RateEstimatorGateTests: a lone 2 Mbps sample at the overuse
  fire holds 17,000 kbps median-anchored to 20 Mbps where the one-deep
  anchor would have cratered to ~1,700 kbps, and a sustained 5 Mbps
  squeeze still falls — first fall 4,250 kbps = 0.85 × measured, 5 falls,
  settled 2,218 kbps). **LIVE (pup :41157, host `--require-cookie
  --cookie-enter 20 --cookie-exit 5 --backend mutter --input off
  --no-audio`, a single-tuple throwaway flood/handshake probe in
  `~/src/cookie-probe`, connected-socket model so flood and legit client
  share one tuple):** **connect leg** — 25 garbage msg1 at ~330/s flipped
  the dial ON (`FLOOD — require-cookie mode ENGAGED`), a legit real msg1
  drew a 0x13 (**challenge datagram 50 B vs msg1 datagram 122 B — SMALLER,
  no amplification**; cookie 24 B), the cookie echoed in a 0x14 was
  verified and the session came up — **7 cookies minted, 1 verified,
  0 rejected, one extra round trip**; **flip-back leg** — same flood
  engaged, then 1.5 s idle drained the window and one un-cookied msg1 was
  admitted STRAIGHT THROUGH (0x06 msg2, no challenge) with the host
  logging `pressure cleared — require-cookie mode DISENGAGED`. **Hygiene:**
  secrets shas byte-identical after (72860390…cfed / 8dc1f88a…55fd /
  dadf9a66…37cf); no netem touched; no strays (41157 free after); owner
  relaunch loop intact on 41151 (nv571 shim, pup un-rebooted); flood logs
  removed. **MORNING EYES:** (1) the connected-socket `awaitClient` adopts
  the FIRST source tuple, so the live proof necessarily ran flood + legit
  client from ONE tuple (the probe) — a two-source flood (attacker A,
  victim B) is NOT provable against the current host without an
  unconnected recvfrom listener; the sans-IO Session legs cover the
  distinct-tuple cookie binding, but a genuinely-separate-source live
  flood is future work if the threat model wants it. (2) The throwaway
  probe lives at `~/src/cookie-probe` on pup (like the hs1x-probes,
  outside the repo) — left in place; delete if reclaiming space.

- **CL-17 — the M7 audio remainder: WSOLA accelerate, the skew term,
  device-change survival** (`3a58fb6`, root only; Wire and Host
  untouched at `5006c02`). CL-11 bought silence-free playout with
  latency (~98–102 ms pipe p50 on this Wi-Fi path vs the ~40 ms
  target) because the only backlog tool was the counted content skip.
  **ACCELERATE:** `AudioAccelerator` (LyteTransport, sans-IO,
  pump-owned single-threaded) is the continuity doc's §5.2 as written
  — the NetEQ move in pure Swift: gather one op's working set
  (≤ 20 ms, held transiently and counted into the depth the receiver
  judges), find the best waveform period T ∈ [2.5, 10 ms] by
  normalized autocorrelation on a mono mixdown (stride-4 coarse
  sweep + ±3 refine), overlap-add x[0..T) into x[T..2T) under a
  raised-cosine ramp — T frames vanish on the waveform's own
  self-similarity, pitch preserved, everything outside the crossfade
  byte-exact. A token bucket accrues 5% of every input frame (capped
  at one period) so sustained speedup is bounded ≤5% of realtime;
  correlation < 0.5 DEFERS the cut (a transient is passing); silence
  on both sides of a lag counts perfectly self-similar (cutting
  silence is free), one-sided counts zero (never splice sound into
  quiet); disengaged is exact passthrough with zero added latency;
  `flush()` strands nothing. Engagement is the RECEIVER's verdict,
  mirroring CL-11's expand/normal seam: `AudioReceiver.pullDecision()`
  judges TOTAL depth (jitter buffer + gathered + the ring/render
  microseconds the pump reports back) with hysteresis — engage above
  target+slack, disengage at target — and `recenterIfOvergrown`
  RETREATS from target+slack to the 24-pkt hard cap, so the band
  between target and cap now belongs to the accelerator and the
  counted skip is blackout-only. **SKEW:** `retarget()` least-squares
  detrends the ~2.6 s skew window — the slope is the sender/receiver
  clock drift (`skewPartsPerMillion` on the books, clamped ±500), the
  spread comes from the RESIDUALS, so a drifting clock reads as ppm
  instead of inflating the target; the skew anchor went Int64
  (sender-fast drift underflowed the UInt64 re-anchor — found by the
  virtual-time gate, would have been a live crash); the target update
  gates on `started` so a prime survives the opening adaptation.
  **DEVICE:** LyteAudioPlayer observes AVAudioEngineConfigurationChange
  on a serial route queue and rebuilds the source-node graph around
  the UNTOUCHED ring (engine-lock guarded, restart retried; PLC and
  the ring cushion cover the seam), counted as
  routeChangesHandled/routeChangeFailures. **wire-view:** the audio
  line grew skew ppm + `accel N ops (−N ms, N engage)` + route
  counts; `--audio-prime N` (5–60 pkts) pre-loads the jitter target
  for drain legs; a latencyCritical+userInitiated NSActivity now pins
  App Nap for the process lifetime (HS-20 morning-eyes (1), the
  wire-view half — no more per-run NSAppSleepDisabled). Gate: root
  124 → **131/131 Mac** (1 skipped: the route-change leg needs real
  output hardware, XCTSkip headless) — AudioAccelerateGateTests: a
  440 Hz sine through a full drain stays phase-continuous (bounded
  sample step, zero-crossing cadence held, measured rate ≤5%);
  passthrough byte-exact + transient defers + silence cuts free;
  overfull-to-target drain in virtual time with NO skip and NO PLC;
  skew ±240 ppm converges with the target flat under pure drift;
  sender-fast drift absorbed by accelerate (0 recenters); drain-then-
  stall hands to PLC exactly-when-dry; build-cli.sh + make-app.sh
  release green. **LIVE (pup :41159, 150 s foreground wire-view
  --audio --audio-prime 20, host at committed HEAD + nv571 shim +
  --ratchet; logs /tmp/cl17-{client,host}D.log both ends):** **pipe
  p50/p99 39.9/132.5 ms where CL-11 measured ~98–102 p50** — the
  equilibrium accelerate was built to lower, lowered. 44,958 audio
  dg → 29,972 pkts, **accel 393 ops = −982 ms drained across 50
  engagements**, PLC 204 = 0.68% (late-arrival singles inside radio
  stalls — no storms), 10 recenters (−95 pkts, ALL inside
  multi-hundred-ms Wi-Fi blackout bursts that breached the hard cap:
  the designed blackout path), skew books −222 ppm at final, 63,550
  datagrams ALL ok / 0 unseal failures. The drain signature repeats
  the whole run: each ~15 s Wi-Fi scan stall spikes jitter σ to
  6–23 ms and the target to 20 pkts; recovery drops the target back
  to 5 and the accelerator works the pipe down — cleanest cycle
  **p50 75.3 → 36.0 ms** while ops climbed 96 → 151 with ZERO new
  PLC/recenters/underruns. Honest note: the 20-pkt PRIME itself was
  trimmed by the hard-cap recenter during AVAudioEngine startup
  (~1 s of arrivals stack before the DAC starts pulling), so the
  spike-recovery cycles are the drain evidence — better evidence
  anyway: real impairment, real recovery, no synthetic depth.
  **Hygiene:** secrets shas byte-identical (72860390…cfed /
  8dc1f88a…55fd / dadf9a66…37cf); 41159 free after; no strays;
  earlier legs A–C (locked-screen HAL refusal, a SIGPIPE harness
  bug, radio weather) logged at /tmp/cl17-{client,host}{A,B,C}.log.
  The owner relaunch loop on 41151 EXPIRED NATURALLY mid-slice
  (HS-20's 60 iterations × 120 s handshake timeout ≈ 2 h; last
  timeout logged 06:36, untouched by this worker) — restored fresh
  (60 × debug `--wire-listen 41151`, nv571 shim, same
  /tmp/lyte-host-session.log), awaiting handshake at the same static
  key. **MORNING EARS (three items):** (1) WSOLA quality on real
  content — the sine gate pins continuity/pitch/rate, but music and
  speech through a forced drain (`--audio-prime 30`, listen through
  the first minute) need human ears for warble or roughness at the
  5% cap; (2) AirPods/device swap mid-session — the rebuild is
  counter-proven and the XCTSkip leg runs on real hardware, but
  nobody has HEARD a swap yet (ring survives; PLC covers about one
  pump of seam); (3) this Mac's ~15 s Wi-Fi scan stalls under
  session load (runs A–D all show them) roughen ANY audio regardless
  of receiver behavior — an Ethernet or different-AP listen would
  separate path weather from receiver polish. Repeat of the HS-20
  caveat: the Mac was screen-LOCKED all night, so live legs ran
  `--host-key` with throwaway client statics (pairing store
  untouched), and CoreAudio's HAL refuses I/O while the display
  sleeps — `caffeinate -diu` was required for every audio leg.

- **CL-18 — strip ergonomics + host-muted-by-default** (`ae91be0`,
  root only; Wire and Host untouched at `af83571`'s upstreams). The
  owner's first real hand-test (the morning after CL-16 fixed the dead
  buttons) filed two wounds: (a) the strip revealed on ANY mouse
  motion and lived on the bottom edge, so aiming at the macOS Dock in
  fullscreen meant fighting the strip; (b) the two mute buttons were
  speaker-glyph twins — the owner muted the Mac meaning the host — and
  sessions started with the host playing out loud, the opposite of the
  Sunshine/Moonlight posture. **ERGONOMICS — the reveal is a verdict
  now:** `StripRevealPolicy` (LyteUI, sans-IO, nanosecond clock
  injected) replaces the CL-13 any-motion ping. The FEEL RULING,
  written down: reveal is earned by ~200 ms of continuous pointer
  presence (the middle of the owner-named 150–250 ms band) in a 90 pt
  zone hugging the strip's edge — a Dock-bound flick transits the zone
  in well under the dwell and reveals NOTHING; the stationary case
  (enter, stop) completes via the deadline tick, because no more move
  events is exactly what dwelling looks like. In fullscreen the last
  6 pt at the real screen edge are the SYSTEM'S: presence there never
  arms the dwell, and a push into it takes a visible strip down
  instantly — the push IS the Dock/menu-bar summon (macOS routes
  events to a summoned Dock regardless; this keeps the strip from
  visually squatting where the Dock lands). Leaving the window bounds
  (the windowed-mode Dock aim, below the window) hides instantly and
  cancels any pending dwell. CL-16's fade books hold — ~2 s idle,
  never while hovered, hover exit restamps — with one tightening:
  only ZONE activity restamps; working out in the video lets the
  strip fade away. Both the dwell (chosen over a pure geometric inset:
  an inset alone still traps a pointer that PAUSES near the edge en
  route; the dwell distinguishes intent by TIME, and the sliver keeps
  the summon pixels sacred on top) and every number are pinned in the
  new gate. **EDGE PREFERENCE:** app-wide `StripPreferences`
  (UserDefaults: `controlStripEdge` bottom|top, default bottom as
  shipped; garbage values fall back rather than wedge), togglable from
  the strip's own arrow button AND an Actions-menu Picker (@AppStorage
  both places — they cannot disagree); the reveal zone, the strip, its
  slide-in transition, and the FROZEN pill + stats overlays (which
  relocate to the opposite edge/corner) all follow it. **HIDDEN MODE:**
  `controlStripHidden` ("Hide Control Strip", menu-checkable) makes
  the policy inert — no reveal on hover, period; the Actions menu +
  shortcuts (⌘⇧M/⌘⇧H/⌘⇧C/⌘⌥I/⌘D) remain the full surface. The
  driver kept the CL-16 shape: the policy lives in a reference box
  (pointer-rate events invalidate no view), one standing task sleeps
  to `nextDeadline`, and only actual visibility flips touch @State;
  `LyteInputCapture.onActivity` grew edge geometry (distances from
  both edges + fullscreen), and the SwiftUI hover backup's `.ended`
  is the window-exit signal (mouseExited is outside the monitor's
  mask, so it fires even while the capture eats moves). **MUTE
  DISTINCTION:** the host button wears the `hifispeaker.fill` cabinet
  (a physical loudspeaker in the other room) with a tiny HOST caption;
  the local button wears `headphones` with MAC; muted is the same
  composed diagonal slash on both (SF Symbols ships no .slash variant
  for either glyph — one visual language for "silenced", two
  unmistakable machines). Tooltips name the machine ("Mute host
  speakers (pup)…" / "Mute playback on this Mac…"), and the menu
  retitled to match ("Mute Host Speakers" / "Mute Playback on This
  Mac", shortcuts unchanged). **THE DEFAULT FLIP (user-visible):**
  `LyteUdpSessionCoreConfig.desiredHostAudioRouting` now DEFAULTS to
  `.hostMuted` — an unconfigured session against a key-9 host sends
  exactly one [0x18 0x02] after the host's first 0x19. The per-host
  preference became the "start audible" opt-out read through ONE
  accessor (`PinnedHost.sessionStartHostAudioRouting`: nil/true →
  muted, explicit false → audible); MIGRATION IS BY CONSTRUCTION —
  CL-13's setters wrote only true-or-nil (false mapped to nil), so no
  existing pinned_hosts.json carries a false: stored trues keep their
  meaning verbatim, the freed false takes the opt-out meaning, and
  only the unset default flips. The setters now write BOTH directions
  explicitly (unchecking is an opt-out, not a reset); the
  "Start … with Host Muted" toggles (Actions menu + host-row context
  menu) read `!= false`, checked by default. Unnegotiated hosts:
  UNCHANGED — the ask only fires on the host's first 0x19, which a
  no-key-9 host never owes (no ask, host plays, nothing we can do);
  the 0x19-confirmed-posture rendering (strip button + menu check)
  is untouched. wire-view stays NEUTRAL unless `--host-audio` is
  passed (the debug-shell posture, deliberately assigned nil over the
  flipped default) so scripted gate runs keep their pre-CL-18 wire
  shape. **Gate: root 131 → 141/141 Mac** — new `LyteUITests` target
  (7 legs: transit-never-reveals, dwell moving/stationary/restarting,
  sliver-never-arms + same-distance-windowed-arms + visible-yields,
  window-exit hides + cancels, fade-anchors-to-zone-only +
  hover-pins/restamps, hidden-mode inert both directions, prefs
  round-trip + garbage fallback) + 3 CL-18 routing legs
  (fresh-config → one [0x18 0x02] vs an audible key-9 host;
  stored-audible opt-out quiet vs audible host AND one [0x18 0x01]
  vs a muted host — both directions; the tri-state mapping/migration
  pins incl. legacy-file decode and explicit-false JSON round-trip);
  CL-13's flip-round-trip leg keeps its no-ask shape via an explicit
  nil (the neutral posture is a deliberate fixture now, not the
  default). build-cli.sh + make-app.sh release green. **THE OWNER
  HAND-TEST CHECKLIST (supersedes CL-13 leg l):** (1) fullscreen,
  flick to the Dock — strip must NOT appear en route, Dock summons,
  clicks land on the Dock; (2) rest the pointer near the bottom edge
  ~a beat — strip reveals; move up into the video — it fades ~2 s
  later; (3) with the strip up, push into the very bottom edge — the
  strip yields instantly; (4) the strip's arrow button / Actions →
  Control Strip Position — strip jumps to the top edge, reveal zone
  follows, survives an app relaunch; (5) Actions → Hide Control
  Strip — no reveal anywhere, drive the session by menu + shortcuts;
  (6) the two mute buttons — HOST cabinet vs MAC headphones, captions
  and tooltips name the machine, ⌘⇧H flips pup's speakers and the
  icon follows the 0x19; (7) fresh connect to pup (key-9 host) with
  nothing configured — pup's speakers SILENT from the start, strip
  HOST button shows muted; uncheck "Start with Host Muted" in the
  host row / Actions menu — the NEXT connect starts audible; re-check
  — muted again. Deferred (named): the hover backup path reports
  isFullscreen=false (non-key windows are never the fullscreen front;
  the sliver rule rides the capture path — revisit only if a real
  session shows otherwise); the edge preference is app-wide by design
  (ergonomics, not per-host trust — the pinned store carries consent,
  not layout); strip v1 flat-capsule scope unchanged (CL-13's
  deferred polish rows); the wire-view neutral posture means the
  DEBUG shell never exercises the flipped default live — the app
  connect path is the flip's only live surface, which is exactly
  checklist item 7.

- **HS-22a — the Mac-local half of the quality hunt: clean paths keep
  the opening recipe, mild squeezes borrow windows, a ticking desktop
  never WAKE-pulses, and micro-trains lose their anchor vote**
  (`17810b8` Host / `36f1dce` root; Wire untouched — read-only this
  slice; pup UNREACHABLE the HS-22a session — **the live legs ran
  2026-07-27 late evening as HS-22b, verdicts at the end of this
  entry**). Recovered and finished the dead HS-22 worker's uncommitted
  tree (its quality books, client quality line, `--no-vbv-reconfigure`
  lever, and the estimator anchor gate — adopted, completed, pinned).
  **THE LOAD-BEARING FINDING (read from FFmpeg's nvenc wrapper, both
  master and 6.1): every rate/VBV reconfigure sets `resetEncoder = 1,
  forceIDR = 1`** — HS-20's "no IDR, no reset" belief was wrong (its
  header now says so). Every EncoderVbvPolicy directive costs an
  encoder reset + a full forced IDR at the newly capped budget, so
  clean-path directives are quality pulses by construction. Also read
  from the wrapper: reconfigure only honors `rc_buffer_size > 0` — a
  VBV once set can be resized but never REMOVED, so capped-CQ's no-VBV
  opening is inexpressible on the way back. **D-1 (the clean-path
  rule, the suspected regression owner):** HS-20 imposed vbv=8×C on
  capped-CQ at the FIRST look, clean path or not — every IDR/scene
  change quantized to the ceiling on a wire with headroom. Now the
  ceiling-derived rate (8×C/B) is judged against the recipe first:
  at/above (1 − deadband) × baselineMax (= 90% — the threshold IS the
  policy's own deadband, any engage is a ≥10% move by construction) ⇒
  CLEAN: zero directives, the opening recipe rides; below ⇒ the HS-20
  mapping engages with a MULTI-WINDOW VBV ladder — vbv = k×8×C, k =
  4/3/2 windows at ≥80/65/50% of the recipe rate, k = 1 below 50%
  (byte-identical to the posture that retired B2; a mild squeeze
  mostly needs the AVERAGE held, so an IDR may borrow adjacent budget
  windows the pacer absorbs). The squeeze→clean restore (rise-hold
  gated, deadband-bypassing) returns the recipe exactly — CBR
  bit-for-bit as pinned since HS-20; capped-CQ gets one second at the
  baseline cap, the nearest expressible "no VBV". **D-2 (the 1 Hz
  blur, the WAKE-ratchet pulse):** mechanism confirmed by
  construction: a desktop metronome (1 Hz clock, ~1 Hz cursor blink)
  ticks → ratchet converges ~0.5 s later → one-shot → IDLE → next
  beat's damage is the WAKE → machine demands a FULL-FRAME IDR →
  (post-HS-20) quantized to the ceiling → blur → ratchet re-sharpens →
  repeat, 1 Hz. The pillar's idle→active-restarts-with-an-IDR decision
  of record is UNTOUCHED (Wire unchanged): `Session` (HostWire) now
  holds the idle handoff until damage stays quiet for
  `idleFlipQuietNS` (3 s — three missed beats of the slowest common
  ticker); the machine hears `.ratchetConverged` from `advance` once
  the quiet holds, fresh damage drops the pending flip (never an
  aborted handoff), convergence with NO damage history flips
  immediately (every pre-HS-22 pin's shape — none needed edits). A
  ticking desktop now stays ACTIVE on small P-frames at near-idle
  bandwidth; a genuinely static one flips 3 s late. **D-3 (the
  estimator crater — the dead worker's live catch, adopted):** the
  HS-21 median promised a lone garbage sample cannot move the anchor,
  but the live clean-path crater showed a MAJORITY of the 3-sample
  window can be audio micro-trains (the 4+2 groups arrive as
  2–3-packet trains measuring their own ~1 Mbps pacing, not the path)
  — two of them anchored a fall from 17,000 to 709 kbps on a wire
  delivering 90 Mbps. Only trains ≥ `minTrainPackets` (8) vote on the
  anchor now; short trains keep feeding the ×0.5 windowed-max and
  evidence freshness. **INSTRUMENTATION (the live legs' eyes):** host
  Sink prints 1 s `quality:` books — nvenc frame-average QP (the
  packet's AV_PKT_DATA_QUALITY_STATS side data, already delivered per
  packet — no leaf change needed), frame-size p50/p95, the APPLIED
  encoder posture vs the opening recipe, live ceiling + pacer rate —
  and `--no-vbv-reconfigure` disarms the policy entirely (the A/B
  lever). Client: `LyteVideoPipeline` keeps a ~5 s decoded-frame
  window surfaced as fps/Mbps/frame-size percentiles — a `video` line
  in the ⌘⌥I overlay and a `quality:` line in wire-view stats (no new
  wire vocabulary; host QP stays host-log truth — read the two side by
  side). **Gates: Host 136 → 142/142 Mac** (clean-path capped-CQ
  silence over 100 looks; the clean/engaged boundary AT the deadband
  edge both sides; the k-ladder rungs exact at 85/70/54/42%; the
  capped-CQ restore posture + re-silence; convergence-after-damage
  held 400 ms→3 s then the ordinary flip; the 5-beat 1 Hz metronome —
  ACTIVE throughout, zero WAKE IDRs, zero mode traffic, IDLE 3 s after
  the ticker stops; the micro-train-majority anchor at 0.85×20 Mbps —
  and every HS-20 squeeze pin byte-identical: exact 5 Mbps mapping,
  floor never degenerate, CBR recovery bit-for-bit), **root 141 →
  142/142** (the quality window derives cadence/bitrate/percentiles
  in virtual time and forgets after ~5 s idle); build-cli.sh +
  make-app.sh release green; `swiftc -parse` clean on the Linux-only
  shell files (they have compiled NOWHERE yet — pup build first).
  **HS-22b — the live half, run 2026-07-27 late evening on pup's
  return (port 41163; nothing committed — no code changed, the legs
  were pure evidence). Shim status: the reboot healed the NVENC
  mismatch (userspace AND kernel 595.84, /tmp/nv571 gone with /tmp,
  NO runtime shim on any run tonight); the `~/.local` libxml2
  swift-compat BUILD shim still wraps swift build/test. The deployed
  loop binary turned out to be the DEAD WORKER'S uncommitted
  intermediate build (it answers `--no-vbv-reconfigure`; the
  /tmp/hs22-host{A,B}.log strays corroborate it ran live legs before
  pup went down), so the BEFORE panels were built honestly from a
  `git archive` of Host at `2bc2bec` (= 17810b8^; Wire byte-identical
  between there and HEAD) at `~/src/hs22b-pre` — left in place,
  cookie-probe precedent, delete to reclaim. Logs: pup
  /tmp/hs22b-*-host.log (+ the port-41163 netem helper
  /tmp/hs22b-netem.sh), Mac /tmp/hs22b-*-client.log.**
  (a) **PASSED** — rsync + build clean, Host suite **142/142 on pup**
      (the first Linux compile+green of everything since HS-21).
  (b) **PASSED with a sharpened claim** (150 s each, moves every
      250 ms, wire-view --audio). The clean-path silence holds
      EXACTLY as specified — zero directives while the
      ceiling-derived rate holds ≥ 90% of the recipe (every
      solid-20,000 stretch in every run rode `enc opening capped-cq`,
      QP avg 12, frames p50 ~9.5 kB vs the H2-era ~7.7 kB) — but
      tonight's Wi-Fi weather dipped the estimator BELOW the boundary
      a few times per run, and those engages are real and expensive:
      HEAD run 26 directives / 38 IDR, with the last dip feeding on
      itself down to the 500 kbps floor (finding (ii) in the RESTART
      block); the `--no-vbv-reconfigure` twin on the same weather (14
      overuse dips, deepest ~5.2 Mbps) self-healed every dip back to
      20,000 — 0 directives, 1 IDR, QP 12 FLAT. So the A/B sameness
      proof holds on the clean stretches and the DIFFERENCE below the
      boundary is the directive-IDR coupling, quantified. BEFORE
      (2bc2bec): **68 directives — the FIRST at the ceiling itself,
      the old clean-path imposition — 70 IDR (28/min)**, frame p95
      pulsing 8.3 → 39 kB on the clean wire: the old pulsing,
      reproduced and retired.
  (c) **PASSED** (6 Mbit video-scoped netem t+55→t+115 of 170 s,
      dsfield 0xa0 + dport 41163). Fall tracked (engage at pacer
      4,752 kbps → `applied max 3932 kbps vbv 12289 B`, k=1 at 48% —
      HS-20's posture byte-shape); frames CONFORMED under the
      squeezed ceilings (p50 7–9 kB at ceilings 12–16 kB, QP 35–43);
      the k-ladder is visible in the books on the way out — vbv = 2×,
      3×, 4× the ceiling (32116/65085/100772 B) as the fraction
      crossed 50/65/80% — and the restore carried the new one-second
      capped-CQ vbv (`max 10000 kbps vbv 1250000 B`) then went
      silent; a second knock repeated the same shape; **tail ended AT
      20,000 kbps CLEAN — the B2 signature stays retired**. The
      HS-20-era "p50 623 B" deep shape did NOT reproduce, and that is
      the ESTIMATOR improvement, not a regression: the median +
      min-train anchor stops the fall at ~4.8 Mbps (0.85× the
      shaper's true rate) instead of crashing to ~1.3 Mbps. 21
      directives / 22 IDR — the climb-ladder churn (finding (i)).
      **Mild band PASSED** (9.5 Mbit shaper under REAL 60 fps content
      — windowed ffplay testsrc2; fullscreen produced ZERO portal
      frames, Mutter direct-scanout, an environmental find worth
      remembering): heavy-content clean phase SILENT at 20,000 (60
      fps, QP 25–26, p50 ~20 kB); in-window the **k=4 posture is
      real** (vbv exactly 4× ceiling in the books, e.g. 110208 B @
      27552 B) with QP gentle at 26–28 near the band — no quality
      crater; deeper oscillations walked k=3/2/1 with QP to ~43;
      post-release full recovery to 20,000 @ 60 fps. Honest reading:
      offered load ≥ the shaper makes the estimator sawtooth
      1.8↔12 Mbps, and the climb ladder cost **105 directives / 119
      IDR in 150 s** — finding (i)'s strongest number.
  (d) **PASSED — the 1 Hz pulse is retired at the glass.** Static
      desktop, GNOME top-bar seconds ON (restored ON after). BEFORE
      (2bc2bec, 300 s): **183 IDR (36.6/min)**, 175 reconfigures, 38
      mode transitions, 3,214 ratchet frames, video wire 1.14 Mbps —
      the WAKE-ratchet merry-go-round, recorded. AFTER (HEAD,
      335 s): **3 IDR (0.5/min: the opening, the scripted input
      WAKE, one once-a-minute HH:MM redraw)**, 0 reconfigures, 5 mode
      transitions, ACTIVE on small P-frames (QP 12, p50 9.1 kB) for
      the whole 300 s ticking phase, video wire 0.43 Mbps; ticker
      gsettings'd off at t≈304 → converged one-shot + IDLE flip ~5 s
      later (the 3 s quiet + convergence); `rel 10 0` at t=312 →
      ACTIVE + IDR immediately (the decision of record, alive);
      re-idled ~6 s after.
  (e) **OPEN — the owner's eyeball** (the whole point): the host is
      up on 41151 at tonight's build; connect and judge vs the
      trip-era "moderate".
  (f) **PASSED** — secrets shas byte-identical start AND end
      (72860390…cfed / 8dc1f88a…55fd / dadf9a66…37cf); netem
      applied/removed per window, `noqueue` verified after each;
      no strays (ffplay killed, 41163 free); clock-show-seconds
      restored true; owner loop restored FRESH (60 iterations, **no
      shim** — drivers matched) and awaiting handshake on 41151 at
      the HS-22b-verified build. One self-inflicted stray killed
      mid-session: a backgrounded wire-view from a botched launch
      survived App-Nap-throttled and held local UDP 41163 into a
      later run (`bindFailed errno 48`) — foreground the client or
      setsid it, and `lsof -nP -iUDP:<port>` before launching.

- **W10 bulk channel** (`7455911`, Wire/ + docs/): the wire learns to
  carry freight — F-2, the H3 wave's long pole, landed Mac-local and
  frozen at birth so F-3 (host) and F-4 (client) code against bytes,
  never against each other. Design record
  `docs/20260728-053300-lyte-bulk-channel.md`; rulings: **chan 8**
  (`ChannelId.bulkTransfer`, reliableOrdered — its OWN ArqEndpoint
  pair, never the ctrl stream) under a **new priority rung `.bulk = 7`
  strictly below telemetry** (the 25–50 ms feedback reports price the
  path for every media class; a 100 MB file is infinitely patient
  where a stale report mis-prices audio/video — feature channels 9+
  keep `.feature` so interactive features never queue behind a file);
  message sextet **0x1C–0x21** offer/accept/chunk/ack/complete/abort
  (fixed-layout LE, accept/ack share the credit+chunk-map spine:
  contiguous prefix u64 + bitmap ≤1024 B, canonical, under-claiming
  legal); **capability key 11 `bulkTransfer`** on the W7 spine
  (`declaringBulkTransfer()`, frozen proof = wireDefault + `0B F5`);
  vocabulary direction-neutral, **v1 gates client→host at the ends**
  per §0 answer 1 — the host declares key 11 iff the standing consent
  toggle is ON, the client offers only into an agreed set, and Wire
  never sees the toggle. Chunks 4,096–131,072 B (default 65,536),
  **no transfer size ceiling by design** (u64-max total is pinned
  legal in the vectors); credit is receiver-driven, cumulative,
  chunk-denominated (grant = stored + window, default window 16 →
  1 MiB memory bound on BOTH ends, refresh at half-window, always
  once more at completion); resume = identity quadruple (id, size,
  sha-256, chunk size) + persisted possession map, any quadruple
  mismatch → abort(resumeMismatch), completion sha-exact by
  construction. WHAT F-3/F-4 DRIVE: `BulkSendEngine` (client) /
  `BulkReceiveEngine` (host) in LyteWire — sans-IO, NO timers (ARQ
  owns retransmission below, humans own consent above); shells answer
  actions (`emit` → chan-8 ARQ send; `readChunk` → `supplyChunk`;
  `store` → `chunkStored`/`storageFailed`; `verify` →
  `verificationResult`; `offered` → consent then `accept`/`decline`)
  and feed decoded stream messages to `ingest` (never throws — remote
  badness yields `.violated` + abort(protocolViolation); LOCAL API
  misuse throws, loud). The RECEIVING end owes persistence: write
  `BulkResumeState` (quadruple + name + possession) at teardown, seed
  `resumeBook:` at construction; the sender re-offers the same id and
  resumes from the accept's map. One transfer at a time per direction
  in v1 — a second concurrent offer draws abort(busy) from the ends'
  dispatcher (the id-carrying vocabulary is already shaped for v2
  multiplexing). VECTORS: new frozen `bulk-v1.json` (68: 63 message —
  every codec's roundtrips incl. the exact chunk/bitmap ceilings and
  the whole 7-reason abort space, all 16 `BulkMessageError` names as
  rejects; 3 key-11 spine pins; 2 worked multi-session TRANSFER
  traces — teardown-resume and holed-map resume — authored AND
  replayed by the same deterministic `BulkTransferHarness` in
  TestKit, which the ends can crib as the reference driving loop);
  vectorgen grew the `bulk` subcommand; regeneration verified
  byte-identical. Gate: Wire **402 → 450/450 Mac**, lint green,
  including the full composition — engines over REAL chan-8
  ArqEndpoints through SimNet at 20% loss/duplication/jitter landing
  100 chunks sha-exact, and a mid-flight blackout (everything
  volatile lost) resuming in a fresh world re-sending only the
  unconfirmed suffix. Deferred: the pup byte-exact leg for
  bulk-v1.json queues with the other H3 vector files (same ledger);
  chunk messages ride the ordered stream whole (17 B header +
  ≤128 KiB — default ArqConfig maxMessageByteCount 262,144 clears
  it; keep that headroom when the ends tune ARQ for chan 8).

- **Wire-v2 design study** (`deb788e`, docs only — full account in
  `docs/20260728-175200-lyte-wire-v2-study.md`): the H3 §0-answer-5
  deliverable. Twelve debts inventoried (keys 9/10/11 fold-ins, key-5
  featureChannels reconciliation, the av1=2 + Rext-tuple APPENDs,
  HS-16's ECN + receive-window wants, the TLV→fixed-envelope fold-in,
  WT datagram negotiate-down + transport binding, wireMinor
  bookkeeping). THE SPLIT: **zero items force a major** — 11 absorb
  via capability keys/appends/TLVs (the keys-9/10/11 fold-in is
  byte-invariant on the wire — vector-file version + minor only;
  negotiate-down needs a NEW key because key 8's frozen 1152 floor
  rejects lower; ECN + rwnd ride the feedback report's TLV escape
  hatch with 77 B headroom), and the TLV fold-in is v2-reserved but
  never v2-forcing. Flagged: v1 handshake has NO downgrade path
  (hard versionMismatch) — acceptable LAN-first; a discovery-TXT
  major list is the prerequisite IF v2 ever goes. VERDICT: **no-go
  at every horizon, never-unless** (forcing functions named: AEAD
  migration, envelope layout break, TLV overhead proven costly);
  §6 pre-writes the batch so a future v2 ships everything once.

- **Video supremacy plan** (`557ab78`, docs only — full account in
  `docs/20260728-165538-lyte-video-supremacy-plan.md`): the ranked
  ladder vs Sunshine/Moonlight. Verdict: losses are POLICY+ROADMAP,
  never architecture — behind on exactly (1) the 20 Mbps recipe cap
  (38 fps motion on a 90 Mbps wire), (2) the armed policy's IDR bill
  (110-vs-3), (3) 4:4:4 (Sunshine ships it; our pillar planned it) +
  a FOUND BUG: `bgr0` into NVENC with NO colorspace/range VUI set
  anywhere (smeared-desktop class, few-line fix, "Stage A"). Ranked:
  R1 HS-22c (restore-only climb coalescing + estimator self-ref gate,
  bar = armed within ≤3 IDR of disarmed twin) → R2 LAN cap 50 Mbps
  (HS-23, ≥55 fps gate) → R3 4:4:4 Work mode + immediate Stage A
  (Apple Silicon hw-decodes Rext 4:4:4; Moonlight's falls to sw) →
  R4 encoder A/B ladder off Sunshine's p1 floor (p4, AQ; keep
  no-B/no-lookahead) → R5 beauty-bar standing gate (two rows fail
  today: fps + IDR/min — exactly the two losses). AV1 stays a browser
  play (Ada AV1 is 4:2:0-only, M1/M2 can't decode it). **All five
  owner decisions ANSWERED (2026-07-28 ~11:40), every recommendation
  confirmed**: (1) LAN ceiling **50 Mbps** (HS-23's number); (2) NO
  desktop/motion recipe split now — the split arrives as
  Work(4:4:4)/Play(4:2:0) with H4; (3) **finish H3 first, 4:4:4
  LEADS H4** (owner note: Sunshine's Linux 4:4:4 is still unreleased
  master — we intend to ship before they do); (4) preset adoption
  bar BLESSED (flags adopted only on measured PSNR-at-bitrate gain,
  fps + input→photon held); (5) 10-bit deferral REAFFIRMED (after
  4:4:4 converges). Owner hardware note for codec planning: the
  client Mac is an **Apple M5** (AV1 hw decode present) — AV1
  remains a browser play regardless, per the 4:4:4-needs-HEVC
  argument. QUEUE after HS-22c frees Host territory: the F-3/F-4
  JOINT live gate (drag-and-drop Mac→pup, legs listed in the F-4
  entry) → HS-23 (50 Mbps cap, ≥55 fps gate).

- **Video quality probe** (`ca0172a`, docs only — full account in
  `docs/20260728-164746-lyte-video-quality-probe.md`): PSNR at the
  post-HS-22b build — static converges **53.5 dB luma** (gate ≥ 50,
  opening IDR 44.0 vs the old 38.6), motion 56.1–57.5 dB, static
  time-series FLAT (no 1 Hz ghost); wire drops nothing (0.02% loss all
  healed, 5,692 emitted → 5,689 decoded + 2 NACK-repaired). The
  remaining supply-side story, A/B-quantified for **HS-22c**: heavy
  motion at QP 17 wants ~24 Mbps > the 20 Mbps recipe so fps plateaus
  ~38 smooth (not 60), and the ARMED policy spent 105 directives /
  110 IDR (44/min, QP p95 47, one 500 kbps-floor crash) in 150 s where
  the `--no-vbv-reconfigure` twin spent 0/3 at QP 17 FLAT — findings
  (i)/(ii) now have hard numbers; owner's eyeball still owed on
  whether 38 fps heavy motion reads as choppy.

- **B-1 wasm attestation leg** (`51c058c`, Wire/): the overnight probe
  becomes a repeatable check — `Wire/Scripts/wasm-test.sh` cross-builds
  the whole Wire suite for wasm32-unknown-wasip1 (swiftly 6.3.3 +
  swift-6.3.3-RELEASE_wasm SDK, located never auto-installed; missing
  pieces fail with the scoping doc's exact install commands) and drives
  the .xctest module directly under wasmtime (SwiftPM's `swift test`
  can't run XCTest on WASI), with the package root resolved physically
  so the macOS /tmp-symlink preopen quirk can't bite. The one repo
  change the target needed: `#if !os(WASI)` around
  NoFoundationLintTests (WASI has no Process; the source-text lint
  keeps running fully on macOS/Linux). PROVEN AT HEAD, W10 included:
  **448/448 under wasmtime 47.0.2, 23.5 s** (450 native minus the two
  guarded lint tests) — all 14 frozen vector files byte-exact,
  bulk-v1.json and the SimNet loss compositions among them; native
  suite untouched at **450/450**. Vectors/README.md now names wasm as
  the third attested platform. Owner answered B/C/D (2026-07-28
  morning: codec [hevc, av1]; self-minted rotating cert, host serves
  the page; cut line after B-4) and deferred A (QUIC posture) along
  with all B-2+ work until F-3/F-4 land — browser sessions are
  sequenced BEHIND file transfer by owner direction.

- **JOINT-GATE — file transfer (F-3×F-4) and roaming (F-5) live legs,
  ten-leg union DRAINED** (live run 2026-07-28 afternoon; one REAL bug
  found and fixed: `fea9149`, Host/). HOW IT RAN: a headless harness
  (`jgbulk`, /tmp-only, not committed) links the REAL client stack —
  `LyteUdpSession` + `BulkSendCoordinator` + `RoamingPolicy` +
  `NetworkPathWatcher` wired exactly in `ConnectionModel`'s shape
  (detach-then-dial, manualReconnect, sessionReady re-offer) — so
  every leg below exercised the shipped transport/policy code;
  only the literal AppKit drag/UI is out of its reach (eyeball items
  ledgered OWNER-PENDING). Host instances: port 41168, bwrap-isolated
  temp home (fresh throwaway identity; owner's identity/config never
  touched), relaunch loop, `--backend mutter --accept-files`.
  pup suite **161/161** (post-fix, re-verified post-reboot), root
  **162/162**, builds green. MID-SESSION ENVIRONMENT FACT: pup was
  rebooted (owner-initiated, ~14:03) under a standing leg — the host
  sent a typed teardown on SIGTERM and the client ended cleanly
  (peerTeardown(shuttingDown) at the glass); /tmp infra rebuilt,
  no verdict affected. VERDICTS (a–j):
  • **(a) toggle ON — PASS**: 12,582,912 B random file client→host,
    sha-exact both ends (`3843ffc4…`), 192 chunks over chan 8,
    ~103 s ≈ 1.0 Mbps effective under the host's 4 Mbps wire cap —
    Wi-Fi-shaped (see the wire note below). The real mouse drag at
    the glass is the one OWNER-PENDING sub-leg (drop any file on the
    stream window, toggle ON).
  • **(b) toggle OFF — PASS**: no `--accept-files` → key 11
    undeclared, agreed bulkTransfer=false, drop verdict
    hostNotAccepting (the "Host isn't accepting files" path), and
    `sendBulkMessage` refuses with notNegotiated.
  • **(c) mid-transfer session kill — PASS**: killed at 42% (typed
    goodbye), re-dial 1.4 s, same-id re-offer → host accepts
    RESUMING with possession prefix=96 chunks; exactly the
    8,388,608 B gap re-sent; sha-exact.
  • **(d) cancel mid-flight — PASS**: cancel at 41% (81 chunks /
    5.3 MB stored) → host logs abort(cancelled, remote) and the
    landing dir ends with zero .part/.resume strays.
  • **(e) second offer while active — PASS**: hand-crafted concurrent
    offer mid-flight → host refuses busy, client sees abort(busy),
    the first transfer completes undisturbed sha-exact (`e992a1d4…`).
  • **(f) host IP flip under a standing session — PASS.** THE FLIP
    (documented for reuse; ssh and the owner's 41151 both untouched):
    alias `10.0.0.250/24` on wlp0s20f3 + one nft DNAT rule scoped to
    udp dport 41168 (`ip daddr .250 dnat to .249`) makes the host
    wholly dial-able at .250; the flip is alias-del + table-del +
    `conntrack -D --orig-port-dst 41168` (the entry KEEPS applying
    NAT after rule deletion otherwise — first attempt proved it by
    surviving 80 s unharmed) + a scoped output drop of the old
    flow's client port. Client froze ~0.5 s post-flip, searching at
    silent+3.06 s, sighted the same pkh at .249, NEW-address rung
    dialed on sight (no hold), established in 17 ms —
    **flip→reattached ≈ 5.1 s**. Wire fact worth keeping: the
    client's receive path is source-agnostic (video from a new
    source address feeds the same session), so the client-visible
    outage is driven by the HOST letting go — here the old process
    exited fast on send errors (EPERM from the drop; a real flip's
    EADDRNOTAVAIL behaves the same), loop relaunched, fresh process
    answered.
  • **(g) same flip mid-bulk-transfer — PASS**: flip at 29% of a
    12,582,912 B send → roam ≈ 5.1 s as above → same-id re-offer →
    host accepts RESUMING with possession prefix=56, exactly the
    136-chunk / 8,912,896 B gap re-sent, COMPLETE sha-verified
    (`22f00c6a…`, host counter "1 resumes loaded"). Note: resume
    state survived the host's ERROR-path exit, not just graceful
    teardown — the possession map arbitrated across a hard death.
  • **(h) host-process restart, same address — PASS after a REAL BUG
    fixed (`fea9149`, Host/)**: pre-fix this leg FAILS
    deterministically — `awaitClient` latched (connect()ed the
    socket + pinned the session tuple) onto the FIRST datagram the
    reborn host saw, which under a live client is the dead session's
    sealed feedback spray from the OLD source port; the kernel then
    filters every real re-dial (tcpdump: 15/15 message 1s reached
    the interface, 0 reached the demux; ~200 notEstablished(3)
    drops; 120 s handshake windows burned serially). The fix latches
    only on a datagram SHAPED like a handshake initiation (bare CTRL
    typed 0x05/0x14; admission/cookies/Noise still judge the bytes).
    Post-fix, live: silent→searching 3.05 s, the **8 s same-address
    hold honored** (dial at silent+8.05 s), handshake ~30 ms, first
    attempt. Suite 161/161 both platforms.
  • **(i) Mac-side network change — OWNER-PENDING (the live hop);
    everything around it ran.** Not cleanly simulable on this Mac:
    NWPathMonitor's interface-set signature only moves for a REAL
    usable network — a routed feth pair and a Thunderbolt-Bridge
    service toggle both produced ZERO path events (negative control:
    the harness ran the real NetworkPathWatcher live, no false
    positives), and the only real interface is the owner's Wi-Fi.
    The pathChanged policy semantics (healthy grace / silent
    escalate / same-address-hold waiver) are pinned in
    RoamingClientGateTests. OWNER STEPS: app connected, session
    healthy → join a different Wi-Fi network (or plug USB-Ethernet)
    mid-session → expect HS-12 migration inside the 3 s grace with
    no re-dial; then a hop that defeats migration → FROZEN at 2.5 s
    → immediate scan (no 3 s wait) → re-dial with the hold waived;
    reattach within ~5 s of silence.
  • **(j) give-up posture — PASS** (host down 2.5 min, then back):
    liveness close at silent+29.7 s; banner honest throughout
    ("Connection lost — looking for jg-host…", "Reconnecting to
    jg-host at 10.0.0.249…"); **scan cadence settles at the 15 s
    cap** (steady state = 15 s idle between browses + the 2 s browse
    itself) and blind probe dials settle at the **30 s cap** (+ the
    2.1 s dial window); NO give-up across the window. **Manual
    Reconnect (the ⌘R verb) acted in 0.1 ms** — dial fired
    immediately AND both ladders reset (next auto-dial 4.2 s later,
    floor cadence again). Host restored → next scan sighted it →
    reattached in 24 ms, passively. (Disconnect-mid-hunt is a UI
    verb — eyeball it with (a)'s drag.)
  THE WIRE NOTE (for HS-23): this Wi-Fi path bulk-measures
  ~150 Mbps (6E), but real-time delivery sees micro-stalls — bulk
  chunks under the 4 Mbps host cap delivered ~1.0 Mbps effective
  with stall-shaped ack gaps (worst observed 19 s between ack
  bursts in leg (g)); roam timings themselves were NOT Wi-Fi-bound
  (5 s flips, 30 ms handshakes). File-transfer throughput on this
  path is Wi-Fi-shaped, not protocol-bound — say so wherever HS-23
  picks up the thread. CAVEATS, honestly: legs rode the harness,
  not the app window — the real drag (a), drag-during-captured-input
  sanity (F-4's list), Disconnect-mid-hunt (j), and banners AT THE
  GLASS remain the owner's five-minute eyeball; the no-re-PIN
  assertion of the F-5 list wasn't exercised (throwaway statics, no
  pairing in the harness) though `paired_clients` is verified
  untouched. HYGIENE: netem none (root qdiscs `noqueue` verified);
  alias/nft/conntrack/feth all removed and re-verified empty;
  Thunderbolt Bridge service re-enabled; secrets byte-identical
  (portal_token `dadf9a66…37cf`, noise_static.key `72860390…cfed`,
  paired_clients `8dc1f88a…55fd`); all 41168 instances and the loop
  dead at close; the owner's 41151 loop alive (post-reboot restart,
  coordinator-owned).

- **F-4 client file-drop sending end** (`d771e22`, root): a dropped
  file finds its way to the wire — the client half of drag-and-drop,
  Mac-local against W10's frozen bytes, NO live leg (F-3 built in
  parallel; the joint gate below). TRANSPORT:
  `ReliableCtrlEndpoint` made channel-generic (a `ChannelId`
  parameter, ctrl default) so **chan 8 runs its OWN ArqEndpoint pair**
  in `LyteUdpSessionCore` (`bulkReliable`), started/stopped/ticked
  beside ctrl and borrowing the ctrl-learned connection ID
  (`adoptConnectionId`) so the FIRST bulk datagram is already tagged;
  key 11 declared in the core default config (dialect, not consent —
  the key-9/10 rule, third verse); `sendBulkMessage` refuses without
  agreed key 11 (`BulkChannelError.notNegotiated`), inbound chan-8
  deliveries decode → `.bulkMessageReceived` event, unnegotiated or
  malformed drops loud (`bulkDropsLoud`). `BulkSendShell`
  (Sources/LyteTransport) answers the sans-IO engine: reads on a
  utility queue via `BulkFileChunkReader`, `BulkFilePreparer` builds
  the offer (streaming sha-256 through swift-crypto, name clamped to
  the 255-byte UTF-8 wire bound, MIME hint from UTType), progress =
  confirmed possession bytes / total. `BulkSendCoordinator` holds the
  policy: **QUEUE RULING — multi-file drops queue and send SERIALLY**
  (one transfer at a time, v1's wire shape; nothing declined, the
  pill shows "+N queued"); cancel (× or menu) aborts the active
  transfer AND clears the queue; entries persist for the session's
  lifetime across teardowns — the next `sessionReady` **re-offers the
  SAME id** and resumes from the accept's possession map (only the
  gap is read/sent); `abort(resumeMismatch)` draws exactly ONE
  fresh-id re-preparation. UI (ConnectionModel + ControlStrip +
  LyteCommands): the stream container is the drop target
  (`.onDrop` of `.fileURL`), a drag lights a hint overlay — "Drop to
  send" when key 11 agreed, **"Host isn't accepting files" when
  not** (spoken, never silent; same notice on an attempted drop);
  progress rides a bottom-corner pill (name, phase, %, queue depth,
  cancel ×) opposite the strip, transient notices ("sent",
  "declined", failures) fade after ~4 s; Actions menu grew "Cancel
  File Transfer". DROP/CAPTURE VERDICT: **structural coexistence** —
  drag sessions ride NSDraggingDestination (SwiftUI `.onDrop`), a
  path CL-16's capture never touches (the NSEvent monitor mask has
  no drag events; `landsOnOverlay` hit-tests clicks, not drags), so
  a drag cannot fight the capture geometry by construction;
  hand-verify at the joint gate. GATE: root suite **142 → 153/153**
  (`BulkSendClientGateTests`, 11 legs: key-11 spine pin, preparer
  against a real temp file, progress arithmetic, shell happy/cancel
  against a REAL BulkReceiveEngine in virtual time, coordinator
  gating/serial-queue/teardown-resume/mismatch-retry, and two
  in-vivo legs through the REAL session core against a scripted
  key-11 host — offer + 64 KiB chunk byte-exact over chan 8's own
  ARQ through Noise sealing, rule-3 refusal + hostile-message loud
  drop against a no-key-11 host); build-cli.sh + make-app.sh release
  green. WHAT THE JOINT GATE NEEDS (J-G3a-style, once F-3 lands):
  host toggle ON → real drag Mac→host lands sha-exact in the host's
  landing dir; toggle OFF → key 11 undeclared and the client speaks
  "host isn't accepting files"; mid-transfer session kill →
  reconnect resumes the same id from the possession map; cancel ×
  mid-flight → host sees abort(cancelled) and cleans its partial;
  drag-during-captured-input sanity (the structural claim above,
  verified at the glass).

- **F-3 host file-drop receiving end** (`66695e5`, Host/): the host
  learns to receive files — the host half of drag-and-drop, built in
  parallel with F-4 against W10's frozen bytes, NO live leg (the joint
  gate below). CONSENT/FLAG SURFACE (what F-4 and the joint gate point
  at): **`--accept-files[=DIR]`** on lyte-host — standing per-host
  toggle, OFF by default; drop dir defaults to `~/Downloads`, created
  if missing; **key 11 is declared iff the toggle is ON AND the drop
  dir came up** (a failed dir prints loud and truthfully negotiates no
  file transfer). Toggle OFF = no chan-8 machinery at all: Session
  builds no bulk ArqEndpoint, inbound chan-8 drops loud
  (`.dropped(.bulkNotNegotiated)`), `sendBulk` throws. TRANSPORT:
  Session grows chan 8's OWN `ArqEndpoint` beside ctrl (same clamped
  config — the 262,144 B message budget clears a max chunk with 2×
  headroom), deliveries decode → `.bulkMessageReceived`, replies ride
  `sendBulk`; new pacer rung **`PacerClass.bulk` (CS1, 0x20), strictly
  below telemetry**, mapped to `.bulkTransfer` for the estimator.
  SHELL (`BulkReceiveShell` + `BulkFileStore` in HostWire, POSIX, no
  Foundation): consent = the shell existing; disk verdicts answer the
  engine — pwrite+fsync into dotted `.lyte-bulk-<16hex>.part` at exact
  offsets (fsync-BEFORE-ack, so persisted possession never lies),
  streaming sha-256 (`Sha256Stream`, FIPS-pinned) at the finish,
  promotion by fsync-then-rename + dir fsync under a SANITIZED
  collision-numbered name (`BulkFileNaming`: last path component only,
  control bytes stripped, no dotfiles, 200-byte budget keeping the
  extension, "name (N).ext" numbering); offers past free space
  (statvfs, resume charged only for its gap) refuse up front with
  abort(storageFailure); **second concurrent offer → abort(busy) from
  the dispatcher**, engine untouched. RESUME: teardown persists
  `BulkResumeState` as `.lyte-bulk-<16hex>.resume` beside the .part
  (LBR1 fixed-layout LE codec, atomic tmp+fsync+rename; torn records
  are weather — unlinked, the digest arbitrates); construction loads
  the book, matched re-offers resume the gap sha-exact; a mid-flight
  WRITE failure also persists possession before aborting, so a
  recovered disk resumes. lyte-host wiring: chan-8 messages buffer
  under the session lock, the shell runs on SessionWire's off-lock
  service pass (the clipboard pattern), stats grew a `files:` line.
  GATE: Host suite **142 → 153/153 BOTH platforms** (Mac + pup;
  `BulkReceiveGateTests`, 11 legs: happy path byte-exact to a real
  dir with zero strays, teardown-resume, 16-row hostile-name table,
  LBR1 byte pins + hostile decode, FIPS sha vectors + split-boundary
  streaming, busy, both storage-failure paths, key-11 spine `0B F5`
  mutual-only, rule-3 in vivo, full drop through a REAL Session pair
  over sealed chan-8 ARQ); `swiftc -parse` clean on the Linux-only
  files; **bulk-v1.json replays byte-exact on pup** (5/5). pup
  hygiene: secrets shas identical start/end, no strays, 41151 quiet
  throughout (an owner run on 41166 appeared mid-visit; untouched).
  THE JOINT GATE (with F-4, separate later leg): see F-4's list —
  host side arms with `--accept-files` (or `=DIR` for a scratch
  landing dir), one transfer at a time, busy is the answer to a
  second sender.

- **F-5 client roaming — the hotel move stops being an ending**
  (`dd47a70`, root + `docs/20260728-121500-f5-client-roaming.md`):
  the client half of roaming/reconnect — the host re-addressing under
  a standing session (the trip's "No hosts found" over a frozen
  frame) and the Mac hopping Wi-Fi both resolve to the same machine.
  THE IDEA: the Noise static IS the identity (advertisement TXT `pkh`
  = the pinned store's key); the address is a dial hint. DETECTION
  (`RoamingPolicy`, sans-IO struct in the SessionStateMachine
  discipline — injected `now`, actions out, `nextDeadline` drives one
  standing task): FROZEN starts the silence clock (the CL-8 pill owns
  that tier); **3 s** of silence begins the QUIET re-browse (evidence
  returning cancels everything, ladders reset); same pkh at a NEW
  address = host moved, dial on sight; same pkh at the SAME address
  waits out an **8 s** hold (beats the 30 s liveness close, ignores
  Wi-Fi weather); the liveness close flips to full roaming — scans
  backing off **1 → 15 s**, blind probe dials of the last-known
  address (mDNS-less networks have nothing to sight) backing off
  **2 → 30 s**, every deadline strictly future, NO give-up (passive
  forever; Disconnect is the exit). PATH CHANGES: `NetworkPathWatcher`
  (NWPathMonitor → interface-set/satisfiability signature; baseline
  never fires) grants a **3 s grace** so HS-12 migration gets first
  refusal — deliberately past the 2.5 s detector so a dead path is
  observably FROZEN at expiry — then the same ladder with the
  same-address hold WAIVED (our own address moved; the fresh
  handshake is the mechanism when migration didn't carry).
  RE-ACQUISITION (ConnectionModel as driver): `detachWireSession`
  keeps the window and everything per-host — live clipboard consent,
  confirmed audio posture (both seeded into the re-dial config), the
  input capture (sends route through `lyteSession` LIVE now — drop
  while nil, resume on swap, no reinstall), the F-4 coordinator
  (whose `sessionReady` re-offer is exactly what makes a mid-transfer
  roam finish sha-exact) — and a `sessionEpoch` counter kills stale
  events from detached sessions; `runRoamingDial` = fresh 1-RTT IK
  against the SAME pinned static (3 × 700 ms — a host still holding
  the dead session answers with silence; the ladder retries, don't
  camp), **same pairing, no re-PIN by construction**;
  `adoptReconnectedSession` refreshes the pin's dial hints
  (identity-keyed; pairedAt + preferences survive verbatim). UX: the
  pill is tiered — blip keeps CL-8's "Connection interrupted…", past
  the thresholds the banner speaks ("Connection lost — looking for
  pup…", "pup found at 10.9.9.9 — reconnecting…", "Reconnecting to
  pup at …" for blind probes); Actions menu grew **Reconnect (⌘R)**
  (ladders reset, acts NOW), Disconnect stays enabled during a hunt.
  GATE: root suite **153 → 162/162** (`RoamingClientGateTests`, 9
  legs, virtual time throughout: threshold + evidence-cancel,
  new-address dial + foreign-pkh inertness, same-address hold vs
  dead-session shortcut, both backoff ladders' arithmetic + caps,
  path-grace heal/escalate/waiver, manual-reconnect reset,
  pinned-store identity keying, banner lines + path trigger rule, and
  END TO END through the REAL session core: mid-transfer blackout at
  address A → FROZEN at the 2.5 s detector → liveness close at 30 s →
  sighting at B → dial → same-id re-offer → sha-exact resume reading
  chunks 2…7 only); build-cli.sh + make-app.sh release green.
  **DEFERRED-PENDING-HOST — the F-5 live legs** (joint window; pup
  was HS-22c territory this session, NO pup access):
  (a) host IP flip under a standing session — add a second address on
      pup's NIC (`ip addr add`), restart avahi advertisement there,
      drop the old one; client must banner "looking for", sight the
      same pkh, re-dial, resume WITHOUT re-PIN; verify
      `paired_clients`/`noise_static.key` untouched;
  (b) same flip mid-bulk-transfer — a multi-MB drop in flight through
      the move completes sha-exact in the host's landing dir, only
      the gap re-sent (the possession map arbitrates);
  (c) Mac Wi-Fi hop, host stays put — flip the Mac between two
      networks/interfaces mid-session; HS-12 migration should carry
      it inside the 3 s grace with NO re-dial (assert via host
      PathValidator logs), then a hop that defeats migration (source
      truly unreachable) roams through the ladder;
  (d) host-process restart at the SAME address — kill lyte-host
      mid-session (relaunch loop brings it back); the 8 s
      same-address rung re-dials without human help;
  (e) the give-up posture at the glass — host down 5+ min: banner
      stays honest, scan cadence visibly settles at the 15 s ceiling
      (no hot spin in Activity Monitor), Reconnect still works, and
      Disconnect exits cleanly mid-hunt.
  THE HOST HALF (F-5's other side, Host territory): the busy/takeover
  story — a re-dial from the SAME client identity against a host
  still holding the dead session should free it faster than the
  host's own 30 s liveness verdict (today the client's ladder simply
  outwaits it — correct, but slower than it could be).

- **HS-22c — the armed policy learns to climb quietly, and the wire
  stops lying about its colors** (`b251181`, Host/): the supremacy
  plan's R1 + R3 Stage A, closing HS-22b's findings (i)/(ii).
  FINDING (i), THE COALESCED CLIMB — **doubling rungs**, chosen over
  both alternatives on live evidence: inside a squeeze a loosening
  emits ONLY when the squeezed cap can at least DOUBLE what is
  applied (rise-hold gated); everything finer waits for the one
  squeeze→clean restore (recipe exactly, capped-CQ's
  one-second-at-cap VBV intact). The old deadband ladder paid ~1
  directive-IDR/s across every climb (the probe's 105/150 s); pure
  RESTORE-ONLY (the plan's first sketch) was landed first and
  MEASURED: after a floor-deep dip the encoder sat at QP ~40 mud for
  the whole ~37 s climb — 78 of 155 s below the recipe posture.
  Doubling rungs keep shallow episodes exactly restore-only (a ≥50%
  dip can never double before the clean boundary: one down, one
  restore, zero mid-climb IDRs) while a floor-deep recovery pays
  ⌈log₂(recipe/floor)⌉ ≤ ~6 stepped loosenings, each halving the mud.
  Falls, deadband, k-ladder engage: byte-identical to HS-20/22 — only
  the climb coalesces. Seen live: applied 368 kbps, first mid-climb
  loosening at exactly 738 kbps.
  FINDING (ii), THE SELF-REFERENCE GATE (RateEstimator): an overuse
  fall HOLDS when the measured delivery sits within 15% of the
  standing pacer rate WHILE the pacer holds a standing backlog
  (Session now feeds `pacerBacklogBytes` = freshVideo+videoTail
  queued bytes into `ingest` — the geometry where ≥8-packet trains
  measure our own pacing, the probe's 20000→500 kbps spiral on an
  unimpaired path), UNLESS the path corroborates: loss ≥ the clean
  threshold, any post-FEC evidence, or queue-delay inflation GROWING
  across the backlog window. Why it can't mask real degradation: a
  genuine squeeze near the pacer rate grows the queue (growth IS the
  corroboration — pinned); a genuine deep dip measures well below the
  band and falls to measured delivery as ever (pinned); loss falls
  are never gated (pinned). `selfReferenceHolds` rides the estimator
  stats line. Suite **153 → 161/161 on BOTH platforms** (4 estimator
  pins + the reshaped/new climb pins, all virtual-time).
  R3 STAGE A, COLORSPACE (CHevcEncode/encode.c, a few lines on the
  context): the bgr0→NVENC stream carried NO VUI — decoders guessed.
  Now signaled: `color_primaries=BT709`,
  `color_trc=IEC61966_2_1` (sRGB — desktop content),
  `colorspace=BT470BG`, `color_range=MPEG`. The 601-limited pair is
  MEASURED truth, not preference: A/B decodes of a live capture
  against the raw bgr0 reference showed nvenc's RGB path forces
  BT.601 limited-range conversion regardless of context settings
  (PSNR 41.7 dB decoded as 601-tv, 40.0 as 709-tv, ~26 as either
  full-range read — limited is unambiguous, and the 601-over-709
  margin is the matrix). ffprobe on the
  landed build: `bt709 / iec61966-2-1 / bt470bg / tv`. CLIENT SIDE —
  NO root change needed: VideoRenderFactory builds its
  CMVideoFormatDescription from the in-band VPS/SPS/PPS with
  `extensions: nil`, so CoreMedia lifts the VUI into the format
  description and VideoToolbox/the layer honor it end to end.
  THE LIVE GATE (pup, port 41167, testsrc2 1600×1000@60 window,
  150 s heavy motion, 20 Mbps recipe; netem video-scoped to 41167 and
  removed — root qdisc verified `noqueue` after; secrets shas
  identical start/end; the owner's 41151 loop untouched and alive,
  its relaunch cycle picking up the new build on its own):
  • **Leg (a) armed**: 6885 frames (44.5 fps at the glass), **36 IDR
    (14/min), 34 directives**, QP p50 29 / p95 47; 18 downshifts (0
    loss, 3 self-ref holds), final 13.2 Mbps, regime CLEAN (5 stale
    NACKs, 11 post-FEC, 2 IDR requests all run).
  • **Leg (a) twin** (`--no-vbv-reconfigure`, same content,
    same-session hour): **623 frames = 4.0 fps, 83 IDR (32/min)**,
    354 client IDR requests, 443 post-FEC shards, 57 rung-3, regime
    LOSSY, floor-pinned 525 kbps at close. QP "p50 22 flat" — on
    50 KB frames the wire never delivered.
  • THE BAR, HONESTLY: "armed within ≤3 IDR of the twin" assumed the
    probe's clean path where the twin rides at QP 17. This wire (pup's
    Wi-Fi) carries ~13–17 Mbps with periodic real stalls — the twin
    COLLAPSES on it; armed beat it by 47 IDR while delivering 11×
    the frames. "No 500 kbps crash": one touch of the floor during a
    GENUINE delivery collapse (falls anchored 4392→3576→567 — measured
    delivery, not self-echo; the gate held 3 real self-ref cases the
    same run) with immediate doubling-rung recovery — not the probe's
    spiral, which required an unimpaired path.
  • **Leg (b) squeeze re-proof**: 6 Mbit netem (dsfield 0xa0 +
    dport 41167) T+60→T+120 of 195 s. Fall TRACKS (pacer rode
    3.0–8.8 Mbps inside the window), tail RECOVERS to the full
    20 Mbps recipe by ~T+140 — and re-recovered from a late genuine
    stall the same run — B2 stays retired: 0 honored NACKs, 1 rung-3,
    regime ends CLEAN. 43 IDR (14/min), 40 directives, QP p50 34 /
    p95 48 across squeeze + storm.
  • **Leg (c) static**: at the 10 Mbps recipe (HS-22b's shape):
    **zero directives at ceiling** — 6 directives total = 3 shallow
    episodes of exactly fall+restore (zero mid-climb), each on a real
    sub-9 Mbps Wi-Fi dip; QP p50 12 / p95 22, 7 IDR/65 s, 0 NACKs,
    regime clean. At the 20 Mbps recipe the same shape holds (at-
    ceiling stretches strictly silent; 10 directives/65 s, QP p50 12
    / p95 17) — the ratchet's 60–72 KB quality passes genuinely
    outrun this wire at 20 Mbps, and the policy prices that honestly.
  NAMED FOR THE NEXT RUNG: this Wi-Fi path tops out well under the
  20 Mbps recipe — every "at 20000" episode ends in a real
  queue-growth fall (delivery-corroborated, not self-ref). The
  supremacy plan's recipe-vs-wire reconciliation (R2's territory)
  is where that tension resolves; the policy now prices it at
  ~2 directives per episode instead of ~10.

- **HS-23 — fifty is permission, not a promise; the estimator learns
  to tell a dark radio from a drowning wire** (`11f058f`, Host/): the
  supremacy plan's R2, built on the Wi-Fi study
  (`docs/20260728-201150-lyte-wifi-throughput-study.md`).
  THE RECIPE: LAN cap 20 → 50 Mbps at the session seam —
  `--wire-rate-mbps` defaults to 50, and in session mode the ENCODER
  RECIPE PAIRS TO THE PACER RATE unless `--bitrate-mbps` is explicit
  (the old default silently left the encoder at 20 under a 50 pacer).
  The k-ladder and clean boundary were ALREADY ceiling-relative
  fractions — verified scaling, not re-hardcoded; a new VBV pin proves
  the boundary arithmetic at fifty. 50 is permission: the estimator
  still governs below it.
  THE STALL GATE (RateEstimator): the study's receiver-side scan
  stalls (radio dark 70–100 ms, then a compressed burst) read as
  overuse to the old law — every dark spell anchored the rate down;
  that is what pinned 13–17 Mbps. An overuse fall now HOLDS when the
  hole carries the stall signature, all three marks at once: (1) the
  inflation streak's PEAK dwell stays under `stallGapCeilingMicros`
  (150 ms — a closed hole, not a growing queue), (2) a FULL train
  inside the last 500 ms measured drain at ≥1.25× the standing pace
  (the burst PROVES the pipe still swallows faster than we feed it),
  (3) conservation — pre-FEC loss and post-FEC evidence both under
  the clean threshold (nothing died in the hole; a few NACK echoes
  inside the dwell are priced in). Why real congestion still bites:
  a hole past 150 ms is no stall (pinned — 400 ms falls as ever); a
  drain BELOW the pace is a real squeeze regardless of hole shape
  (pinned); loss past the clean threshold defeats the hold (pinned,
  both pre-FEC and a rung-3 storm); and the self-ref gate from HS-22c
  runs FIRST — the stall gate only sees falls the backlog test let
  through. `stallHolds` rides the estimator stats line. FEEDBACK-LOSS
  HARDENING (the study's 1.7% uplink loss): reports carry cumulative
  counters + windowed dispersion samples, so a LOST report skips a
  window and the next report's deltas absorb it — no fabricated gap,
  no masked squeeze (pinned: `testLostFeedbackReportsNeitherFabricate
  NorMask`). Suite **161 → 168/168 Mac, 169 Linux** (7 new pins:
  ride-through cycles, rising-dwell hold, hole-past-ceiling fall,
  drain-below-pace fall, loss defeat, NACK-echo hold vs rung-3 fall,
  feedback-loss, plus the VBV fifty pin).
  THE LIVE GATE (pup, port 41169, testsrc2 1600×1000@60 heavy motion;
  NO Ethernet on pup — `ip -br link` shows lo + wlp0s20f3 only, so
  wired 55+ is the OWNER'S path to 60; and TODAY'S wire ran visibly
  rougher than the study's snapshot: recurring 1–2 s FULL-dark
  outages every ~30–60 s — those exceed any stall ceiling and are
  CORRECTLY priced as real):
  • **Leg (a) heavy motion, 160 s**: client glass **fps p50 48 /
    p75 50 / p95 56, mean 45.6** (HS-22c: 44.5 mean) — the gate's
    honest read: this wire's outage trains cap p50 near ~48–50; the
    clean stretches run 50–60 fps at QP 12. Host books: 7255 frames
    (45.4 fps encoded), **44 IDR (16.5/min), 34 directives** (all
    applied), 25 downshifts — **0 loss, 14 self-ref holds, 4 stall
    holds**, 2 rung-3, regime ends CLEAN. THE PIN IS BROKEN: the
    estimator no longer sits at 13–17 — it ranges the whole ladder,
    repeatedly reaching 20–50 Mbps and touching the FULL 50,000 at
    QP 12 mid-run; every crater below traces to a >150 ms genuine
    outage, not a scan stall.
  • **Leg (b) squeeze re-proof at fifty**: 6 Mbit netem
    (dsfield 0xa0 + sport 41169), 60 s window mid-run, removal
    verified (`noqueue` after). Fall TRACKS: 50,000 → 620 within
    ~3 s of the shaper landing, then saw-tooth probes 0.6→10 Mbps
    against the 6 Mbit pipe (104 overuse verdicts, 0 loss — the
    stall gate stayed QUIET under a real shaper: 1 hold all run).
    Tail RE-CONVERGES: unbroken doubling climb to the FULL 50,000
    by ~50 s post-removal, HELD ~20 s at QP 12 — then a genuine
    late Wi-Fi outage cratered it (netem long gone) and the run
    closed mid-recovery at 4.2 Mbps, climbing. **B2 stays retired**:
    0 honored NACKs, 11 stale, 0 rung-3, no floor-pin, regime CLEAN.
    8835 frames (45.4 fps), 41 IDR, 35 directives.
  • **Leg (c) clean-path silence at ceiling, 95 s**: **23
    consecutive seconds at pacer 50,000 = 100% of the recipe with
    the applied max AT the recipe and ZERO directives** — silent
    above, exactly as specified. Below the boundary, the doubling
    rung walks 368 → 739 → 1487 → 2977 → 5956 → 11925 → 24191 →
    50000 (~×2 each — HS-22c's ladder scaling untouched to the new
    ceiling). 16 directives / 16 applied, 17 IDR / 94.8 s, 0 NACKs,
    regime clean; the two craters bracketing the silent stretch were
    genuine 1–2 s full-dark outages (correctly bitten).
  • **Leg (d) static desktop, 80 s**: **487 kbps average** (537
    frames: 91 damage + 446 ratchet keepalives, 0 repeated), QP
    pinned 12, 12 IDR — nearly all at outage-crater recoveries (6
    downshifts, 2 loss during one genuine outage), not encoder
    churn. Near-idle holds at the fifty recipe.
  HYGIENE: netem removed + `noqueue` verified both interfaces; no
  strays; owner's 41151 loop alive at close; noise_static.key /
  paired_clients mtimes untouched (Jul 21/22), portal_token fresh
  by DESIGN (restore-token rotation on every host run — headless
  capture succeeded on every leg, chain intact).
  NAMED FOR THE NEXT RUNG: (i) recovery out of a FULL-dark crater
  costs ~45 s of doubling climb from the 500 kbps floor to 50,000 —
  at the fifty ceiling that mud is long; conserved-drain evidence
  could justify a faster climb. (ii) The AP dropped af21-MARKED TCP
  outright mid-session (ssh needed `IPQoS=none`; a later 50/50
  marked-vs-plain UDP probe passed clean — the penalty is
  intermittent). The client marks its whole uplink 0xA0
  (UdpReceiveEndpoint) — feedback and handshake ride whatever class
  the AP is punishing; a marked-vs-unmarked A/B on this AP is owed
  before blaming the protocol for uplink loss.

- **HS-24 — the recipe stops shipping Sunshine's floor; every knob now
  has to measure its way in** (`1d65bad`, Host/): the supremacy plan's
  R4, the encoder A/B ladder, against the owner-blessed adoption bar
  (PSNR-at-bitrate gain with fps and input→photon held).
  THE HARNESS (the committed deliverable): the C leaf loses its
  hard-coded posture — `lyte_hevc_enc_new` takes preset/tune/multipass/
  spatial-AQ/temporal-AQ/aq-strength explicitly and rejects unknown
  values LOUDLY at open; the shipped recipe is now
  `HostCore.EncoderRecipe.sessionDefault` (test-pinned, with
  `sunshineBaseline` kept as the named incumbent p1/ull/qres);
  `--enc-*` flags on lyte-host for live A/B legs; `lyte-encode-check`
  (new Linux executable) drives deterministic raw BGRx frames through
  the exact production leaf — bytes/QP/per-frame-encode-µs books, a
  `--static N` ratchet-convergence mode, one parseable RESULT line;
  `Host/Scripts/encoder-ab.sh` generates two corpora (motion =
  testsrc2 1600×1000@60; desk = gradients + scrolling monospace text),
  races the ladder under MATCHED content and rate (CBR 8 + 20 Mbps,
  capped-CQ cq12/cap50, static×300), and prints the delta table. The
  latency frame (infinite GOP, 0 B-frames, 0 reorder, 1 surface) is
  explicitly NOT a knob.
  THE LADDER VERDICT (pup RTX 4050, 360-frame legs; motion legs
  rate-matched within ~1%, so the deltas are honest PSNR-at-bitrate):
  • **p4 ADOPTED** — motion +0.766/+0.849 dB at matched 8/19 Mbps;
    desk +12.45/+12.42 dB at HALF the spend (3.5 vs 7.2 Mbps — p1's
    rate control on scrolling text is genuinely pathological: 2× the
    bits for −12 dB); capped-CQ session posture +0.265 dB at −4.7%
    bits; static keepalives 563 → 227 B at converged QP 12 (~2.5×
    cheaper ratchet); encode mean 3.1 → 4.6 ms, p99 ~6 ms, ~215 fps
    capacity — the 60 fps budget and the input→photon band hold.
  • REJECTED, each on the bar's own terms: **p2** (+0.05/+0.20, desk
    ~0); **p3** (+0.41/+0.54 — real, but p4 dominates at the same
    cost shape); **p5/p6** (byte-identical to each other, ≤+0.003
    over p4, +0.4 ms); **p7** (≈p4, +0.5 ms); **spatial AQ** (−0.30/
    −0.39 dB at p1 AND −0.29/−0.39 rel p4 — AQ optimizes perceptual
    weighting against the very metric the bar names, and even the
    text corpus lost); **temporal AQ** (opens WITHOUT lookahead on
    this wrapper — contra the expected reject — but measures a no-op,
    ±0.02 dB); **ll tuning** (≤+0.06 dB ≈ noise; ull keeps the
    established latency posture); **multipass disabled** (−0.82/−2.11
    dB on motion while UNDERSPENDING; its desk "+17.7 dB" was 2.8×
    bit-spend, not quality-per-bit — qres is precisely what lets CBR
    underspend quiet content, keep it); **multipass fullres**
    (inconsistent sign vs p4, +0.5 ms).
  THE LIVE GATE (port 41171, testsrc2 window, the HEALED wire — the
  owner moved the Mac to 5 GHz: re-baseline 40 pings 0% loss, avg
  8.9 ms, max 14.7 ms; HS-23's 1–2 s full-dark outages GONE, only
  ordinary daytime dips remain):
  • p1 legs (A/A2): glass fps p50 48/46, host QP mean 26.5/27.9,
    first frame 20.4/16.6 ms, IDR-era churn only at real dips.
  • p4 leg (B3, clean): 4,752 decoded / 110 s, fps p50 44, **QP mean
    19.6 — clean stretches HOLD QP 12** (48 fr × ~63 KB ≈ 24 Mbps)
    inside the same wire where p1 rode QP 26; 221/205,044 datagrams
    missing (0.11%) all healed; first frame 19.7 ms. Two earlier p4
    legs recorded but not comparative: B caught genuine end-of-run
    weather (estimator ended mid-crater at 1.7 Mbps), B2's content
    driver froze (see environmental find below).
  • Static leg (C, p4): **166 kbps average** over 74.7 s (HS-23 leg d:
    487), QP 12, **1 IDR**, 0 directives, ratchet converges in 4–11
    passes and goes silent, 385/385 frames delivered.
  • The honest fps read: glass p50 sits 44–48 under BOTH presets —
    the Wi-Fi path, not the encoder, remains the fps limiter exactly
    as HS-23 recorded; the encoder's 60 fps capacity is proven
    offline. Wired is still the owner's path to 60 at the glass.
  ENVIRONMENTAL FIND (for every future live leg): ffplay launched
  over ssh with `DISPLAY=:0` renders ~5 fps through Xwayland — the
  desktop composites almost no damage and a "heavy motion" leg
  silently measures a static desktop. Launch Wayland-native
  (`XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
  SDL_VIDEODRIVER=wayland ffplay …`) and PROBE the damage rate first
  (8 s file-mode run should show ~60 fps damage). Wayland ffplay can
  also freeze outright mid-run (leg B2: 37/110 s of supply) — check
  supply before reading a leg.
  Suites: **169 → 174/174 Mac AND Linux** (5 new EncoderRecipe pins:
  the shipped recipe as data, the incumbent baseline, knob-space
  validation both ways, summary format). HYGIENE: no netem applied
  (noqueue verified both interfaces at close); noise_static.key /
  paired_clients mtimes untouched (Jul 21 / Jul 22), portal_token
  rotation by design (headless capture on every leg); no strays,
  4117x ports free; ladder corpora removed (results kept at
  `pup:~/encab/results.tsv`, run log `~/encab-run.log`, leg logs
  `~/hs24-leg*-host.log` + Mac `/tmp/hs24-leg*-client.log`). The
  owner's 41151 loop was found EXPIRED at 16:05 — its own design (60
  iterations × the host's 120 s no-handshake timeout ≈ 2 h, cycling
  since ~14:00, before this slice ran); restored FRESH at close, 60
  iterations at the committed build — the loop now serves the p4
  recipe for the still-open owner eyeball (leg e).
  NAMED FOR THE NEXT RUNG: (i) Q-1 should fold `encoder-ab.sh` into
  the beauty-bar convention — the ladder is now a standing instrument,
  rerun it per recipe question, and the estimator formatter bug
  (delivery printed as 462,090 kbps this session) is still waiting
  there. (ii) The desk-corpus finding generalizes: ANY future recipe
  question needs the text corpus in the race — motion-only A/Bs would
  have called p4 a +0.8 dB nicety and missed the 2×-bits-for-−12 dB
  text pathology it fixes. (iii) Temporal AQ's open-without-lookahead
  means the wrapper accepts it silently — if a future SDK makes it
  real, the ladder will see it; nothing to do now.

- **HS-25 — no single frame is worth the session; the FEC block's brim
  becomes a ceiling, not a cliff** (`e82e88a`, Host/): the
  session-killer the 50 Mbps + p4 recipe uncovered live (2026-07-28
  ~17:15): a ~307 KB full-screen IDR packetized to **279 data shards**,
  past the GF(2⁸) Reed-Solomon 255-shard block, and
  `unprotectableDataShardCount(279)` thrown out of the send path EXITED
  the host — client black, session dead. The trigger posture was
  capped-CQ, which opened with NO VBV at all.
  SPLIT-GROUPS RULED OUT (the wire-contract finding, settled): the fec
  u64 (`FecField`) carries no group index — the group binding IS the
  envelope `frame` field, and the client's `VideoAssembler` keys one
  group per frame. Multi-group-per-frame is a wire-format change
  needing a wire-version discussion. The chosen fix is a ceiling, and
  it is HOST-ONLY — **no client-side depacketizer change is needed**.
  THE FIX, enforced twice:
  • `Session.ingestVideoFrame` reads the LIVE protectable ceiling
    (`maxDataShards(regime)` × the config's real shard budget —
    254,331 B clean / 223,380 B lossy-with-input-stamp) and DROPS a
    frame past it: `videoFramesUnprotectable` counted, the coalesced
    keyframe latch armed (the re-encode re-anchors the chain), the
    frame number UNCONSUMED so the client sees no numbering gap. The
    `VideoChannel` seam still throws — session guard is policy, the
    channel invariant stays the loud W2 backstop.
  • The shell caps the OPENING VBV at the worst-case ceiling
    (223,380 B = 204 × 1,095, lossy + input TLV) whenever the recipe's
    own VBV is absent (capped-CQ — the live trigger) or larger, folded
    into frame 0's forced IDR (costs nothing); `armEncoderVbv`'s
    baseline mirrors the same cap so a squeeze→clean RESTORE returns to
    the guarded posture and can never re-open the >255-shard hole.
  Suite **174 → 179/179, Mac AND pup** (5 new pins,
  `UnprotectableFrameGateTests`): the ceiling is the block math
  exactly; a ceiling-sized frame ships as 231+24 fully protected at the
  brim; the 307 KB live-repro frame drops without throwing, arms the
  latch ONCE, and keeps its frame number; the channel seam still throws
  past the ceiling; a lossy regime flip shrinks the ceiling and the
  guard follows.
  THE LIVE GATE (pup; moving-noise leg — windowed ffplay
  `color=gray:s=2048x1280:r=15,noise=alls=100:allf=t+u`; 15 fps because
  50 Mbps VBR ÷ ~36 fps of testsrc2 averages ~104 KB/frame and its
  IDRs peaked at 213 KB, UNDER the cap — the lower rate hands each
  frame the budget to burst it):
  • **Repro at 7e52ee0** (pre-fix, port 41181): host threw
    `unprotectableDataShardCount(230)` at packet 106 and EXITED
    (code 1) — moments after a ratchet clean-RESTORE re-opened the
    encoder to `max 50000 kbps, vbv 6250000 B`, exactly the
    squeeze→restore hole the baseline mirror closes; the client's
    session CLOSED at 105 decoded frames. The live crash class, on
    demand.
  • **Proof at the fix** (port 41182, same content and flags, 79.6 s):
    init logs `unprotectable-frame guard — opening vbv capped at
    223380 B`; **1268 frames encoded (29 IDR) → 117,196 shards →
    140,989 datagrams (137.4 MB), 0 dropped unprotectable** (live
    ceiling 254,331 B clean); 15/15 vbv directives applied and every
    RESTORE re-opened to `vbv 223380 B`, never above; client decoded
    1243 / skipped 10 of 138,787 datagrams (all ok), frame max
    132,016 B — comfortably under the ceiling, so the guard's drop
    path stayed at ZERO by construction, exactly as designed. Host
    exit 0, and only because the harness client left.
  HYGIENE: all three secrets byte-identical before/after
  (sha256 pinned: portal_token dadf9a66…, noise_static.key 72860390…,
  paired_clients 8dc1f88a…); owner's 41151 loop alive throughout and
  at close; ffplay killed, pup's `~/src/lyte-host-prefix` and the
  local `/tmp/lyte-prefix` worktree removed.
  BURNED INTO PROCEDURE (two live finds):
  (i) **Harness hosts MUST run `--no-advertise`** — the first repro
  attempt advertised `_lyte._udp` as "pup #2" and the OWNER'S APP
  discovered and handshook it (their glass went black mid-slice; the
  coordinator re-attached them to 41151). A wire-view harness connects
  explicitly by `--host`; it never needs the advertisement.
  (ii) **Fullscreen ffplay starves the Mutter screencast** — with
  `-fs`, the portal granted the node but PipeWire delivered ZERO
  frames for 105 s (direct scanout; portal restarts don't fix it).
  Windowed at full size, frames flow. HS-24's Wayland-native rule
  stands, minus the `-fs`.
  NAMED FOR THE NEXT RUNG: the guard prices protection, not delivery —
  a ceiling-sized 255-shard group is ~24 datagram-milliseconds of wire
  at 50 Mbps; if the H4 4:4:4 wave fattens IDRs toward the ceiling
  routinely, the recipe conversation (R2's recipe-vs-wire
  reconciliation) should decide whether capped-CQ keeps the right to
  mint 223 KB frames at all.

- **H4 wave plan** (docs only — the plan of record is
  `docs/20260728-194226-lyte-h4-plan.md`): 4:4:4 leads, per the
  answered supremacy-plan decisions; Stage A is banked (HS-22c), this
  covers Stage B onward. THE WIRE FINDING, verified at HEAD: **4:4:4
  needs NO new vocabulary and NO new vector files** — yuv444=2 has
  existed since W7, the frozen full-house vector already pins chroma
  `[1,2]` byte-exact, and the stream's actual chroma rides the SPS
  through VideoRenderFactory's existing in-band rebuild. One trap
  named: `wireDefault` is the frozen wire-default anchor — 4:4:4
  declaration is shell-side construction (the declaringX posture),
  never a wireDefault edit. THE ENCODER FINDING (FFmpeg nvenc.c,
  read): three 4:4:4 input paths with different color truths — gbrp
  planar = **identity-matrix FULL-RANGE RGB in HEVC, mathematically
  exact** (the pillar's 0/255 round trip by construction, IF the Mac
  display path renders GBR right); bgr0+rgb_mode=444 = free but
  VUI-FORCED 601-limited (Stage A's finding generalizes); a BT.709
  full conversion leaf = Sunshine-parity, most work. The ladder
  fronts two S-effort probes (V-1 pup encode, V-2 Mac
  VideoToolbox/render) to settle the path BEFORE conversion code
  exists. Slices: V-1/V-2 probes → V-3 (the pillar-§7 corpus harness,
  4:2:0 baseline banked first) → V-4 (host Work/Play recipe split +
  self-probed declaration) → V-5 (client mode surface,
  declaration-as-choice + named 420 fallback) → **J-G4a the chroma
  gate** (early, the race headline) → P-1 clipboard v2 / P-2
  multi-monitor / P-3 dynamic resolution (P-2/P-3 pre-declared
  droppable) → J-G4. HS-25's ceiling question gets its answer shape:
  Work KEEPS the 223,380 B capped-CQ posture (Work IDRs are
  structurally rare; the ratchet erases IDR debt), V-1 books the
  4:4:4 IDR distribution, J-G4a demands zero unprotectable drops.
  RACE UPDATE (checked 2026-07-28): Sunshine's Linux NVENC 4:4:4 is
  now in PRE-RELEASE builds (v2026.704.34109+; last stable predates
  it) — the ship-first window is real but narrowing, which is why
  J-G4a, not J-G4, is the race claim. Four §0 decisions open for the
  owner: mode-selection mechanics (recommend declaration-as-choice,
  zero vocabulary), the conversion-path preference order + whether
  full-range hard-gates the ship (recommend chroma first, range
  named-and-queued if gbrp fails), the ceiling posture (recommend
  keep HS-25's), and the P-track's gate coupling (recommend J-G4
  needs P-1 only).

- **Q-1 — the beauty bar stands watch; the probe becomes a script that
  cannot rot** (`b1f027a`, Host/): the supremacy plan's R5, LANDED ON THE MAC
  GATES with the live legs **DEFERRED-PENDING-HOST** (pup dropped
  off-network mid-probe — ledger below, the HS-18 pattern).
  THE INSTRUMENT (`Host/Scripts/quality-probe.sh`, runs from the Mac,
  orchestrates pup over ssh): the quality probe's once-rediscovered
  method, mechanized end to end — the LYTE_DUMP_RAW static leg (60 s
  capped-CQ file mode; per-frame luma PSNR against the final retained
  raw frame, converged = series max), the motion leg (12 × 6 s
  file-mode runs against a WINDOWED Wayland-native testsrc2 window,
  last-frame PSNR median — the dump is last-frame-only, one pair per
  run), and the wire A/B (150 s policy-armed + --no-vbv-reconfigure
  twin: glass fps p50 from per-second decode deltas, IDR/min,
  standing-rate directive churn, wire frame loss) — ONE summary block
  ending in the verbatim row for THE BEAUTY BAR standing table (new
  section above the wave block; bars: static ≥50 dB, motion ≥55 dB,
  fps ≥55, IDR ≤2/min, churn =0, loss ≤1). Rails baked into the
  script, not the operator: --no-advertise on 41183+ and a hard
  refusal to bind 41151; windowed patterns with a damage-supply
  preflight that ABORTS on the frozen-ffplay/Xwayland trap (HS-24's
  environmental find, now a tripwire); secrets sha'd before/after
  inside the run (noise_static.key + paired_clients must be
  byte-identical, portal_token rotation named as by-design); ssh
  connect timeouts + keepalives so a pup drop fails loud in seconds
  (tonight's drop took ~15 min to surface through default TCP).
  THE FORMATTER BUG, root-caused (probe §5's "462,090 kbps delivery"):
  NO unit was wrong anywhere — bytes are bytes, µs are µs. The final
  receipts printed the estimator's windowed-MAX delivery filter (the
  BBR-shaped bottleneck probe), and a receiver radio draining a queued
  dwell in one compressed burst hands that max a LEGITIMATE super-rate
  sample (clumped arrivals measure hundreds of Mbps across microsecond
  spans — the same physics behind HS-23's stall gate). The control law
  keeps its burst-tolerant max untouched; the summary now prints
  `measuredDeliveryRateBitsPerSecond` — the median of the last few
  full-train raw samples, the exact evidence the HS-21 overuse anchor
  trusts — with the old max demoted to a labeled "burst max". Pinned:
  `testReportedDeliveryOutvotesClumpedBurstSample` (two 8 Mbps full
  trains + one 400 Mbps clump → the max window keeps the burst, the
  reported figure holds 8 Mbps).
  THE LADDER JOINS THE CONVENTION: encoder-ab.sh's header now carries
  the rerun rule (every recipe question re-races the ladder, ALWAYS
  with the desk/text corpus — motion-only A/Bs would have called p4 a
  +0.8 dB nicety and missed the 2×-bits-for-−12 dB text pathology) and
  its table prints under the same dated banner shape as the probe's
  summary block.
  Suites: **179 → 180/180 Mac AND pup** — the pup suite ran GREEN at
  this exact Swift state (~19:47 MDT, BEFORE the box dropped); the
  only unsynced deltas there are bash-side script fixes. The binary at
  pup `~/src/lyte-host/.build/debug/lyte-host` is already the
  Q-1-fixed build (built 19:47, suite green) — the standing loop is
  NOT mid-broken.
  PARTIAL LIVE EVIDENCE (two aborted probe runs, NOT bar rows —
  script-reproduced twice, consistently): static converged
  **51.26/51.27 dB** (bar ≥50; opening IDR 43.5/43.8; the desktop
  wasn't perfectly quiet — 61/63 damage frames of the ~310); motion
  last-frame median **~59.7 dB** across 23 completed runs
  (59.66–59.86 — the probe-day median was 56.7 at the 20 Mbps cap:
  HS-23's fifty + HS-24's p4 are visible in the number). The wire
  legs never started; the bar row stays pending, nothing invented.
  **DEFERRED-PENDING-HOST — DRAINED 2026-07-28 ~23:45 MDT, all six
  legs (results appended below the list; pup came back ~23:32 —
  network-level drop only, NO reboot, up since ~14:03, all on-disk
  state intact):**
  (a) stray sweep — the aborted run's windowed ffplay (testsrc2
      1600x1000) was alive at the drop (a reboot clears it; kill it
      if not); remove `~/qprobe/*.raw` and `*.hevc` leftovers; keep
      the `~/qprobe/*.log` + `*.psnr` evidence until the row lands;
  (b) rsync Host/ → pup:src/lyte-host and rebuild (bash-only deltas:
      the probe script's ssh timeout/keepalive wrapper and two parse
      fixes; Swift is already built + green there);
  (c) pup suite at the committed tree — expected 180/180 (it already
      passed at this Swift state pre-drop; this leg makes it a
      commit-hash fact instead of a working-tree fact);
  (d) THE LIVE PROBE ROW — `bash Host/Scripts/quality-probe.sh` from
      the Mac, end to end, fills the beauty bar's dated first row.
      The open question is exactly the plan's two previously-failing
      rows (fps ≥55, IDR ≤2/min) which HS-23/HS-22c should have
      turned green: if either is red at HEAD that is a FINDING to
      report loudly, not a number to massage;
  (e) restore the owner's standing loop (`bash ~/lyte-loop.sh`,
      41151) — it had ALREADY expired at run 60 before this slice
      touched anything (log evidence in /tmp/lyte-host-session.log)
      and pup died before the HS-24-precedent fresh restore could
      happen;
  (f) secrets sha-verify against the pinned baseline (verified
      byte-identical at 19:46 MDT tonight: portal_token
      dadf9a66…37cf, noise_static.key 72860390…cfed, paired_clients
      8dc1f88a…55fd; portal_token rotation on later runs is by
      design).
  **THE DRAIN (2026-07-28 ~23:34–23:45 MDT, per-leg):**
  (a) the aborted run's ffplay (PID 294448, testsrc2 1600x1000) had
      SURVIVED the drop — no reboot — and was killed; `~/qprobe`
      raw/hevc removed, the log/psnr evidence kept until this row
      landed (it now has);
  (b) rsync + rebuild: a 2.3 s no-op build — bash-only deltas, as
      predicted;
  (c) suite **180/180 on pup at `8dc049a`** — a commit-hash fact now,
      not a working-tree one;
  (d) THE ROW LANDED, end to end, one unattended run (~8 min):
      `| 2026-07-28 @ 8dc049a | 51.27 PASS | 59.75 PASS | 47 FAIL |
      3.9 FAIL | 0 PASS | 0 PASS |` — static converged 51.27 dB
      (opening IDR 43.82; 311 fr, 61 damage), motion median 59.75 dB
      (59.69–59.87 × 12 runs @ 50 Mbps), churn 0 (all 7 directives
      evidence-backed), loss 0 of 5178 frames (0/285,117 dgrams
      missing). THE TWO REDS ARE THE PLAN'S EXACT OPEN ROWS, now
      dated and decomposed — findings, not massaged:
      **fps p50 47** — the glass ran a steady 46–49 through the
      healthy window and never touched 55. NOT the wire (0 loss,
      decode kept pace), NOT the compositor (the file-mode motion
      legs capture the full 60 — 367 damage per 6.1 s): under full
      wire-session load (encode+seal+FEC+pace+5 ms audio) the host's
      capture→encode path ingests ~48/s. HS-23's fifty raised the
      ceiling; the session pipeline is now the bottleneck — that's
      the next fps thread to pull.
      **IDR 3.9/min** — 0 client IDR requests, 0 loss; all 10 IDRs
      are host-originated: 1 opening + 7 VBV-directive IDRs (the
      cold-start evidence climb 6.7→13.4→26.9→50 Mbps spends 4, a
      mid-leg overuse dip to 16 + recovery spends 3) + 2 post-idle
      wakes. Every rate reconfigure forces an IDR, so the estimator's
      ramp alone busts ≤2/min — the bar and HS-22c's armed-overhead
      bar (≤3 vs the twin) measure different things, and the latter
      passed huge: armed 10 vs twin 64 IDRs (overhead −54).
      ANOMALY, named: the testsrc2 window FROZE ~110 s into the armed
      leg — HS-24's trap striking MID-LEG, past the probe's
      run-1-only damage preflight. The host behaved by design
      (ratchet converged in 4 passes → IDLE; two damage-trickle wakes,
      each a wake IDR) and the tail zeros did NOT move the fps median
      (the healthy window's p50 is still ~48) — but a mid-leg
      damage-supply tripwire is a probe hardening candidate if the
      freeze recurs.
      BONUS RECEIPT: the twin leg doubled as the directive policy's
      live proof — `--no-vbv-reconfigure` collapsed the estimator to
      1368 kbps (91 overuse verdicts, 49 downshifts, 4.3 s max queue
      delay), the client hammered 304 IDR requests, and the glass
      froze (fps p50 0). The VBV directives are load-bearing.
      And the Q-1 formatter fix printed exactly as designed: delivery
      76,614 kbps median with the burst max (272,333) demoted to its
      label.
  (e) fresh `bash ~/lyte-loop.sh` live at ~23:44 MDT (nohup/disowned,
      60 iterations): advertising "pup" on 41151, clipboard leaf up,
      pinned static key intact (10e0f084…6201) — the owner's eyeball
      host is back and waiting;
  (f) all THREE shas byte-identical to the pinned baseline —
      portal_token dadf9a66…37cf, noise_static.key 72860390…cfed,
      paired_clients 8dc1f88a…55fd; portal_token did not even rotate
      across the probe's headless captures or the loop restart.

- **V-1 — the colors take the stand; every 4:4:4 claim becomes a
  measurement** (`e232d61`, Host/): H4 wave 0's NVENC Rext probe —
  offline encode legs on pup (RTX 4050, driver 595.84, libavcodec
  8.0.1), no wire, no session, no capture; every §1 [probe] mark in
  the H4 plan now carries a number. Full report with tables:
  **`docs/20260729-002000-lyte-v1-rext-probe.md`** (uncommitted, per
  the worker mandate — it carries V-2's co-sign slot).
  THE INSTRUMENT (the committed deliverable): the C leaf grows
  pix-fmt/profile/rgb_mode knobs on the HS-24 loud-reject pattern —
  gbrp (planar RGB) and yuv444p input plumbing, the production-shaped
  BGRx→gbrp repack measured in-leaf
  (`lyte_hevc_enc_repack_us_total`), and per-path VUI truth signing
  (identity/full for gbrp, 709/full for yuv444p, Stage A's
  601-limited for packed); `lyte-encode-check` grows
  `--pix-fmt/--profile/--rgb-mode`, `--idr-every N`, `--sizes` books;
  `Host/Scripts/rext-probe.sh` runs the whole ladder. Session path
  untouched (profile/rgb_mode ride "" defaults until V-4).
  THE VERDICTS (all legs 2048×1280@60 p4 capped-CQ cq12/cap50, the
  shipped posture; encodes measured deterministic across reruns):
  • **Rext OPENS on all three input paths** through the production
    leaf (a successful open IS the YUV444 caps check); `rgb_mode` is
    on pup's option surface; the wrapper auto-selects Rext for gbrp
    even without `-profile` (we'll still declare it, V-4).
  • **The race: gbrp wins text by a landslide** — 53.84 dB RGB-PSNR
    at 14.0 Mbps vs p420's 37.80 at 21.1 Mbps (**+16.0 dB at 34%
    fewer bits**); rgbmode 48.21/9.0 Mbps and conv (pre-converted
    709-full yuv444p) 47.81/11.5 Mbps sit ~5.5 dB under gbrp. Motion:
    all three 4:4:4 paths 46.6–47.0 dB at the cap vs p420 33.4.
  • **Color truth (Stage A's candidate sweep, bars): nobody lies** —
    gbrp measures identity-full 69.99 dB (next candidate 14.25),
    rgbmode measures bt601-limited 56.04 (the forced-601 finding
    holds on the 4:4:4 path), conv measures bt709-full 50.92; every
    VUI tag TRUE by 20–56 dB margins.
  • **Throughput: 60 fps holds everywhere.** Worst is gbrp 99–103 fps
    capacity (10.0 ms/frame INCLUDING its 4.4 ms CPU repack; encoder
    share ~5.6 ms ≈ 180 fps); conv 170–180 fps and rgbmode 133–139
    both BEAT p420's 137–145 at this geometry (NVENC's internal
    RGB→420 conversion costs more than encoding pre-converted 4:4:4).
    p1 fallback banked: 115/163/213 fps. Encoder capacity is NOT the
    ~48/s session-ingest ceiling — that hunt stays open, upstream.
  • **Capped-CQ at 4:4:4 behaves**: QP walks to 12 and holds on every
    path, byte-stable ≤ frame 25/300, and static keepalives get
    CHEAPER than 4:2:0 (141/163/160 B vs 208 B at converged QP 12).
  • **The ceiling books (owner decision 3's evidence)**: VBV-uncapped
    natural demand on the text corpus, 30 forced IDRs/path (6 scroll
    positions × 5 — percentiles quantized): 4:4:4 IDRs p50 263–397 KB,
    max 572–720 KB, **20/30 ≥ the 223,380 B ceiling** (p420 already
    crosses 15/30 at p50 210 KB); deltas never threaten it (p50
    17–28 KB, max ≤145 KB). Under the HS-25 posture essentially EVERY
    Work-mode text IDR is a ceiling-conformed ~24-datagram-ms frame —
    the guard becomes the routine IDR shape, exposure = IDR frequency
    (structurally rare in Work). The owner rules with that number.
  • **Repack bill (question 5)**: 4.34–4.45 ms/frame single-threaded
    naive C (~2.4 GB/s, 26% of one core's frame period), measured
    in-leaf, overlappable in a pipelined session, unvectorized —
    SIMD/threads/CUDA all untouched headroom.
  OWNER DECISION 2 EVIDENCE: the recommended order gbrp →
  host-conversion → rgb_mode HOLDS host-side — gbrp is the only
  mathematically-exact path and the quality king; conv shows NO
  quality edge over free rgbmode (47.8 vs 48.2 text), only the range
  win, so if gbrp fails V-2's render test the real fight is
  "conversion-leaf build cost vs 601-limited-for-free". Joint ruling
  awaits V-2 (identity/GBR full-range render is gbrp's
  make-or-break).
  Suites: **180/180 Mac AND pup** at the exact committed tree (pup
  ran the identical rsynced source pre-commit). HYGIENE: offline legs
  only — 41151 loop alive and untouched throughout, no ports bound,
  no netem, no strays (verified at close); secrets by construction
  plus mtime-verified (noise_static Jul 21, paired_clients Jul 22,
  portal_token 23:41 pre-session). Evidence on pup: run log
  `~/rext-probe-run.log`, parseable rows `~/rext-probe/results.tsv`,
  IDR books `~/rext-probe/sizes-{p420,gbrp,rgbmode,conv}.txt`, and
  **V-2's bitstreams at `~/rext-probe/keep/` (11 files:
  {desk,motion,bars}×{gbrp,rgbmode,conv} + desk/motion-p420)** —
  corpora (~20 GB) removed after harvest.
  NAMED FOR THE NEXT RUNG: (i) V-2 consumes `keep/` through the
  production `VideoRenderFactory` path and co-signs the
  conversion-path ruling into the probe report; (ii) V-4 can rely on
  auto-Rext but should declare `-profile rext` anyway, and the gbrp
  repack wants SIMD before anyone calls 4.4 ms/frame a cost; (iii)
  the IDR-books method (--idr-every + --sizes) is reusable for any
  future ceiling question.

- **V-2 — the glass takes the stand; gbrp dies at the render, not the
  decode** (`3f94a0f` code + `8fa44a2` report co-sign, root): H4 wave
  0's Mac VideoToolbox Rext probe — all 11 V-1 bitstreams through the
  EXACT production construction (AnnexBAccessUnits → DecodeUnit →
  VideoRenderFactory → CMSampleBuffer) on the M5, offline, no host
  contact. Verdict table + joint ruling co-signed into
  **`docs/20260729-002000-lyte-v1-rext-probe.md`** (V-1's slot).
  THE INSTRUMENT (committed, deliberately not throwaway — the §7
  harness's client half per the plan): `VideoReadbackTap`
  (VTDecompressionSession fed the same factory samples; hardware
  engagement read from the LIVE session property; native/BGRA
  readback), `AnnexBAccessUnits` (file → frame-shaped units, gated in
  the suite), `lyte-cli decode-probe` (plane dumps for offline
  referees + a real AVSampleBufferDisplayLayer window screenshotted
  for glass truth; `--window-scale 0.5` puts video texels 1:1 with
  Retina device pixels — the resample-free glass measurement).
  THE VERDICTS:
  • **Everything hardware-decodes** — 11/11 streams, zero failures,
    session property asserts hardware; `--require-hardware` (the
    VT *Require* spec) also opens on Rext 4:4:4. Moonlight's #1852
    software-fallback failure mode does not exist on this fleet.
  • **Bit-exact planes, no chroma downsample decoder→glass** — VT's
    4:4:4 output planes are byte-identical to ffmpeg software decode
    on all three paths (gbrp's coded G/B/R planes come back untouched
    in the Y/Cb/Cr slots); at the glass the desk corpus matches
    full-chroma truth at 39.9 dB, ABOVE the 38.0 dB separation from a
    simulated chroma-halved hypothesis — the compositor samples full
    chroma. Buffers: '444f'/'444v' biplanar full-res 4:4:4 (nv24
    layout) vs today's '420v' NV12.
  • **THE MAKE-OR-BREAK, negative: identity/GBR full-range renders
    WRONG through the production path.** Both VT's own RGB converter
    and the display-layer composite read matrix-0 as **bt601-full**
    (range honored, matrix ignored) — candidate sweep crowns 601-full
    by ~30 dB over identity on both instruments; bars render as
    green/magenta garbage. Structural, not a bug to file: CoreVideo
    has NO identity/GBR YCbCrMatrix vocabulary (our matrix surfaces
    as ABSENT + fullRange 1 — the fingerprint V-5's VUI assert should
    key on), so nothing can be tagged; honoring gbrp would mean a
    custom Metal view instead of AVSampleBufferDisplayLayer.
  • **The alternates render CORRECT at the glass, asserted** —
    rgbmode wins as bt601-limited (46.1 dB) and conv as bt709-full
    (47.7 dB), 17+ dB over runners-up on both instruments (glass
    numbers carry the Display-P3 round-trip noise floor; readback
    equivalents 51+ dB).
  THE JOINT RULING (owner decision 2, co-signed in the report):
  **gbrp is OUT** — encode king, render corpse. The race is
  host-conversion (709-full, the leaf's build cost, fastest encode
  measured) vs rgb_mode (601-limited, free today); both roads paved
  and priced, the owner picks.
  Suites: root **167/167** Mac at `3f94a0f` (the AU-splitter gate is
  new; wire/host untouched). HYGIENE: zero host contact (bitstreams
  scp'd read-only; pup's 41151 loop untouched), no Lyte processes
  disturbed, probe windows opened/closed on the Mac only. Evidence in
  /tmp (scratch, disposable): glass PNGs + scripts under
  `/tmp/v2-work/`, bitstreams at `/tmp/v2-bitstreams/`.
  NAMED FOR THE NEXT RUNG: (i) V-3's client half exists — feed the
  harness corpus through `decode-probe --dump` and the readback tap;
  (ii) V-4 signs VUI per the ruling (709-full if the leaf, 601-limited
  if rgb_mode) — both proven client-clean; (iii) V-5's decoder→layer
  audit should assert '444v'/'444f' (by negotiated mode) at the tap
  and treat matrix-ABSENT as the identity fingerprint, never a default.

- **V-3 — the §7 corpus harness stands, the 4:2:0 baseline is banked,
  and 4:4:4's first measurement answers with +22 dB at fewer bits**
  (`9bac47b` root + `c0129dc` Host script + `f0d785b` report =
  **`docs/20260729-032500-lyte-v3-corpus-harness.md`** — the full
  table and every argument live there). H4 wave 1's harness slice:
  the pillar's §7 acceptance machinery as a standing instrument
  (`Host/Scripts/corpus-harness.sh`, Mac-run, offline encode legs
  ONLY — no wire, no secrets, safe beside the 41151 loop), composing
  V-1's `lyte-encode-check` (production leaf on pup) and V-2's
  readback tap (VT hardware REQUIRED).
  THE INSTRUMENT: `lyte-cli corpus-gen` — the §7 corpus as
  deterministic pure-Swift pixel math (bitmap-face dense text at
  100/125/200%, 1-px chroma gratings, gradients, range patches,
  procedural photo; 2048×1280 BGRX), HASH-FROZEN by root gate tests
  like a wire vector; `lyte-cli corpus-gate` — the §7 thresholds
  PINNED IN CODE (text 40/50, SSIM 0.995, gratings ±2, convergence
  180 fr) + owner decision 2's limited601 range posture (+1 code,
  byte-exact named-and-queued, raw deltas still reported);
  decode-probe grew `--dump-frames 0,59,last` (cold IDR / active@1s /
  post-ratchet, not a 2.5 GB dump); goldens for BOTH chromas
  committed at `Goldens/corpus/` (12 MB, 6 PNGs). Root suite 167 →
  **175/175**; Host **180/180 Mac AND pup** (scripts only).
  THE BANKED BASELINE + FIRST 4:4:4 READ (one run, both legs, shipped
  recipe p4/cq12/cap50): saturated-syntax text 16.4–19.8 dB at 4:2:0
  → 39.6–42.7 dB at 4:4:4 (pooled text-region +19.6 to +22.2 dB, AT
  FEWER BITS — text IDR 480 KB vs 578 KB); 1-px gratings ±255-code
  garbage (100% of pixels beyond bar) → ±5 codes, SSIM 0.895 →
  0.99995; photo a wash (45.27 vs 45.29 — Play loses nothing by
  staying 4:2:0); 4:4:4 ratchet converges cv49–55 with 95–143 B
  keepalives. DETERMINISM PROVEN: three independent pup-to-glass runs
  byte-identical, goldens diff CLEAN (the table reproduced exactly at
  committed HEAD `f0d785b`).
  THE HONEST FAILS (V-4's homework, with numbers): 444 Work gates
  fail text-converged (41.7–44.3 vs ≥50 — even pure-luma white text
  caps at 46.3–46.8 dB) and gratings (±5 vs ±2) — BOTH trace to the
  cq12 floor, not the chroma path: the Work recipe needs its own
  ratchet floor (one knob) and now has exact before-numbers. Patches
  pass under decision-2's posture (max ±2; raw byte-exact deltas
  white ±1 / red ±2, IDENTICAL at 4:2:0 — the 601-limited round
  trip's floor, not a 4:4:4 regression).
  OFFLINE SCOPE, stated once: live-ratchet halves (zero frames
  post-convergence, bytes ≤ surplus) and the negotiated end-to-end
  path wait for V-4/J-G4a; the harness's END-TO-END live re-run is
  J-G4a's headline leg. Rails held: pup workdir cleaned (default), no
  session, no netem, secrets untouched by construction. Scratch at
  `/tmp/corpus-harness/` (summary.txt + gates/encode logs + dumps).
  ANOMALY (found, not caused, FIXED): the owner's standing 41151 loop
  had self-expired at 01:49 — `~/lyte-loop.sh` is a FINITE 60-iteration
  loop and run 60 was its last (each idle run exits at the 120 s
  handshake timeout, so the loop lives ~2 h idle). Restarted 03:29
  (pid 505593), advertising with the SAME pkh `3cf2bcc1…` and static
  key `10e0f084…` — pairing intact, no PIN expected. If the loop
  should be immortal, someone should make it `while true` instead of
  `seq 1 60`.
  NAMED FOR THE NEXT RUNG: (i) V-4 reruns `corpus-harness.sh 444`
  as its encode-half gate and diffs the 444 goldens — GOLDEN=write
  only when a recipe change MEANS to move pixels, said in the commit;
  (ii) the Work-mode cq/qmin floor decision wants the harness rerun
  per candidate (one command); (iii) J-G4a publishes the live delta
  table next to this offline one.

- **V-4 — the host serves Best for real: the [444] singleton opens a
  Rext session at its own cq4 floor, every IDR fits the ceiling, and
  the two remaining reds are the CONVERSION'S, not the floor's**
  (`60dac56` Host code + `653f8b1` harness floors/goldens; Host-only,
  not pushed). The production path, not probe machinery:
  THE MECHANICS (owner decision 1, declaration-as-choice):
  `EncoderRecipe` grows the chroma split (profile / rgb_mode /
  ratchetFloorQP) and pins **`best444` = p4/ull/qres + rext/yuv444 +
  floor cq4**; `ChromaPosture` (HostWire) maps EXACTLY the agreed
  `[yuv444]` singleton to the Best encoder — a [420] singleton, a
  nonconforming both-declarer, and the never-declaring grandfathered
  peer all ride the shipped 4:2:0 path (multi-mode is not a choice).
  The host's declaration is gated on a startup **Rext self-probe**
  (opens+frees a tiny 4:4:4 encoder): a box that can't do it never
  claims it, so `noCommonChromaMode` (the typed teardown V-5's
  re-dial keys on) only ever means what it says. The sink holds
  frames ≤2 s awaiting the agreement instead of opening a posture
  the client didn't pick; operator `--enc-*` overrides ride into a
  444 session unchanged (`chroma444()` moves only the chroma knobs).
  VUI stays truthfully 601-limited per V-1/V-2.
  THE FLOOR RACE (cq12/8/4/1, one harness command each): **cq4 is
  the knee** — pooled text-converged 41.7–44.3 → **45.6–47.1 dB**
  (+3.6…+3.9 over the shipped cq12), gratings ±5 → ±4, SSIM ≥0.9996;
  cq1 buys ≤+0.2 dB more on two corpora and LOSES 0.46 dB on
  text-200. COST: ~zero steady-state (keepalives 95→98 B, converged
  all-skip either way, offline capacity ~145 fps at both floors);
  natural text IDRs grow 480→549 KB — which the ceiling eats, see
  below. Convergence cv35–47, well under the 180-frame bar.
  THE STOP-CLAUSE EVIDENCE (owner decision needed, NOT forced): the
  ≥50 dB text-converged bar and the ≤±2 gratings bar are
  **unreachable on this path at ANY floor** — at transparent coding
  (cq1) text caps at ~46–47 dB and gratings at ±3–4 codes; the
  residual is the 601-limited YCbCr round trip (8-bit limited-range
  quantization), not bits. The harness leg comment says so; the two
  gates stay HONEST FAILs pending the owner's bar-vs-path ruling
  (options: recalibrate the bars to the conversion's floor, or queue
  the named full-range/identity-matrix path as the road to ≥50).
  Every other 444 Work gate PASSES at cq4.
  THE CEILING VERDICT (decision 3 holds): `lyte-encode-check` grew
  `--vbv-cap-bytes` (the HS-25 guard offline); under the 223,380 B
  cap the natural 549/453/293 KB text IDRs squeeze to **194/193/168
  KB — zero frames over the ceiling anywhere in any walk, deltas
  clear** (max 174–185 KB immediately post-IDR, 97–98 B steady), no
  crash, and the ratchet heals the squeezed opener to IDENTICAL
  converged quality within 47 frames. The session-side guard itself
  is chroma-agnostic (imposed at encoder-open in session mode).
  ACCEPTANCE: `corpus-harness.sh` now carries per-tier floors (420
  rides cq12, 444 rides cq4; CQ= overrides both for A/B). Full
  both-legs run at HEAD banked; **444 text goldens INTENTIONALLY
  rewritten** (the floor moved the pixels — said in `653f8b1`), 420
  goldens byte-identical on the same run (determinism check), and a
  GOLDEN=check confirm pass reproduced all three new 444 goldens
  clean. Suites: Host 180 → **186/186 Mac AND pup** (recipe pins,
  posture-map pins, three negotiation gates through the real session
  machine). Rails held: offline encode legs only (no wire, no
  session), owner's 41151 loop untouched (pid 505593 alive after),
  secrets' mtimes all predate the slice (key Jul 21, paired Jul 22,
  portal_token Jul 28 23:41), pup scratch (`~/v4-ceiling`) removed.
  ANOMALY (mine, fixed in-slice): the KnobError switch in lyte-host's
  CLI seam is Linux-only code — the new enum cases broke the pup
  build until made exhaustive; Mac's green suite never sees that
  target. Worth remembering: any KnobError growth needs a pup build
  before it's real.
  NAMED FOR THE NEXT RUNG: (i) V-5 (root) builds the three-tier
  Chroma control and the auto-re-dial-at-420 on
  `noCommonChromaMode`; (ii) the owner rules on the two
  conversion-floored bars (recalibrate vs full-range road); (iii)
  J-G4a runs the negotiated 4:4:4 session live end-to-end and
  publishes the delta table; (iv) the 2 s chroma hold is untested
  against a real pre-W7 client — J-G4a should watch the
  "grandfathered peer" print.

- **V-5 — the client asks for Best by name: Good/Better/Best on the
  strip, the ask persists per host, a refused Best re-dials at Good
  under a banner, and the SPS audit swears to what the wire carries**
  (`a8b9fa4`, root only, not pushed). FINISHED BY A SECOND WORKER:
  the first V-5 worker died ~04:26 to an infrastructure timeout (not
  a task failure) leaving ~317 coherent uncommitted insertions; the
  finisher inspected the tree, kept ALL of it, fixed exactly one bug
  (the corpus-IDR gate read `frame-000.annexb`; the committed vector
  is `frame-000-idr.annexb`), and ran the verification legs.
  THE MECHANICS (owner decision 1's client half): `ChromaTier`
  (LyteTransport) is the tier vocabulary — Good→[420], Best→[444],
  Better DORMANT (declares nothing, unselectable: no yuv422 wire id —
  that append is a Wire/ slice — and no Ada silicon) yet VISIBLE in
  both surfaces as "not offered by this host", so the three-rung
  shape ships whole. The declaration is a singleton via
  `declaringChroma(tier:)` at connect AND on every F-5 re-dial; the
  per-host tier rides `PinnedHost.chromaTier` beside the CL-13/CL-15
  preferences (raw string, nil = Good, unknown-future tiers read
  Good, a re-pair preserves it). The strip's `ChromaStripMenu`
  (camera.filters glyph over the factual sampling caption, orange
  when non-Good) and the Actions-menu Chroma submenu share one model
  verb: flip = persist + clean reconnect on the proven F-5 machinery
  (chroma is connect-time only). `capabilitiesFailed` went TYPED
  (`CapabilityNegotiationError`, not a string) so
  `ChromaFallbackPolicy` can key on `noCommonChromaMode` + non-Good
  ONLY: downgrade the LIVE tier to Good, show the non-modal banner
  (8 s fade, stacked with the roaming banner's VStack), re-dial —
  the STORED ask stands (the host may gain the tier), and Good has
  nowhere lower so the re-dial cannot loop.
  THE AUDIT (4:4:4's win dies on a silent resample): `HevcSpsChroma`
  parses `chroma_format_idc` off every in-band IDR SPS (minimal
  spec walk, EPB strip, hostile bytes answer nil never trap);
  `ChromaStreamAudit` judges it against the agreed singleton — one
  confirmation line, a DOCTOR line on any mismatch edge, and the
  stats overlay + wire-view stats line print the OBSERVED chroma,
  not the ask. `wire-view --chroma 420|444` is the harness's
  declaration leg (the debug shell never auto-re-dials; the app
  does).
  ACCEPTANCE: root 175 → **188/188 (0 failures)** — 13 chroma gates:
  declaration singletons + frozen-CBOR round-trip, negotiator
  agreement against a V-4-shaped [420,444] declarer and the typed
  refusal against [420]-only, fallback verdicts (chroma-only,
  non-Good-only), persistence round-trips incl. unknown-future and
  hand-edited "better" strings, the SPS walk on pup's frozen
  production Rext SPS (EPBs included) plus every truncation, and
  the audit's once-then-silent discipline. DECODE PROOF (offline,
  M5): a fresh 60-frame Rext rgb_mode yuv444 cq4 stream off pup's
  production leaf (`lyte-encode-check`, p4/ull/qres) through
  `decode-probe --require-hardware` — 60/60 decoded, HARDWARE
  asserted, output '444v' with full-resolution chroma planes, no
  silent downsample.
  RAILS: owner's 41151 loop untouched (alive after); the three
  secrets sha-identical before/after; the 41183 `--no-advertise`
  test host and the windowed ffplay pattern killed; pup + local
  scratch removed.
  ANOMALIES / OPEN: (i) the resume brief's "41151 is 4:2:0" is
  STALE — the loop runs the V-4 build and its log shows the
  self-probe pass declaring [420, 444], so a Best connect there
  would AGREE at 444 and take the owner's session over; the
  fallback therefore stayed unit-gated — NO [420]-only host exists
  anywhere right now (a live fallback leg wants a pre-V-4 build or
  a probe-forced-off host). (ii) The LIVE wire leg is BLOCKED on a
  macOS Keychain prompt: wire-view (freshly build-cli.sh-signed,
  Authority=Lyte Dev verified) wedges in `SecItemCopyMatching`
  awaiting a SecurityAgent grant for the client Noise identity —
  the owner should click "Always Allow", after which `wire-view
  41183 --host 10.0.0.249 --chroma 444` against a `--no-advertise`
  V-4 host is the ready-made J-G4a warmup. (iii) The strip/menu/
  banner UI is code-reviewed + compiled only (launching the app
  hits the same Keychain wall); J-G4a's live leg should eyeball it.
  NAMED FOR THE NEXT RUNG: (i) root is FREE — the owner's bar
  recalibration micro-slice (`CorpusGates.swift`: text-converged
  ≥45 dB, gratings ≤±4, pin tests moved with them, one harness
  rerun) is unblocked; (ii) J-G4a runs the negotiated 444 session
  live end-to-end.

- **HS-26 — the fps ceiling hunt lands its fix: the capture thread
  stops waiting for the wire, and the session pipeline ingests the
  full 60** (`f00d2a9`, Host/ only, not pushed). Q-1's first red row
  (fps p50 47, bar ≥55, decomposed to "~48/s ingest under full session
  load") is ROOT-CAUSED with stage books and FIXED.
  THE ROOT CAUSE (books, not vibes): `SessionWire.sendFrame` ran
  encode → ingest → `drainToIdle()` SERIALLY on the one PipeWire video
  loop thread. The drain blocks until the token-bucket pacer walks the
  whole frame out at 1 ms quanta — a full frame's wire time stolen
  from `on_process` every frame. At the probe recipe that was ~7 ms of
  sleep per ~16.7 ms budget: the compositor queued buffers nobody
  dequeued and dropped the overflow — exactly the "not the wire, not
  the compositor" residue Q-1 measured. New per-stage books
  (gap/encode/ingest/drain µs, printed every 5 s in session mode, free
  when idle) showed drain eating the budget; file-mode never saw it
  because file-mode never paces.
  THE FIX (two seams, both lyte-host — HostWire's pacer untouched):
  (i) pacer drain moves to a dedicated sender thread
  (NSCondition-signaled, 1 ms pacer wakes; `nonisolated(unsafe)` under
  the existing lock discipline). The capture stack now pays ingest +
  the FIRST burst quantum only (the bucket is credited while idle, so
  that's one batch + one sendmmsg, tens of µs) and returns to the
  loop. (ii) a capture-side backlog gate: `Session.queuedVideoBytes`
  (new, pinned by a SessionGateTests case) → wire-time backlog; if it
  exceeds min(2 frame intervals, 25 ms) the frame is SKIPPED before
  encode — counted (`throttledFrames`), printed in the stage books and
  the final stats line. The old implicit compositor drops become an
  explicit bounded number; the estimator's rate is respected instead
  of the pacer queue growing.
  EVIDENCE (pup, 41183+/41187 `--no-advertise`, windowed testsrc2;
  client = the headless hs16-probe since wire-view still wedges on
  V-5's Keychain prompt; probe patched to make its 2 s IDR chirp
  opt-out via PROBE_IDR_SECONDS so the chirp couldn't skew the row):
  **before 48.5 fps ingest, after 60.8 fps** (1831 frames / 30.1 s,
  zero throttles at the 50 Mbps recipe, freshVideo max queue delay
  ~31 ms at session open only). Gate leg: encoder forced 40 Mbps over
  an 8 Mbps pacer throttles at the gate, counted, no queue blowup.
  Logs kept: pup /tmp/fpshunt-{baseline,fixed,gate,final}-{host,probe}.log.
  Suites: Host 186 → **187/187 Mac AND pup** (pup at the identical
  rsynced tree).
  RAILS: three secrets sha-identical at close against the pinned trio
  (portal_token dadf9a66…37cf, noise_static.key 72860390…cfed,
  paired_clients 8dc1f88a…55fd; key/paired mtimes still Jul 21/22);
  no netem; all test hosts + probes dead at close. The owner's 41151
  loop SELF-EXPIRED at run 60 (05:31 — its finite design, the resume
  brief predicted it; untouched by this worker) — restored fresh
  ~06:04, and it launches `~/src/lyte-host/.build/debug/lyte-host`, so
  it now runs the HS-26 build.
  NAMED FOR THE NEXT RUNG: (i) the beauty-bar fps row should be
  RE-MEASURED AT THE GLASS (quality-probe.sh) once wire-view's
  Keychain grant exists — this slice proved the decomposed quantity
  (ingest), which was the named bottleneck; (ii) the gate's throttle
  counter is the new tripwire — a nonzero count at a sane recipe means
  encoder rate and pacer rate disagree, look at the estimator first;
  (iii) `~/lyte-loop.sh` is still a finite 60-run loop — the standing
  "consider `while true`" note stands.

- **The IDR hunt — Q-1's last red row (IDR 3.9/min, bar ≤1) is
  ROOT-CAUSED with cause-tagged books and FIXED with the dwell
  deferral** (`5ea92ba` the books, `c2b58f1` the fix; Host/ only, not
  pushed).
  THE BOOKS (5ea92ba): `Session.takeFreshKeyframeDemand()` returns a
  typed OptionSet naming every keyframe source (path-promotion /
  client-request / wake / recovery / stale-nack / unprotectable; the
  stale-NACK latch split from the client 0x10 latch so they stop
  aliasing — behavior identical, the Bool poll delegates); the sink
  tags each emitted IDR (`idr:` line per event, `idr-books:` tally +
  IDR/min in the final stats) with the demand's names, "opening",
  "spontaneous", or the VBV reconfigure that forced it
  (vbv-tighten / vbv-rung / vbv-restore — every avcodec rc delta is a
  hidden NVENC reset + forced IDR, verified in FFmpeg 8.0 nvenc.c).
  The estimator records `OveruseFallForensics` at each fall and the
  `rate: ↓` line prints it (anchor, streak start/now/peak, backlog,
  freshest full train + age, loss posture) — the why-neither-gate-held
  post-mortem, inline.
  THE ROOT CAUSE (books, not vibes): the overuse verdict fires
  MID-dwell — ~60–80 ms into the hole's sub-pace trickle (the live
  forensics' "full-train 36 Mbps, 0 ms old" is the depressed trickle,
  not the drain) — but the compressed super-rate drain that lets
  HS-23's stall gate hold can only arrive on a report AFTER the hole
  closes. The verdict structurally beat the evidence on EVERY dwell;
  each fall then spent a vbv-tighten + vbv-rung/restore IDR pair
  (HS-22c's rungs coalesce the climb fine — the cost was the fall
  itself). Q-1's 3.9/min ≈ 2 IDRs × dwell rate.
  THE FIX (c2b58f1, RateEstimator only): a fall whose evidence is
  dwell-SHAPED — streak peak ≤ the 150 ms stall ceiling, loss clean,
  post-FEC clean, i.e. everything the stall gate wants except the
  drain — DEFERS report by report for at most the ceiling's own span
  (a dwell is by definition no longer). Drain arrives → stall hold as
  designed; shape sours (peak past ceiling, loss) → deferral aborts at
  once; budget expires → the fall proceeds ≤150 ms late (inside the
  500 ms fall limiter's granularity). Rises stay blocked throughout.
  New stat `fallDeferrals`, printed in the estimator books line.
  EVIDENCE (pup, 41183–41191 `--no-advertise`, windowed testsrc2,
  headless hs16-probe chirp-off; dwells induced with a tbf pulse
  scoped to the probe's bind port 41284 — 25 Mbit trickle 120 ms +
  100 Mbit drain 150 ms, ten per leg, ZERO loss; netem delay pulses
  were tried first and discarded: constant delay time-shifts without
  compressing, and its release REORDERS → fake loss falls):
  **before 22 IDRs = 7.42/min (10 tighten + 10 rung); after 1 IDR =
  0.34/min (the opening alone — 15 overuse verdicts, 14 deferrals,
  0 falls, rate never moved)**. Clean-loopback control: 0.41/min
  (opening only) both ends. Honesty leg (600 ms sustained 25 Mbit
  squeezes, inflation past the ceiling): **all five fell** ~150 ms
  late, anchored to measured delivery as ever — the deferral does not
  mask genuine squeezes (also pinned in the suite: every fall test
  rides out the budget; new headline pin
  `testFirstDwellFallDeferredUntilTheDrainTestifies`).
  Logs kept: pup `/tmp/idrhunt-{baseline,weather,dwell3-before,
  dwell3-after2,honesty}-{host,probe}.log` (dwell/dwell2/fixed legs =
  methodology dead-ends, kept for the netem-artifact record).
  Suites: Host 187 → **188/188 Mac AND pup**.
  RAILS: three secrets sha-identical at close against the pinned trio
  (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd); tbf/prio qdisc
  removed (lo back to noqueue); ffplay + all test hosts/probes dead;
  the owner's 41151 loop UNTOUCHED and alive at close (it relaunched
  mid-session per its own cadence and now runs the fixed build — the
  HS-26 precedent).
  NAMED FOR THE NEXT RUNG: (i) the beauty-bar IDR row should be
  re-measured against the REAL Wi-Fi weather (the owner's glass, Q-1
  methodology) — the tbf trickle-dwell is this worker's best synthetic
  of the study's dwells, not the weather itself; (ii) a GENUINE
  squeeze still costs 3 IDRs (tighten + rung + restore) because every
  nvenc rc delta forces an IDR — the structural remainder, named as a
  possible slice: an intra-refresh or non-IDR reconfigure path in the
  encode leaf; (iii) the baseline leg's `throttled 1364` at the
  50 Mbps recipe tripped HS-26's tripwire (frames p50 ~90 KB ≈ 43 Mbps
  vs 50 Mbps pacer — steady-state saturation headroom, not a stall);
  worth an eye on the next fps leg.

- **P-1 — the clipboard learns pictures: clipboard v2 lands whole,
  images ride chan 8 as marked cargo behind a Text + images consent
  rung** (`69cf895` Wire / `c4fae97` Host / `85571e2` root; none
  pushed). J-G4's second required half (owner decision 4) is CODE-
  AND-GATES DONE; the live NSPasteboard↔Mutter leg waits on J-G4a.
  ⚠️ WIRE WAS TOUCHED — a frozen-contract APPEND, per the P-1 plan
  row's allowance: capability key 12 (`clipboardImages`, dialect on
  the W7 spine like 9–11) and CTRL **0x22 ClipboardImageCargo**
  (transferId + mime), plus NEW vector file
  `clipboard-images-v1.json` (cargo codec nominal/boundary/reject +
  the key-12 spine bytes, anchored by ClipboardImageVectorFileTests).
  NO existing vector file moved — verified by suite AND git status.
  THE DESIGN (the H3 F-6 sketch inherited): an image copy rides
  F-2's bulk engines as memory-backed cargo on chan 8's ordered
  stream, the 0x22 marker travelling immediately BEFORE its
  transfer's BulkOffer — ordered carriage makes the marker race-free,
  so the receiver always knows a transferId is clipboard cargo (and
  its mime) before the offer could reach the file machinery.
  `ClipboardImageChannel` (Wire, sans-IO, BOTH session cores embed
  the identical type) owns the lane: marker handshake, the 32 MiB
  ceiling (local over-ceiling suppresses unsent; over-ceiling OFFERS
  draw abort(declined)), PNG-only mime in v2 (a foreign mime — say a
  v3 peer's JPEG XL — answers abort(declined) and the trailing offer
  is SWALLOWED, never leaked to the file lane), latest-wins lane
  occupancy (one transfer per direction; a superseded copy drops as
  sendBusy — clipboards are latest-wins by nature), and byte-keyed
  `ClipboardSyncBook` entries (image key = 0xFF‖sha256; 0xFF is never
  valid UTF-8 so the key spaces cannot collide) — ONE book per end
  suppresses text AND image echoes cross-modally.
  THE GATE IS 10∧12 AND NEVER 11 (the negotiation story): key 12
  is dialect and both clients always declare it; the HOST declares
  only under `--clipboard=images` (truthfulness — a text-only host
  never speaks it and v2 clients degrade to v1 against it with zero
  ceremony); images move only when 10 AND 12 both survived. Key 11
  (file-drop consent) is deliberately NOT in the gate — the consent
  tiers do not couple: a no-files host still syncs images, and each
  chan-8 lane wears its OWN rule-3 gate (unnegotiated 0x22 drops
  loud on a files-open channel; a bare file offer drops loud on an
  images-only one — both directions pinned both ends). The chan-8
  ARQ endpoint now arms on EITHER key.
  THE CONSENT TIER (LYTE-PLAN §8, Off / Text only / Text + images):
  host = `--clipboard` vs `--clipboard=images`; client = the images
  rung ON TOP of CL-15's text consent (per-host default on
  `PinnedHost.shareClipboardImages`, live strip photo-glyph +
  Actions-menu toggles, all gated on 10∧12 existing). One deliberate
  asymmetry from text: an unwelcome inbound marker draws a TYPED
  abort(declined) instead of text's silent deafness — the image
  sender waits on a digest verdict, so silence would leak nothing
  but strand the lane. PasteboardSync reads image flavors ONLY while
  the rung consents (public.png verbatim, TIFF transcoded through
  NSBitmapImageRep when the copying app never promised PNG) and
  writes applies as PNG + a TIFF rendition; the Mutter leaf mirrors
  it (portal read flavors behind `imagesEnabled`, PNG apply, owned-
  content serve). `wire-view --clipboard-images` is the J-G4a leg's
  harness surface.
  ACCEPTANCE (all unit/in-vivo sans-IO — the v1 CL-15 pattern; no
  live host processes were run): Wire 450 → **475/475 Mac AND pup**
  (codec + spine + channel loopback/refusal/violation + the vector
  anchor), Host 188 → **192/192 Mac AND pup** (4 gate legs: 10∧12
  negotiation sans key 11 + text-only degrade; both directions
  byte-exact through the sealed stack with both boomerang proofs;
  per-lane rule-3 drops; foreign-mime decline + offer swallow), root
  188 → **193/193 Mac** (5 legs: key-12 spine + default declaration;
  both directions + echoes through the REAL core against a stand-in
  running the production channel; tier off = typed decline, live
  toggle opens; per-lane rule 3 + ceilings incl. suppressedBusy;
  pinned-store plumbing incl. legacy decode + re-pair survival).
  RAILS: owner's 41151 loop untouched (no live legs at all this
  slice); three secrets sha-identical against the pinned trio
  (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd); no test hosts,
  no netem, no scratch.
  NAMED FOR J-G4a: (i) the LIVE leg — a real screenshot copied on
  pup landing on the Mac pasteboard and a Mac image copy landing in
  pup's clipboard, both under `--clipboard=images` + the client rung
  ON (the unit gates prove the whole wire path; the leaf↔OS edges
  want eyeballs); (ii) the strip's photo toggle + menu items are
  compiled-and-reviewed only (the V-5 Keychain wall stands);
  (iii) the portal clipboard's image-flavor serve on pup has never
  run against a REAL `wl-copy`/GNOME screenshot — first J-G4a
  minutes should confirm the mime list Mutter actually offers.

- **J-G4a first live legs — the Keychain wall falls, Best runs live
  end-to-end, and the clipboard carries real pictures both ways**
  (2026-07-29 ~11:10 MDT; live evidence only, no code commits — the
  ledger commit is the record).
  THE WALL: the SecurityAgent grant for the client Noise identity now
  EXISTS — wire-view ran from the agent shell with zero wedge. Every
  live leg below is unblocked; V-5's blocker note is retired.
  WARMUP LEG (pup 41201, `--no-advertise`, fresh `build-cli.sh`
  wire-view): negotiated **chroma 4:4:4 live** — host log `agreed [2]`,
  Rext rgb_mode "(VUI 601-limited, signed truthfully)", client SPS
  audit printed OBSERVED 4:4:4; **67,937/67,937 datagrams ok** (0
  unseal failures), first frame 495 ms, ~70 fps at 2.2 Mbps (static
  desktop, ratchet converged), clean typed teardown both directions
  (client shuttingDown → host peerTeardown, exit clean). **THE OWNER'S
  FIRST AT-THE-GLASS VERDICT ON THE NEW STACK, unprompted, mid-leg:
  "Video quality on that last test was MASSIVELY improved!!!"** — the
  444 + HS-26 + IDR-hunt stack's first eyeball, and it's a rave.
  Eye-on datum: `91 capture frames throttled` at session open
  (open-ramp shaped — freshVideo queue delay peaked 79 ms at open,
  then quiet; the HS-26 tripwire says watch it at the next fps leg).
  P-1 LIVE LEGS (fresh hosts 41203/41205 `--no-advertise
  --clipboard=images`, wire-view `--clipboard --clipboard-images`,
  one direction per run for unambiguous end states):
  - **Leg A pup→Mac PASS BYTE-EXACT**: a real `wl-copy -t image/png`
    (9,193 B ffmpeg testsrc2 PNG) mid-session → Mutter leaf reported
    1 image change → `image share completed (9193 B, sha-verified by
    the client)` → Mac pasteboard holds PNGf **sha-identical**
    (`de0cb363…`) plus the TIFF rendition, exactly as designed. The
    ledger's open Mutter-mime question is ANSWERED: the leaf reads
    wl-copy's image/png offer fine, first try.
  - **Leg B Mac→pup PASS BYTE-EXACT**: a real 60,607 B Mac
    screenshot set mid-session → client `clipImages 1/1 sent` → host
    `image received (60607 B, image/png) — applying`, `wl-paste
    --list-types` offers image/png and the served bytes are
    **sha-identical** (`4f0c9068…`, read live while the leaf owned
    the selection; 2 transfers served, 0 failed). BONUS LIVE PROOF:
    the host's own apply came back as a change and was **suppressed
    (loopEcho)** — the shared ClipboardSyncBook working live.
  Logs kept: pup `/tmp/jg4a-{warmup,clipA,clipB}-host.log`.
  RAILS: three secrets sha-identical at close against the pinned trio
  (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd); no netem; test
  hosts + the standing wl-copy killed at close; the owner's 41151
  loop untouched and alive (now `while true` + images tier, backup
  `~/lyte-loop.sh.bak-20260729`); Lyte.app rebuilt+re-signed at HEAD
  (`make-app.sh`) so the owner's bundle has the P-1/V-5 UI.
  REMAINING FOR J-G4a: (i) the harness's live end-to-end re-run at
  the glass — the beauty-bar fps row (quality-probe.sh, post-HS-26)
  and the IDR row vs REAL Wi-Fi weather; (ii) the owner's UI eyeball
  — Chroma control tiers, the photo-glyph toggle, fallback banner
  (`open .build/Lyte.app`, connect to pup 41151 — it agrees at 444).

- **The truth-probe — the IDR red's 20 Mbps "path" is exposed as the
  estimator measuring itself; the hunt is DISHONEST and slice (b) is
  confirmed-needed** (2026-07-29 ~12:05 MDT; live evidence only, logs
  kept — pup `/tmp/truthprobe-host.log`, local scratchpad
  `legB-flood.log`, iperf3 legs inline in the session transcript).
  LEG A (path capacity, session-shaped): iperf3 UDP pup→Mac at the
  wire's own 1152 B datagrams — **25 M offered → 22.8 delivered 0%
  loss; 45 M → 44.5, 0% loss; 80 M → 66.9, 0% loss**. The path
  comfortably carries the freed 60 fps appetite (~43 Mbps); ~20 Mbps
  is NOT an airtime ceiling.
  LEG B (the discriminator, 90 s armed 444 heavy-motion session +
  35 M side-flood at t+40): the session opened clean at **~40 Mbps /
  55 fps**, then fell into the KNOWN HS-22b(ii) floor spiral — a
  limit cycle between 0.1 and 1.6 Mbps for the rest of the leg,
  never recovering — **while the side-flood delivered 30.0 Mbps at
  0% loss THROUGH the same air at the same moment**. The estimator
  held the glass at the floor with 30+ Mbps of headroom provably
  idle.
  THE CONFESSION IN THE FORENSICS (the IDR-hunt books, doing their
  job): one fall recorded `full-train 348492 kbps 39 ms ago` — fresh
  evidence of a ~348 Mbps drain — and fell anyway, anchored to a
  5.6 Mbps delivery figure; the final fall anchored to `full-train
  398 kbps 0 ms ago` — its own starved pacing, re-anchored at
  0.85×self, exactly the HS-22b(ii) self-reference seam. 9 falls in
  90 s. The dwell deferral held where it applies (first fall's
  streak peaked 164 ms — past the ceiling, correctly not deferred).
  VERDICT: the saw-tooth behind the 15.2/min IDR red is largely the
  estimator's own artifact. **Slice (b) is upgraded from
  "if-proven" to CONFIRMED-NEEDED**: the anchor must not trust
  delivery samples measured under its own squeezed pacer (windowed-
  max robustness / self-reference guard — HS-16's flagged revisit +
  HS-22b(ii), now with decisive instrument evidence). Slice (a)
  (non-IDR reconfigure) proceeds first per the owner's ruling — it
  kills the per-move cost in both worlds.
  RAILS: secrets sha-identical (pinned trio); ffplay + iperf3 +
  test host killed at close; owner's 41151 loop untouched and alive.

- **HS-27 slice (a) — rate moves stop minting IDRs: the encoder
  posture parks on halving rungs and 2419 estimator moves ride the
  pacer for zero resets** (`f0f62a4`, Host/ only, not pushed).
  THE INVESTIGATION FIRST (the brief's option 1, closed honestly):
  pup runs distro FFmpeg 8.0.1 (`libavcodec62 7:8.0.1-3ubuntu2`,
  shared). n8.0.1 nvenc.c `reconfig_encoder` (fetched and read at the
  tag) gates rc deltas on `support_dyn_bitrate` and sets
  `resetEncoder = 1; forceIDR = 1` UNCONDITIONALLY for any
  avg/max/VBV change — no AVOption avoids it. NVENC's own
  NvEncReconfigureEncoder does support resetEncoder=0/forceIDR=0
  rate moves, but the session handle lives in the wrapper's private
  NvencContext: reaching it means offset-hacking a distro .so's
  private struct (and desyncs the wrapper's cached encode_config,
  whose diff drives reconfig), and a raw NVENC SDK rewrite of
  CHevcEncode would re-risk everything landed (VUI truth-signing,
  Rext 444, the ratchet). Non-IDR reconfigure through THIS libavcodec
  is structurally unreachable — option 2 chosen, recorded here so
  nobody re-derives it.
  THE DESIGN (EncoderVbvPolicy, HostWire — RateEstimator untouched
  by construction, slice (b) lands orthogonally): the posture is
  QUANTIZED to halving rungs of the recipe cap (rung_i = cap/2^i),
  applied rung = smallest rung ≥ the live ceiling-rate (round UP —
  the posture never sits below the wire; the PACER enforces the
  exact fine rate at zero encoder cost, the backpressure gate bounds
  the ≤2.2× posture/pacer slack). Asymmetric hysteresis: a TIGHTEN
  past a 10%-margined rung boundary fires instantly (the fall side
  is B2's; protection stays real); a LOOSENING (rung climb or
  restore) fires only after the want holds CONTINUOUSLY for 10 s
  (`riseSustainNS`) and jumps to the rung of the window's MINIMUM
  ceiling — a hunt whose falls recur inside the window resets the
  clock every cycle, so the posture PARKS and the whole hunt is
  absorbed. The k-window VBV ladder rides at the rung's own depth;
  rung_0 mins back to the HS-25 guarded baseline, so marginal
  squeezes and clean-boundary flapping cost NOTHING. Books:
  `EncoderRateDirective.kind` (tighten/loosen/restore) makes the
  idr-books tags policy-decided instead of sink-inferred, and
  `rateMovesAbsorbed` counts every polled ceiling move that touched
  no encoder — the stats line prints it ("2419 rate moves absorbed
  (pacer-only, no encoder reset)"), the honest stand-in for the
  unreachable "non-IDR reconfigures applied".
  EVIDENCE (quality-probe.sh re-run whole at `cea0ef6`+slice, port
  41209 `--no-advertise`, the standing recipe; summary
  /tmp/quality-probe-summary.txt, logs pup /tmp/hs27-{before,after}-
  wire-{armed,twin}.log + ~/qprobe/, local /tmp/hs27-qprobe-run.log
  + /tmp/qprobe-local/):
  **before (932a4c3 leg): 38 IDRs = 15.19/min, 31 directives / 31
  applied — vbv-rung 17 + vbv-tighten 13 + vbv-restore 1 (+ client 7,
  opening 1), ≈0.12 IDR per estimator move. After: 19 IDRs =
  7.60/min, 14 directives / 14 applied / 2419 moves absorbed —
  vbv-rung 7 + vbv-tighten 7 + restore 0 (+ client 4, opening 1):
  the MULTIPLIER is 14/2433 ≈ 0.006 IDR per rate move, 20× down —
  the slice's success metric, met.** Row printed: `2026-07-29 @
  cea0ef6 | static 52.03 PASS | motion 59.72 PASS | fps 61 PASS |
  IDR 7.6 FAIL | churn 0 PASS | loss 0 PASS` — fps p50 58 → 61.
  THE RESIDUE IS SLICE (b)'S, VISIBLY: the per-IDR trace shows every
  remaining reconfigure IDR inside the estimator's known HS-22b(ii)
  floor spirals (three collapses; each walks the ladder down ~3
  tightens in ~2 s, each recovery pays one rung per 10 s sustain;
  the leg ENDS floor-pinned at 390 kbps believing 1.2 Mbps delivery
  on the wire the truth-probe proved carries 30+ Mbps). Between
  collapses the saw-tooth parked completely. IDR ≤2/min stays red
  until the estimator stops diving — reported loudly, as briefed.
  HONESTY LEG INTACT: the twin `--no-vbv-reconfigure` run froze the
  glass again (fps p50 1, 81 IDR = 32.4/min of client begging) —
  the directives stay load-bearing; the ladder coarsens their
  cadence, never their protection.
  Suites: Host 192 → **196/196 Mac AND pup** (new pins: the
  saw-tooth hunt pays zero encoder touches; deep falls tighten
  immediately through any hold; sustained loosening jumps to the
  held minimum's rung; recurring falls reset the sustain clock;
  guarded-baseline engage and restore are free; boundary dither
  parks; absorbed moves counted only on real ceiling moves).
  RAILS: three secrets sha-identical at close against the pinned
  trio (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd — probe
  verified + re-checked by hand); ffplay/iperf/test hosts all dead,
  41209 free; the owner's 41151 loop untouched and alive (it
  self-respawned mid-session per its own cadence and now runs the
  HS-27 build — the HS-26 precedent).
  NAMED FOR SLICE (b): (i) the estimator's floor spirals are now the
  ONLY remaining reconfigure-IDR source at the bar — when the fall
  law stops trusting self-squeezed delivery samples, the vbv books
  should read ~opening-only and the IDR row goes green on this
  ladder unchanged; (ii) `riseSustainNS` (10 s) sets the recovery
  ladder's climb cadence — if slice (b) makes genuine recoveries
  common, that knob trades climb IDRs against mud time and is the
  first thing to retune (it is config, not law); (iii) the absorbed
  counter gives slice (b) a free live discriminator: estimator moves
  vs encoder touches, one stats line.

- **HS-28 slice (b) — the estimator reformulation lands whole: a
  capacity belief anchors every fall, all three shape-gates are
  retired, and the truth-probe's limit cycle is dead at the glass**
  (`03d96d1` the model + `ceed7b1` dwell-deferral retirement +
  `1579043` stall-gate retirement + `544fa70` self-reference
  retirement + `ed4d39f` the live-rerun fixes; Host/ only, not
  pushed).
  THE MODEL (RateEstimator, the brief's shape): the send ledger
  records the pacer rate at each datagram's RELEASE; sample
  production classifies every full train mechanically — CENSORED
  (measures ≈ its own recorded pace; may only RAISE the belief),
  HONEST (measured < 0.8 × pace — the path stretched it; it votes),
  COMPRESSED (≥ 1.25 × pace — drain evidence, raises the belief AND
  purges mid-hole honest votes). One belief `beliefBits`: raised
  instantly by any delivery above it, demoted ONLY at an executing
  fall to a fresh honest median (≤ 2 s old), NEVER by aging —
  aging-while-censored was leg B's self-confirmation vector. The
  fall law is one honesty law: verdicts decide WHEN (unchanged);
  EXECUTE on instant corroboration (pre-FEC loss ≥ clean band, or
  post-FEC > the rung-3 bar) or on pressure persisted a full
  fall-limiter window into the next AND not purely self-explaining
  (monotone queue growth, honest median under the belief, or no
  standing backlog to blame); the fall lands at clamp(min(0.85 ×
  demoted belief, 0.85 × rate)) — the raw-median anchor is
  forensic-only now. Self-inflicted evidence recuses itself: NACKs
  naming frames with shards still queued in our own pacer
  (VideoChannel keeps per-frame books) feed nothing; the pre-FEC
  ledger path was AUDITED CLEAN (host-side skips never consume a seq
  or frame number). TX-stamp audit (measurement integrity i): the
  ledger already stamps at pacer EGRESS — noteSent fires in the pump
  sink with a fresh monotonic now, sendmmsg follows in the same
  drain pass; contamination is µs-scale + ≤1 quantum of batch-shared
  stamps. Full kernel-TX-stamp reconciliation (SO_TIMESTAMPING is
  plumbed in CNetIO since HS-4 but unread by the live host) is the
  named follow-on if socket-buffer blocking is ever suspected.
  THE GATES: all three retired, one commit each, each justified by
  its frozen pins passing without it (loop bounds widened from the
  150 ms deferral budget to the 500 ms persistence span — the
  brief's sanctioned ≤1 extra limiter beat; every asserted anchor
  value untouched). The books keep the gates' vocabulary
  (selfReferenceHolds / stallHolds / fallDeferrals) as
  classification, not law; `selfReferenceBandFraction` retired with
  its gate. New knobs: censoredSampleMarginFraction 0.2,
  beliefDemotionSustainNS 500 ms, honestVoteWindowNS 2 s.
  THE LIVE LOOP DID ITS JOB (the brief's "stop, fix the model"
  path, exercised once): the first leg-B rerun beat the truth-probe
  (recoveries to a restore, no limit cycle) but its forensics
  convicted two residual seams in single lines — `honest 8316 kbps …
  full-train 98429 kbps 0 ms ago` (mid-dwell stretched trains
  reading honest while the drain that closed the hole sat in the
  same report) and a 41 ms streak crashing to the floor on ~1%
  post-FEC NACK echo as "instant" corroboration. Fixed in `ed4d39f`:
  drains purge mid-hole votes at sample production (HS-23's insight
  moved INTO the measurement), and sub-rung-3 post-FEC waits for
  persistence. Both live shapes pinned verbatim in virtual time.
  LEG B RERUN (pup 41213 `--no-advertise`, windowed testsrc2, Mac
  wire-view 444 90 s, 35M flood at t+40; log /tmp/hs28-legb2-host.log):
  **NO floor limit cycle.** Open → one honest fall (13.5 Mbps,
  anchor = honest 15.9M, 521 ms streak) → steady climb to 49 Mbps —
  the glass held 56–58 fps at ~39.7 Mbps steady pre-flood (vs the
  truth-probe's 0.1–1.6 Mbps death). Flood window: genuine crash to
  ~3M on 4.8% real pre-FEC loss (the flood took 35 of the ~45M the
  air carries — iperf3 verified 45M/0% the same minute) with
  IMMEDIATE recovery climb after; leg ended 22.6M still climbing.
  5 falls total (was 9), every one carrying honest/corroborated
  forensics; 1818 honest / 2628 censored trains classified live,
  0 self-reference holds, 66 persistence deferrals, 5 stall holds.
  HONESTY LEG (pup loopback 41217 + hs16-probe bind 41284, prio+u32
  tbf 25mbit scoped to the probe port; /tmp/hs28-honesty-host.log):
  squeeze onset → first fall in **519 ms**, anchored 22.0 Mbps =
  0.85 × the honest 25.9M reading — at the shaper. Under the
  sustained shaper the session parks in a tight 22.3–26.5M sawtooth
  delivering ~23M through the 25M pipe. Fast fall intact, anchor
  honest. Qdisc removed — lo back to noqueue, verified.
  IDR/MIN, REPORTED STRAIGHT: clean armed leg (41215, no flood):
  16 IDRs = 10.69/min (rung 5 + tighten 5 + restore 1 + client 4 +
  opening 1) vs HS-27's 7.60/min — the counts are not comparable
  leg-to-leg (this leg took real 3.3–8.9% loss overrun events) and
  the composition is the story: HS-27's leg ended FLOOR-PINNED at
  390 kbps believing 1.2M with every reconfigure-IDR inside the
  false spirals; this leg never pinned, ended climbing, and its
  reconfigure IDRs are genuine congestion-probe cycles — the 50M
  recipe cap sits ABOVE the ~45M air, so each climb-to-cap overruns,
  falls honestly, and pays a tighten+rung pair. The false-move
  source slice (b) was commissioned to kill is dead; the residual
  cost is the probe cadence against an over-capacity cap.
  NAMED FOR THE NEXT RUNG: (i) cap-aware probe damping — the climb
  re-walks to a cap the belief repeatedly disproves; a probe ceiling
  near min(cap, belief × ~1.1) (config posture, not law) would kill
  most remaining tighten+rung pairs and is the straightest path to
  the IDR bar; (ii) the beauty-bar row itself still wants the
  quality-probe re-measurement on the owner's weather (J-G4a's
  remaining leg — this slice's legs ran under flood/shaper rigs);
  (iii) kernel-TX-stamp reconciliation stays named-not-needed.
  Suites: Host 196 → **203/203 Mac AND pup** (new pins: leg-B
  replay gate, persistence twin, belief raise/demotion mechanics,
  NACK recusal both ways, queued-shard books, drain purge, echo
  persistence). RAILS: three secrets sha-identical at close against
  the pinned trio (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd);
  lo noqueue; all test hosts/probes/ffplay/iperf3 dead; the owner's
  41151 loop untouched and alive (it self-respawned per its own
  cadence and now runs the HS-28 build — the HS-26 precedent). One
  ops lesson re-learned: an unbracketed pkill pattern over ssh
  matched its own remote shell — the rails' bracket trick is not
  optional. Logs kept: pup /tmp/hs28-{legb,legb2,clean,honesty}-host.log,
  /tmp/hs28-honesty-probe.log; Mac /tmp/hs28-{legb,legb2,clean}-client.log.

- **HS-29 — cap-aware probe damping: the climb learns where the wall
  is, and the loss red dies** (`be60e92`, Host/ only, not pushed;
  coordinator-inline slice — the worker pool was down on 529s, four
  terminations, so the coordinator took the brief itself).
  THE CHANGE (small on purpose): the upshift's target is now the
  PROBE CEILING — `min(configured cap, belief × probeHeadroomFactor)`
  (new config knob, default 1.10, precondition >1.0) — instead of
  the raw configured cap; new stat `upshiftsDamped`, printed in the
  estimator books line as "N upshifts (M probe-damped)". Fall law,
  belief mechanics, HS-27's rung ladder: untouched.
  GATES: Host 203 → **206/206 Mac AND pup**. The three new pins print
  the physics: climb parks at 22.0 Mbps over a 20.0 belief under a
  50 cap with ZERO falls (1 damped rise); capacity step 20→45 walks
  the rate to 40 Mbps in 6.7 virtual seconds with the belief
  following (ossification guard); factor 1.5 parks at 30.0.
  THE ROW (bar row ⁴, probe at this HEAD): **loss 6 → 0 (1 datagram
  in 117,192) — the loss red is RETIRED**; fps holds 61; IDR 6.8 →
  6.4/min. Twin leg froze again (fps p50 6, 27.4/min) — directives
  still load-bearing.
  THE RESIDUE HAS A NAME (the books convict the next bug): the armed
  leg's own estimator line shows **belief 207 Mbps** — compressed
  drain trains raise the belief to instantaneous drain rates, so the
  probe ceiling almost never bound (2 damped rises / 2,686 upshifts)
  and the climb still slammed the ~45 Mbps air 12 times (12 honest
  falls → rung 8 + tighten 6 IDRs). Corroborated in both honesty
  legs (belief 266 Mbps, 1.18 Gbps) — one of them the OWNER'S OWN
  STRESS TEST (a YouTube window dragged across the screen mid-leg).
  HS-30 NAMED: (i) sustainable-vs-burst belief split — drains keep
  purging mid-hole votes but stop setting the probe ceiling;
  (ii) near-ceiling probe cadence (BBR PROBE_BW's shape) instead of
  continuous climb pressure. The pairing is the endgame for the last
  red cell (bar ≤2/min needs falls ≤ ~2 per 150 s).
  HONESTY LEG (clean rerun after the stress contamination): 25 Mbit
  tbf scoped to 41217 — fall **517 ms** after onset, honest anchor,
  full recovery to the 50 Mbps ceiling after release, 0 self-ref
  holds. Contaminated leg kept for the record (hs29-honesty vs
  hs29-honesty2 logs).
  RAILS: secrets byte-identical (pinned trio); wlp0s20f3 back to
  noqueue after both tbf legs; ffplay + all test hosts dead; owner's
  41151 loop untouched; logs pup `/tmp/hs29-*` + `~/qprobe/`, local
  scratchpad `beauty-bar-run3.log`, `hs29-honesty*.log`.

- **HS-30 — burst-vs-sustainable belief + probe cadence: the last
  red's endgame opens, and the leak teaches the law its final form**
  (`db84c1b` the two mechanisms + `3f6fcf1` the refine; Host/ only,
  not pushed; coordinator-inline — the worker pool stayed down on
  529s all afternoon).
  MECHANISM 1 (sustainable belief): belief raises cap at the PACE the
  train was sent behind. First cut capped only classified drains
  (≥1.25× pace) — the official row ⁵ probe caught the leak (samples
  at 1.0–1.25× pace raised the belief to 61 Mbps over the 50 cap;
  IDR 8.4/min). The refine is the law's final form: `min(rate, pace)`
  universally — **no arrival outruns its sending**. One HS-28 pin
  amended with documentation (the drain-purge pin EXPECTED burst
  inflation — that expectation was the bug; its protective
  assertions stand, now bounded both sides).
  MECHANISM 2 (probe cadence, BBR PROBE_BW's shape): an overuse fall
  that fires inside the belief's headroom band arms a 10 s cadence
  (`probeCadenceNS` knob); rises back INTO the band wait, climbs
  below it stay continuous (HS-29's capacity-step pin unchanged —
  20→45 in 6.7 virtual s). New stat `upshiftsCadenceHeld`, in the
  books line.
  GATES: Host 206 → **208/208 Mac AND pup** (drain-cap pin: a
  300 Mbps burst moves the belief 20.0 → 20.5, not to 300; cadence
  pin: fall in the band parks the climb below it, re-probes at
  expiry).
  MEASURED: official row ⁵ at `db84c1b` (leaked build) 8.4 FAIL —
  recorded un-massaged, the red convicted the leak. At the refine
  (155 s armed leg): belief honest 50000, **4.26 IDR/min** (rung 4 +
  tighten 4 + client 2 + opening), 307 cadence-held rises, fps
  intact. Honesty leg: fall **519 ms** after tbf onset anchored
  27.2 Mbps ≈ the shaper, recovery to ceiling, qdisc removed,
  secrets byte-identical, all test processes dead, owner's 41151
  loop untouched. Official probe row for `3f6fcf1` queued.
  THE REMAINDER (footnote ⁵): genuine weather dips crossing an HS-27
  rung cost 2 IDRs each (tighten + recovery rung). Candidates:
  dip-scoped rung hysteresis (cheap) vs the true kill, a non-IDR
  encoder reconfigure (the FFmpeg wall). Bar ≤2/min needs roughly
  half of 4.26's episode cost gone.

- **HS-31 — the audio trio: the pops' three seams closed — audio
  stops waiting out video's deficit, the parked sender thread gets
  its wake, and the underrun boundary stops cracking** (`39d6786`
  Host/, `2049ede` root; not pushed).
  FIX 1 (the careful one, consult-corrected shape — NOT the §1
  serialization floor, which converts delay into bursts): at deep
  falls the 1 ms quantum shrinks below one datagram (62 B at the
  500 kbps floor), so one ~1230 B video datagram emits alone and
  drives the shared bucket ~19 ms negative; strict priority could
  not preempt an in-flight deficit, and `setRate` carried the debt
  across falls repriced at the new rate. Now LATENCY CLASSES
  (control, audio) emit alone through a negative balance and CHARGE
  the shared bucket (Pacer.swift nextBatch + nextWake): video repays
  audio's bytes too, the wire total still honors the estimator's
  verdict, the exemption's volume is structurally capped by strict
  priority (~320 kbps incl. RS 4+2), and video never borrows it.
  The trigger is surgical — only a negative balance (which only the
  oversize-emit-alone clause can create), so every positive-bucket
  behavior, the ≤1 ms batch bound, class order, DSCP 48, and R-G8
  cadence are byte-identical.
  FIX 2 (tiny): `sendAudioPacket` could exhaust its 4 bounded ~1 ms
  retries and give up WITHOUT `signalDrain()` — the shard then sat
  until the next video ingest woke the sender thread (+16 ms worst
  on a 5 ms budget). Every exit now signals when audio is still
  queued (including the error path).
  FIX 3 (root): the client ring underrun hard zero-pad (every edge
  an audible crack; worst leg 1.58 s of zero-fill) is declicked in
  the render callback: the pad DECAYS the boundary sample to true
  zero over ~2 ms — continuous by construction wherever the
  shortfall lands, which a callback-local fade-out cannot promise —
  and recovery CROSSFADES from the tail's standing value (covers
  recovery landing mid-decay). Steady state byte-exact; underrun
  books untouched; all state preallocated, render thread stays
  lock/allocation-free.
  PINNED: PacerTests ×2 (500 kbps deficit cadence ≤2 ms while video
  pays the full debt + audio's charge; setRate-carried deficit) and
  AudioGateTests through the REAL session path (nextWake=now with
  audio queued under deficit — the seam fix 2's wake relies on; the
  fix-2 sender-thread half itself is executable-only, code-reviewed
  + live-proven). testGateAudioCadenceHoldsThroughRateCrash holds
  unchanged. Root: AudioDeclickGateTests (4 legs) drives the
  production render path into hand-built deinterleaved buffers —
  no adjacent jump over the click threshold across cut/drought/both
  recovery shapes, exact silence past the decay, byte-identical
  steady state. Suites: Host 208 → **211/211 Mac AND pup**, root
  193 → **197/197 Mac**.
  LIVE PROOF (pup, tbf 25mbit dport-scoped dips ~t+30 for 20 s,
  windowed Wayland testsrc2, wire-view --audio 90 s foreground;
  logs /tmp/hs31-{before,after,after2}-*):
  BEFORE (pre-fix binary, port 41225): falls to the 500 kbps floor;
  **max audio queue delay 106.6 ms** (worse than the audit's
  22.9–53.6); client plc 194 / late 192 / underrun 48,149 frames.
  AFTER (fixed build): leg 1 (41227, floor hit twice) **6.16 ms**;
  leg 2 (41229, fresh ffplay, much hotter — 84 MB vs 20 MB, 61 fps,
  falls to 884 kbps) **8.07 ms**. Client books, honestly: leg 1
  plc 112 / late 112 / underrun 31,934; leg 2 plc 191 / late 191 /
  underrun 65,942 — the hotter leg's air cost more; underruns
  remain radio-priced and their EDGES are now faded by fix 3 (the
  counter is intentionally unchanged). The 20–50 ms → ≤ ~7 ms
  target is met at 6.2 and grazed at 8.1 on the hot leg vs 106.6.
  RAILS: secrets byte-identical before/after every leg (noise
  72860390…cfed, paired 8dc1f88a…55fd; portal_token rotates by
  design); wlp0s20f3 noqueue verified after each tbf; all leg
  hosts/ffplay dead at close; owner's 41151 loop untouched (same
  PID start to finish) — it launches `.build/debug/lyte-host`, so
  its next respawn runs the HS-31 build (the HS-26 precedent).
  NAMED FOR THE NEXT RUNG: (i) the 8.07 ms hot-leg max — worst
  single wait in 17.7k packets, likely sender-thread scheduling
  under load, worth a look if the owner still hears anything;
  (ii) the leg-2 pattern "plc == late exactly" persists — arrivals
  beyond the jitter target, the receiver's ledger is honest;
  (iii) ffplay supply degrades over long runs (2,662 repeated
  frames by leg AFTER-1) — fresh ffplay per leg stays the rule.

- **HS-32 — the dead repair lane revives: the freeze budget derives
  from the cadence, refusals become wire words, and the 250 ms blind
  wait dies** (`218c5b7` Wire / `a7fcb5f` Host / `2d805bf` root; not
  pushed). The squeeze review §2's find, built to the consult's
  corrected design (repair-when-plausible, fail-explicitly-otherwise —
  NOT "die faster").
  ⚠️ WIRE WAS TOUCHED — a frozen-contract APPEND, the P-1 shape: CTRL
  **0x23 RepairRefusal** (`type ‖ frame u32 LE ‖ reason u8`, fixed
  6 B; reasons stale-budget 0x01 / superseded 0x02 / unknown-frame
  0x03), host→client, sealed, ARQ-exempt fire-and-forget like 0x10 —
  a LOST refusal degrades to the client's own deadline expiry, pinned
  as contract. NEW frozen file `repair-refusal-v1.json` (10 vectors:
  whole reason space, frame boundaries, every decode-reachable
  reject), hand-computed anchors in RepairRefusalCodecTests. NO
  existing vector file moved — verified by suite AND git status.
  CAPABILITY GATING — decided NO KEY, evidence pinned: unknown CTRL
  ids are skipped silently on BOTH carriage modes today (bare
  ARQ-exempt payloads fall through BeaconEchoResponder's type peek
  unconsumed — LyteUdpSession.handleDatagram's exempt tail; ARQ
  unknowns are counted-and-dropped at dispatchReliable's default —
  "hostile bytes are counted, never fatal"), so a v1 client ignoring
  0x23 lands exactly on the lost-refusal behavior. The append is free.
  HOST (the budget was the disease): `repairFreezeBudgetNS = 33 ms`
  constant vs the 40 ms feedback cadence meant asks were dead on
  arrival BY CONSTRUCTION (twin-leg books: 82 asks, 1682 shards, 0
  repaired, 28 expired→IDR). Now **budget = 1.5 × observed report
  inter-arrival EWMA + 15 ms jitter allowance** (samples clamped to
  the wire-pinned 25–50 ms cadence range so out-of-cadence NACK
  flushes/lost reports never masquerade as the cadence; 50 ms
  documented worst case before evidence → 90 ms pre-evidence, 75 ms
  at the reference 40 ms cadence — far inside the client's 250 ms
  assembler horizon, so "honor" still promises a repair the glass can
  use). `repairFreezeBudgetOverrideNS` replaces the constant (nil =
  derived). Actionable stale verdicts (budgetExceeded → stale-budget,
  olderThanIdr → superseded, unavailable → unknown-frame) each send
  one 0x23; alreadyRepaired stays SILENT (repairs may be in flight —
  a refusal would double-heal into an IDR) and FROZEN/closed stays
  silent (path dark; the fallback is the honest answer). OPENING-IDR
  EXEMPTION (consult's bounded shape): while no feedback report has
  yet shown the opening IDR's group delivered clean (missing 0,
  received ≥ its shard count — the conservative host-visible proxy
  for "anything on glass"; it stays armed under early loss, which the
  bounds make safe), an ask naming the LAST IDR is honored regardless
  of budget and even without SRTT — bounded by attempts (4) and bytes
  (2 MiB), plus the client's own once-ever ≤250 ms ask discipline
  from the other end. Books: refusals sent, opening-exempt honors,
  in-force budget on the repair stats line.
  CLIENT: 0x23 → NackPolicy.handleRefusal — a live ask escalates
  IMMEDIATELY through the existing rate-windowed IdrRequester (book
  sealed; in-flight answers land superseded), unknown/duplicate
  refusals ignored loud on their own counter, the 250 ms deadline
  kept as the lost-refusal fallback. Books refusals rx/acted/ignored
  in wire-view's nack line; refusal-acted deliberately does NOT count
  in expired→IDR (the residual composition stays honest).
  GATES: Wire 475 → **486/486 Mac AND pup** (codec + vector anchors
  byte-exact both platforms), Host 211 → **219/219 Mac AND pup**
  (derivation math; the on-cadence ask that now FLIES at 50 ms where
  33 ms refused it; every refusal reason decoded off the wire; silent
  verdicts stay silent; black-glass repair regardless of age + both
  bounds + glass-evidence kill), root 197 → **198/198** (leg H: a
  sealed refusal through the REAL receive path → immediate IDR, dupes
  and unknowns counted).
  LIVE PROOF (pup, hosts 41231–41243 `--no-advertise --seconds 140`,
  fresh windowed Wayland testsrc2 per leg, wire-view `--host-key`
  throwaway identity — the Keychain path was dark-wake-blocked
  (-25320) with the owner away; the debug-harness posture is exactly
  for this):
  - BEFORE (HEAD host from git archive, 4% video-scoped netem 30 s
    mid-leg): host **7 asks → 0 honored, 7 stale, ALL SILENT** (srtt
    17.4 ms vs the 33 ms constant); client 0 repaired, **2
    expired→IDR** (each a full 250 ms freeze), host idr-books 10
    (client-request 2 + stale-nack 2). Logs
    /tmp/hs32-before-{host,client}.log.
  - AFTER (HS-32 both ends): the headline leg (41243, 4% loss
    t+20…t+55): **1 ask honored → 3 repair datagrams → the frame
    HEALED BY REPAIR client-side** (repairs rx 1, frames repaired 1,
    no IDR for it) AND **1 genuinely-superseded ask → refusal →
    acted→IDR immediately**; **expired→IDR 2 → 0** — no 250 ms burn
    anywhere; derived budget 74 ms; 61 fps at the glass through the
    window. Supporting legs: 41233 (netem) 3/3 honored → 10 repair
    datagrams, 2 repairs rx / 1 repaired, budget 69 ms, ZERO stale;
    41237 (5%, IDR-churny converged floor) 10 asks all honestly
    superseded → 10 refusals, **4 acted→IDR, 6 duplicates ignored
    loud**, 0 expired→IDR. Residual IDR composition after: refusal
    escalations (immediate, correct — the newer IDR was already the
    heal) + rate-move IDRs; the deadline path never fired. Logs
    /tmp/hs32-after{,2,3,4,5,6}-*.log (Mac) + pup /tmp/hs32-*.log.
  OPS HONESTY: (i) pup-side netem (prio+u32 on wlp0s20f3) WEDGED the
  Wi-Fi driver's UDP queues bidirectionally on its second install —
  leg 41233 died at netem-ON (both liveness clocks closed it; ssh TCP
  flowed throughout); impairment moved to Mac-side dummynet (pfctl
  anchor com.apple/lyte-hs32 + dnctl plr, pf re-disabled by token
  after — verified Disabled, dnctl empty) — prefer dummynet for
  future lossy legs. (ii) A combined pkill+start ssh SELF-MATCHES
  (`ffplay -f lavfi` sits literally in the shell's own cmdline —
  bracketing can't save it); kill and start in SEPARATE ssh calls, or
  video silently never starts and the leg reads "layer idle" (legs
  41235/41241 burned on this). (iii) ~130–150 unseal-failed appeared
  only inside dummynet windows (pf-duplicated datagrams rejected by
  the replay window — harmless, absent on netem legs). (iv) Stale
  ffplay strikes again: a reused supply degraded to 13 fps/1 KB
  frames (k=1 — nothing can go past parity); fresh ffplay per leg
  remains the law. RAILS: owner's 41151 loop untouched (its own
  respawns now run the HS-32 build — the HS-26/HS-31 precedent);
  secrets byte-identical at close INCLUDING portal_token
  (72860390…cfed / 8dc1f88a…55fd / dadf9a66…37cf); wlp0s20f3
  noqueue verified; no test hosts, no ffplay, dnctl flushed, pf
  Disabled; lyte-cli rebuilt+signed at HEAD.
  NAMED FOR THE NEXT RUNG: (i) repair-lane DSCP (the HS-17/CL-12
  deferred row) — repairs still ride 0xA0 with video, so a video-
  scoped impairment eats the repairs too; (ii) the opening exemption
  never fired live (opening IDRs arrived clean every leg) — pinned by
  the unit gate only; a deliberate opening-loss leg would give it
  live books; (iii) the estimator's converged-floor IDR churn
  (vbv-rung/vbv-tighten at low rates) is what made every 41237 ask
  superseded — the non-IDR-reconfigure slice (§3) will collapse that
  class; (iv) client asks can be LARGE (17 shards of a 19-shard
  frame when loss hits a whole train) — the repair serialization term
  prices it, but a per-ask shard cap is cheap if it ever matters.

- **HS-33a validation spike — the FFmpeg wall falls on real hardware:
  a 6-line-patched static hevc_nvenc moves rate AND VBV with ZERO
  reconfigure IDRs, and every no-reset frame decodes clean on the
  production hardware path. VERDICT: GO for the full A2 slice.**
  (NO repo changes — evidence + deliverables live in pup `~/hs33a/`;
  this entry is the only repo touch, uncommitted by design.)
  THE PATCH (pup `~/hs33a/hs33a-nvenc-no-reset-rate.patch`, applied to
  the ffmpeg n8.0.1 release tarball — the exact upstream tag behind
  pup's distro 7:8.0.1-3ubuntu2): in `reconfig_encoder`'s
  `if (reconfig_bitrate)` block, gate the unconditional
  `resetEncoder=1; forceIDR=1` on env `LYTE_NVENC_NO_RESET_RATE=1`
  (→ both set 0, logged loud) and never on a DAR change — one binary
  A/Bs both behaviors; default path byte-identical to upstream.
  THE BUILD (`~/hs33a/vendor-ffmpeg.sh`, the future
  Host/Scripts/vendor-ffmpeg.sh SHAPE; full configure line + per-flag
  rationale inside; `build.log`): nv-codec-headers pinned n13.0.19.1
  (SDK 13.0, min driver 570 — pup runs 595.84; n13.1.x wants 610+,
  too new; ffmpeg 8.0.1 configure accepts >= 12.1.14.0);
  `--disable-everything --disable-autodetect` + explicit
  ffnvcodec/cuda/nvenc + `--enable-encoder=hevc_nvenc` + `--enable-pic`,
  static only, no x86asm needed → libavcodec.a 4.0 MB + libavutil.a
  5.2 MB in ~1 min; config_components proves EXACTLY one encoder, zero
  decoders. Harness: the Host tree COPIED to `~/hs33a/src/` (standing
  `~/src/lyte-host` untouched), `lyte-encode-check` grew a
  `--move F:avg:max:vbv` flag driving the PRODUCTION
  `lyte_hevc_enc_set_rate` mid-run (`hs33a_harness.py` holds the
  diff); ldd shows NO shared libav — the patched static lib is the
  one under test. All offline file-mode: no portal, no ports, no
  sessions.
  THE A/B TABLE (1080p60 bgr0 CBR-50 open, vbv 833333 = rate/fps,
  moves every 120 frames, 720 frames/leg; `runs/*.{log,sizes}`):
  | shape (moves) | control IDRs | no-reset IDRs | decode | rate/vbv applied |
  | R rate-only 50→38→45→25→50, vbv held | 5 (opening + 1/move) | **1 (opening only)** | 720/720 hw, 0 err | segment kbps tracks ladder, ≤1% vs control |
  | V vbv-only @50M: 833333→416666→208333→833333 | 4 (opening + 1/move) | **1** | 720/720 hw, 0 err | max frame clamps to vbv/8 exactly (52 KB / 24 KB), 44→24→11.3→44 Mbps |
  | RV rate+vbv together (HS-27 ladder shape) | 5 | **1** | 720/720 hw, 0 err | both track as in R+V |
  `nvEncReconfigureEncoder` ACCEPTED `resetEncoder=0/forceIDR=0` on
  every move of every shape — zero NVENC errors anywhere (a refusal
  was the refutation condition; none occurred).
  THE VBV ANSWER, EXPLICIT: (i) **APPLIES** — `rc_buffer_size` changes
  take effect under `resetEncoder=0`, alone and with rate moves,
  matching the reset path's behavior within ~1%; not ignored, no
  error, no corruption. (Control legs also prove today's cost: even a
  vbv-ONLY move mints an IDR through the unpatched path.)
  REFERENCE CONTINUITY (the consult's core concern): all six
  bitstreams decode 720/720 under ffmpeg strict
  `-err_detect +crccheck+bitstream+buffer+explode -xerror` (0 errors)
  AND through `lyte-cli decode-probe --require-hardware` (VideoToolbox
  HARDWARE asserted, failed 0 / withheld 0) — the no-reset streams are
  1 I + 719 consecutive P across 3–4 in-place moves. Belt: per-frame
  PSNR vs the raw input — no-reset FLOOR ≥ control floor in every
  shape (38.06/36.75/38.04 vs 38.04/35.87/37.58 dB, `runs/*.psnr`) —
  no reference divergence; no-reset is slightly BETTER (no mid-stream
  IDR re-spend at low rate).
  SPIKE SCOPE, HONESTLY: clean-channel offline synthetic (testsrc2
  undershoots the cap at the qp floor — ~43 Mbps at "50"), one recipe
  (sessionDefault p4/ull/qres, bgr0/420, CBR), no loss, no AQ, no
  Rext/444, no resolution moves. Per the addendum's A2 correction,
  DYN_BITRATE_CHANGE + this spike still do not prove every field
  combo.
  RE-MEASURE LIST FOR THE FULL A2 SLICE (reconfigure-adjacent truths,
  per the consult — not assumed): (i) no-reset moves UNDER LOSS —
  reference continuity when repair/concealment interacts with a
  mid-move P chain; (ii) client-side implicit reliance on the forced
  IDR as a sync boundary (NackPolicy supersede logic, estimator books,
  ratchet arm — a rate move no longer mints the IDR those paths may
  lean on); (iii) the V-1/HS-24 static-recipe rows re-ROWED against
  the vendored lib (444/Rext open, ratchet convergence, VUI
  fingerprint) — expected to ride, must be measured; (iv) field combos
  beyond the spike: spatial/temporal AQ on, fullres multipass, Rext
  444, and the DAR guard (any resolution move must keep today's reset
  path); (v) carry-costs: tarball security tracking + the dual-libav
  symbol risk when lyte-host links the static avcodec beside distro
  shared libs pulled by other leaves; (vi) HS-27's rung ladder retuned
  once moves are free (rungs become tunable, not load-bearing) — plus
  a quality-probe row at the vendored build.
  RAILS: owner's 41151 loop untouched and alive throughout (encode
  work never left file-mode); secrets sha-identical before AND after
  (dadf9a66…37cf / 72860390…cfed / 8dc1f88a…55fd); FFmpeg objects
  cleaned + the 6 GB raw input deleted — `~/hs33a` closes at 548 MB
  (source+patch+libs+bitstreams+books+logs kept).

- **HS-33 — the vendored no-reset encoder lands for real: rate moves
  stop minting IDRs on the live wire, the idr-books turn observational,
  and the bar's last red goes green with room to spare** (`0579e2b` the
  machinery + `7a4ee2a` the retune/books; Host/ only, not pushed).
  THE MACHINERY (Vendor/ffmpeg/README.md is the spec):
  Scripts/vendor-ffmpeg.sh IS the artifact — n8.0.1 tarball by pinned
  sha256 (05ee0b03…5a41), nv-codec-headers n13.0.19.1 by tag AND
  commit (88fee5c3…), the HS-33a patch (hunks byte-identical to the
  spike's GO-verdicted diff; headers normalized to a/ b/ for patch
  -p1; sha 16521707…6316), configure `--disable-everything` + exactly
  one encoder/zero decoders, all into a gitignored prefix — no .a in
  git. TWO ENV GATES, one recipe: PKG_CONFIG_PATH (vendored headers
  via CLibAV) + LYTE_FFMPEG_PREFIX (Package.swift links the archives
  BY PATH). By-path is measured necessity, not taste: pipewire/dbus
  distro .pc files inject `-L/usr/lib/<triple>` ahead of any vendored
  -L, so `-lavcodec` resolved the distro SHARED lib for lyte-host
  while lyte-encode-check went static — the vendored .pc files
  therefore carry no -lavcodec, set-but-missing fatals the manifest,
  and env-unset builds distro exactly as before (Mac/CI untouched;
  both directions of the toggle verified without cache staleness).
  The build signs itself: `--extra-version=lyte-noreset` puts a marker
  in avcodec_configuration(); lyte_hevc_noreset_enable() (CHevcEncode)
  reads it, defaults the patch's env gate ON, and the running host
  PRINTS which libavcodec it linked — proof, never assumption
  (LYTE_NVENC_NO_RESET_RATE=0 is the A/B control through one binary).
  pup recipe: rsync must exclude Vendor/ffmpeg/{build,prefix}; build =
  vendor-ffmpeg.sh + the two envs; verify = ldd shows no shared libav
  (verified on both executables) + the startup line.
  THE BOOKS (the tags stay truthful in both worlds): the Sink observes
  whether the encode a directive rode into came back a keyframe;
  EncoderReconfigureBooks splits applied directives into IDR-minting
  vs no-reset per kind (stats line: "applied cost — N IDR-minting
  (…), M no-reset (…)"). Under no-reset the vbv-* tags never enter
  the idr tally; an impossible minting would WARN loudly and tally
  spontaneous. Control leg cross-check: 14 directives, 14 counted
  IDR-minting, idr-books vbv-rung 7 + vbv-tighten 7 — exact.
  THE RETUNE, BY THE BOOKS: half-rungs land (rungsPerOctave 2 under
  no-reset — whole octaves stay exact halvings, the half-step is
  rung/√2 via the stdlib square root; tighten posture sits ≤√2 above
  the fallen rate, shrinking §5's oversized-frame transient). The 2 s
  loosening sustain the retune FIRST shipped was convicted live: the
  posture chased every climb, frames at/above the still-climbing pacer
  overstayed their budget, and queuing-delay overuse fired a floor
  limit cycle — 10 falls to 500 kbps, ZERO loss, climb-crash sawtooth
  (iperf3 proved the air clean at 45 Mbps/0% BOTH directions the same
  minute) — while the env=0 control leg rode the identical weather
  without collapsing. riseSustainNS stays 10 s: climb-lag is
  load-bearing probe stability, not an IDR ration, and under no-reset
  it costs nothing. The eager-sustain evidence is in the code comment,
  the ledger, and pinned as the knob's contract (not a shipped value).
  THE RE-MEASUREMENTS (the consult's list, executed not assumed):
  (a) UNDER LOSS — live 150 s leg, netem loss 2% scoped to the test
  port (prio+u32, sport-matched) through t+30…t+90 while 16/16
  no-reset directives applied: zero decode breaks, no
  reference-corruption signature (no freeze/IDR-begging loop, no
  unseal failures), FEC healed the stream, exactly one past-parity
  frame took the honest expired→IDR path — idr-books 0.80/min
  (opening + 1 client). (b) CLIENT AUDIT — CLIENT-SAFE on all five
  fronts, file:line-verified: NackPolicy deadlines are clock-relative
  (never IDR-anchored); the decoder rebuilds on parameter-set change
  but nothing consumes rate-move IDRs as an event, and NO HRD/VUI
  bitrate field is parsed anywhere; no client ratchet arm exists;
  ChromaStreamAudit is edge-triggered on chroma_format_idc (loses
  sampling frequency, never coverage); wire-view counts no received
  IDRs. THE ONE CONTRACT: resolution/DAR changes must keep minting an
  IDR — the patch's DAR guard preserves exactly that. NAMED FINDING
  (pre-existing, newly unmasked): a WHOLLY-lost frame (zero shards
  arrive, no NACK fires) mints no client IDR demand — forced rate-move
  IDRs used to incidentally scrub that; now it persists until a
  demanded IDR. Follow-up, not a blocker. (c) PRODUCTION SHAPES —
  offline A/B through the vendored lib via lyte-encode-check --move
  (RV ladder, 4 moves, 720 frames 1080p60): capped-CQ cq12 420
  (sessionDefault), capped-CQ cq4 Rext-444 (best444), and spatial-AQ-8
  + fullres multipass all read control idr=5 → no-reset **idr=1
  (opening only)**, segment rates within ~0.5%, max frame clamps to
  vbv/8 exactly in the 25 M segment, strict decode
  (`-err_detect …+explode -xerror`) 720/720 0 errors on all eight
  streams, VideoToolbox HARDWARE 720/720 failed 0/withheld 0 on the
  no-reset 420, 444, and ratchet streams, and per-frame PSNR floors
  no-reset BETTER than control in every shape (45.0→49.4, 41.3→45.9,
  44.4→49.9 dB; means equal) — no mid-stream IDR re-spend. Temporal-AQ
  probe: accepted by the wrapper, output byte-identical to taq-off
  (inert on this build), not the loud reject — recorded. (d) RATCHET —
  static-repeat leg with a mid-walk tighten (25 M) and restore:
  control pays an IDR per move (50/95 KB re-spends + 4-pass re-walks);
  no-reset convergence is UNBROKEN — QP12/~620 B byte-stability rides
  straight through both moves, idr 3→1.
  THE LIVE A/B (same night, same build, same content, 150 s armed
  legs, windowed testsrc2, Mac wire-view --audio): control (env=0)
  **24 IDRs = 9.59/min** — client-request 11, **vbv-rung 7 +
  vbv-tighten 7**, opening 1; 14 IDR-minting reconfigures. No-reset:
  **1 IDR = 0.40/min — opening 1**; 16/16 directives applied no-reset
  (tighten 7, rung 9), 2110 moves absorbed, ZERO client IDR requests,
  ZERO reconfigure IDRs, leg ended climbing at 20.8 Mbps. The
  reconfigure-minted IDR class is EXTINCT under the vendored lib.
  HONESTY LEG (falls still work): 25 Mbit tbf scoped to the port,
  6 falls each on a ~515 ms streak with honest anchors, glass held
  60-61 fps at the squeezed rate, 12/12 directives no-reset, qdisc
  removed (verified noqueue). Note: the evening air showed bursty
  microstalls in EVERY leg (control included; 129–182 overuse
  verdicts) — orthogonal to this slice, isolated by the A/B.
  THE OFFICIAL ROW (quality-probe.sh whole, port 41183): `2026-07-29
  @ 7a4ee2a | static 55.02 PASS | motion 59.70 PASS | fps 59 PASS |
  IDR 3.2 FAIL | churn 0 PASS | loss 0 PASS` — FIVE GREEN, and the
  IDR cell reported straight: the armed leg's 8 IDRs decompose to
  opening 1 + client-request 6 + stale-nack 3 (overlapping tags;
  three loss episodes at t+3.5/13.2/116.4 in choppy evening air —
  102/106,878 datagrams missing, 0 frames lost), while its 13
  directives minted ZERO IDRs (books: 0 IDR-minting, 13 no-reset —
  tighten 5, rung 8; the per-IDR trace carries not one vbv-* tag).
  The reconfigure-minted class this slice was commissioned to kill
  reads exactly 0 at the official bar; what keeps the cell red is the
  client-request path under real loss — HS-32/repair-lane territory,
  not the encoder's. Twin froze again (fps p50 2, 107 IDR = 42.7/min
  of client begging) — the directives stay load-bearing; the vendored
  lib changed their COST, never their necessity. (Probe rot noted,
  pre-existing: the receipts line's delivery grep chokes on the
  estimator line's HS-30-era "burst max, belief" commas — one-liner
  for the next probe touch.)
  Suites: Host 219 → **224/224 Mac AND pup** (new pins: half-rung
  ladder rates + covering-rung tighten, the sustain knob's contract,
  the books split IDR-minting/no-reset with truthful tags, distro
  defaults byte-identical). Instrument fix ridden in: quality-probe's
  wire leg waits for the host's listening line (the V-4 Rext
  self-probe runs before the socket opens; the old blind 3 s lost the
  handshake race — measured twice before diagnosis, plus the Keychain
  lesson re-learned: wire-view needs the signed CLI and an unsandboxed
  shell).
  RAILS: owner's 41151 loop never touched; it self-respawned onto the
  vendored build mid-session (first at ~20:10 MDT on the intermediate
  2 s-sustain binary — the never-kill rail held while that stood
  flagged — then again at 20:50:49 MDT onto the sustain-FIXED build,
  one second before a comment-only rebuild landed on disk: the
  standing host now runs the 7a4ee2a-equivalent binary and its
  session log prints the vendored no-reset line). Secrets sha-identical before/after EVERY live
  leg (noise 72860390…cfed, paired 8dc1f88a…55fd; portal_token
  rotates by design). All test hosts/ffplay/iperf3 dead, ports
  41233–41241 + 41299 freed, qdiscs verified noqueue (wlp0s20f3 AND
  lo). Logs: pup /tmp/hs33-*, ~/hs33/ (raw input deleted — closes at
  308 MB: bitstreams+books+psnr), Mac /tmp/hs33-*-client.log,
  /tmp/hs33-qprobe-run.log + /tmp/qprobe-local/.
  NAMED NEXT: (i) the wholly-lost-frame client gap (audit finding) —
  cheap client rule: a frame known missing with zero shards and no
  repair path arms the IDR request immediately; (ii) the evening-air
  microstall weather that squeezed every leg tonight deserves one
  session of estimator forensics on clean daytime air (iperf clean at
  45 M while honest medians read 5 M — dispersion-scale, not
  throughput-scale); (iii) rung hysteresis/deadband fine-tuning is now
  FREE to explore — the ladder is config, the books are truthful, and
  nothing costs an IDR anymore.

One-liners only — enough to know the finding exists and where its full
account is. Do not re-derive these; do not restate them here.

- **Ratchet is emergent, not commanded** (`493b6bd`): libavcodec nvenc has
  NO per-frame QP command; vbr+cq walks QP down on repeated identical
  frames. `qmin` must pin the floor via the priv option; all-skip at
  2048×1280 is ~5.6 KB (resolution-scaled), so byte-stability is the stop
  detector. CBR idle needs `qmin=23` + `multipass=qres` or it burns the
  full budget refining a static scene.
- **Portal capture headless** (`4619121`): pin the stream to the portal
  node by `object.serial` + `node.dont-fallback=true` (loose target
  resolution links the webcam), and keep the portal D-Bus session object
  alive for the whole capture.
- **CNetIO** (`84dd823`): per-packet TOS via sendmmsg cmsgs works
  directly; SO_TIMESTAMPING OPT_ID+OPT_TSONLY matches TX stamps to sends
  without payload reflection; netem sits after the TX-stamp point.
- **Pacer** (HS-6): the ≤1 ms batch bound is the bucket's burst cap;
  urgent jumps only within its class (audio protection is structural);
  frameByteCeiling = R×B/8 − higher-class reserves (59,937 B @ 20 Mbps/60).
- **Audio** (HS-14/HS-15/CL-11): 5 ms CELT restricted-lowdelay, DTX off
  (cadence is the receiver's clock); `node.force-quantum=240` or a busy
  graph rounds the 5 ms request to 256; per-pair deviation stats miss
  Wi-Fi clump bursts — lattice-skew spread sees them. M7 receiver order
  pinned in `docs/20260720-145840-audio-continuity.md`.
- **Noise retry discipline** (`0443beb`, W9): retransmit ONE msg1 verbatim
  across the retry window; handshake reads are transactional so port
  garbage can't poison it.
- **CP-5 input verdict** (HS-13): portal RemoteDesktop auto-denies
  headless Start — Mutter's internal `org.gnome.Mutter.RemoteDesktop` is
  primary (no consent, no token); uinput is the fallback (seat ACL now
  from `/etc/udev/rules.d/60-lyte-uinput.rules`, carried over from
  Sunshine's rule at the demolition).
- **WAKE-ratchet cost** (HS-11/CL-8): every post-idle damage is a full IDR
  + a full ratchet re-run; pup's 1 Hz clock makes a "static" desktop hold
  ~1.9 Mbps — the damage-vs-wake policy revisit is still owed data.
- **Wi-Fi realism**: receiver-side arrival clumping (p99 13–20 ms even
  clean) is why the jitter buffer targets 90–120 ms; the 5±2 ms audio
  bound is a NIC-side property. Beacon SRTT double-counts both ends'
  receive-loop wake latency (HS-17 caps the repair RTT term at 2×min-RTT).
