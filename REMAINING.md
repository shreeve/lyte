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

### Host performance — the rate-fall moment

### Client performance — per-datagram fat on the receive thread

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

2. **Capture-starvation tripwire** [S] — PR #2, merged 2026-07-30. The Sink
   tick now trips a throttled `capture: STARVED` line (ACTIVE + input within
   2 s + no capture frame > 500 ms; cursor is EMBEDDED so input must damage),
   naming the scanout prerequisite; episodes counted in the final stats block.
   Host build on pup clean with the vendored no-reset recipe.

3. **Pin tonight's untested pure logic** [M] — PR #4, merged 2026-07-30.
   VideoDeliveryBooks.swift moved verbatim to LyteTransport; the watchdog
   debounce extracted as pure `RadioHoldPolicy`; 12 pins in
   OverlayGaugeTests.swift (window law, anchor eviction, hop percentiles,
   strike ladder). Patient-connect stays app-embedded deliberately — its
   round policy is a refactor, not a pin; possible follow-up. Full suite
   222/222 green.

4. **Docs/hygiene batch** [S] — PR #3, merged 2026-07-30. HANDOFF CURRENT
   sections retitled HISTORICAL with the P-2/P-3 contradiction superseded
   inline; H4 plan rows struck with the DROPPED ruling; stale ConnectionModel
   comment fixed; awdl-quiet.sh demoted to manual fallback; TODO's sniff entry
   narrowed to the decrypt half; vanished misc/ patterns collapsed; spike file
   deleted. One audit claim corrected in-flight: Package.resolved was ignored
   AND untracked (not ignored-yet-tracked) — the ignore stays; pin-tracking
   policy is an owner call.

5. **Pacer `queuedBytes` O(n) → running total** [S] — PR #5, merged
   2026-07-30. `ClassQueue.bytesQueued` maintained by push/pop; O(1) reads
   for both hot gates. Pinned by a drain-era ground-truth test; host suite
   225/225 Mac AND pup.

6. **Fall-repricing purge** [M] — PR #6, merged 2026-07-30. `Pacer.dropClass`
   + `VideoChannel.purgeQueuedVideo` + Session hook: genuine falls (never
   evidence decay) reprice queued video at the new rate and purge past a
   50 ms threshold, arming a named `fall-purge` IDR through the coalesced
   latch; counters + live `rate: fall purge` line. FallPurgeGateTests (4
   rungs incl. a whole-session 20%-loss leg); suite 229/229 Mac AND pup.
   NOT yet observed live under a real fall — watch the new line on the next
   constrained-air session.

7. **VBV exact-tighten** [S] — PR #7, merged 2026-07-30. `exactTighten`
   config flag (shell-gated by the proven no-reset lib, same gate as the
   half-rung ladder): tightens land exactly on the ceiling rate and material
   within-band falls retune; loosen/restore untouched (10 s sustain stays).
   5 pins incl. a ladder-mode control; suite 234/234 Mac AND pup.

8. **Log lines out from under the session lock** [S-M] — PR #8, merged
   2026-07-30. 48 event-log/inject prints buffer into `pendingLogLines`
   under the lock and flush at the service-tick/drain-loop/awaitClient/
   shutdown seams; line text byte-identical, only the print moment moves.
   Suite 234/234 Mac; pup build clean.

9. **Host thread priorities** [S] — PR #9, merged 2026-07-30. `lyte-audio`
   asks SCHED_RR 12 and `lyte-wire-drain` RR 10 at thread entry, degrading
   loudly to nice −10 then default; README grew the optional rtprio rlimit
   grant. pup has no rlimit yet — the `sched:` lines will show the degrade
   path until it's granted; `maxQueueDelayNS` books are the loaded-box
   evidence surface.

10. **VideoAssembler per-shard sweep** [S-M] — PR #10, merged 2026-07-30.
    Sweep gated on highestSeq-advance/new-group; `contiguousPrefix` early-out
    (clean in-order shards never touch a slot); `sweepSettled` latch (a fully
    reported+written-off group is grieved once); sorts only when a walk fires.
    Wire 486/486, root 212/212, host 234/234.

11. **Unseal double copy** [S] — PR #11, merged 2026-07-30. The
    `TransportCrypto.unseal` seam returns `[UInt8]`: the AEAD's fresh buffer
    rides through the demux whole; insecure mode takes the one unavoidable
    copy. Root suite 212/212.

12. **`mediaPathEvidence` off the per-datagram path** [S-M] — PR #12, merged
    2026-07-30. Accepted datagrams stamp a relaxed `Atomic<UInt64>`; the
    100 ms beat feeds the machine the newest stamp at its true arrival time
    (detector/liveness bit-exact); a `machineFrozen` flag keeps the FROZEN
    exit datagram-immediate. Root suite 212/212.

13. **`noteVideoShard` no-input fast path** [S] — PR #13, merged 2026-07-30.
    Relaxed `hasPendingInput` atomic re-derived at every book mutation;
    shards skip the TLV decode + lock cold while both books are empty
    (lossless: a pre-send frame's stamp is always < the new seq). New skip
    pin + re-armed honesty pin; root suite 213/213.

14. **ARQ PTO timer reschedule skip** [S] — PR #14, merged 2026-07-30.
    `armedDeadlineMicros` bookkeeping with a ±1 ms skip band; the fired
    path clears it under the lock before re-arming (no sleep-forever), as
    does stop(). Root suite 213/213.

15. **Histogram single-sort percentiles** [S] — PR #15, merged 2026-07-30.
    `percentiles([q...])` answers every quantile from one sort; both
    double-sorting overlay sites converted; element-exact pin. Capacity
    right-sizing deliberately left as an owner call: the input gauge's
    65,536-sample ring reads near-cumulative — say the word if the user
    line should feel more recent. Root suite 214/214.

## Closed

(none yet)
