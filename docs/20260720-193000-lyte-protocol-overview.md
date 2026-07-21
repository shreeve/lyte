# Lyte Protocol v1 — Capstone Overview (2026-07-20)

*The binding reconciliation layer over the four pillar designs
(image quality 191701, timing 191702, resiliency 191703, transport 191704).
Where this doc and a pillar disagree, this doc wins; the pillar docs are not
edited. Context: LYTE-PLAN §6, HOST-PLAN, the audio-continuity decisions
(20260720-145840), and the Caddy-bridge plan (20260720-184200). Amended same
evening: see the §6 addendum — the Lyte-UDP decision (20260720-215100)
replaces QUIC carriage and voids the H2.5/DSCP rulings; everything else
stands.*

## 1. The protocol in one page

**Lyte protocol v1 is a damage-driven, dual-mode, QUIC-carried,
end-to-end-encrypted remote-desktop protocol that ratchets a settled screen to
visually lossless and goes genuinely silent when nothing changes.** One QUIC
connection per session (swift-nio-quic primary, msquic C-FFI fallback behind
the one-week spike); a CTRL bidi stream for handshake/input/mode/beacon;
unreliable datagrams for audio, active video, and telemetry/feedback; a
reliable uni stream per sparse idle frame. Noise IK above QUIC TLS gives
mutual auth and payload confidentiality end-to-end, so the future Caddy bridge
relays ciphertext it cannot read. HEVC Rext 4:4:4 full-range BT.709 is the
Work-mode codec; capped-CQ VBR bounded by a single-frame VBV; Play mode keeps
CBR. Every frame gets per-frame RS FEC, RTT-gated NACK as the second line,
IDR as the backstop. Congestion is estimated from the bursts we already send
(dispersion trains), sensed continuously by the 5 ms audio cadence, and
actuated through exactly two encoder knobs. Audio's 5 ms ± 2 ms p99 inter-send
bound at the host NIC is the one constraint every pillar bends around.

**End-to-end walkthrough.** *Cold connect:* Bonjour (or host:port) → QUIC
connect under ALPN `lyte/1`, TLS 1.3 with self-signed certs, unauthenticated
at that layer by policy. Client opens CTRL. First contact runs the
PIN-as-PAKE pairing (CPace/SPAKE2 bound via TLS exporter) and pins static
Noise keys; every later connect runs Noise IK in 1-RTT against the pinned
statics. Capabilities exchange (CBOR intersect), the 1 Hz clock beacon starts,
continuous 5 ms CBR audio starts, and the host sends a fresh paced IDR.
*Active typing burst:* input events (client-timestamped, sequenced) ride
CTRL; the host injects, echoes (seq, rx ts, inject ts), and stamps
`lastInputSeq` into the next frame. Damage encodes the instant PipeWire
delivers it; shards go out as `chan=2` datagrams in ≤1 ms pacer batches at
0.8 × btlRate, audio dispatching between batches. The client feeds back
per-packet arrivals every 25–50 ms on `chan=3`; FEC failure triggers an
immediate NACK, honored iff it beats the freeze budget. Work mode presents
ASAP. *Ratchet:* 250 ms after damage-quiet, refinement P-frames step down the
QP ladder — still ACTIVE, still datagrams + FEC, shaped as ≥8-packet trains
that double as capacity probes. *Idle silence:* when a pass comes back
~all-skip, the host re-sends that final converged frame on a reliable
video-idle stream, signals ACTIVE→IDLE on CTRL, and stops datagram video.
Audio and the beacon keep flowing. *Wake:* an injected input pre-arms
next-damage-as-IDR before the damage exists, flips IDLE→ACTIVE on CTRL, and
the IDR goes out paced at min(btlRate, lastGoodRate), presented with no
display-link wait. *Wi-Fi roam:* feedback and audio acks go silent for
350 ms → FROZEN — datagram video stops, audio continues as the path probe,
CTRL keeps the session alive. The client's packets arrive from a new address;
QUIC migration validates the path; first feedback from the new 4-tuple →
RECOVERY at ≤50% of the stale estimate, fresh paced IDR, ratchet re-runs,
two clean feedback windows → ACTIVE. Full quality is back within ~3 s.

**Scope of authority.** This overview binds only the *interfaces*: the rows
in §2 and the rulings in §3. Everything inside a pillar's own boundary — the
codec matrix and QP ladder (image quality), the latency budget and
presentation policies (timing), the FEC geometry table, control law, and
netem gauntlet (resiliency), the channel table, crypto layering, and
migration plan (transport) — remains authoritative in the pillar doc and is
deliberately not restated here. A future change to any §2 row is an edit to
this doc first, then to the affected pillars; a change inside a pillar that
does not cross an interface needs no edit here.

