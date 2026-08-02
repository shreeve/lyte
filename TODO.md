# TODO — deferred work, deliberately

*Small items we chose not to block on. Each entry says where it lives and why
it was deferred, so the next touch of that code picks it up naturally.
(Slice-level work is tracked in `HANDOFF.md`, not here.)*

## Audit-sweep verification caveats (2026-07-30, post-REMAINING.md)

*The 19-PR audit sweep (#1–#19) landed and was verified end to end by a
five-agent read pass plus all four suite legs; REMAINING.md was then
retired. These are the advisory findings that pass surfaced — none are
live bugs; each is armed only by a future change to its seam.*

- **VideoAssembler threshold invariant** (`Wire/Sources/LyteWire/VideoAssembler.swift`,
  walk early-out in `sweepLossPresumption`) — the early-out compares absent
  slots against `reorderThresholdPackets` only, while write-off uses
  `fecImpossibleThresholdPackets`; safe only while
  `fecImpossible >= reorder`. Every in-tree config satisfies it, but
  `VideoAssemblerConfig.init` accepts an inverted pair, which would skip a
  group forever and suppress its `fecImpossible` report. Next touch: use
  `min(reorder, fecImpossible)` in the early-out, or assert the invariant.
  Also: PR #10 shipped source-only — `sweepSettled`, `contiguousPrefix`,
  and the `seqAdvanced || openedGroup` gate have no dedicated pins.

- **ARQ PTO sleep-forever guard has no pin**
  (`Sources/LyteTransport/ReliableCtrlEndpoint.swift`, `timerFired()`
  clearing `armedDeadlineMicros` before service) — the only sweep change
  whose correctness invariant is held by code + comment alone. Worth a
  virtual-time pin next time that file is open.

- **Residual under-lock prints** (`Host/Sources/lyte-host/SessionWire.swift`) —
  PR #8 buffered the 48 event-log lines, but a few rare paths still print
  while the session lock is held: the `flushOutbox` path-challenge lines,
  `notePeerGone`, `driveBulkShell`'s bulk-send failure, and `awaitClient`'s
  connect-failed line. A wedged stdout can still block the wire through
  those; route them through `emit` on the next touch.

- **FROZEN exit one-beat deferral** (`Sources/LyteTransport/LyteUdpSession.swift`) —
  a datagram landing inside the exact `applyMachine` critical section that
  enters FROZEN reads `machineFrozen == false`, skips the immediate exit,
  and is delivered by the next beat instead (≤100 ms in production;
  lossless — the atomic stamp retains it). Bounded and by design, but
  "datagram-immediate FROZEN exit" carries that one caveat.

*(Two caveats from this pass retired 2026-08-02 with the E5 demolition:
the Sink's encode() `-2` resend trap died with the Sink, and
quality-probe.sh's grep contract died with the script.)*

*Still owed live (not code): watch #6's `rate: fall purge` line and #16's
`hole-recused` count on the next evening-air session; optional rtprio
grant on the host machine (`Host/README.md` prerequisites item 3); ⌘W a
live stream window (PR #25) and watch for the host's peer-goodbye line +
awdl0 release; a live monitor-mode change mid-session (PR #24) should now
end in a typed teardown, not a crash — worth one deliberate flip.*

## ANALYSIS ledger — the live remainder (moved 2026-08-02)

*The 2026-07-30 six-territory review's ledger (ANALYSIS.md, with
ANALYSIS-DETAILED.md and ANALYSIS-FULL.md as raw material) was retired
per owner directive after the E5 demolition; the full record — Tier 1's
landed entries, the Tier 3 performance ranking, the architecture/clarity
essay, and the strengths inventory — lives in git history (last at
`860369a`, `git show 860369a:ANALYSIS.md`). Below are the still-open
numbered items, re-verified against the post-E5 tree. Retired as moot:
#11 (`--no-idle-floor` signal swallow — flag and Sink deleted; the
direct leg polls the termination flag itself since #72), #17 (mute on
fresh connect — since fixed; `setAudioMuted` now rides both connect and
roam paths), #21/#22 (quality-probe.sh / corpus-harness.sh deleted),
#19's capture half and #26's linebuf residue (demolished / fixed
in #72).*

*Second re-verification (2026-08-02, code-level): SEVEN more turned out
to have landed during the hardening/quality waves and are retired with
their pins — **T2-7** peer retarget (#33: adoption gated on `.accepted`,
pin `testUnauthenticatedDatagramCannotRetargetPeer`), **T2-8** NACK-IDR
throttle (#27: `unknownFrameIdrArmIntervalNS` + throttled counter, pin
in NackRepairGateTests), **T2-9** ARQ group reclaim (#30:
`reclaimAbandonedReceiveGroups` — poisoned + past-lifetime one-shots
evicted, pins in ArqAdversarialTests), **T2-12** EINTR deafness + stop
join (#33: `EINTR → continue`, UdpReceiveEndpointStopTests), **T2-14**
bounded send retry (#38: `sent == 0` re-queues to the outbox and the
retry sleeps OUTSIDE the session lock), **T2-15** helper interruption
handler (#33: `interruptionHandler` installed beside invalidation),
**A-18** stale belief across RECOVERY (#27: `applyIdrPacing`'s
half-stale arm resets belief, delivery windows, cadence hold, and band
floor — the exact invariant is documented at the site), and **T2-16**
held keys (#43: `heldKeys`/`heldButtons` tracking with
`releaseAllHeld()` on focus-resign AND stop — found on the second
look; the first sweep grepped the wrong symbol names). The last two
T2 items closed 2026-08-02: **T2-10** → #75 (horizon pinned as local
policy, adversarial pin in AudioInteriorTests) and **T2-13** → #76
(configLock publication + `_Atomic` uinput extent). **Every T2 item is
now closed.* *The A-train batch landed 2026-08-02: **A-19** → #77
(2 s guard timer bounds every roundtrip — a wedged wireplumber turns
into a loud restore failure, the next-start sweep backstops),
**A-24** → #77 (`exit_reason` `_Atomic`; quit's CAS yields to an
error verdict; the NULL-`spa_dict_lookup` companion verified already
guarded — moot), **A-23** → #78 (validation above allocations;
nothing may throw past thread.start(), stated at the site),
**A-25** → #79 (compiler-enforced discard binding + the mixed-clock
warning at both ends), **A-27** → #79 (anchor and centering offset
from the same sample; order-invariance pinned through a coprime
scramble). The TWO below remain — both design/migration-shaped,
deliberately not batch work.*

