# H2 Joint Gate — everything at once, formally verified

*2026-07-22, ~11:50–13:15 MDT. Verification run, not a feature slice: both
ends at committed HEAD `f9ca59c`, live against pup (10.0.0.249) over the
real Wi-Fi LAN. No feature code was touched. Follows the H1 report's shape
(`docs/20260722-h1-joint-gate.md`).*

## Verdict

**H2 FUNCTIONAL PARITY IS CLOSED.** Every criterion in the master plan's
H2 parity definition (`docs/20260720-222500-lyte-build-plan.md` — input +
audio + CC/NACK/FROZEN-RECOVERY, the wave-4 ▲ rows HS-13/CL-9,
HS-14→HS-15→CL-11, HS-16→HS-17 plus the HS-18 semantics that landed
distributed across W4b/HS-11/HS-16/CL-11) passed live, together, in one
coherent session shape: video rendering + 5 ms audio + scripted input +
the estimator at its ceiling + idle cycles in a single run, then adversity
legs (bandwidth squeeze, 15% video loss with targeted repair, ≥3 s
blackouts with FROZEN→RECOVERY).

**H2 EXIT remains OPEN by design**: the exit also prescribes demolition —
Sunshine uninstalled from the host box and the client's frozen GameStream
stack (LyteKit/CEnet/CNanors) deleted as one reviewed series (J-G2, after
the CP-2 daily-drive declaration). That is the human's call, explicitly
not this gate's to make. Sunshine was verified untouched and `active`
before, during, and after every leg.

## Environment

- Host: pup, Ubuntu 26.04, GNOME/Mutter Wayland, RTX 4050, Swift 6.1.2,
  PipeWire; `lyte-host` built on pup from a `git archive` of committed
  HEAD `f9ca59c` (`~/src/h2gate/{Wire,Host}` — sibling layout; the repo
  working trees were never rsynced). Portal capture headless off the
  persisted restore token; Mutter RemoteDesktop injection backend; audio
  leg default-on; `--ratchet` every leg.
- Client: this Mac, `lyte-cli` built + signed via `Scripts/build-cli.sh`
  at the same HEAD; `wire-view --audio` with `--input-script` as the
  driving surface. All dials used the `--host-key` debug posture
  (`10e0f084…6201`): the Keychain zero-UI leg is unusable from a headless
  shell (CL-8's documented caveat, OSStatus −25320); the Keychain/pinned
  path itself was live-gated at CL-6 and re-held at the H1 joint gate.
- Port: 41091 for every leg. A separate victory-lap host ran concurrently
  on :41101 for the maintainer — never touched, no contention observed.
- Netem: `/tmp/h2netem.sh` on pup (committed as
  `Scripts/netem/h2gate-netem.sh`) — the `lo-netem.sh` prio+u32 pattern on
  `wlp0s20f3` egress scoped to udp dport 41091, with video legs further
  scoped to `dsfield 0xa0` so audio/CTRL ride untouched; the blackout legs
  added an iptables INPUT drop on udp dport 41091 for the reverse
  direction. Everything removed and re-verified after each leg.
- Timestamps: both ends' logs piped through perl epoch-ms stamping;
  receiver-side arrivals from `tcpdump` on the Mac's en0 (pcaps for runs
  A/B2/C/G), send-side cadence from `tcpdump` on pup's NIC (run F).
- Logs: Mac `/tmp/h2gate-run{A,B2,C,D,E,F,G}-client.log` +
  `/tmp/h2gate-run{A,B2,C,G}.pcap`; pup `/tmp/h2gate-run*-host.log` +
  `/tmp/h2gate-runF-audiosend.txt`.

## The runs

- **Run A — steady state, everything at once** (190 s): 38 phase-swept
  single moves every 3.106 s for the first ~117 s, then a 73 s quiet tail;
  audio playing; idle cycles throughout both halves.
- **Run B2 — congestion** (230 s): continuous damage (moves every 250 ms);
  6 Mbit video-scoped netem rate squeeze from t+82 for 90 s, then release.
- **Run C — loss/repair** (195 s): continuous damage; 15% video-scoped
  loss from t+56 for 95 s, then a clean tail.
- **Run D — blackout** (160 s): continuous damage; bidirectional dark
  (egress netem 100% + ingress iptables drop) for ~13 s mid-run.
