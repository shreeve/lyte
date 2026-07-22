# Lyte Protocol — Network Resiliency Design (2026-07-20)

*One of four parallel pillar designs for the greenfield Lyte protocol (v2, LYTE-PLAN §5
Stage 3). This pillar owns loss, congestion, recovery, and adverse networks. Siblings own
image quality/codecs, timing/pacing/latency, and transport/session architecture;
assumptions on their areas are stated explicitly and not designed here.*

## TL;DR

Active-mode video keeps **per-frame Reed-Solomon FEC as the zero-RTT first line, adds
NACK-triggered retransmit as the RTT-gated second line, and keeps IDR-heal as the
backstop** — a hybrid, because with an infinite GOP every frame is a reference and a
"16 ms-old slice" is never stale: it repairs the decode chain. RaptorQ is rejected for
frame-sized blocks (§1.1). Audio keeps 4+2 RS unchanged. Congestion control is a
**delay-gradient estimator (GCC-family) re-based onto burst dispersion**: every
damage-burst we send is treated as a packet-train capacity probe, the continuous 5 ms
audio stream is the always-on queue-delay sensor, and the control law is deliberately
simple capped-CBR-with-downshift driving the encoder bitrate cap. The sender paces every
frame to the estimated bottleneck rate — never line rate; Sunshine's 80%-of-1-Gbps burst
is the documented anti-pattern behind its IDR-loss cascade. Wi-Fi adversity is a
four-rung detection/response ladder ending in the blackout state the client already
survives for 45 s. MTU starts at 1200 and probes up (DPLPMTUD). Acceptance is a
reproducible netem gauntlet with numeric pass bars (§7).

## Assumptions imported from sibling pillars

- **Transport**: provides an unreliable datagram service and a reliable channel; every
  datagram carries a monotonic transport-wide sequence number and a send timestamp is
  recoverable at the sender per sequence number; connections are identified by
  QUIC-style connection IDs, not 4-tuples (§6 states the requirement); everything is
  AEAD-encrypted.
- **Timing**: owns the send scheduler and the client-side jitter/pacing buffers. This
  pillar supplies the pacer *rate math* (§3) and the *buffer-grow trigger* (§4); timing
  owns the schedule and the buffer itself.
- **Image quality**: owns the encoder and the quality ratchet (post-damage refinement
  passes). This pillar supplies two inputs to it — `bitrateCap` and `frameByteCeiling`
  (§2.4) — and borrows its refinement traffic as probe traffic (§2.3).
- Decided tonight, built upon here: damage-driven video; idle mode = reliable channel +
  liveness beacon; idle→active = fresh IDR over datagrams; client tolerates arbitrary
  video silence after first frame and heals via IDR request (HANDOFF.md, idle-video
  acceptance).

## 1. Loss recovery per traffic class

### 1.1 Video, active mode: hybrid FEC + NACK + IDR backstop

Three candidates were evaluated for 60 fps LAN/Wi-Fi:

