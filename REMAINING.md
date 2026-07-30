# REMAINING — the three-auditor sweep, 2026-07-30

Three read-only auditors (host performance, client performance, cleanup/debt)
swept the repo after the all-green Beauty Bar day. Verdict: no architectural
problems, no unbounded growth, no correctness threats. What remains is listed
here, ranked by payoff-per-effort within each tier. Each item becomes one PR
that lands on success or closes on failure; resolved items migrate to the
Landed / Closed sections at the end of this file.

Effort: S = under an hour, M = a session slice, L = a full slice or more.

## Pending

### Do-now tier

2. **Capture-starvation tripwire** [S] — the direct-scanout freeze class has no
   runtime detector, only a startup warning. All inputs exist on the host tick
   (`lastOnFrameAt`, session state, input recency): one throttled loud book line
   when ACTIVE + recent input + capture gap > 500 ms.

3. **Pin tonight's untested pure logic** [M] — `RateMeter`, `VideoDeliveryBooks`
   (window-anchor eviction, wrap-safe math, ring percentiles), and the radio
   watchdog's 3-strike debounce live in the app target no test bundle reaches.
   Repo precedent is extraction (ControlStripPolicy → LyteUI, overlayLine →
   LyteTransport). Extract and pin.

4. **Docs/hygiene batch** [S] — HANDOFF.md sections titled CURRENT are two eras
   stale (line 406 contradicts the P-2/P-3 DROPPED ruling); H4 plan still carries
   un-annotated P-2/P-3 ladder rows; ConnectionModel comment quotes the
   pre-rename overlay string; `Scripts/awdl-quiet.sh`'s "interim until the M6
   helper" charter expired; TODO.md's `lyte sniff` entry doesn't know HS-5
   shipped; `.gitignore` ignores tracked Package.resolved files and vanished
   misc/ checkouts; `Host/spike/uinput_probe.c` is a self-declared throwaway
   whose question was answered.

### Host performance — the rate-fall moment

5. **Pacer `queuedBytes` O(n) → running totals** [S] — `Pacer.swift:182` walks
   every queued token; called per feedback report (20–40 Hz) and per capture
   frame (60 Hz), worst exactly when the queue is deepest (the fall). Maintain
   per-class byte/count totals in push/pop. Prerequisite hygiene for the purge.

6. **Fall-repricing purge** [M] — bytes admitted at 50 Mbps serialize at the
   crashed rate: 80–895 ms of stale wire measured. Add `Pacer.dropClass` for
   freshVideo/videoTail, clean up `VideoChannel.pending`/`queuedShardsByFrame`,
   arm the coalesced keyframe latch so the next frame re-anchors. Session
   already knows the fall moment (`Session.swift:2179`). The top-value host fix.

7. **VBV exact-tighten** [S] — with rung changes costing zero IDRs (HS-33), the
   √2 posture slack on tighten is pure quantization; tightens can land exactly
   on the ceiling rate. Loosen keeps the measured 10 s sustain lag (load-bearing
   per the 2026-07-29 A/B).

8. **Log lines out from under the session lock** [S-M] — `SessionWire.swift`
   `log()` prints while `lock` is held; a stalled stdout pipe would freeze
   audio/pacing/capture (priority inversion through console I/O). Buffer under
   lock, emit after unlock (the `pendingClipboardApplies` pattern).

9. **Host thread priorities** [S] — no `sched_*`/nice anywhere; the 1 ms-quantum
   pacing drain and 5 ms audio cadence ride default CFS against NVENC and the
   compositor. SCHED_RR (graceful EPERM degrade) on drain + audio threads;
   verify via `maxQueueDelayNS` books on a loaded box.

### Client performance — per-datagram fat on the receive thread

10. **VideoAssembler per-shard sweep** [S-M] — `VideoAssembler.swift:306`: full
    loss-presumption sweep + eviction scan (two `keys.sorted()` allocations) on
    every ingested shard, ~2–4k/s, walking all 64 groups even clean — worst
    during loss bursts. Gate the sweep on highestSeq advance, drop the sorts
    (eviction is time-based; the 50 ms tick already runs it), and fold in the
    drain/holdbackExpiry running-count fix. Largest recoverable client CPU.