## 2. Interface contract table

| Interface | Owner (computes/defines) | Consumer | Ruling |
|---|---|---|---|
| Pacer quantum | Resiliency (number) | Timing (applies) | **≤1 ms** batch quantum, delivered inside `PacerPolicy` {rate ppm, quantum, burst budget}. Timing's ≤2 ms was an upper bound; 1 ms is binding — audio waits ≤1 batch, meeting 5 ms ± 2 ms p99 with margin. R-G8 is the gate. |
| Pacer rate | Resiliency | Timing | **0.8 × btlRate, capped at the negotiated session rate.** Timing's "token bucket at the negotiated bitrate" reads as "at the current PacerPolicy rate." |
| Frame drain bound | Resiliency | Timing | Binding bound is the burst budget **min(2 × frameInterval, 25 ms)**, enforced upstream by `frameByteCeiling`. Timing's "≤ one frame interval by construction" holds only when pacer rate = encoder cap; it is the target, not the invariant. |
| Encoder knobs | Resiliency computes; image quality consumes | — | One struct, `RateBudget` {`bitrateCap` bps, `frameByteCeiling` bytes, `ratchetPaused` bool}, EMA-smoothed, updated ≤ once per frame. `bitrateCap` = safeRate − audio − 500 kbps control reserve − FEC overhead; it **is** image quality's "cap M" (post-deduction, not the raw estimate). `frameByteCeiling` is enforced as the single-frame VBV. Applied via NVENC dynamic reconfig, never restart. |
| Rate-control invariant | Image quality | Timing | The load-bearing invariant is **single-frame VBV + zero reorder**, not CBR. Work = capped-CQ VBR with `bufsize = maxrate/fps`; Play = CBR. Timing's drain math survives both. |
| Datagram envelope | Transport | All | 24 B fixed, little-endian: chan u8, flags u8, seq u16 (per-channel), frame u32, timestamp u64, fec u64. Envelope + payload ≤ **1152 B** (payload ≤ 1128 B). With the 16 B Noise AEAD tag, total app overhead is 40 B — inside resiliency's ≤60 B budget. |
| `timestamp` field | Timing (semantics); transport (layout) | All | **u64 microseconds, host PipeWire monotonic domain** (media capture time) on host-sent datagrams; client monotonic µs on client-sent ones. One clock domain, one `HostClockModel` on the client, two consumers (audio rate correction, video presentation). |
| `fec` field (8 B) | Resiliency | Transport carries opaquely | Pinned layout: shardIdx u8 \| dataShards u8 \| parityShards u8 \| scheme/flags u8 \| reserved u32. FEC group id = the envelope `frame` field. One RS block per frame, ≤255 data shards — 255 × 1128 B ≈ 287 KB max protected frame, far above any `frameByteCeiling`. Geometry fits; the silent-disable branch stays deleted. Audio's 4+2 RS expresses in the same field. |
| Loss/NACK addressing | Resiliency | Transport | NACKs and feedback address **(chan, seq)** with u16 serial arithmetic. Wrap at peak rate ≈ 3.6 s ≫ the NACK gate window. Sender keeps a per-channel send-timestamp ring ≥ 4 s deep — satisfying resiliency's "send timestamp recoverable per sequence number" without a transport-wide counter. |
| Payload size / PMTU | Transport (cap); resiliency (probing) | — | **1152 B is the default and the bridge-safe ceiling.** DPLPMTUD may raise the shard budget on direct paths only, as a negotiated session parameter applied at an IDR boundary — never per-packet, never past 1152 when a bridge is in path. |
| Mode machine | Transport (wire signal); resiliency (FROZEN/RECOVERY) | All | Four sender states: **ACTIVE, IDLE, FROZEN, RECOVERY**. ACTIVE⇄IDLE are wire modes signaled on CTRL; FROZEN/RECOVERY are the path-loss overlay, entered from either. WAKE is the IDLE→ACTIVE transition, not a state. |
| Ratchet channel & mode boundary | This doc | Image quality, transport, resiliency | **The session stays ACTIVE while the ratchet runs.** Refinement frames ride `chan=2` datagrams + FEC, shaped as ≥8-packet paced trains (resiliency's probe requirement). ACTIVE→IDLE fires at ratchet convergence (all-skip stop), and the final converged frame is re-sent on a video-idle reliable stream before the mode flips — a lost last refinement can never leave a stale screen. New damage during the ratchet aborts it; the session never left ACTIVE. |
| Priority order (unified) | Audio doc (root); this doc (tail) | Timing, resiliency | **CTRL/input > audio > fresh video > video tail + NACK retransmits > ratchet refinement > telemetry.** Retransmits complete older reference frames and ride the tail class; refinement is strictly below; telemetry last. |
| DSCP posture | Transport | All | v1 native: **one connection, DSCP 40**, audio protected by send scheduling (measured, R-G8). The 48/40 split lives on in the GameStream compat dialect (per-socket) and is the H2.5 A/B baseline. `audio-express` (second connection at DSCP 48) stays a reserved capability, not built until telemetry demands it. Audio-as-queue-sensor is unaffected — it needs cadence, not marking, and sharing video's queue makes it sense the queue that matters. |
| Beacon | Timing (content); transport (carriage); resiliency (fast detector) | — | **One beacon**: the clock-mapping message, host→client on CTRL at 1 Hz (plus at session start), client-echoed — feeding `HostClockModel` and slow session liveness (teardown ≥30 s on CTRL death). Fast blackout detection is **not** the beacon: it is 350 ms of silence on the client's 25–50 ms feedback stream + audio acks, owned by resiliency. |
| Congestion feedback carriage | Resiliency (content) | Transport | Client→host per-packet arrival reports (RFC 8888 semantics) ride **`chan=3` telemetry datagrams** every 25–50 ms. Unreliable is correct: stale feedback is worthless, and its absence is itself the blackout signal. |
| Retransmit budget | Timing supplies; resiliency gates | — | Freeze budget = client jitter buffer + 2 frame intervals. Work mode has no video jitter buffer, so the budget is 2 frame intervals — LAN NACKs still clear it easily. |
| Session-parameter renegotiation | Transport | Image quality | Typed CTRL message; capabilities that declare renegotiability (resolution, PMTU raise, rekey) change via clean IDR restart. Chroma/codec remain connect-time only. |
| Acceptance-gate namespaces | Each pillar | — | Resiliency keeps **R-G1…R-G8**; timing's table is **T-\***; image quality's §7 is **Q-\***. No collisions; cross-references use the prefix. |

## 3. Conflicts found & resolutions

1. **Pacer quantum: ≤2 ms (timing §4) vs ≤1 ms (resiliency §3).** Resolved: **1 ms, resiliency owns the number** (its own text claims the numbers via `PacerPolicy`; timing owns the scheduler). 2 ms sat exactly at the ±2 ms audio bound with zero margin for p99; 1 ms leaves headroom and matches R-G8's pass criterion verbatim.
2. **Pacer rate: "negotiated bitrate" (timing §4) vs 0.8 × btlRate (resiliency §3).** Resolved in resiliency's favor: the pacer runs at the PacerPolicy rate (0.8 × btlRate, never above the negotiated cap). Timing's §9 already conceded the ceiling is "the value their congestion controller maintains."
3. **Frame drain bound: timing's "≤ one frame interval by construction" (§1 row 6b, §4) assumed CBR VBV drained at the same rate the encoder targets.** With the pacer at 0.8 × btlRate and the cap decoupled, that identity breaks. Resolved: the binding bound is resiliency's burst budget min(2 × frameInterval, 25 ms), guaranteed upstream by `frameByteCeiling`; one-interval drain is the healthy-path outcome, not the invariant.
4. **Work-mode rate control: timing assumes "[codec sibling keeps CBR + single-frame VBV]" (§4, §9); image quality moved Work to capped-CQ VBR (§3).** Resolved: the invariant timing actually needs is single-frame VBV + zero reorder, which capped-CQ VBR preserves (`bufsize = maxrate/fps`). CBR survives only in Play mode. No numbers change.
5. **Ratchet vs mode boundary: image quality emits refinement during stillness; transport routes idle video onto reliable streams; resiliency borrows refinement as datagram probe trains.** Resolved (§2 table): ACTIVE holds through the ratchet; refinement rides datagrams + FEC as ≥8-packet trains; IDLE begins only at convergence; the final converged frame is re-sent reliably on a video-idle stream before the CTRL mode flip. All three pillars' assumptions survive; the only new rule is the reliable final-frame handoff.
6. **Encoder knob ownership: image quality wires "the congestion sibling's available-bandwidth estimate" into its cap; resiliency emits `bitrateCap` + `frameByteCeiling` post-deductions.** Resolved: one interface, `RateBudget`, resiliency computes, image quality consumes; cap M := `bitrateCap` exactly (already net of audio/control/FEC); ratchet surplus and pause collapse into `bitrateCap` + `ratchetPaused`. Units bps/bytes, ≤ once per frame, EMA-smoothed, NVENC reconfig.
7. **DSCP: audio doc mandates 48 on audio; timing §4 restates 48/6 + 40/5 per class; transport concedes one connection = one DSCP (40).** Resolved: the three are consistent once scoped — 48/40 per-socket is the compat dialect's (and the A/B baseline's) posture; the native v1 posture is DSCP 40 with scheduling-protected audio and `audio-express` reserved. Timing's DSCP sentence applies to the compat dialect only. Resiliency's audio-as-sensor never needed the marking.
8. **Sequence-number model: resiliency assumes a transport-wide monotonic sequence with sender-recoverable send timestamps; the envelope provides per-channel u16 `seq`.** Resolved: all loss/feedback addressing is (chan, seq) with serial arithmetic; the sender keeps per-channel send-timestamp rings ≥4 s. u16 wrap (~3.6 s at peak) vastly exceeds every gate window.
9. **MTU: resiliency's "1200 B floor + DPLPMTUD toward ~1400" vs transport's fixed ≤1152 B.** Resolved: 1152 wins as default and as the hard cap whenever a bridge is in path; DPLPMTUD may raise the shard budget on direct connections only, via session-parameter renegotiation at an IDR boundary. Resiliency's 1400 B examples are illustrative, not contractual.
10. **Beacon ownership: timing's 1 Hz clock-mapping message, transport's CTRL liveness beacon, resiliency's feedback-silence detector.** Resolved: one beacon — the clock-mapping message on CTRL at 1 Hz, host-sent, client-echoed — serving clock sync and slow liveness. The 350 ms blackout detector is a different mechanism (feedback-stream silence) and stays resiliency's. A 1 Hz beacon could never drive a 350 ms detector; conflating them was the trap.
11. **Feedback carriage gap: no pillar assigned the congestion feedback a channel.** Resolved: `chan=3` telemetry datagrams, client→host, 25–50 ms cadence.
12. **Envelope `timestamp` semantics left open by transport ("owned by timing").** Pinned: u64 µs, host PipeWire monotonic domain, capture-time semantics — timing's stated requirements, now written into the envelope contract.
13. **Priority-order tail drift: "complete video" (timing) vs "retransmits/refinement" (resiliency) vs "ratchet below fresh damage" (image quality).** Unified: CTRL/input > audio > fresh video > video tail + retransmits > refinement > telemetry.
14. **Idle wake vs blackout recovery: timing's pre-armed-IDR wake and resiliency's RECOVERY both emit "a fresh IDR" and could be misread as one path.** Resolved as distinct transitions in one four-state machine: WAKE (IDLE→ACTIVE, healthy path, IDR at min(btlRate, lastGoodRate)) vs RECOVERY (FROZEN exit, IDR at ≤50% of the stale estimate). The pre-arm flag persists through FROZEN and is consumed by RECOVERY's IDR, so a keypress during a blackout is never lost semantics.
15. **Rung-1 response "grow client jitter buffer" (resiliency §4) vs Work mode's zero video jitter buffer (timing §5).** Resolved: rung 1 acts on the audio adaptive target and Play-mode D only; Work-mode video simply presents late. No knob exists to fight over.
16. **Vocabulary pinned:** "frame number" = envelope `frame` (u32); "sequence" = envelope per-channel `seq` (u16); modes are ACTIVE/IDLE (wire) + FROZEN/RECOVERY (overlay); "StartB" is compat-dialect vocabulary — the native equivalent is "capabilities complete" on CTRL. Gate namespaces R-/T-/Q- per §2.

