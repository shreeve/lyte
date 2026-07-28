# Lyte — Session Handoff

*Current as of 2026-07-27 ~02:30 MDT. The session ledger — tracked in the
repo since `8da50bf` (the .gitignore entry is vestigial; the file is
tracked). Update freely; commit updates in the ledger voice.*

# CURRENT STATE — post-H2 (start here)

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
