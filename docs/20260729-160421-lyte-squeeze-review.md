# The squeeze review — five performance candidates, assessed

*2026-07-29 ~16:00 MDT. Owner-commissioned: five parallel read-only
investigations into where performance headroom remains after the
HS-26…HS-30 arc (fps 47→61, IDR 15.2→4.26 clean-air, loss red retired).
Each section condenses one agent's full audit — verdicts, evidence,
fix lists with file:line pointers. Ranked recommendation at the end.*

## 1. Audio pops (owner-reported) — NO regression; two real fixes found

**Verdict:** client code and CL-17 controller behaving as designed;
nothing audio-touching changed since CL-17/HS-20. The afternoon's
saturating test legs on shared air explain the owner's pops (jitter σ
swinging 1.5→5.8 ms, late==plc exactly, real FEC-impossible groups).
**But the audit found a structural hole the estimator work exposed:**

- **Pacer granularity collapses at deep falls** — at the 500 kbps
  floor a 1 ms quantum is 62 B; one ~1230 B video datagram drives the
  bucket ~19 ms negative and strict priority cannot preempt an
  in-flight deficit (`Host/Sources/HostCore/Pacer.swift:266`;
  `setRate` line 211 carries deficit across falls). Measured: audio
  max queue delay **22.9 ms / 53.6 ms** vs the §4.1 design bound of
  5±2 ms.
- `SessionWire.sendAudioPacket` (SessionWire.swift:662–701) can give
  up its 4 bounded retries **without `signalDrain()`** — up to +16 ms
  hold when the sender thread is parked.
- Client ring underrun **hard zero-pads** (LyteAudioPlayer.swift ~118)
  — every edge is an audible crack (worst leg: 1.58 s of zero-fill).

**Fixes (one session, ordered):** (1) pacer serialization-rate floor
~5 Mbps (video demand still follows the estimator via frameByteCeiling
+ backlog gate), ~10–20 lines; (2) the missing signalDrain, 1–3 lines;
(3) declick the underrun boundary with 1–2 ms fades. Doc nits: accel
engage is target+3 (not "target+slack"); printed depth is
pending+pipeline, not buffer-local.

## 2. First frame — premise corrected; a DEAD REPAIR LANE found