- **RS block FEC (today's nanors).** Zero-RTT recovery, MDS-optimal (any k of n shards),
  already proven client-side (M3: a 5% drop soak recovered 1,087 packets). Weakness is
  geometry, not the code: Sunshine caps frames at 4 FEC blocks of ≤255 shards and
  **silently disables FEC on frames that exceed it** — a lost packet in such an IDR is
  unrecoverable, the client requests another IDR, the host emits another oversized
  unprotected IDR, and the stream hangs in a feedback loop. This is a documented
  real-world failure mode ([Sunshine stream.cpp: "Skipping FEC for abnormally large
  encoded frame"](https://github.com/LizardByte/Sunshine/blob/3a12f96a/src/stream.cpp),
  [PR #2787](https://github.com/LizardByte/Sunshine/pull/2787),
  [PR #2803](https://github.com/LizardByte/Sunshine/pull/2803)).
- **RaptorQ / fountain codes** ([RFC 6330](https://datatracker.ietf.org/doc/html/rfc6330)).
  Rateless, linear-time, decode failure ≤10⁻⁶ with k+2 symbols. **Rejected for video.**
  Its advantages are asymptotic: they matter for source blocks of thousands of symbols.
  Damage-driven frames are 1–80 packets; at that scale RS is *optimal* (RaptorQ at k+0
  fails ~1% of the time where RS at k-of-n never does), and RaptorQ would add a new
  non-leaf C dependency against the two-C-leaf doctrine for zero recovery benefit.
  Revisit only if a future bulk channel (file transfer) wants fountain semantics.
- **WebRTC-style NACK + PLI.** Retransmission costs one RTT; PLI is our existing
  IDR-request. Alone it is wrong for us (first-loss always shows damage or waits an
  RTT), but as a *second* line it is exactly right on the paths we target.

**Decision: hybrid.** The reasoning hinges on one architectural fact: the encoder runs
infinite GOP with one reference (HANDOFF, encoder recipe), so every P-frame is a
reference frame. A retransmitted 16 ms-old slice is therefore **not useless** — the
decoder needs it to decode every subsequent frame, and decoders drain a two-frame
backlog far faster than real time. The real comparison is:

- *Retransmit*: costs `lostBytes` (typically 1–3 packets) + one RTT.
- *IDR heal*: costs a full IDR (~90 KB at 4:2:0, growing with 4:4:4) + RTT + encode
  time, and the IDR burst is itself the likeliest packet to be lost next — the cascade
  above. Parsec's BUD reaches the same conclusion: decide per-packet what is "safely
  dropped vs. retransmitted" rather than retransmitting indiscriminately or always
  rekeying ([Parsec BUD](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007),
  [US10951890](https://patents.justia.com/patent/10951890)).

**Rules:**

1. Per-frame RS FEC on every datagram frame; adaptive ratio per §5.2. FEC failure on a
   frame → client sends NACK naming the missing shards (transport sequence numbers).
2. Loss detection sender-side follows QUIC: packet-threshold 3 reordering, or
   time-threshold 9/8 × max(SRTT, latestRTT)
   ([RFC 9002 §6](https://datatracker.ietf.org/doc/html/rfc9002)); receiver-side NACK
   fires as soon as RS decode for the frame is impossible (missing > parity), not after
   a timer — the FEC geometry tells us immediately.
3. **Retransmit gate**: honor a NACK iff `SRTT + retxSerialization <
   remainingFreezeBudget` (budget = client jitter buffer + 2 frame intervals, supplied
   by timing) **and** the frame is newer than the last IDR. One attempt; no
   retransmission of retransmissions.
4. Otherwise, or if the retransmit doesn't complete the frame by deadline: IDR request
   (existing 0x0302 path). IDR-heal remains the backstop for everything — it is proven
   (45 s blackout test) and it is the *only* correct response to multi-frame loss.

On a 1–3 ms LAN RTT the gate always passes and IDRs become rare even at 5% loss. On a
50 ms+ WAN path the gate usually fails and behavior degrades gracefully to today's
FEC+IDR — correct, since retransmits there would arrive after the freeze anyway.

### 1.2 Audio

**Keep 4+2 RS interleave unchanged.** Measured impairment on the reference LAN is delay
variance with *zero* loss (audio-continuity doc §1); 4+2 already survives a 5% synthetic
drop (187 packets recovered, M4). The FEC-class alternatives (Opus LBRR, RFC 2198) are
already rejected on the record (audio doc §2) — do not re-litigate. One addition: audio
packets are never retransmitted (a 5 ms packet older than the playout point is genuinely
useless — unlike video there is no reference chain) and never NACKed. If Remote/WAN
telemetry ever shows sustained loss beyond 2-of-6, the knob is the RS ratio (e.g. 4+4),
negotiated at session start, not a new mechanism.

### 1.3 Input/control and idle-mode frames

Both ride the reliable channel (decided). The resiliency requirement on transport:
retransmission there must follow RFC 9002-style RTT-adaptive timers, not fixed-interval
(ENet-style) retry, so control latency degrades with the path rather than stepping.
Input is additionally idempotent-framed (absolute mouse coordinates and key-state
snapshots at recovery boundaries) so a reliable-channel stall never replays stale deltas
— the state machine in §4 depends on control-channel liveness as its ground truth.
Idle-mode sparse frames need no design here: reliability owns idle by decision, and the
liveness beacon doubles as the blackout detector (§4).

## 2. Congestion control and bandwidth estimation

### 2.1 Why not the incumbents unmodified

- **GCC** ([draft-ietf-rmcat-gcc-02](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02))
  is the right *sensor* — delay-gradient overuse detection reacts before loss, which on
  bufferbloated hotel APs is the only early signal — but its arrival-time filter and
  multiplicative ramp assume a near-continuous flow. Damage-driven video is silent for
  seconds, then 80 packets in one frame; GCC's estimator starves during silence and its
  slow additive probe never discovers headroom between bursts.
- **TCP-friendly (TFRC-class)** schemes chase loss equality with TCP flows —
  throughput-fair, latency-wrong for a real-time stream, and equally starved by silence.
- **BBR** ([draft-cardwell-iccrg-bbr-congestion-control](https://datatracker.ietf.org/doc/html/draft-cardwell-iccrg-bbr-congestion-control))
  contributes the right *model* — bottleneck bandwidth from delivery-rate samples,
  inflight below BDP — but PROBE_BW assumes it may inflate the send rate to probe, and
  padding a quiet desktop to probe defeats damage-driven silence.
- **Capped CBR with downshift** (GameStream in practice) is robust and simple but blind:
  Sunshine ignores the loss reports entirely ("loss stats are decorative",
  sunshine-v2026.715.205118.md §14.2) and paces at an assumed gigabit.

### 2.2 Design: burst-dispersion estimator, GCC-family detector, CBR control law

**The insight that fits our traffic: every burst we already send is a packet train.** A
paced burst of N packets sent at known spacing measures the bottleneck: the receiver's
arrival spacing gives a delivery-rate sample (BBR's core measurement), and the
arrival-vs-send delta trend across the burst gives a GCC-style queue-gradient sample. An
80-packet IDR is a superb chirp; even a 3-packet damage frame yields a coarse sample.
We are "usually quiet" only in bytes — in *events*, desktop use generates damage bursts
constantly, and each one refreshes the estimate.

Components:

1. **Feedback**: the client reports per-packet arrival times (transport sequence number
   + receive timestamp deltas), batched every 25–50 ms on the existing loss-stats
   cadence, semantics per transport-wide-cc / [RFC 8888](https://datatracker.ietf.org/doc/html/rfc8888).
   We own both ends; this replaces the decorative 0x0201 blob.
2. **Capacity estimator**: per-burst delivery-rate samples → windowed-max filter
   (BBR-style, window ≈ 10 s) → `btlRate`. Samples from bursts < 8 packets are
   weighted down (dispersion noise on Wi-Fi aggregation is severe for short trains).
3. **Overuse detector**: GCC trendline slope over the arrival deltas, adaptive
   threshold, three states (underuse / normal / overuse). The **audio stream is the
   always-on input**: 200 packets/s at fixed 5 ms spacing is a continuous delay-variance
   probe that never goes idle, so queue growth is detectable even during video silence.
   (Assumption on audio: it stays continuous CBR — it does, by the audio doc.)
4. **Control law**: capped CBR with downshift/upshift. `safeRate = min(btlRate × 0.8,
   lossRate-based cap)`. Overuse → multiplicative downshift (×0.85, ≥1 per 500 ms).
   Sustained loss > 2% beyond FEC recovery → downshift and raise FEC ratio one step.
   Underuse + headroom evidence → upshift ≤10%/s toward the session cap. Floor:
   500 kbps (enough for a paced IDR within 2 s even on a terrible path).

### 2.3 Estimating while quiet

Three sources, in preference order; no dedicated padding in steady state:

1. **Quality-ratchet piggyback.** The image-quality sibling's post-damage refinement
   passes are real bytes with flexible deadlines — ideal probe traffic. Requirement
   stated to that sibling: refinement sends are *shaped as paced trains* (≥8 packets
   when available) so each doubles as a capacity sample. This is our PROBE_BW
   substitute: probing with useful bytes.
2. **Audio gradient** (above) detects deterioration during silence but not headroom.
   That asymmetry is fine: while idle we don't need headroom knowledge, we need to not
   be surprised.
3. **Idle decay + conservative re-entry.** `btlRate` confidence decays after ~30 s
   without video samples. On idle→active, the fresh IDR is paced at
   `min(btlRate, lastGoodRate)` and its own dispersion immediately corrects the estimate
   — one frame of measurement, no blind burst. If confidence has fully decayed (minutes
   idle, or post-blackout), re-enter at 50% of the stale estimate.

### 2.4 Interface to the encoder (image-quality sibling)

Two values, updated at most once per frame, EMA-smoothed:

- `bitrateCap` = `safeRate − audioRate − controlReserve(500 kbps) − fecOverhead(ratio ×
  videoShare)`. The encoder never targets more.
- `frameByteCeiling` = the largest single frame that is (a) FEC-protectable under §5.2
  geometry and (b) pace-able within the burst latency budget (§3) at current `btlRate`.
  The encoder enforces it as its single-frame VBV cap. This closes Sunshine's oversized-
  IDR hole at the source: frames that can't be protected and paced are never emitted.
  (Precedent: capping VBV at the FEC-recoverable size is exactly the community fix for
  Sunshine's cascade.)

## 3. Burst pacing at the sender

Line-rate bursts are the proven killer: a 90 KB+ IDR at NIC rate overflows AP/switch
queues, tail-drops its own tail, and traps audio behind it (audio doc §1; Sunshine
cascade evidence §1.1). Policy:

- **Pacer rate** = `btlRate × 0.8`, expressed as packets-per-ms:
  `ppm = btlRate × 0.8 / (8 × pathMTU)`. Example: 200 Mbps estimate, 1400 B datagrams →
  ~14 packets/ms; a 77-packet protected IDR spreads over ~5.5 ms.
- **Burst latency budget**: a frame must finish serializing within
  `min(2 × frameInterval, 25 ms)`. If `frameBytes / (btlRate × 0.8)` exceeds it, the
  frame was too big — prevented upstream by `frameByteCeiling`, never "solved" by
  bursting faster.
- **Batch quantum ≤ 1 ms** of packets per sendmmsg/GSO batch, so the audio priority rule
  holds by construction: audio dispatches between batches, waits behind at most one
  batch (≤1 ms), preserving the 5 ms ± 2 ms p99 inter-send acceptance (audio doc §4.1).
  Priority order stands: input/control > audio > fresh video > retransmits/refinement.
- **Interface to timing sibling**: timing owns the frame schedule and send clock; this
  pillar owns the numbers — `ppm`, batch quantum, and burst budget — delivered as a
  `PacerPolicy` struct they apply. DSCP 40/`SO_PRIORITY` 5 on video, 48/6 on audio, as
  already decided.

## 4. Adverse networks: detection ladder and state machine

Wi-Fi failure modes are ordered by severity; each rung has one detector and one response,
and rungs are strictly escalating so responses never fight each other.

| Rung | Detector | Response | Owner |
|---|---|---|---|
| 1. Jitter spike (aggregation, AWDL scan) | audio/video arrival-delta variance up, loss ≈ 0, trend transient | grow client jitter buffer (timing's knob); **no rate change** | timing |
| 2. Congestion (queue growth) | GCC trendline overuse, sustained | downshift `bitrateCap` ×0.85; hold FEC | this pillar |
| 3. Sustained loss | post-FEC loss > 2% over 1 s | downshift + FEC ratio one step up (§5.2); NACKs continue | this pillar |
| 4. Blackout / roam | **no feedback and no audio acks for `N = 350 ms`** (covers office→kitchen roams; well past any aggregation stall) | freeze protocol below | this pillar |

**Blackout/roam state machine** (foundation: the client already survives 45 s of video
silence and heals by IDR — HANDOFF idle-video acceptance):

```
ACTIVE/IDLE ──(feedback silence > 350 ms)──▶ FROZEN
  FROZEN: stop all datagram sends (video + retransmits); audio continues at CBR
          (cheap, doubles as path probe); reliable channel keeps liveness beacon;
          estimator state parked, confidence decaying; session stays alive
          indefinitely — teardown only on reliable-channel death (transport's
          timeout, ≥ 30 s).
  FROZEN ──(any feedback returns / beacon acked, possibly from a NEW address
            via connection ID migration §6)──▶ RECOVERY
  RECOVERY: treat as unknown path: btlRate = max(floor, 0.5 × stale estimate);
            send fresh IDR paced at that rate; first-burst dispersion re-seeds
            the estimator; quality ratchet re-runs (image-quality's job).
  RECOVERY ──(2 consecutive clean feedback windows)──▶ ACTIVE
```

The roam case (brief 100% loss, then a new path with possibly different capacity — e.g.
5 GHz → 2.4 GHz) is exactly why RECOVERY resets rather than resumes: the old `btlRate`
may be 10× the new path. A same-address recovery inside 350 ms never enters FROZEN at
all — rung 1/3 absorb it.

## 5. MTU and packetization

### 5.1 Path MTU

- **Datagram size starts at 1200 bytes** — QUIC's safe-everywhere floor
  ([RFC 9000 §14](https://datatracker.ietf.org/doc/html/rfc9000#section-14)) — and
  probes upward per DPLPMTUD ([RFC 8899](https://datatracker.ietf.org/doc/html/rfc8899)):
  padded probe datagrams at 1400, then interface-MTU−28, acked via the normal feedback
  stream; success raises the packetization size at the next IDR boundary. Never
  fragment; never trust ICMP alone. LAN sessions settle at 1400 within the first second;
  tunneled/hotel paths stay at 1200. Probes re-run on path migration (§6).
- **Header budget**: transport header + AEAD overhead + resiliency header (frame number,
  shard index, FEC geometry) must fit ≤ 60 bytes = ≤5% of a 1200 B datagram (assumption
  stated to transport sibling; today's dialect spends 32 B on the GCM prefix + 28 B
  RTP/NV headers, so the budget is realistic).

### 5.2 FEC geometry under damage-driven traffic

Sunshine's fixed 20%-with-4-block-cap fails at both ends: tiny frames get useless
protection (20% of a 2-packet frame rounds to one parity shard only via a minimum rule)
and huge frames get *none* (silent disable, §1.1). Moonlight's client-side minimum
(`minRequiredFecPackets`) papers over the small end only. Per-frame adaptive ratio,
computed from frame size and the current loss regime:

| Frame size (data packets) | Parity (clean, post-FEC loss <0.5%) | Parity (lossy regime, rung 3) |
|---|---|---|
| 1–2 | 1 shard (50–100%) | 2 shards |
| 3–8 | 2 shards | ceil(50%) |
| 9–32 | ceil(15%) | ceil(35%) |
| 33–255 | ceil(10%) | ceil(25%) |

Rationale: small frames are cheap to overprotect and are the common case under damage
(a cursor-region update is 1–3 packets); large frames lean on NACK as the second line,
so their ratio buys single-loss immunity, not burst immunity — burst loss on an IDR is
handled by retransmit or IDR re-issue, not by 40% parity on 80 packets. One RS block per
frame up to 255 data shards; `frameByteCeiling` (§2.4) guarantees no frame ever exceeds
one block, so multi-block geometry and the silent-disable branch are *deleted from the
protocol*, not inherited. Parity shards carry the same per-shard headers rebuilt after
encoding (dialect precedent), and the FEC ratio in flight is advertised per-frame in the
shard header so the receiver's NACK decision (§1.1 rule 2) is immediate.

## 6. Multi-path and future-proofing (brief)

- **Connection migration is a v1 requirement** (stated to transport sibling): sessions
  are identified by QUIC-style connection IDs so a client whose address changes (DHCP
  renew, Wi-Fi roam across subnets, sleep/wake) resumes via the §4 RECOVERY path with a
  handshake-free address rebind + anti-spoof path validation (echo challenge), per QUIC
  §9 semantics. The 350 ms blackout detector plus RECOVERY already handles the media
  side; migration only requires that feedback from a new 4-tuple be attributable to the
  session.
- **Simultaneous multi-path (LAN + relay) is out of scope for v1** — consistent with
  "no TURN in v1" (LYTE-PLAN §7). Do not preclude it: feedback messages carry a path ID
  byte (0 for v1), and estimator/pacer state is per-path by construction (one instance
  in v1). Adding a second path later is new instances plus a scheduler, not a protocol
  change.

## 7. Acceptance gates

All profiles are netem/tc scripts checked into `Scripts/` (reproducible, run against
the host or a Linux bridge box), each ≥ 120 s, measured at the client with existing
kernel-timestamp instrumentation. "Artifact" = any rendered frame containing damage from
an incompletely decoded reference, or a freeze.

| Gate | Profile | Pass criteria |
|---|---|---|
| G1 random loss | 1% / 5% uniform loss | 1%: zero visible artifacts (FEC absorbs all). 5%: no artifact visible > 150 ms; ≤ 2 IDR requests/min; audio underruns ≤ baseline +0.05/s |
| G2 burst loss | Gilbert-Elliott, 25% loss in 40 ms bursts, 2 s spacing | no artifact > 250 ms; recovery via NACK not IDR in ≥ 70% of bursts (LAN RTT) |
| G3 jitter | delay 20 ms ± 15 ms normal, no loss | zero artifacts; zero rate downshifts (rung 1 must not trigger rung 2); audio underruns ≤ +0.05/s |
| G4 reorder | 25% reordered by 2–4 packets | zero artifacts; zero spurious NACK retransmits (QUIC thresholds absorb reordering) |
| G5 hotel Wi-Fi | 25 Mbps cap, 30 ms RTT, ±15 ms jitter, 0.5% loss, 300 ms bufferbloat queue, one 200 ms outage/min | stream settles ≤ 20 Mbps within 5 s; steady-state one-way queue delay < 50 ms (no bufferbloat riding); outages: no session drop, artifact ≤ 500 ms |
| G6 blackout | 100% loss for 10 s, same address | session alive; freeze, then first decodable IDR ≤ 300 ms after path return; full negotiated quality ≤ 3 s (ratchet) |
| G7 roam | 100% loss 500 ms, resume from new source address, capacity halved | migration accepted; IDR ≤ 400 ms after first packet from new path; no overshoot loss burst (RECOVERY enters at ≤ 50% stale estimate, verified from pacer logs) |
| G8 IDR pacing | forced IDR every 2 s at full bitrate, capture at host NIC | no send-side batch exceeds 1 ms quantum; audio inter-send 5 ms ± 2 ms p99 throughout (audio doc §4.1 criterion, now under adversarial video load) |

A gate change requires editing this table, not a test script — scripts implement the
table.

## References

- [draft-ietf-rmcat-gcc-02](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02) — Google Congestion Control (delay-gradient + loss, min-wins)
- [RFC 8888](https://datatracker.ietf.org/doc/html/rfc8888) — RTCP feedback for congestion control (per-packet arrival reporting)
- [RFC 9002](https://datatracker.ietf.org/doc/html/rfc9002) — QUIC loss detection (packet/time thresholds, RTT-adaptive timers)
- [RFC 6330](https://datatracker.ietf.org/doc/html/rfc6330) — RaptorQ (evaluated, rejected for frame-sized blocks)
- [RFC 8899](https://datatracker.ietf.org/doc/html/rfc8899), [RFC 9000 §14](https://datatracker.ietf.org/doc/html/rfc9000#section-14) — DPLPMTUD; 1200-byte floor
- [draft-cardwell-iccrg-bbr-congestion-control](https://datatracker.ietf.org/doc/html/draft-cardwell-iccrg-bbr-congestion-control) — delivery-rate/bottleneck model
- [Sunshine stream.cpp](https://github.com/LizardByte/Sunshine/blob/3a12f96a/src/stream.cpp), [PR #2787](https://github.com/LizardByte/Sunshine/pull/2787), [PR #2803](https://github.com/LizardByte/Sunshine/pull/2803) — FEC block cap, silent disable, pacing retrofit
- [Parsec BUD](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007), [US10951890](https://patents.justia.com/patent/10951890) — encoder-bitrate-as-congestion-lever, selective retransmit
- Local: docs/sunshine-v2026.715.205118.md (§6, §14), docs/20260720-145840-audio-continuity.md (§1, §4), docs/moonlight-common-c.md (§12), HANDOFF.md (idle-video acceptance)