- **Run E — input-wake** (118 s): phase-swept single moves every 1.037 s,
  timestamped, for IDLE→input→ACTIVE attribution.
- **Run F — second squeeze + NIC-side audio cadence** (160 s): moves every
  500 ms; 6 Mbit video-scoped squeeze for ~72 s; pup-NIC tcpdump on the
  DSCP-48 audio datagrams.
- **Run G — blackout precision re-run** (125 s): ~10.2 s dark window with
  a Mac-side pcap so the pill timing and the recovery instant share one
  clock with the client log.

## Ledger — H2 parity criteria, pass/fail

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Input end-to-end on the sealed reliable stream (HS-13/CL-9) | **PASS** | 38+577+577+105+289+247 scripted events across six runs, every one injected via Mutter exactly-once in order with a byte-faithful echo (zero send failures, zero unmatched). Host receive→inject p50 1.0–1.3 ms / p99 1.8 ms on the clean runs (A: 1268/1818 µs; E: 1166/1788 µs — HS-13's <2 ms gate re-held live); adversity runs stretch p99 to 3.8–11 ms while the wire is deliberately squeezed/darkened. Client books live all runs: input→inject p50 5.2–16.5 ms, input→photon p50 29.3–48.6 ms (run E: 12.0 / 39.7 ms), `lastInputSeq` TLV stamping continuous (frame stamp = last seq every run). |
| 2 | Input-wake: IDLE → one event → ACTIVE + IDR within budget | **PASS** | Run E (timestamped): **15 events landed while the client's mirror stood IDLE → `mode → ACTIVE` +7…+108 ms later (p50 ≈ 20 ms)**, against idle windows of p50 244 ms — attributable to the event, not the 1 Hz clock damage. IDR discipline exact: 34 wakes → 34 `rate: → (IDR pacing lastGoodRate)` applications, one per wake. Injection continued across wakes (105/105 echoed). |
| 3 | Audio on the wire: 5 ms cadence held under load (HS-15, R-G8 shape) | **PASS** | Run F at pup's NIC (tcpdump, DSCP-48 datagrams, clean phase): **emission cadence p50 4.999 / p99 5.978 ms, deviation p99 1.26 ms, 0.34% outside 5±2 ms** — R-G8's bound re-held on the live Wi-Fi NIC (HS-15's committed loopback gate: p99 5.446 ms). Host max audio queue delay ≤ 26 ms across the squeeze runs, 0 send failures, hard-CBR clean (0 encode failures, F32 48 kHz 2ch). TOS 0xC0 on every audio datagram at both NICs (0xA0 video, 0xC0 CTRL — per-packet DSCP verified in the pcaps). |
| 4 | Audio receiver: continuity, FEC, PLC only when honest (CL-11) | **PASS** | Clean leg (run A): 41,982 dg → 27,988 packets, **PLC 48 (0.17%, opening adaptation + one Wi-Fi micro-outage), 3 fec-impossible**; depth p50/p99 33/40 pkts stable. Squeeze leg (B2): **PLC 17 of 45,969 (0.037%) through a 90 s video squeeze** — cadence held at the receiver's books. Loss leg (C): audio unimpaired by the video-scoped loss, PLC 89 (0.23%). Blackout leg (D): 6 packets FEC-rebuilt across 4 groups byte-exact; PLC concentrated in the dark window, exactly as designed. Receiver-side raw inter-arrival p99 sits at 13–20 ms on this Wi-Fi in EVERY leg including clean (aggregation clumping, CL-11's documented finding — the jitter buffer's 90–120 ms adaptive target absorbs it); the 5±2 ms bound is the NIC-side R-G8 property, held per row 3. |
| 5 | Audio as the always-on probe: flows in IDLE/FROZEN; detector at 350 ms | **PASS** | `audio evidence — blackout detector tightened to 350 ms` on the first chan-1 arrival, every run. Run A's quiet tail (9 idle cycles, zero input): **audio kept arriving at the full 300 dg/s through every idle window** (6,597 datagrams in the 22 s analyzed tail). Detector honesty proven twice: run G's pill rose **425 ms after the last datagram arrival** (pcap + client log, one clock; 350 ms detector + arrival/tick quantization) and cleared **≤1 ms after the first returning datagram** (pill-off 1784747395.020 vs first arrival .019). Two transient pills on clean legs (runs A, F) each matched a real ≥350 ms Wi-Fi stall and cleared within ~0.7 s — the detector doing its job, not flapping. |
| 6 | Estimator live: ceiling in steady state, falls anchored to measured delivery (HS-16) | **PASS** | Steady state (A, E, G): rate = pacer = **20,000 kbps = the ceiling**, frameByteCeiling@60fps 59,937 B (the HS-6 figure), 0 malformed reports (3,514/2,938/2,859 parsed). Squeeze (B2): overuse falls anchored at measured delivery (20,000→11,166→8,188… kbps, each ×0.85 of a real delivery figure), evidence climbs ≤10%/s between falls, floor 500 kbps held. Loss (C): rung-3 post-FEC falls (17,000→14,450→… — the >2% post-FEC band, not the held 2–10% FEC band). |
| 7 | Congestion release → re-convergence | **PASS** (dynamic named) | Run G: after a 10.2 s blackout + honest loss falls, the estimator **climbed back to the full 20,000 kbps ceiling by run end**. Run B2's post-release tail instead cycled 500→~900 kbps under the synthetic 250 ms full-frame damage script: the encoder does not yet consume frameByteCeiling (HS-16's deferred VBV/NVENC-reconfig row), so ceiling-sized frames pour into a floor-squeezed pacer, frames overstay the client's 250 ms presumption, and the resulting NACKs sustain rung-3 verdicts. The estimator's own behavior is correct (falls anchored, climbs on evidence); the known deferred row is what pins the floor under sustained synthetic damage. Flagged for the VBV slice; not a wire regression. |
| 8 | Loss/repair: FEC heals below parity; past-parity draws NACKs answered with repairs or stale-IDRs (HS-17/CL-12) | **PASS** | Run C, 15% video-scoped loss: **client emitted 71 NACK entries (345 shards) — host consumed EXACTLY 71 entries / counted EXACTLY 345 post-FEC shards (1:1 wire correlation)**. Host honored 36 → 62 videoTail repair datagrams, judged 35 honestly stale → 35 IDR-armed; client accepted 28 repair shards → **7 frames HEALED BY REPAIR**, 27 rule-4 expiries → IDR, 26 fec-impossible verdicts deferred while asks were live. 293 fec-impossible → 294 coalesced IDR requests → healed every time; **video `.rendering` continuously** (2,567 frames decoded through the leg). 59 rung-3 downshifts + 17 §5.2 regime steps live. NACK emission quiesced with the loss: asks after removal tapered within the in-flight window and the missing counter froze (1,439). |
| 9 | FROZEN → RECOVERY: 350 ms detector, half-stale IDR, estimator verdicts (HS-18 semantics) | **PASS** | Runs D and G, bidirectional blackouts (13 s / 10.2 s ≥ the 3 s bar). Host: `FROZEN — 350 ms of media-path silence` (video suppressed: 109 / 61 frames counted, never sent), then on the FIRST returning evidence `RECOVERY — fresh IDR at the half-stale rate` + `rate: → (IDR pacing halfStaleEstimate)` on the pacer, then honest blackout-gap loss falls, then **`lifecycle: active` 153 ms / 117 ms later — graduation on real estimator window verdicts, not the retired 25 ms stub**. Client: pill per row 5, **never entered RECOVERY** (receiver role, by design), idle cycles resumed immediately post-recovery. |
| 10 | Idle machine under H2 load: flips ack-gated, 0x15 frames, audio unaffected | **PASS** | Run A: **45 idle flips / 44 wakes in 190 s** (89 host transitions mirrored label-for-label), 46 reliable 0x15 idle frames — 45 deduped against the datagram path, **1 ARQ-rendered** (the reliable copy carried a converged frame the datagram path lost — the CL-8 seam live again). Run E: 34 full cycles. Idle windows 44–517 ms (bounded by pup's 1 Hz clock damage, the HS-11/CL-8 known rhythm). Audio full-rate through every window (row 5). |
| 11 | Session hygiene under everything: seals, ARQ, clock, teardown | **PASS** | ≈550,000 sealed datagrams across seven runs, both directions: **0 unseal failures in six runs on both ends' books**. Run F alone counted 4 client-side (0.005%), all in one tick coincident with a >2 s netem queue flush (host freshVideo max queue delay 2.07 s) — the W3/W9 replay-window discipline (stragglers behind an advanced window die `.staleSequence`, which the demux counts under unseal) rather than an authentication failure; the host's own books stayed at 0. ARQ exactly-once every run (duplicates ignored as routine); clean typed 0x0A teardown every run (host `client unreachable — closing cleanly` on the one early client exit); beacons/clock through the session object: residual rms 62–540 µs (all under the 1 ms joint bound); handshakes 10.6–44.7 ms (one 152 ms first-dial outlier and one 1,017 ms Wi-Fi-retry dial, both benign). |
| 12 | Demolition (Sunshine uninstall + LyteKit/CEnet/CNanors deletion) | **NOT MINE — OPEN** | The remaining H2 EXIT item, explicitly reserved for the human (J-G2: CP-2 daily-drive declaration → one reviewed demolition series + the uninstall in the same breath). Sunshine verified `active` and untouched throughout this gate. |

Cited-not-reproduced (per-slice HANDOFF gates stand as depth): the uinput
fallback backend (HS-13 run H: 2/2 injected, same cursor centroid), the
PIN-PAKE pairing + `--require-paired` legs (H1 joint gate, unchanged
since), the 440 Hz tone RMS check (CL-11: −27.0 dBFS/440 Hz exact), and
the M7 WSOLA/skew items CL-11 explicitly deferred. Outside the cited
parity definition and untouched: Work/Play presentation scheduling, CL-13
4:4:4 fixtures, HS-19 behind CP-1.

## Headline numbers

- Input: 1,833 scripted events across six runs, 100% injected
  exactly-once with echoes; host rx→inject p50 ~1.2 ms / p99 1.8 ms
  (clean legs); input→photon p50 29–49 ms.
- Input-wake: 15/15 attributed IDLE wakes, ACTIVE in +7…+108 ms (p50
  ≈20 ms); IDR pacing exactly one per wake (34/34).
- Audio at the NIC: inter-send p50 4.999 / p99 5.978 ms, 0.34% outside
  5±2 ms. At the receiver: PLC 0.037% through a 90 s video squeeze,
  0.17–0.57% everywhere else, FEC rebuilds byte-exact.
- Detector: pill +425 ms of last arrival; cleared ≤1 ms after first
  returning datagram; host FROZEN at 350 ms, RECOVERY→active in ≤153 ms
  on estimator verdicts with half-stale IDR pacing.
- NACK/repair correlation: 71 asks ↔ 71 consumed, 345 ↔ 345 post-FEC
  shards (1:1); 62 repair datagrams sent, 7 frames repair-healed, 35
  stale→IDR; 0 duplicate asks.
- Estimator: ceiling (20 Mbps) in steady state; squeeze falls anchored at
  measured delivery; full re-convergence to ceiling post-blackout (run G).
- Hygiene: ~550k sealed datagrams, 0 unseal failures on both ends in six
  of seven runs (4 stale-straggler counts in the seventh, 0.005%); clock
  residual rms down to 62 µs; every teardown typed and clean.

## Cleanup (verified after the last leg)

netem removed (`wlp0s20f3` and `lo` back to `noqueue`); iptables INPUT
clean (0 rules for 41091); port 41091 free; no stray lyte-host (the
maintainer's :41101 victory-lap host left running as instructed); no
tcpdump; Sunshine user unit `active`; and the three secrets byte-identical
to the pre-run snapshot: `portal_token dadf9a66…37cf`,
`noise_static.key 72860390…cfed`, `paired_clients 8dc1f88a…55fd`.

## Deferred items (named, none gating functional parity)

1. **Demolition** — the H2 exit item, awaiting the human's go (row 12).
2. **Encoder VBV consuming frameByteCeiling** (HS-16's deferred row) —
   the floor-pinning dynamic under sustained damage (row 7); the number
   is computed and logged, the NVENC reconfigure call is the slice.
3. **Repair-lane DSCP / tail-class marking** (HS-17/CL-12's row) — under
   a floor squeeze the videoTail queue is still where repairs die.
4. **Receiver-side inter-arrival vs Wi-Fi clumping** — if the 5±2 ms
   bound is ever wanted at the receiver, it needs a wired path or the M7
   accelerate work; the NIC-side bound and the playback books are the
   honest measures today.
5. **Keychain zero-UI dial from a real GUI session** + the app
   human-at-glass legs — CL-8's standing caveat, unchanged.