- **A-20 Delivery trains are segmented channel-blind** —
  `Host/Sources/HostWire/RateEstimator.swift`: trains mix fast-lane
  audio (131 B) with video (1152 B) under DSCP, skewing the measured
  rate that drives the honest/censored trichotomy — and at the 500 kbps
  floor the rate-scaled gap (~55 ms) chains audio's 5 ms cadence into
  every train. Consider single-channel trains or per-channel
  classification. (Estimator design work — belongs with the direct-leg
  quality refinement on the postures queue.)

- **A-26 (residue) duplications + missing host-side seams** —
  `LatencyHistogram` ≡ `HostCore.Histogram` and `AnnexBCheck` ≡
  `HostCore.AnnexB` are documented-in-code duplications; the host's
  crypto and ARQ carriage are inlined switches where the client has
  named seams (`TransportCrypto`, `ReliableCtrlEndpoint`) — the missing
  host-side seam is why the ARQ repack duplication exists. (The
  evidence FOR the v2 Common/IO split — resolve there, not piecemeal.)

## Browser client + Caddy bridge (`docs/20260720-184200-browser-client-caddy-bridge.md`)

- **Post-H6 plan of record, deliberately parked.** Same Swift client protocol
  layer compiled to WASM (WebCodecs decode), reaching lyte-host through a
  Caddy module — simplified by the 2026-07-20 Lyte-UDP decision to a **dumb
  WebTransport-datagram ↔ UDP-packet relay** (CONNECT-UDP / RFC 9298 shape);
  the host-side protocol is Lyte-UDP, not GameStream, and E2E Noise keeps the
  bridge untrusted. Pick up only after the native path runs flawlessly.
  (Design consult 2026-07-20; amended per
  `docs/20260720-215100-lyte-udp-decision.md`.)

## `lyte sniff` — the key-joined decrypt half (future)

- **Mostly done.** `lyte-host sniff` (HS-5, `Host/Sources/lyte-host/Sniff.swift`)
  has pretty-printed envelopes/channels for waves. What remains is the half
  its header explicitly defers: joining a session key so payloads decrypt —
  today it dissects headers only, with Noise blinding the cargo. Pick up if
  a debugging season ever needs plaintext on the wire.
  (`docs/20260720-215100-lyte-udp-decision.md` §7.)

## AV1 end-to-end (banked 2026-08-01, sequenced after the direct leg is stable)

*The capture-organ replacement this decision was sequenced behind is
DONE (E0–E5, 2026-08-02, tag `self-hosted`) — the full genesis record
(the weak-organ case, the KMS/EGL prototype results, the format-bridge
finding) is in this file's history, `git show 0753cbc:TODO.md`, and the
epoch's plan is docs/20260801-105800-direct-eye-plan.md. What survives
here is the banked AV1 decision and the standing encoder policy.*

- **Owner sequencing ruling**: "Get it all running, then add AV1 — at
  that point it's easy." The gate is the direct leg stable and
  quality-refined (the postures queue), not merely landed.
- **Hardware-viable when we get there**: owner's Mac is an M5
  (VideoToolbox AV1 decode); pup has TWO hardware AV1 encoders (Meteor
  Lake Arc media engine + Ada NVENC). Caveats recorded: hardware AV1
  is 4:2:0-only both ends — the 4:4:4 text ambition stays HEVC-Rext;
  AV1's screen-content tools + WAN bitrate savings are the prize.
- **The HEVC-shaped seams to unwind, re-inventoried post-E5**: (1) the
  encode seat — HostCore's pens author HEVC bitstream; AV1 means OBU
  authoring pens (or a vetted encoder leaf) against the same VAAPI
  surfaces; (2) `AnnexB.swift` parses NALs — AV1 is OBU framing
  (keyframe detect, packetizer boundaries need a twin); (3) the wire
  needs a negotiated codec field (host offers, client picks — the
  "doctor" decides); (4) the client pipeline constructs HEVC-style
  format descriptions.
- **Encoder/GPU policy by topology** (standing, implemented by the
  direct eye): encode on the die that owns the scanout. pup (VERIFIED
  no-MUX Optimus: all connectors hang off card1/Intel) → Arc media
  engine; a desktop with its panel on NVIDIA → NVENC zero-copy (E6a
  productionize, lyte-nvenc probe banked); the Intel→NVIDIA copy path
  stays rejected (keeps dGPU awake, wonky cross-adapter dmabuf, no
  quality win).
