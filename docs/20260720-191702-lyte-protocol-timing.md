# Lyte Protocol: Timing, Pacing, and Latency (design note, 2026-07-20)

## TL;DR

One master clock (the host PipeWire graph clock, already pinned for audio RTP),
one client-side skew estimator shared by audio and video, damage frames encoded
the instant they arrive, a strict-priority token-bucket pacer that makes the
audio-continuity doc's 5 ms ± 2 ms p99 inter-send criterion true by
construction, host-clock-mapped adaptive video playout in every mode,
audio-master sync only when motion content is actually playing, and an
input-echo loop that gives us Reflex-grade input-to-photon numbers without a
photodiode. Target: **≤ 10 ms p50 added latency** (capture-copy through decode)
on wired LAN — the pipeline costs less than one 60 Hz frame over running the
app locally. Sibling designs own codec choices, FEC/congestion, and wire field
encodings; assumptions on them are flagged inline as **[assume: …]**.

---

## 1. End-to-end latency budget

The chain for one damage event at 2048×1280@60 (16.7 ms host frame interval,
8.3 ms client vsync interval on 120 Hz ProMotion):

| # | Stage | p50 | p95 | Notes |
|---|-------|-----|-----|-------|
| 1 | Damage → compositor composite | 8.3 | 16.0 | App commits mid-refresh; Mutter paints once per refresh period, max one-refresh added latency ([mutter frame clock](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/1241)). Cost exists locally too — not Lyte overhead. |
| 2 | Composite → PipeWire buffer delivery | 1.5 | 3.0 | Screencast blit rides the compositor paint; delivered on the PipeWire graph clock near vblank. |
| 3 | Dequeue + copy/CSC | 1.0 | 2.0 | BGRx → NV12/YUV444 conversion; CUDA path when DMA-BUF import lands. |
| 4 | NVENC encode (P1/ULL, CBR, single-frame VBV) | 3.0 | 5.0 | 1–3 ms measured at 1080p60 HEVC on Ada ([Remio encoder comparison](https://remio.net/blog/hardware-encoder-comparison)); 2048×1280 is 1.26× the pixels; RTX 4050 is a small Ada part — budget 3–5 ms. |
| 5 | Packetize + RS-FEC | 0.5 | 1.0 | nanors on ≤ VBV-cap frame. |
| 6 | Pacer + wire (typical P-frame) | 1.0 | 3.0 | Serialization at negotiated rate; typical damage frame is a few KB. |
| 6b | Pacer + wire (worst-case IDR) | — | 16.7 | Single-frame VBV caps any frame at `bitrate/fps` bits, so draining at the negotiated rate takes ≤ one frame interval **by construction** (§4). |
| 7 | Network propagation | 0.3 / 3 / RTT⁄2 | 1 / 10 / — | Wired LAN / good Wi-Fi / remote. |
| 8 | Video playout target | 15 | 50 | Adaptive D, clamped to 15–50 ms (§5); rises quickly under jitter, shrinks slowly. |
| 9 | VideoToolbox HEVC decode | 3.0 | 5.0 | Hardware decode, `kVTDecompressionPropertyKey_RealTime`, async decompression; a few ms per frame on Apple Silicon ([AVF decode benchmark](https://gist.github.com/vade/f72362c60434e5af2801d01f09bdbf34)). |
| 10 | Enqueue → vsync (120 Hz) | 4.2 | 8.0 | Present-ASAP waits at most one 8.3 ms ProMotion slot — half the penalty of a 60 Hz client. |
| 11 | Scanout + panel response | 6.0 | 8.0 | ~half scanout to mid-screen + LCD response. Also paid locally. |

**Totals (damage event → photon), Work mode:**

| Tier | p50 | p99 target |
|---|---|---|
| Wired LAN | ~29 ms | **≤ 45 ms** |
| Good Wi-Fi (5 GHz, clean channel, AWDL suppressed) | ~33 ms | **≤ 60 ms** |
| Remote (hole-punched P2P) | 29 ms + RTT⁄2 | ≤ 45 ms + RTT⁄2 + jitter allowance (§5) |

The honest comparison is **added latency vs sitting at the machine**: rows 1
and 11 are paid locally too. Lyte's own cost is rows 2–10 ≈ **10 ms p50 on
wired LAN** — sub-frame overhead, in the same class as Parsec's measured
"~7 ms added on LAN" and 2-frames-behind at 240 fps
([Parsec technology](https://parsec.app/technology),
[Parsec 240 fps test](https://medium.com/parsec/parsec-game-streaming-total-latency-at-240-frames-per-second-c0818cc0daa5)).
That is the number the telemetry in §8 must report continuously.

## 2. Clock architecture

**One master clock domain: the host PipeWire graph clock** (CLOCK_MONOTONIC
on the host). The audio-continuity doc already pins audio RTP timestamps to it
(§4.3 there); this design extends the same domain to video rather than
revisiting it. Every capture buffer — audio and video — gets a timestamp from
the same monotonic clock at the same conceptual point (media entered the
graph). One domain means A/V sync (§6) is a subtraction, not a negotiation.

- **Video timestamp semantics:** host capture time of the frame (PipeWire
  buffer pts), resolution ≥ 1 µs internally. The Sunshine dialect carries a
  90 kHz RTP clock; that is a wire encoding detail, not the source of truth.
  For Lyte v2 the recommendation is one shared 1 MHz (microsecond) media
  clock for both streams **[assume: transport sibling owns the field layout;
  this doc specifies source, semantics, and ≥ 1 µs resolution]**.
- **Clock mapping message:** the host periodically publishes
  (host-monotonic µs ↔ media timestamp) pairs on the control channel — the
  RTCP SR role from RFC 3550 §6.4.1, with RFC 6051-style rapid sync at
  stream (re)start so the very first frames are mappable. Cadence: at
  StartB, then every 1 s.
- **Client mapping:** the client estimates offset + skew between host
  monotonic and its own `mach_absolute_time` using the existing control-channel
  ping round-trips: take the **minimum-filtered** one-way estimate over a
  sliding window (queuing delay only ever adds, so the min edge tracks the
  true offset), and fit skew by linear regression over the window — the same
  family as WebRTC's `RemoteNtpTimeEstimator`/timestamp extrapolator. Expected
  consumer skew is ~50 ppm ≈ 3 ms/min (audio doc §1), so a 30 s window fits
  skew to well under 1 ms/min residual.
- **One estimator, two consumers.** The session owns a single
  `HostClockModel`; the M7 audio rate-correction term (audio doc §5.5) and the
  video presentation mapper (§5 below) both read it. Audio and video must
  never run independent skew estimates — divergent estimates *are* an A/V
  sync error.
- Wi-Fi asymmetry makes min-filtered RTT/2 imperfect (a few ms offset error).
  That is acceptable: A/V sync uses only *differences* within the host domain
  (offset error cancels), and absolute one-way error only biases the latency
  telemetry, which we cross-check with the input-echo loop (§7).

## 3. Host-side frame timing: encode immediately, never align

**A damage frame encodes the moment PipeWire delivers it. No capture tick, no
alignment to an encode clock.** Rationale: PipeWire delivery already rides the
compositor's paint clock, so frames cannot arrive faster than the refresh
rate — an aligning tick would add a mean half-interval (8 ms) of latency to
buy a regularity the stream already has. Damage-driven means aperiodic is the
*normal* case; the pipeline must be event-driven end to end.

Two rules keep the encoder honest under load:

1. **One frame in flight, latest-wins.** The encoder facade holds at most one
   pending frame (Sunshine's own invariant). If a new damage frame arrives
   while one is encoding, it replaces any not-yet-started pending frame. We
   ship the freshest pixels, never a backlog.
2. **pts is the capture timestamp, always.** The idle-floor re-encodes
   (HANDOFF, H0a slice 2) get the tick time as pts; damage frames get PipeWire
   buffer pts. Monotonic by construction on the single PipeWire loop thread.

## 4. The pacer (hard constraint restated)

**Hard constraint, inherited from docs/20260720-145840-audio-continuity.md §4
and not negotiable: while a worst-case IDR transmits, audio inter-send
intervals at the host NIC stay within 5 ms ± 2 ms at p99, and no audio packet
waits behind more than one in-flight video send batch.** Sunshine's
80%-of-1-Gbps line-rate burst is the recorded anti-pattern.

Design:

- **Strict-priority classes** over one egress path:
  input/control > audio > fresh video > complete video (the pinned ordering).
  "Fresh video" is the newest frame's shards; "complete video" is the tail of
  an older frame still draining. Stale-frame discard and bitrate backoff under
  this ordering are designed in H2, implemented in H4 (per the audio doc).
- **Token bucket at the negotiated bitrate** for the video classes, drained in
  **quanta of ≤ 2 ms of wire time** (at 50 Mbps ≈ 12 KB per quantum). Between
  quanta the scheduler re-checks the higher classes. An audio packet due
  mid-IDR therefore waits at most one quantum: 5 ms cadence ± ≤ 2 ms — the
  acceptance criterion is met *by construction*, then verified by NIC-level
  measurement (§8), never assumed.
- **Bounded tail by VBV.** Single-frame VBV caps every frame at
  `bitrate/fps` bits **[assume: codec sibling keeps CBR + single-frame VBV]**,
  so draining at the negotiated rate completes within one frame interval even
  for the worst IDR — pacing across the frame interval (the audio doc's
  requirement) and bounded video latency are the same mechanism, not a
  trade-off. Typical damage P-frames are a few KB and clear in 1–3 ms.
- **Aperiodicity is free.** The bucket accumulates credit while the desktop is
  static, so an isolated damage frame after quiet sends immediately at full
  quantum rate; sustained 60 fps motion converges to smooth per-interval
  pacing. No mode switch, no heuristic.
- DSCP/SO_PRIORITY tiers ride each class as pinned (audio 48/6, video 40/5)
  so on-host qdisc and Wi-Fi EDCA agree with our internal ordering.

## 5. Client-side presentation

**Accepted posture (2026-07-31): one adaptive policy in every mode.**
Present-ASAP/`DisplayImmediately` is retired. Each frame presents at
`clientTime = HostClockModel.map(captureTs) + D` on a CoreMedia timebase
slaved to the local host clock. D is clamped to **15–50 ms**, grows immediately
when arrival jitter or lateness consumes its margin, and decays slowly
(0.1 ms per successfully early frame). The first frame needs no second-frame
warm-up: before the first clock fit it schedules from its local arrival.
Scheduling against the *host capture timeline*
  preserves the source's temporal spacing for aperiodic frames — this is what
  makes 60 fps motion smooth on a 120 Hz panel (each content frame owns two
  vsync slots; a miss costs 8.3 ms, not 16.7). A frame arriving later than its
  slot presents ASAP and bumps D. Moonlight's macOS pacer (display-link
  driven, ProMotion treated as fixed 120 Hz, one pending frame ≈ one frame of
  latency) is the closest prior art
  ([moonlight-qt frame pacing](https://github.com/andygrundman/moonlight-qt/commit/bef8d26a3d0b8a8eeb76365ef1dff2f0dc478aa0));
Lyte's difference is scheduling on the mapped host clock instead of queue
  depth, which handles aperiodic damage frames without misreading "queue
  empty" as "behind".
- Renderer readiness is authoritative: a not-ready renderer does not receive
  an unconditional enqueue. A serial queue retains the complete compressed
  dependency chain (four samples / 50 ms maximum). Crossing either bound,
  renderer failure, or excessive lateness discards and flushes the **whole**
  decode episode, emits one coalesced IDR recovery demand, and rejects
  inter-frames until that IDR starts the next episode. An arbitrary P-frame is
  never dropped by itself.
- The display link idles when no frames are in flight (damage-driven idle);
  the wake path (§7) must not wait for it — the first frame after idle is
  enqueued for immediate display, not for a display-link callback.

## 6. A/V sync policy

Strict lip-sync is the wrong default for a remote desktop: during typing there
is often *no video at all* (damage-driven idle) while audio plays — classic
sync is meaningless there. The perceptual physics: audio **leading** video is
detectable at +45 ms and objectionable at +90 ms; audio **lagging** is
tolerated to −125/−185 ms (ITU-R BT.1359-1,
[thresholds](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1359-1-199811-I!!PDF-E.pdf)).
Our steady state — video near-zero buffered, audio at its 50–120 ms adaptive
target — puts video *ahead* (audio lagging), squarely in the tolerable region.

- **Work mode: sync is monitored, never enforced.** Video latency (typing)
  and audio continuity each optimize independently. No mechanism trades one
  for the other.
- **Play mode: audio is master; video slaves.** Audio's delay controller runs
  exactly as the audio doc specifies (its seams are expensive). The video
  presentation mapper adds a bias term to D to hold the measured sync error
  inside **[−100 ms, +30 ms]** (audio-lead positive; tighter than BT.1359
  detectability on the dangerous side, generous on the harmless side).
  Nudging D is cheap and artifact-free; nudging audio is not.
- **Measurement:** both pipelines report "host-timeline media time at output"
  through the shared `HostClockModel` — video: capture ts of the frame at its
  predicted photon time (scheduled vsync + scanout constant); audio: capture
  ts of the samples at the DAC (render-callback position + reported output
  latency). Sync error = the difference; one signed number, histogrammed. The
  two streams having different jitter buffers is exactly why the measurement
  must be at the *outputs*, not at the queues.

## 7. Input-to-photon and the idle wake path

The full typing loop: client keydown → control channel → host inject (portal
RemoteDesktop, uinput fallback) → app renders → compositor damage → §1
pipeline. On wired LAN the budget composes to **~50–60 ms p50 keypress →
photon** (input send ~1 ms + inject ~1–2 ms + app render + one compositor
frame ~17 ms + §1 rows 2–11), dominated — correctly — by the app and the two
displays, not by Lyte.

**Live measurement, protocol-level.** NVIDIA Reflex measures click-to-photon
by correlating a click with a deterministic pixel flash
([Reflex Latency Analyzer](https://www.nvidia.com/en-us/geforce/news/reflex-low-latency-platform/));
we get the equivalent without hardware because we own both ends:

- Every input event carries a client-monotonic timestamp and sequence number.
- The host echoes (seq, receive ts, inject-complete ts) on the control
  channel → isolates network + inject cost per event.
- Every video frame header carries **lastInputSeq**: the newest input sequence
  injected before that frame's capture ts **[assume: transport sibling
  allocates the field; semantics: host fills at encode submit]**. The client,
  at that frame's photon time, closes the loop: a true per-keystroke
  input-to-photon sample, attributable per stage. This is Moonlight's
  frame-time overlay extended end-to-end.

**The wake path (first frame after idle is the latency-critical one).**
Someone just typed; the idle→active IDR restart must not add a frame:

1. **Capture never sleeps.** The PipeWire stream stays connected during idle
   (damage-driven delivery means it costs nothing); no renegotiation on wake.
2. **Encoder stays warm.** The NVENC session persists through idle; the
   idle-floor already exercises it. Wake reuses it — no session setup.
3. **Input is the pre-arm signal.** An injected input while idle immediately
   flips the pacer to active and marks *next damage frame = IDR* — the IDR
   decision is made before the damage arrives, never after a client
   request round-trip. The keypress→damage interval (app think time) is free
   pre-arm time.
4. **The wake frame races nothing.** It encodes on arrival (§3), pays the IDR
   wire tail (≤ one interval at negotiated rate, §4), and presents via
   Work-mode ASAP with a direct enqueue (§5) — no display-link wait, and the
  adaptive mapper without waiting for a second frame to estimate anything.
5. **Measured option, default off:** a wake-only 2× token-bucket rate to
   halve the IDR tail, with the ≤ 2 ms quantum (and therefore the audio
   criterion) unchanged. Adopt only if §8 telemetry shows the tail dominating
   wake latency in practice.

Net wake cost over a mid-session damage frame: the IDR serialization tail
alone. Acceptance gate below holds it to ≤ one frame interval extra at p95.

## 8. Instrumentation and acceptance gates

Symmetric, kernel-stamped, histogrammed. The client already collects
SCM_TIMESTAMP arrival probes (HANDOFF); the host mirrors the discipline with
SO_TIMESTAMPING TX stamps so every stage boundary in §1 is a measured edge,
not an estimate.

**Host exports** (per session, p50/p95/p99 histograms + counters):
capture→encode-start, encode duration, pacer queue delay *per priority
class*, frame wire-drain time, **audio inter-send interval at the NIC** (the
H2 gate), input receive→inject, clock-mapping publish age.

**Client exports:** kernel RX gap histograms (exist), reassembly-complete
→ decode-start, decode duration, decode→vsync wait, predicted photon error
(Play mode: scheduled vs actual vsync), video target-delay D trajectory, A/V
sync error histogram, per-keystroke input-to-photon via lastInputSeq, and
`HostClockModel` residual (fit error, ppm skew). All of it flows through
`LyteSession.Stats` into the doctor, same as the audio gap probes today.

**Acceptance gates** (each gates a named slice; measured, not vibes):

| Gate | Criterion | Slice |
|---|---|---|
| Audio pacing under IDR | host-NIC audio inter-send 5 ms ± 2 ms p99 during worst-case IDR | H2 (pinned; restated) |
| Damage-to-photon | p99 ≤ 45 ms wired LAN, Work mode, while streaming 4:4:4 | H4 |
| Added latency | rows 2–10 of §1 ≤ 10 ms p50 / ≤ 20 ms p99 wired LAN | H4 |
| Input-to-photon | p99 ≤ 80 ms wired LAN (terminal typing workload), 4:4:4 | H4 |
| Wake-from-idle | first-photon ≤ (mid-session damage-to-photon + one frame interval) p95 | H2 |
| Clock model | mapping residual < 1 ms after 30 s of session | H2 |
| Play-mode pacing | ≥ 99% of frames hit their scheduled vsync slot at D, LAN, 60 fps motion | M7 |
| A/V sync (Play) | sync error inside [−100, +30] ms ≥ 99% of the time, motion content | M7 |

## 9. Boundaries with sibling designs

- **Transport/session** owns field encodings for: capture timestamps, the
  clock-mapping message, input echo tuples, lastInputSeq. This doc fixes
  their semantics and resolution (≥ 1 µs, host PipeWire monotonic domain).
- **Resiliency/FEC** owns loss recovery and congestion response; this doc
  assumes the pacer's negotiated-rate ceiling is the value their congestion
  controller maintains, and that FEC overhead is inside the VBV/bitrate
  accounting so §4's one-interval drain bound survives.
- **Image quality/codecs** owns encoder configuration; this doc depends on
  CBR + single-frame VBV + zero reorder (the bound in §4 and the decode-order
  simplicity in §5 both rest on it).
