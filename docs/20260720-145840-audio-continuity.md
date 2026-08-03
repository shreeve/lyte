# Audio Continuity: Consult Verdict, H2 Sender Amendments, M7 Receiver Spec (2026-07-20)

## TL;DR

A long architectural essay (the "audio continuity engine" consult, 2026-07-20)
argued Lyte should adopt a WebRTC/NetEQ-class audio pipeline. Evaluated against
the actual code, the essay's *diagnosis* is correct — and largely re-derives the
2026-07-15 3-AI consult conclusion already in HANDOFF.md ("NetEQ-style
time-scale playout beats carrying a high buffer"). Its genuinely new
contribution is the **sender-side pacer framing, arriving exactly while we
design the sender**. Verdict: fold audio-priority send scheduling into H2 with
a measurable acceptance criterion (§4); pin the M7 receiver work as a
Swift-native continuity engine (§5); reject the FEC-class and
vendored-NetEQ prescriptions with reasons recorded so they are not
re-litigated (§2). No code changes — the M5.5–M7 freeze holds; nothing here
qualifies as a critical fix.

---

## 1. What the essay gets right (verified, not asserted)

Each claim below is checked against the code, not the essay's characterization
of it.

- **The three-timelines framing** (sender audio clock → network arrival
  timeline → receiver hardware clock) is the accurate root-cause description.
  Playout today is driven by arrival + hardware clocks with no reconstruction
  of the sender timeline: `RtpAudioQueue` orders purely by sequence number and
  reads the RTP timestamp only to rebuild headers of FEC-recovered packets
  (`RtpAudioQueue.swift`, `baseTs`); `AudioPlayer` enqueues on arrival and
  drains on the hardware callback. The dominant measured impairment is exactly
  what the framing predicts: **delay variance with zero loss** (150 s test,
  2026-07-20: 565 arrival gaps >50 ms, max 331 ms, zero packets lost, ~20
  underruns, adaptive buffer riding 35–137 ms).
- **Reactive delay control is necessarily late.** The adaptive buffer
  (`AudioPlayer.swift`) jumps the target +20 ms per underrun *event* (HANDOFF's
  "grow 10 ms/s" is a simplification), decays 5 ms per ~10 clean seconds,
  floor 50 / ceiling 120 ms — growth happens only after audible damage. The
  statistics a predictive controller needs (kernel-stamped gap histogram:
  >20 ms, >50 ms, max) are already collected and already flow through
  `LyteSession.Stats` into the Doctor's EMA rates.
- **Time-scale modification is the root-cause tool.** The trim rule
  (target + 30 ms slack → discard oldest audio, declicked) is simultaneously
  the A/V-sync bound and the post-burst recovery mechanism — after a 331 ms
  stall+burst it skips ~180 ms of audio content in one seam. Accelerate-after-
  burst replaces that content skip with time compression, and lets equilibrium
  sit lower than the worst recent gap. This is the recorded 2026-07-15 consult
  conclusion; the essay independently re-derives it.
- **The render callback holds a lock.** The `AVAudioSourceNode` render block
  takes an `NSLock` shared with the enqueue path (`AudioPlayer.swift`) — a
  genuine violation of Core Audio render-thread rules. Severity today is low
  (no allocations in the callback, short critical sections, userInteractive-QoS
  writer, no observed failure), but the hazard is real and the fix (lock-free
  SPSC ring) is mechanical. First M7 audio commit, not a freeze-breaking fix.
- **No packet-loss concealment.** A lost packet decodes to one frame of
  silence; `OpusDecoder.swift` documents that the system `AudioConverter` has
  no PLC entry point. libopus PLC is already the M7 plan (same file's header;
  PLAN.md §4.2 surround note).
- **Clock skew is unhandled** except crudely: receiver-slow drift accumulates
  into the trim (a declicked seam), receiver-fast drains into underrun-driven
  growth. At plausible consumer skews (~50 ppm ≈ 3 ms/min) that is one seam
  per ~10 minutes — real, small, lowest priority in §5.
- **The sender-burst hypothesis is plausible and testable.** Sunshine paces
  video at a hard-coded 80% of 1 Gbps in 1 ms groups regardless of negotiated
  bitrate (sunshine-v2026.715.205118.md §6 step 9, §14.5) — a worst-case IDR
  frame goes out as a line-rate burst of hundreds of packets that can trap the
  5 ms audio packet behind it in AP queues. Our measurements attribute the gap
  floor (~0.14 underruns/s) to client-radio causes (AWDL, shared-channel
  airtime), but the sender-bunching share has never been isolated. The H2 host
  is the instrument that can isolate it (§4).

What the essay's baseline caricature omits (already built and working):
kernel `SCM_TIMESTAMP` arrival probes (`AudioStream.receiveLoop`), a real
reorder queue with a 30 ms out-of-order wait window, 4+2 Reed-Solomon FEC with
the Nvidia parity matrix, VO socket service class, the AWDL helper, pre-roll
priming, and declick ramps at every seam. The architecture criticism survives;
the "packets arrive → queue → play → enlarge on underrun" characterization
does not.

## 2. Rejections (recorded so they are not re-litigated)

| Prescription | Verdict | Reasons |
|---|---|---|
| **Opus in-band FEC** (LBRR: packet N+1 carries recovery for N) | **Rejected** | Impossible in the current mode: Sunshine encodes `OPUS_APPLICATION_RESTRICTED_LOWDELAY` (CELT-only) and 5 ms frames are CELT-only regardless — LBRR is a SILK-mode feature. The receiver must call `opus_decode(..., decode_fec=1)`, which stock moonlight-common-c does not and our `AudioConverter` cannot. Adopting it means a host mode/frame-size change *plus* a Lyte↔Lyte client extension — to fix loss, which we measure at **zero**, and which the dialect's RS 4+2 FEC (33% overhead, bit-exact recovery of 2-of-6) already covers. FEC of any flavor does not fix delay variance, our actual disease. |
| **RFC 2198 redundant audio** | **Rejected** | Same target (loss we don't have), same redundancy with RS-FEC, and no slot in the Sunshine dialect — it would be a Lyte↔Lyte extension. Revisit only if Remote/WAN telemetry ever shows sustained real loss that RS 4+2 fails to cover. |
| **Comfort noise / expand-into-comfort-audio** | **Rejected** | Telephony machinery. Desktop audio is music and UI transients, where speech-tuned spectral expand sounds phasey. Fade-to-silence for long outages (declick ramps exist) is correct behavior here. |
| **Vendoring Chromium's NetEQ as a C library** | **Rejected** | Three axes. *Effort:* NetEQ is C++ deep inside the WebRTC tree with dependencies on `common_audio`, `api/`, `rtc_base`, and abseil — "compile as a small native library with a narrow C interface" understates a maintenance-heavy fork. *Doctrine:* the locked dependency rule is two vendored C libs, C only at hardware/OS leaves (HANDOFF "Architecture decisions locked"); NetEQ is a large mid-pipeline C++ engine, exactly what the rule prohibits. *Fit:* NetEQ is tuned for two-way speech at minimum delay; Lyte is a one-way media consumer comfortable at 50–120 ms whose payoff is seam quality and post-burst recovery, not call-grade minimum delay. The license claim is correct (BSD-3) — license was never the obstacle. The valuable *ideas* (percentile-targeted delay, WSOLA accelerate, decoder-integrated PLC) are a few hundred lines of Swift (§5). |

## 3. Verified code facts (the evidence base)

- **The sequence number is a sample-accurate media clock.** Sunshine sends
  hard-CBR Opus at a fixed client-negotiated packetDuration; the audio RTP
  timestamp increments in packetDuration-*ms* units, not sample ticks
  (sunshine-v2026.715.205118.md §6). Under CBR, `seq × packetDuration` *is*
  the sender media timeline — the essay's "give every packet a real media
  timestamp" is already satisfied by the wire; what's missing is a consumer
  of (media time, arrival time) pairs.
- **Kernel arrival timestamps are already collected.** `AudioStream` enables
  `SO_TIMESTAMP` and parses the `SCM_TIMESTAMP` cmsg so gap measurements blame
  the radio, not our thread scheduling; gap counters (>20 ms, >50 ms, max)
  ride `LyteSession.Stats` into the Doctor. The delay estimator in §5 consumes
  data that exists today; no wire change, no new probes.
- **`AudioConverter` supports neither `decode_fec` nor PLC.** Documented in
  `OpusDecoder.swift`; lost packets are silence until libopus lands (M7).
- **`x-nv-aqos.packetDuration` is client-negotiable and hard-coded `"5"`** in
  `Sources/LyteKit/Session/Sdp.swift`; Sunshine parses it at ANNOUNCE
  (sunshine-v2026.715.205118.md §5). 10 ms frames are therefore a one-line
  *client* policy experiment carried by the existing dialect (§5, item 6).
- **Sunshine already sets DSCP 48 / `SO_PRIORITY` 6 on audio** (DSCP 40 / 5 on
  video) via IP_TOS on Linux (sunshine-v2026.715.205118.md §2). The HANDOFF
  jitter-playbook item "host-side DSCP EF + SO_PRIORITY 6 … needs Sunshine
  patch" is therefore about *configuration/verification* on a Sunshine host;
  our own host ships the marking by construction (§4 below).

## 4. H2 sender design amendments

The sender side is where the essay's advice is cheap now and expensive to
retrofit. All of it is host-internal behavior on the existing dialect — zero
wire changes. Amendments to the H2 audio scope
(docs/HOST-PLAN.md §6 "H2"; LYTE-PLAN §6):

1. **Audio-priority send scheduling.** The host's send path maintains the
   priority ordering **input/control > audio > fresh video > complete video**.
   An audio packet due for transmission always dispatches ahead of any queued
   video shards; a video frame's packets are paced across the frame interval
   at the *negotiated* bitrate (never Sunshine's 80%-of-1-Gbps line-rate
   burst — the H4 pacing amendment, now load-bearing for audio).
   **Acceptance criterion (measurable):** while a worst-case IDR frame
   transmits, audio inter-send intervals at the host NIC stay within
   **5 ms ± 2 ms at p99** (measured via send-side timestamping or tcpdump on
   the host); no audio packet waits behind more than one in-flight video send
   batch. Stale-video discard and video-bitrate backoff (video yields before
   audio continuity is threatened) are *designed* under this ordering in H2
   but *implemented* in H4, where loss-driven adaptation lands.
2. **Socket priority parity.** DSCP 48 + `SO_PRIORITY` 6 on the audio socket,
   DSCP 40 + `SO_PRIORITY` 5 on video — byte-for-byte what Sunshine sets on
   Linux (sunshine-v2026.715.205118.md §2), so the qdisc/EDCA behavior our
   client is calibrated against is preserved.
3. **Media timestamps from the capture clock.** Audio RTP timestamps derive
   from the PipeWire graph clock, monotonic, in Sunshine's packetDuration-ms
   units — H1 acceptance (e) already pins the units (HOST-PLAN §6);
   this pins the *source*. Never wall-clock (Moonshine's `/11` hack is the
   documented client-breaking cautionary tale — moonshine.md §6.4).
4. **The H2 host is the jitter instrument.** With a correctly pacing host,
   A/B against Sunshine under identical radio conditions isolates the
   sender-bunching share of the measured ~0.14 underruns/s floor from the
   client-radio share (AWDL, shared-channel airtime). The doctor gains a new
   discriminator: gaps that vanish under the Lyte host are sender-induced;
   gaps that persist are the radio's.
5. **Rejections carried into the host design:** no Opus in-band FEC, no
   RFC 2198 redundancy, no comfort noise (§2 reasons). The host encodes
   `RESTRICTED_LOWDELAY` CBR exactly as the dialect requires.

## 5. M7 receiver spec (pinned)

The Swift-native continuity engine, in priority order — so the freeze thaws
into a spec, not a memory. Each item is independently landable.

1. **Lock-free render path.** Replace the `NSLock`-protected ring in
   `AudioPlayer` with a single-producer/single-consumer ring (atomic
   read/write indices). The render callback never touches a lock, an
   allocation, or Swift concurrency. Mechanical; first commit.
2. **Accelerate-only time-scale modification.** WSOLA-style compression of
   queued audio back to target after a burst, replacing the trim's content
   skip. Accel-only first: our failure mode (post-burst overshoot) only needs
   compression, and compression artifacts on music are milder than
   expansion's. Preemptive expand is a later evaluation, not part of this
   item's acceptance. **Acceptance:** a 300 ms stall+burst recovers to target
   depth with no content skip and no audible seam.
3. **Percentile-based predictive target-delay controller.** Replace the
   +20 ms/−5 ms heuristics with a statistical target: the smallest depth
   covering (e.g.) the 99.9th percentile of recent gap durations, fed by the
   kernel-timestamped gap data already in `Stats`. Depth changes apply via
   item 2's time stretching, never queue jumps. Honest limit: the first AWDL
   scan of a session is unpredictable by any receiver-side model — this
   improves equilibrium-finding and decay, not clairvoyance.
4. **libopus PLC + `decode_fec`-capable decode.** Rides the libopus vendoring
   M7 already plans for surround (PLAN §4.2). libopus is a genuine leaf codec
   library, consistent with the two-C-leaf doctrine in a way NetEQ is not.
   Lost packets interpolate instead of going silent; the decoder gains the
   *capability* to consume in-band FEC should a future Lyte↔Lyte mode ever
   justify it (§2 says today it does not).
5. **Slow clock-skew correction.** A rate-correction term (≤ a few hundred
   ppm) folded into item 2's resampling path. **Measure first:** long-run
   arrival rate vs 48 kHz is computable from seq + kernel timestamps already
   collected; implement only if telemetry shows drift outrunning the seam
   budget (today's worst case: one declicked seam per ~10 minutes).
6. **10 ms packetDuration as a measured policy experiment.** One line in
   `Sdp.swift` per Work/Play policy. Trade-offs are real in both directions:
   halves packet rate and per-second FEC overhead, gives the buffer more
   reaction time per packet — but adds 5 ms of frame latency and doubles the
   RS block time-window to 40 ms. Decide from measurement, not from the essay.

**Rejected for M7:** vendoring NetEQ (§2). The engine above captures its
load-bearing ideas at leaf-library weight.

**M7 acceptance envelope** (adapted from the consult, sized for one-way
desktop streaming, not calls): no arrival pattern inside the adaptive target
produces an audible discontinuity; bursts within ~2× target recover via
time-compression with no content skip; audible underruns on a healthy LAN
trend to zero; buffer equilibrium sits at the percentile model's output, not
at the worst gap ever seen.

## 6. Relationship to other docs

- **HANDOFF.md** jitter-research bullet records both consults; this doc is the
  second consult's full verdict.
- **docs/HOST-PLAN.md §6 (H2)** references §4 of this doc for the audio
  send design.
- **PLAN.md §6 (M7)** and **LYTE-PLAN §6 (H2/H4)** milestone rows stand;
  this doc is the audio-specific spec they point into.
- The freeze rule (LYTE-PLAN §6: M5.5–M7 paused during H0–H2) is untouched:
  everything in §5 waits for M7; everything in §4 is H-ladder work already
  in flight.