**Verdict:** the 495 ms was ONE lossy 4:4:4 open (J-G4a warmup, 177 KB
opening IDR lost at the 50 Mbps opening pace, pre-HS-29/30 estimator);
the metric is first-datagram→first-enqueue (same as H2's 21.4 ms) and
**post-HS-30 legs open at 13–26 ms — already better than H2**.
**The real find is systemic:** the NACK repair lane essentially never
succeeds — host `repairFreezeBudgetNS = 33 ms`
(HostWire/Session.swift:157, refusals at 2183–2201, SILENT on the
wire) vs the 40 ms feedback cadence means asks are dead on arrival;
the client then burns its full 250 ms repair deadline
(NackPolicy.swift:80–81) before escalating. Twin-leg books: **82 asks,
1682 shards, 0 frames repaired, 28 expired→IDR**. Every past-parity
frame pays ~250 ms of freeze then IDR-churns — this also feeds the
IDR red's client-request row.

**Fixes:** (1) client rule-3 gate mirrors the host's real budget —
too-old-at-ask goes straight to the IDR path (~200–250 ms saved per
loss episode, low risk); (2) host: exempt the opening/last IDR from
the freeze budget while nothing has ever reached glass; (3) heal-IDRs
minted promptly and sized to the wire that just dropped them.
Lossy-open worst case bounds to ~60–120 ms, no protocol change.
Separately: true dial-to-glass is UNMEASURED (handshake 12.4 ms + caps
+ arm are outside the current anchor) — cheap instrumentation slice.

## 3. Non-IDR rate reconfigure — the FFmpeg wall is TWO LINES

**Verdict: highly feasible.** FFmpeg 8.0.1 `nvenc.c reconfig_encoder`
(2936–3026) already diffs rates and calls NvEncReconfigureEncoder —
then unconditionally sets `resetEncoder=1; forceIDR=1` (2997–98).
The gating GPU cap (DYN_BITRATE_CHANGE, supported on pup's RTX 4050)
exists precisely to promise no-reset rate changes. Runtime-option
routes: conclusively dead (zero RUNTIME_PARAM options). Direct SDK
rewrite: works but re-risks every measured truth (~2.5k lines).

**Recommended route A2:** vendored minimal static FFmpeg build —
n8.0.1 tarball + ~6-line patch + `--disable-everything
--enable-encoder=hevc_nvenc` → static libavcodec.a linked in place of
distro (CLibAV is the leaf's only consumer; Package.swift 54–57,
122–128, 150–160). Wrapper code stays byte-identical, so every
V-1/HS-24 measured truth rides unchanged. 1–2 sessions, ~90% kill
confidence; residual = whether VBV-resize also demands reset
(validate first via `lyte-encode-check` against the patched lib;
fallback = hold VBV per episode, move only rates). Payoff: the
rung-crossing toll dies everywhere — books collapse toward
client+opening; HS-27's rungs become tunable, not load-bearing.

## 4. WAKE-ratchet — high promise, re-titled by evidence

**Verdict:** the ~1.9 Mbps idle headline is STALE (HS-22's quiet-gate
won it). What survives, live in the owner's session log today: every
true post-idle wake = QP-46 blur flash → **179-pass / ~1 MB / 12 s**
ratchet re-sharpen (vs 4 passes / 200 ms for the same damage while
ACTIVE) + estimator knock-down (25→7.2 Mbps) minting climb IDRs.
Root cause: capture never negotiates `SPA_META_VideoDamage`
(capture.c:117–118) — a 30 px clock redraw and a full-screen repaint
are indistinguishable.

**WAKE-lite policy:** IDLE + small damage (≤1–2% area) + no input
pre-arm + clean interlude → P-frame at standing quality, no IDR arm,
no `applyIdrPacing` (belief preserved); anything else = today's path
byte-for-byte. Safe by construction (idle flip acks the converged
frame; encoder DPB never torn down; 0x10 escape hatch bounds
misclassification). ~200–350 lines / ~6 files; fully pinnable in
virtual time; **amends a W4b pillar pin** (needs the decision
ceremony). Gains: idle-adjacent IDRs → ~0, no blur pulse, ~50× per-
wake bytes.

## 5. Backlog gate — NOT worth it; the seam is fall-repricing

**Verdict: eliminated.** The 25 ms gate admits ~0 ms standing queue in
steady state (flat throttle counters across all quiet windows; frames
drain in ~8 ms vs the 16.7 ms interval; the backlog measure is already
estimator-priced). Tightening buys ≤8 ms transient-only and staples a
skipped frame to nearly every IDR. **The real episode latency lives in
rate-fall repricing**: bytes admitted at 50 Mbps become 80–895 ms of
wire when the rate crashes (the 352/895 ms queue-delay maxima).
Candidate: purge/re-gate already-queued fresh video at the moment of
an executing fall — new, evidence-backed, unsized.

## Ranked recommendation

1. **The repair-lane fix (§2)** — smallest effort, systemic payoff:
   every loss episode stops costing 250 ms of freeze + IDR churn;
   feeds directly into the IDR bar's client-request row.
2. **The audio trio (§1)** — one session, kills the user-audible
   failure mode at its three seams.
3. **Non-IDR reconfigure A2 (§3)** — 1–2 sessions, structurally
   greens the last red; validate the VBV question first, cheaply.
4. **WAKE-lite (§4)** — the glass stops flinching at idle wakes;
   needs the pillar-amendment ceremony.
5. **Fall-repricing purge (§5's find)** — size it during slice 3's
   estimator-adjacent work.
Dropped: backlog-gate tightening (measured ~0 gain); cap-raise to
60 Mbps (unassessed, expected ~nil at 59.7 dB motion).

---

# Addendum — independent consult (gpt-5.6-sol via rip-ai, 2026-07-29 ~16:15)

An external model reviewed the five verdicts on the four judgment
questions (ranking, A2 route, WAKE-lite safety, repair-lane design).
Agreements and CORRECTIONS adopted:

**Two framing errors caught (motivated reasoning, conceded):**
1. "The repair-lane fix stops IDR churn" — WRONG as written: aligning
   the client's patience to a dead lane reaches the IDR path SOONER;
   only the 250 ms dead wait is saved. The honest fix makes the lane
   WORK: **widen the HOST freeze budget** (~1.5× feedback cadence as
   the first experiment, derived not constant), add an EXPLICIT
   repair-refused/expired signal so the client never blind-waits
   (⚠️ wire touch — contract-safe append or wire-v2 batch), THEN
   derive the client deadline from the advertised budget + RTT.
   Opening-IDR exemption bounded by age/bytes/attempts.
2. "Wrapper byte-identical ⇒ measured truths unchanged" (A2) —
   INVALID: the changed transition semantics are exactly what must be
   revalidated. The static-recipe truths ride; the reconfigure-
   adjacent behavior (reference continuity across no-reset rate
   moves, under loss) is new surface. Also flagged: DYN_BITRATE cap
   does not prove every field combo (VBV size, multipass, AQ);
   check whether anything client-side implicitly leans on the forced
   IDR as a sync boundary; carry-costs (security tracking, rebase,
   dual-libav symbol risk) acknowledged. A2 still the right route.

**Ranking adjusted (consult + concessions):**
1. **Audio trio** — but the pacer fix reshaped: a 5 Mbps
   serialization floor under a 500 kbps verdict converts delay into
   bursts at the bottleneck; prefer the audio-reservation /
   bounded-preemption shape (exempt audio bytes from the shared
   bucket — strict priority already caps its volume). signalDrain +
   declick unchanged.
2. **Repair lane** — as the coordinated host+client fix above, not
   the client-only patience cut.
3. **Non-IDR reconfigure A2** — unchanged route, honester validation
   scope (reconfigure-adjacent truths re-measured, not assumed).
4. **Fall-repricing** — promoted above WAKE-lite: fund a bounded
   design/prototype (80–895 ms stale queues are severe and the purge
   helps multiple transitions).
5. **WAKE-lite** — demoted: weakest safety argument. Consult's
   failure catalog adopted into its future brief: ACK proves
   transport, not decode/DPB retention; concealment divergence;
   suspend/resume/decoder-reset during idle; epoch confusion across
   the idle boundary; the escape hatch itself being lost or answered
   with more P-frames. Required belts: decode-ack (not assembly-ack),
   stream epochs, periodic timeout IDR.