## 4. Open questions for the maintainer

1. **Accept the QUIC dependency as decided, pending the one-week spike?** The transport pillar reverses the bridge doc's "no QUIC" reasoning with 2026 facts (swift-nio-quic). If the spike fails criteria (a)–(e), msquic C-FFI is the recorded fallback — but taking *any* QUIC stack is the largest dependency decision in the project's history and deserves an explicit yes.
2. **Adopt H2.5 sequencing — native transport between H2 and H3, and clipboard shipping native-only?** This amends LYTE-PLAN Stage 2 (the ENet extension channel becomes a fallback, not the plan). It front-loads QUIC/Noise risk in exchange for never building the feature channel twice.
3. **Sign off the v1 DSCP posture:** audio at DSCP 40 inside the single native connection, protected by scheduling alone, with the compat dialect's 48/40 as the measured A/B and `audio-express` built only on proven regression. This is the one place v1 knowingly regresses a pre-existing audio commitment on paper.
4. **Where does the ratchet land?** Image quality frames it as "what the idle floor becomes in the native protocol"; the mode-boundary ruling here assumes native channels. Options: hold it for H2.5+ (clean), or prototype the QP ladder on the compat dialect's idle floor first (earlier data, throwaway wiring). Sequencing call, not a design call.
5. **Accept 1152 B as the universal shard budget until DPLPMTUD-raise ships?** It simplifies v1 (one geometry everywhere, bridge-proof by default) at ~4% wire efficiency cost on LANs that could carry 1400 B. The alternative — shipping the raise mechanism in the first native slice — buys bytes but adds a renegotiation path to the very first milestone.

