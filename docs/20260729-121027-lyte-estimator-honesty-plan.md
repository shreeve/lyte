# Slice (b) design brief — estimator honesty: the self-reference family

*2026-07-29. Commissioned off the truth-probe verdict (ledger `adb29ea`):
during a live session pinned at 0.1–1.6 Mbps by the estimator, a
concurrent 35 Mbps UDP flood delivered 30.0 Mbps at 0% loss through the
same air. The hunt is dishonest. This brief scopes the fix slice that
follows HS-27 (non-IDR reconfigure) in Host/ territory. Evidence logs:
pup `/tmp/truthprobe-host.log`, the 2026-07-29 quality-probe row
(`~/qprobe/` on pup), and the iperf3 legs in the truth-probe wave entry.*

## What the existing gates already cover — and how leg B threaded them

`RateEstimator.swift`'s header documents three defenses, all of which
behaved AS DESIGNED in leg B and still lost:

- **HS-22c self-reference gate**: refuses a fall when the pacer holds
  standing backlog AND the anchor median sits within a band of the
  standing rate ("the sample measures us"). Leg B's falls escaped via
  its honest-signature exits: anchors at 0.64× standing read as
  "measurably below the band" (exit 1), and the collapse window showed
  real post-FEC loss (exit 2 — `loss 0.156/0.229` on one fall).
- **HS-23 stall gate**: refuses closed-hole-shaped falls. Leg B's
  streaks peaked past the 150 ms ceiling (244 ms) and carried loss, so
  the gate correctly stood aside.
- **IDR-hunt dwell deferral**: defers dwell-shaped falls ≤150 ms. Same
  story — the evidence shape wasn't a dwell.

The lesson is structural: every gate asks "is THIS sample shaped like a
measurement of ourselves?" None of them asks "is this fall consistent
with what the path PROVED it could carry seconds ago?" Once one genuine
episode (real loss during the initial 40 Mbps overshoot collapse)
starts the descent, every subsequent sample is taken at the squeezed
rate, reads honestly-low, and the ratchet of falls has no memory to
argue with. The forensics wrote it down: one fall recorded
`full-train 348492 kbps 0.039 s ago` — fresh evidence of a ~348 Mbps
compressed drain — and fell to 4.8 Mbps anyway, because the anchor is
the MEDIAN of recent raw samples (HS-21) and the median was
trickle-dominated. The final fall anchored to `full-train 398 kbps
0 ms ago`: 0.85 × its own starved pacing.

## Proposed mechanisms (P1 is the heart; the rest support)

**P1 — capacity memory floors the fall.** The 10 s windowed-MAX
`btlRate` exists precisely to remember what the path proved (BBR's
shape, measured-not-hoped, errs low by construction). Today the fall
anchor never consults it. Rule: an overuse or post-FEC fall may not
anchor below `k × btlRate` (k ≈ 0.5–0.7, gate-tested) unless the
below-capacity evidence PERSISTS — e.g. delivery median below the
memory floor across ≥2 consecutive 500 ms fall-limiter windows with
corroborating loss or monotone queue growth. A real capacity drop
(the tbf honesty legs) produces exactly that persistence within ~1 s,
so the fast-fall pillar property survives at one limiter beat of
extra latency. A self-reference spiral cannot produce it — the next
compressed drain or side-traffic burst refreshes the max.

**P2 — app-limited marking (BBR's discipline).** A delivery sample
taken while the pacer's offered load sat at/below the standing rate
(send ledger knows: backlog + rate at sample time) is a LOWER BOUND on
capacity, not an estimate of it. Mark such samples; they may RAISE
btlRate, they may never vote in a fall anchor. This subsumes the
HS-22c band heuristic (which only catches anchor ≈ self) with the
principled version (anchor ≤ self is equally self-shaped when the
pacer was the constraint).

**P3 — TX-stamp the send instants.** The queuing-delay signal is
client-arrival − host-send. If the send ledger stamps at ENQUEUE
(pacer entry) rather than wire egress, our own pacer queue counts as
"path inflation" — the first leg-B fall carried `backlog 158743 B` and
a 164 ms streak at a rate the path demonstrably carried. CNetIO has
kernel TX timestamps since HS-4 (SO_TIMESTAMPING, OPT_ID+OPT_TSONLY)
and HS-16 chose the pacer-domain clock; reconcile them. If enqueue
stamps are confirmed, move dispersion/inflation to TX stamps — that
alone may retire a whole class of false overuse verdicts.

**P4 — self-inflicted loss must not testify.** At deep floors the
frame byte ceiling forces starvation (the HS-20 deep-floor note: the
QP-51 damage-frame minimum cannot fit the 500 kbps floor's ceiling).
Losses the host inflicts on itself — unprotectable drops, backlog
skips, ceiling-forced truncation — flow into the same ledger deltas
the loss bands read as path evidence, which is how the floor becomes
self-sealing. Audit the drop-reason books vs the ledger-delta path;
anything host-originated gets excluded from the loss fractions (it is
already counted, loudly, in its own books).

**P5 — bounded recovery probing.** 242 evidence rises in 150 s is the
10%/s crawl doing its best against a poisoned baseline. With P1's
memory in place, recovery can ride it: after a fall, a brief paced
probe pulse (one frame interval at btlRate, BBR PROBE_BW's shape,
bounded by the FEC/ceiling budget) refreshes the max instead of
waiting for luck. Optional — land P1–P4 first and re-measure; P5 only
if recovery latency still reads slow at the glass.

## What must NOT change

- Genuine squeezes must still fall fast: the tbf honesty legs (25 Mbit
  sustained squeeze → all five fell ~150 ms late, anchored to measured
  delivery) are the regression pins, re-run live.
- The 2–10% held loss band, the stall gate, the dwell deferral, and
  the HS-21 median's lone-outlier rejection all stay.
- Sans-IO, injected clock, no wire bytes move. The estimator is
  HostWire; nothing above the socket learns anything new.

## Acceptance shape

- Virtual-time gate replaying leg B's shape (initial genuine episode →
  trickle-shaped follow-on samples + fresh super-rate full trains):
  the standing rate must recover toward btlRate instead of ratcheting
  to the floor; plus the persistence path (real capacity drop) still
  falls within ~1 s.
- Live: repeat the truth-probe leg B (armed 444 heavy motion, 90 s,
  35 M side-flood at t+40) — the session must hold a sane share
  (≥ ~0.5× of what leg A proved) and never enter the floor limit
  cycle; the honesty tbf leg re-run must still fall.
- The Beauty Bar IDR row re-measured after BOTH slices (HS-27 kills
  the per-move cost, this slice kills the false moves) — that pairing
  is the path to the last red going green.
