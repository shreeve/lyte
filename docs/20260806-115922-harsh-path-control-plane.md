# Harsh-path control plane — detection, mitigation, optimality

*2026-08-06 local. Analysis of Lyte’s end-to-end congestion / loss / jitter /
stall control plane, with the harsh-network patch as the working tree under
review. Control-plane policy only — not a wire/protocol change; frozen
vectors untouched.*

## Measured path envelope

| Path | Evidence |
|---|---|
| Mac Wi‑Fi → pup wired `.232` | Abundant ~100 Mbps; latency bursts p95 ~75 ms / p99 ~92 ms even to wired pup (owner path notes) |
| Pup Wi‑Fi `.249` | Backup; scan-stall study (`docs/20260801-075746-lyte-pup-scan-stall-study.md`) is why production prefers wired |
| Clean LAN motion (pre‑#204) | 1,831/1,831 frames, 0 IDR, 0 NACK, transport p99 ~5.8 ms (`HANDOFF.md`) |
| Moderate netem (prior investigator) | Before IDR fix: 124 IDRs; after client-owned recovery: 2 IDRs, 0 corrupt/handoff drops |
| 1% netem residual | Estimator could settle ~3 Mbps while air still had headroom — climb pinned by post-FEC clean bar |

Product posture today: default 4:2:0 on many connects; Best 4:4:4 when negotiated. Conductor reserve is automatic 1–4 beats (PR #207 elapsed-time return).

## Detection inventory and optimality verdicts

### Host (rate / repair owner)

| Detector | Home | Cost | Verdict |
|---|---|---|---|
| Packet-train delivery rate | `RateEstimator.absorbDeliveryTrains` | CPU per report; rides existing feedback | **Optimal sensor** for capacity; censored/honest/compressed classification (HS-28) is load-bearing on radio |
| Queuing-delay inflation | `RateEstimator.absorbDelay` | Light; 2× report cadence (~50–100 ms) | **Earliest rate signal in use**; second-min baseline rejects wake jitter. Not RTT |
| Pre-FEC loss bands | ledger deltas, 1 s window | Negligible | Correct hold 2–10% for FEC; >10% falls |
| Post-FEC (NACK) loss | `absorbNacks` + recusal | NACK TLVs | Correct rung-3 at >2%; was **over-strict on climb** at >0.5% (fixed below) |
| Beacon SRTT / min-RTT | `SessionBeaconClock` → `noteRtt` | 1 Hz CTRL | **Not in rate law** — repair freeze only. Correct split |
| Blackout silence | 350 ms without feedback | Lifecycle | Correct FROZEN → RECOVERY |
| Pacer / kernel backlog | queue budget 50/100 ms | Local | Fall purge + IDR when stale wire time exceeds budget |

### Client (absorb / evidence)

| Detector | Home | Cost | Verdict |
|---|---|---|---|
| Path delay → Conductor cue | `VideoBeatConductor.schedule` | O(1)/frame | **Correct rung-1 owner**: holes grow reserve; slip returns on 2 s surplus proof. Does not uplink |
| Audio skew spread | `AudioJitterBuffer` | Retarget every 5 pkts | Independent DAC lattice; slow decay by design |
| Assembler / NACK policy | `NackPolicy` + `FeedbackSender` | 25–50 ms reports; ≤6 NACKs | Efficient; one ask/(frame,shard); 250 ms → IDR |
| Renderer handoff pressure | `BoundedRendererHandoff` | Local | Terminal path → coalesced IDR episode |
| Delivery gauge / link pill | overlay + `LinkHealthMeter` | Display only | Correct: no control coupling |

**Earliest reliable congestion signal used today:** one-way queuing-delay inflation from matched dispersion (GCC family), needing two consecutive inflated reports (>15 ms over second-min baseline), often plus 500 ms persistence before an uncorroborated fall.

**Earliest Lyte could use without wire-v2:** same feedback already carries audio’s always-on delay sensor; it already feeds per-channel inflation. ECN / receive-window hints remain parked wire wants (`docs/20260728-175200-lyte-wire-v2-study.md`).

## Mitigation inventory and optimality verdicts

| Actuator | Home | Verdict |
|---|---|---|
| Standing rate / pacer | `RateEstimator` → `VideoChannel` / `Pacer` | Primary capacity knob; priority control > audio > freshVideo > videoTail |
| Frame byte ceiling | `frameByteCeiling` + `EncoderVbv` | **Must be FEC-wire-aware** (patch); old encoded-byte equality overstated budget under lossy FEC |
| Floor | 2 Mbps (patch; was 500 kbps) | **Necessary**: 820 kbps protected reserve made 500 kbps mathematically impossible |
| FEC regime clean/lossy | `stepRegime` | Correct ladder; 5 s step-down hold avoids flap |
| NACK repair | `Session.respondToNack` | SRTT freeze gate; opening exemption; refusals 0x23 |
| Fall purge | Session on rate fall | Purges stale backlog; arms `.fallPurge` IDR |
| Fresh-keyframe book | `SessionFreshKeyframeBook` | Coalesced causes; **stale-NACK IDR arm removed** (patch) |
| Client IDR episode | `IdrRequester` 500 ms retry | Sole recovery owner after stale repair; host suppresses older-named 0x10 only for an in-flight offer window (encode-time `lastKeyframeNumber` is not delivery proof) |
| Conductor reserve | 1–4 beats | Absorb delay/jitter without rate churn |
| Audio PLC / depth | jitter buffer 5–20 pkts | Protects intelligibility; pacer reserves 320 kbps |

## Causal map of loops (including fixed IDR amplification)

```text
Wi-Fi dwell/jitter      CLIENT ABSORB (no rate change)
delay burst, ~0% loss   Conductor hole -> +beat; audio spread
             |
             v
Queue growth /          HOST RATE (HS-16/28)
capacity loss           delay inflate / loss / post-FEC
                        -> x0.85 fall, FEC step, fall purge
             |
             v
Post-FEC holes          REPAIR then RECOVER
                        NACK -> videoTail; stale -> 0x23
                        Client IdrRequester owns IDR

FIXED AMPLIFICATION (prior patch):
  host stale-NACK armed IDR  +  client coalesced 500 ms retries
  -> 124 IDRs under moderate netem
  NOW: host refuses; client episode; host suppresses older-named 0x10
       only while a newer IDR offer is in flight (500 ms), then re-arms
       if the episode keeps naming pre-offer damage (lost-IDR stall fix)
```

### Loop-interaction answers

1. **Earliest signal used vs possible** — Delay inflation from 25–50 ms feedback; could not go much earlier without faster reports or ECN (wire change). Audio already contributes delay; it does not need a separate uplink.
2. **Over / under / fighting** — IDR storm **fixed**. Under-react: climb after mild residual post-FEC (**fixed below**). Fighting: rate vs Conductor is intentionally layered (pillar rung 1 vs 2); do not couple reserve to standing rate.
3. **Delay vs loss bias** — Path measurements are delay-burst heavy; HS-28 stall/belief already treat delay holes without cratering. Rate law uses delay first; loss corroborates. Estimator treats delay correctly when persistence + honesty hold.
4. **Bidirectional efficiency** — Feedback 25–50 ms + sparse NACK + 1 Hz beacon is appropriate. Input is reliable ARQ; not a congestion actuator. Uplink is not the bottleneck on this LAN.
5. **Audio vs video fairness** — 320+500 kbps reserves + pacer priority are correct; the old 500 kbps video floor starved video into uselessness while still failing to pace protected traffic.
6. **Metadata chatter** — No wasteful REMB; no Conductor uplink. Delivery gauge stays local. Good.
7. **Mitigation coherence** — Prefer Conductor tempo for jitter, rate/FEC for capacity, one client IDR episode for decode breaks. That is the optimal Conductor metaphor.

## Ranked defects / missed opportunities

| Rank | Defect | Evidence | Status |
|---|---|---|---|
| 1 | Floor 500 kbps < protected reserve | Math: 820 kbps reserve + lossy 1+2 FEC in 25 ms | **Fixed in patch** (2 Mbps) |
| 2 | `frameByteCeiling` ignored FEC wire | Harsh path entered lossy geometry; encoder admitted unpaceable frames | **Fixed in patch** |
| 3 | Host stale-NACK IDR × client retries | 124 IDRs moderate netem | **Fixed in patch** |
| 3b | Encode-time `lastKeyframeNumber` forever superseding 0x10 | Wholly lost recovery IDR + static desktop → permanent black glass | **Fixed**: in-flight offer window, then re-arm |
| 3c | Diagnostic sink never closed IDR episode | wire-view enqueued IRAPs but omitted `noteVideoIrapEnqueued` → 116×0x10 / 4 verdicts; host 500 ms offer window re-armed static-screen IDRs at ~2 Hz (114/60s) | **Fixed**: required `onIrapEnqueued` on `AVSampleBufferRendererVideoSink`; app handoff already closed |
| 4 | Climb gated on post-FEC < 0.5% | ~3 Mbps settle under 1% netem; rung-3 is 2% | **Fixed this pass** |
| 5 | Probe cadence 10 s after failed probe | Slows recovery after wall-slam; intentional HS-30 | Deferred — needs live A/B |
| 6 | Belief censored at pace | Structural; climb is geometric 10%/s | Accept; do not fake padding |
| 7 | Conductor reserve sticky after Wi‑Fi holes | 2 s/beat return by design (#207) | Deferred product feel |
| 8 | No ECN / recv-window | Wire-v2 parked | Deferred |
| 9 | Chroma / coalescing / clean-path tails | Owner notes | Outside this control-plane slice |

## Recommended optimal architecture

Layered stages matching resiliency §4 and the Conductor laws:

1. **Absorb (client tempo)** — Conductor reserve + audio depth for delay/jitter with ≈0 loss. No host rate move.
2. **Shape (host capacity)** — Delay inflation and honesty-gated falls; pre-FEC hold band; post-FEC rung-3 + FEC step; FEC-aware frame ceiling; operational floor ≥ protected + min FEC flight.
3. **Repair (targeted)** — NACK within freeze budget; refuse otherwise; never host-arm IDR from stale NACK.
4. **Recover (one episode)** — Client coalesced IDR; host coalesces older-named 0x10 only for an in-flight offer window, then re-arms if the episode continues; fall purge / unprotectable / lifecycle keep their own arms.
5. **Climb** — Evidence rises whenever pre-FEC is clean and post-FEC ≤ rung-3; `lastGoodRate` and FEC step-down stay on the strict clean column (< 0.5%).

Sans-IO: all policy remains in `HostWire` / `LyteCore` value types with injected time. No frozen-vector change.

## What this pass implemented vs deferred

### Implemented (uncommitted, with prior patch)

| Change | Files |
|---|---|
| Floor 2 Mbps; FEC-aware `frameByteCeiling` | `RateEstimator.swift`, tests, `benchmark-netem.sh` artifact filter |
| Client-owned recovery; in-flight 0x10 coalesce; remove stale-NACK arm; lost-IDR re-arm | `Session.swift`, `SessionFreshKeyframeBook.swift`, `HostApplication.swift`, `SessionWire.swift`, `IdrOfferInFlightGateTests.swift`, related tests |
| Climb admits mild post-FEC residual (≤2%); book `upshiftsUnderMildPostFec`; pins | `RateEstimator.swift`, `RateEstimatorGateTests.swift` |

### Deferred (actionable)

- Live re-commission moderate netem + delay-burst on a fresh 41xxx port after deploy.
- HS-30 probe-cadence A/B once mild-residual climb is live.
- Optional audio↔video shared “tempo stress” signal inside LyteCore (v2 convergence), not a second rate loop.
- ECN / recv-window TLVs only with a wire-version decision.

## Before / after metrics

| Scenario | Before | After (evidence) |
|---|---|---|
| Floor viability | 500 kbps commanded impossible recovery | Unit: production floor fits lossy 1+2 in 25 ms |
| Moderate netem IDRs | 124 | Prior patch: 2 IDRs, 0 corrupt/handoff (live) |
| Mild post-FEC climb | Structurally pinned (~3 Mbps reports) | Unit: 3091 → 4609 kbps in 4 s virtual with ~1% residual; rung-3 still blocks |
| Host tests | — | Full `Host` suite green (342 tests) after this pass |

Live netem was **not** re-run here: standing `lyte-host.service` must not be displaced; unit pins cover the new climb property. Next experiment: test host on fresh 41xxx with scoped netem per `Scripts/benchmark-netem.sh`, then restore.

## Open questions / next experiments

1. Under real 1% netem, does mild-residual climb restore ≥ half of negotiated ceiling within ~15 s without IDR growth?
2. Do Mac Wi‑Fi p95/p99 delay bursts still produce zero rate falls with Conductor absorbing (rung 1 only)?
3. Is HS-30’s 10 s probe cadence still earning its keep after the climb fix, or does it dominate residual settle time?
4. Should `lastGoodRate` refresh on mild-residual climbs after sustained delivery above the old mark (product WAKE quality), or stay strict-clean forever?

## References

- Resiliency pillar §2 / §4: `docs/20260720-191703-lyte-protocol-resiliency.md`
- Conductor: `docs/20260803-050422-metronome-playout-design.md`
- DESIGN D2–D4: `docs/DESIGN.md`
- Quality probe (floor crash / directive IDR): `docs/20260728-164746-lyte-video-quality-probe.md`
- Scan-stall: `docs/20260801-075746-lyte-pup-scan-stall-study.md`
- Live resume: `HANDOFF.md`