## 5. Suggested build order (first three native slices)

**Slice N1 — transport skeleton (≈2 weeks).** The §1 validation spike
(swift-nio-quic pass/fail (a)–(e); on failure, pivot to msquic, no redesign),
then one QUIC connection: CTRL echo + input + raw video datagrams to the
debug client, envelope v1 frozen exactly as §2 pins it (timestamp and FEC
layouts included — freezing them now is the point of this overview).
*Gates:* spike criteria; input-echo tuples flowing on CTRL; envelope
round-trip under the 1152 B budget through a local WebTransport relay stub.

**Slice N2 — media, paced and protected.** Audio datagrams (4+2 RS in the fec
field, continuous CBR); per-frame adaptive RS FEC on video; the pacer at
PacerPolicy (0.8 × btlRate, ≤1 ms quanta); `chan=3` feedback stream + the
burst-dispersion estimator; `RateBudget` wired into NVENC reconfig; Noise IK
end-to-end (TLS-only stub allowed for the first week, slice fails without
Noise on). *Gates:* **R-G8** (audio 5 ms ± 2 ms p99 under forced IDRs) and
**R-G1** (1%: zero artifacts); **T** clock-model residual < 1 ms after 30 s;
H2.5 A/B vs the compat dialect answers the DSCP question with data.

