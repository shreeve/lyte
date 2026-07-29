# Slice (b) design brief — the estimator reformulation: an honest
# capacity belief replaces the shape-gates

*2026-07-29, REWRITTEN by owner ruling (~12:25 MDT): the first draft
proposed five mechanisms ALONGSIDE the existing gates — patches five
and six. The owner asked the sharper question ("is there a simpler way
that fixes this resoundingly?") and ruled for the reformulation: change
the model, don't add a fourth gate. Commissioned off the truth-probe
verdict (ledger `adb29ea`): during a live session the estimator pinned
at 0.1–1.6 Mbps, a concurrent 35 Mbps UDP flood delivered 30.0 Mbps at
0% loss through the same air. Evidence: pup `/tmp/truthprobe-host.log`,
the 2026-07-29 quality-probe row (`~/qprobe/` on pup), iperf3 legs in
the truth-probe wave entry. Follows HS-27 in Host/ territory.*

## The flaw, stated once

**A paced sender can never measure more than it sends — every delivery
sample is censored from above by our own rate.** The estimator's model
treats each sample as an unbiased estimate of path capacity, so any
rate reduction (for any reason, including a genuine one) makes all
subsequent "evidence" confirm the reduction, forever. Every prior
finding in this family — the HS-20 garbage-sample crater, HS-22b(ii)'s
floor spiral, HS-23's stall pinning, the IDR hunt's dwell falls, leg
B's limit cycle — is this one modeling error wearing different clothes.

The three existing gates (HS-22c self-reference band, HS-23 stall
gate, IDR-hunt dwell deferral) are hand-written classifiers for three
observed SHAPES of the lie. All three behaved as designed in leg B and
the spiral threaded them anyway, arriving in a fourth shape (a genuine
loss episode handing off into self-reference). A signature blocklist
loses by induction; the accumulation of gates is the tell that the
model underneath is wrong.

## The reformulation — separate measurement from control

Today, measurement (what can the path carry?) and control (what do we
do about it?) are entangled: the fall anchor reads the median of the
last few RAW samples, censored or not, and the windowed-max `btlRate`
the estimator dutifully maintains is consulted by nobody at fall time
(the leg-B forensics line `full-train 348492 kbps 39 ms ago` — fresh
evidence of a ~348 Mbps drain, ignored, fall to 4.8 Mbps — is this
entanglement in one line). The slice splits them:

**MEASUREMENT — the capacity belief.** One number, `btlRate`, the 10 s
windowed-MAX of delivery samples (already built, BBR's shape), fed
under two invariants:

- **INVARIANT 1 (app-limited discipline, BBR's day-one insight): a
  sample taken while the pacer was the constraint is a LOWER BOUND on
  capacity, not an estimate of it.** The send ledger knows at
  production time whether the pacer was saturated by demand or pacing
  below it (backlog + standing rate at the sample's train). Censored
  samples may RAISE the belief (delivery above expectation is always
  honest news), they may never lower it or vote in a fall anchor. No
  shape analysis — the property is mechanical, known before the sample
  touches the control law.
- **INVARIANT 2: the belief falls only on evidence a censored sender
  cannot manufacture, SUSTAINED.** A genuine capacity drop produces
  persistent corroboration — delivery median below the belief PLUS
  loss or monotone queue growth, across ≥2 consecutive 500 ms
  fall-limiter windows. A self-reference artifact structurally cannot
  sustain that: the next compressed drain, idle-air beat, or probe
  refreshes the max. Genuine squeezes (the frozen tbf honesty legs)
  still fall within ~1 s — one limiter beat later than today, inside
  the pillar's fast-fall property.

**Measurement integrity (folded in, same slice):**
- **TX stamps, not enqueue stamps.** If the send ledger stamps at
  pacer entry, our own queue wait reads as path inflation (leg B's
  first fall: `backlog 158743 B`, 164 ms streak, at a rate the path
  provably carried). CNetIO has kernel TX timestamps since HS-4
  (SO_TIMESTAMPING OPT_ID+OPT_TSONLY); reconcile the ledger to wire
  egress so the queuing-delay signal measures the network.
- **Self-inflicted loss recuses itself.** At deep floors the frame
  ceiling forces starvation (HS-20's deep-floor note) and host-side
  drops flow into the same ledger deltas the loss bands read as path
  evidence — the floor seals itself. Host-originated drops
  (unprotectable, backlog-skipped, ceiling-forced) are already
  counted in their own books; exclude them from the loss fractions.

**CONTROL — unchanged in role, honest in inputs.** Verdicts (delay
inflation, loss bands) still decide WHEN to act, exactly as today. But
the fall anchor answers to the BELIEF — `0.85 × btlRate` under
invariant 2's decay — never to the median of raw recent samples. The
2–10% held loss band, the 500 ms limiter, the 10%/s climb, floor and
ceiling pins all stay. Optional follow-on (only if recovery still
reads slow at the glass after the model lands): a bounded probe pulse
after falls (one frame interval at btlRate, BBR PROBE_BW's shape) to
refresh the belief instead of crawling on luck — leg B logged 242
climb steps in 150 s.

## The gates dissolve — by staged retirement, not deletion

Under the model, each gate is a special case already handled:
self-reference band = a censored sample trying to lower the belief;
stall gate = censored trickle during the hole + an honest drain train
that RAISES the belief; dwell deferral = the belief's memory makes a
100 ms trickle unable to drag the anchor, nothing to defer.

Sequencing is conservative:
1. Land the model with ALL THREE GATES STANDING; every existing pin
   green on Mac and pup (the gates' virtual-time suites, the tbf
   honesty legs, HS-21/22 fast-fall pins).
2. Retire the gates ONE AT A TIME, each retirement its own commit,
   justified by its pins passing with the gate deleted — the model
   catches the case upstream. A pin that fails means the gate covered
   something real the model missed: stop, learn, fix the model, then
   retire.
3. End state: one model, two invariants, ~three fewer hand-written
   classifiers, and the whole finding family closed by construction
   rather than enumerated.

## What must NOT change

- Fast fall on genuine congestion (tbf honesty legs re-run live; ≤1
  limiter beat of added latency).
- The held 2–10% loss band (resiliency G1), floor/ceiling pins,
  sans-IO with injected clock, no wire bytes, nothing above the
  socket learns anything new.
- The idr-books and fall forensics keep working — they convicted the
  old model and they'll acquit the new one.

## Acceptance shape

- **Virtual-time leg-B replay**: a genuine loss episode followed by
  censored trickle samples + fresh super-rate full trains — the
  standing rate must recover toward the belief instead of ratcheting
  to the floor; the persistence path (real capacity drop) must still
  fall within ~1 s.
- **Live truth-probe leg B re-run** (armed 444 heavy motion, 90 s,
  35 M side-flood at t+40): no floor limit cycle; the session holds a
  sane share of what leg A proved (≥ ~0.5×); the flood still delivers.
- **Live tbf honesty legs**: sustained genuine squeezes still fall,
  anchored near true shaper rate.
- **Gate-retirement pins**: every retired gate's frozen tests pass
  without it.
- **The Beauty Bar IDR row re-measured after BOTH slices** — HS-27
  kills the per-move IDR cost, this slice kills the false moves; the
  pairing is the path to the last red going green.