11. **Unseal double copy** [S] — `ReceiveDemux.swift:139` does `Array(plaintext)`
    on a slice `NoiseTransportCrypto.unseal` just built as a fresh `[UInt8]` and
    downcast. Return `[UInt8]` from the unseal seam; deletes one ~1.1 kB
    alloc+memcpy per datagram on every channel.

12. **`mediaPathEvidence` off the per-datagram path** [S-M] —
    `LyteUdpSession.swift:939` takes the core lock and runs machine.apply/poll
    (two array allocs) per accepted datagram just to record "path alive."
    Relaxed-atomic last-evidence stamp read by the existing 100 ms machine
    timer; careful with FROZEN-exit-on-evidence semantics.

13. **`noteVideoShard` no-input fast path** [S] — `InputSender.swift:271`: TLV
    decode + lock per video shard to maintain the frame→stamp book that's only
    consumed while echoes are pending. Relaxed-atomic "input pending recently"
    check skips ~3k decodes+locks/s in the common no-input stretches.

14. **ARQ PTO timer reschedule skip** [S] — `ReliableCtrlEndpoint.swift:347`
    re-arms the DispatchSourceTimer on every send and every ACK (hundreds/s
    during drags), nearly always to an equivalent deadline. Track last-armed
    deadline; skip when unchanged within 1 ms.

15. **Histogram single-sort percentiles** [S] — `InputSender.swift:81`
    `percentile` re-sorts the whole ring per call; overlay lines call p50 then
    p99 (two sorts of up to 65,536 elements). One sort serving all requested
    percentiles; right-size gauge capacity to the 3 s window law.

### Worth doing — bigger or design-flavored

16. **Estimator stretched-train guard** [M] — the honest-vote classifier
    (`RateEstimator.swift:1115`) admits trains whose arrival span was stretched
    by a mid-train microstall (8 pkts over ~15 ms reads ~5 Mbps → honest median
    poisoned → belief demoted on clean 45 Mbps air). The compressed-drain purge
    encodes the right insight for drains; add the symmetric guard: discard or
    down-weight trains whose arrival span ≫ send span. Virtual-time pins plus
    an evening A/B.

17. **Idle-floor retention copy** [M] — `main.swift:742` memcpys the full
    ~14.7 MB capture buffer per damage frame; the encoder's AVFrame already
    holds the last-submitted pixels. A "re-encode retained frame" C entry point
    (reuse `e->frame`, skip input copy) frees ~6% of the 1440p60 frame budget.

18. **Adaptive audio pump** [M] — `LyteAudioPlayer.swift:298`: the 2 ms pump
    wakes 500×/s for the session's life — the client's biggest standing energy
    cost. When the ring sits at/above target the next interesting instant is
    computable; adaptive one-shot reschedule (floor 2 ms, ceiling ~10 ms) keeps
    the dry-ring reflex at ~3–5× fewer steady-state wakeups. Touches pacing
    doctrine; re-verify urgent/PLC path.

19. **wire-view dialect contract** [S] — wire-view still speaks the pre-rename
    stats dialect (`wire:`, `render:`, caps grammar) while the app overlay moved
    to session/user/network/audio/video. quality-probe.sh PARSES wire-view's
    lines, so either converge both in one commit or declare wire-view's output
    the machine-parse contract and document that at both sites. Doing the
    latter (S) unless a rename day arrives.

### Ruled out this sweep (recorded so they stay ruled)

- **Deep-floor shedding below ~1.5 Mbps** — real but worst payoff-per-effort on
  the board; the estimator work is making that regime rarer. Deferred.
- **Repair-lane per-ask shard cap** — mostly defused by the HS-32 budget gate's
  serialization term; keep as defense-in-depth someday.
- **Pointer-motion coalescing** — touches the HS-13 every-event contract; a
  design conversation, not a patch. Latency win only under loss.
- **Histogram triplication** — deliberate (sans-IO/no-Foundation boundary),
  documented and tested at each site. Leave.

## Landed

1. **quality-probe receipts grep rotted** [S] — PR #1, merged 2026-07-30.
   Pattern became `delivery [^)]*)` (captures through the belief-bearing close
   paren) plus a loud `*** GREP ROTTED ***` guard if the shape ever drifts
   again. Verified against today's real probe logs.

## Closed

(none yet)
