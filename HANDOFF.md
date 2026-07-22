# Lyte — Session Handoff

*Current as of 2026-07-22 ~14:30 MDT. The session ledger — tracked in the
repo since `8da50bf` (the .gitignore entry is vestigial; the file is
tracked). Update freely; commit updates in the ledger voice.*

# CURRENT STATE — post-H2 (start here)

**Where things stand.** H2 FUNCTIONAL PARITY IS CLOSED (joint gate passed
2026-07-22 ~13:15 MDT, report `docs/20260722-h2-joint-gate.md`) and the H2
EXIT demolition is DONE (commits `2018f6d` → `d5de430` → `9e1cd27`): the
client's GameStream stack (LyteKit/CEnet/CNanors, ~14.3k lines) is deleted,
Sunshine is uninstalled from pup, and both ends speak exactly one protocol —
Lyte-UDP. H1 closed earlier the same day (`docs/20260722-h1-joint-gate.md`).
Suites at HEAD: Wire **372/372**, Host **104/104**, root **104/104**, green
on Mac AND pup; `build-cli.sh`/`make-app.sh` release builds green. A live
post-demolition proof ran at the new HEAD (60 s: 48,474/48,474 datagrams ok,
0 unseal failures, render + audio + input + clean teardown).

**In flight RIGHT NOW: HS-18** (host audio routing / virtual-sink mute) — a
worker is mid-flight in Host/ sources. Its pup LIVE legs are DEFERRED
(pup is off for the owner's travel, below); the in-tree legs proceed. It
will append its entry to the CURRENT WAVE block at the marker below.

**pup is OFFLINE (traveling).** Shut down 2026-07-22 afternoon; back online
TONIGHT from a hotel — a different network, so the address in the ssh
config (10.0.0.249 today) will likely change and `ssh pup` may need
updating before any live leg runs. Discovery/pairing survive the move by
design (Avahi + pinned keys are address-independent); expect a new IP and
possibly client-isolation quirks on hotel Wi-Fi.

**Queued next (in order):**

1. **Client control-strip slice** (root) — auto-hiding stream-window UI,
   capability-gated buttons (including the host-mute toggle HS-18
   provides), per-host defaults.
2. **Codec-promotion slice into Wire/** — 0x15 IdleFrame, 0x16 InputEvent,
   0x17 InputEcho, TLV 0x03 lastInputSeq, and the HS-15/CL-11 audio
   interior. Mirrors exist byte-pinned on BOTH ends; all copies delete
   together (registry append + file moves + a new vector file).
3. **H3 ladder** — the capability-gated feature channel: clipboard both
   ways, then drag-and-drop files, per the master plan
   (`docs/20260720-222500-lyte-build-plan.md`).

**Standing deferred seams** (named at their slices, none blocking):
reconnect/takeover UX (needs a host session-busy story), HS-9 cookie-mode
enforcement in HandshakeGate (W8 landed; the client leg is live in every
dial), encoder VBV consuming frameByteCeiling (the floor-pinning dynamic
the H2 gate named), repair-lane DSCP for videoTail repairs, M7 audio items
(WSOLA accelerate, skew term, device-change handling), app human-at-glass
legs (Keychain zero-UI dial + stream-window visual from a real GUI
session).

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
  Wire/ (with the host copy), WSOLA accelerate + skew-term (M7),
  AVAudioEngine device-change/route-change handling, app human-at-
  glass listen (audio default-on in the app path awaits CL-8's
  deferred human leg), background-run death root-cause if it ever
  shows in a real session.

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

- **HS-18 — (in flight; the Host/ worker appends its entry here when it
  lands. Its pup live legs are deferred until pup is back online — see
  CURRENT STATE.)**

<!-- HS-18: replace the placeholder entry above with your landing entry. -->

---

# Hard-won findings index (details live at the named commits/files)

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