**Slice N3 — modes and adversity.** ACTIVE⇄IDLE on CTRL with the video-idle
reliable streams; the ratchet over datagrams with the convergence handoff
(final frame reliable, then IDLE); pre-armed WAKE; FROZEN/RECOVERY with the
350 ms detector; QUIC migration + path validation. *Gates:* **R-G6**
(blackout: IDR ≤ 300 ms after path return, full quality ≤ 3 s), **R-G7**
(roam: RECOVERY enters at ≤50% stale estimate, verified from pacer logs),
**T** wake-from-idle (first photon ≤ mid-session damage-to-photon + one frame
interval, p95), **Q** ratchet convergence ≤ 3 s at LAN surplus with zero
frames after convergence.

Everything after (feature channels on H3, 4:4:4 gates on H4, resume/rekey
soak, the remaining R-gates G2–G5 as netem scripts) rides the existing
H-ladder unchanged.

## 6. Addendum (2026-07-20, ~21:51): the Lyte-UDP decision

The maintainer's same-evening decision
([20260720-215100-lyte-udp-decision.md](20260720-215100-lyte-udp-decision.md))
drops the GameStream compat dialect entirely and replaces QUIC with
homegrown Lyte-UDP over plain UDP. The body of this doc is deliberately not
rewritten; read it with these rulings:

- **The H2.5 sequencing (§4 question 2, §7 references) is void** — there is
  no compat protocol to upgrade from, so there is no "native transport
  upgrade" milestone. The build order in §5 collapses into the new H0b/H1/H2
  ladder (LYTE-PLAN §6 as amended).
- **The DSCP compromise (§2 DSCP row, §3 conflict 7, §4 question 3) is
  void — superseded by the 2026-07-20 Lyte-UDP decision: no compat dialect;
  per-packet DSCP restored.** We own the UDP socket outright, so per-packet
  TOS/DSCP via `sendmsg` cmsg applies from day one: audio 48 / video 40, the
  audio doc's original commitment. `audio-express` is moot.
- **QUIC carriage is replaced** by plain UDP datagrams plus a tiny homegrown
  ordered-retransmit sublayer for the reliable consumers (CTRL/input, sparse
  idle frames, final ratchet frame). Every §2 interface ruling survives —
  envelope, timestamp, fec field, (chan, seq) addressing, mode machine,
  ratchet boundary, priority order, beacon, feedback carriage, 1152 B budget
  — they were transport-agnostic or app-level already. Where the text says
  "QUIC stream," read "reliable sublayer channel"; the decision record §8
  carries the detailed adjudications (crypto collapses to Noise-only,
  version in the first handshake datagram, migration via connection IDs).
- **§4's open questions are all answered**: (1) no QUIC; (2) H2.5 void;
  (3) DSCP posture reversed as above; (4) the ratchet prototypes now, on the
  H0a file-output host.
