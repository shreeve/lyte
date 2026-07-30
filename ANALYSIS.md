# ANALYSIS — final comprehensive codebase review (2026-07-30)

*Six independent read-only deep reviews at `b00149b`-era HEAD, one per
territory — architecture/layering, Wire protocol core, client transport,
host congestion stack, host runtime + C leaves, app shell/UI — each
judging correctness, efficiency, clarity, and performance. Every finding
was read-verified with a concrete failure scenario; none have been
adversarially re-verified or reproduced live, so each fix deserves a
reproducing gate test alongside it (the audit-sweep discipline). The six
TODO.md "Audit-sweep verification caveats" are excluded here — they
remain tracked there. The six agents' complete unabridged reports are
preserved verbatim in `ANALYSIS-DETAILED.md`.*

## Overall verdict

**The architecture is sound, the disciplines are real, and nothing found
threatens the product's design.** Zero architectural rework items — every
finding is a localized fix inside a structure worth keeping. The
distribution is telling: the most-tested territory (Wire, 486 pins)
yielded no HIGHs at all, while the two territories hardware and UI make
hardest to test (the host's C/thread seams and the app's window
lifecycle) yielded almost all of them. The known weaknesses sit exactly
where the test discipline couldn't reach — the profile of a healthy
codebase.

## Tier 1 — real bugs a user can hit (fix-worthy now)

1. **⌘W tears down nothing** — `Sources/Lyte/ConnectionWindow.swift:5`
   (no `.onDisappear`), `Sources/Lyte/ConnectionModel.swift:451`
   (`endLyteSession` reachable only from Disconnect / peer teardown /
   capability failure). Closing a stream window — the most natural macOS
   verb — leaves the receive thread, 100 ms machine beat, and feedback
   cadence alive forever: no typed 0x0A leaves, the host keeps encoding
   full-rate into the void, the menu bar still says "streaming," and
   awdl0 stays held down (AirDrop/Continuity broken) until app quit.
   Every other exit path is clean; this one verb has no seam.

2. ~~**Mid-session resolution change reads past the capture buffer**~~
   — **LANDED, PR #24** (2026-07-30; see Landed section at the end).

3. ~~**AudioWire thread-lifetime hazards (two HIGHs)**~~ — **LANDED,
   PR #23** (2026-07-30; see Landed section at the end).

4. ~~**Channel-0 seq/seal race**~~ — **LANDED, PR #22** (2026-07-30;
   see Landed section at the end).

5. ~~**Estimator delay-baseline poisoning**~~ — **LANDED, PR #21**
   (2026-07-30; see Landed section at the end).

6. ~~**`exactTighten` rising-edge ratchet**~~ — **LANDED, PR #20**
   (2026-07-30; see Landed section at the end).

## Tier 2 — hostile-peer and edge-condition hardening

7. **Unauthenticated peer retarget** (client) —
   `Sources/LyteTransport/UdpReceiveEndpoint.swift:202-233`: any
   datagram whose source parses as AF_INET overwrites `peerAddress`
   *before* the AEAD sees the bytes; an off-path trickle at ~50 Hz
   steals the return leg (ACKs, input, feedback). The host has
   PathValidator for the mirror case; the client has nothing. Fix:
   adopt the source only on `.accepted` — strictly better for roaming
   too.

8. **NACK-driven IDR arming has no throttle** (host) —
   `Host/Sources/HostWire/Session.swift:2366` arms the coalesced
   keyframe latch on every unknown-frame NACK, unbounded. An
   authenticated client naming one garbage frame per 25–50 ms report
   forces 100% IDR encoding at 60 fps (and per-frame NVENC resets under
   distro libavcodec). The other five demand sources are host-armed and
   self-limiting; only this one is peer-driven at wire cadence. Fix:
   per-interval cap on `.unavailable` arms.

9. **ARQ receive groups never reclaimed** (Wire) —
   `Wire/Sources/LyteWire/ArqEndpoint.swift:369-443`: removal happens
   only on complete one-shot delivery; abandoned/poisoned groups live
   forever. 63 never-completed one-shot groups pin the 64-group table;
   thereafter every new one-shot is refused *without an ACK* — and since
   idle-frame acknowledgment drives ACTIVE→IDLE, the session can
   permanently lose its idle flip while accumulating retransmitting
   send-groups. The adversarial spray test asserts exactly the half
   that still works (group-0 liveness), not fresh-group admission.

10. **Audio retention horizon read off the wire** (Wire) —
    `Wire/Sources/LyteWire/AudioDepacketizer.swift:143-156, 252-264`:
    staleness gate and eviction derive `k` from the *arriving shard's*
    declared FEC geometry, not the stream's. One legal `k=1` shard
    shrinks the horizon ~4× and flushes groups still awaiting parity
    (recoverable audio lost); a `k=255` shard widens admission ~1000×.
    The horizon is local policy — pin it in the depacketizer's config.

11. **`--no-idle-floor` session mode swallows SIGINT/SIGTERM** (host) —
    `Host/Sources/lyte-host/main.swift:1828-1834`: the tick is armed
    only under idle-floor, but it is the sole poller of
    `lyteTerminationRequested`, the sole caller of `wire.service()`,
    and the sole drain of the stats windows. Without it: Ctrl-C/kill
    are no-ops (SIGKILL-only, stranding audio routing), peer-gone runs
    to the safety timeout, and the stage/quality buffers grow unbounded.

12. **Receive-loop `EINTR` deafness + unsynchronized fd close**
    (client) — `Sources/LyteTransport/UdpReceiveEndpoint.swift:222-227,
    167-173`: one `SIGPROF`-class signal permanently deafens the
    session (treated as "closed by stop()"); `stop()` closes the fd
    without joining while a roaming re-dial can reuse the fd number
    within the race window.

13. **Post-handshake config published unlocked to the drain thread**
    (host) — `Host/Sources/lyte-host/main.swift:1684-1723` writes
    `inputInjector`/clipboard closures/`bulkShell` while the drain
    thread may already read them (`SessionWire.swift:1450, 1387,
    1411`); `noteMonitorExtent` mutates the injector from the video
    thread unlocked. All cold paths — route through `lock`.

14. **Unbounded send retry under the session lock** (host) —
    `Host/Sources/lyte-host/SessionWire.swift:1546-1562`: `sent == 0` →
    `usleep(200); continue` with no bound, holding the lock everything
    needs — a wedged interface hangs the process silently. Cap and
    throw into the existing `drainFailed` path.

15. **Helper XPC: interruption unhandled** (app) —
    `Sources/Lyte/HelperClient.swift:114-119` installs only
    `invalidationHandler`; a *crashed* daemon produces an interruption,
    `engaged` stays true, and `AgentMenu.swift:106-111`'s documented
    re-engage never fires — awdl0 comes back up and stays LOOSE for the
    session.

16. **Held keys never flushed** (app) —
    `Sources/Lyte/LyteInputCapture.swift:203-231`: no all-keys-up on
    resign-key/stop/teardown anywhere in client or host. ⌘Tab away with
    a modifier down leaves the host with Super/Alt latched; a held key
    across app-switch → host-side auto-repeat storm.

17. **Mute not applied on fresh connect** (app) —
    `Sources/Lyte/ConnectionModel.swift:280-305` (connect path) never
    pushes `muted` into the new session; the roaming path (:783) does.
    Mute → disconnect → reconnect = full volume under a "muted" UI.
    One-line fix mirroring :783.

## Tier 3 — performance and efficiency (ranked by payoff)

- **Jitter-buffer retarget: 512-double sort, 200×/s, on the receive
  thread** — `Sources/LyteTransport/AudioJitterBuffer.swift:359,
  372-418`: ~1M comparisons/s plus ~8 KB/packet transient allocation
  inside the AudioReceiver lock, directly ahead of the video demux, to
  recompute a target quantized to whole 5 ms packets. A 25 ms cadence
  is behaviorally identical and ~8× cheaper. The single biggest
  remaining hot-path waste in the tree.
- **ARQ `poll()` quadratic in queue depth** —
  `Wire/Sources/LyteWire/ArqEndpoint.swift:557-729`: ~5 full scans of
  all queued segments per poll (a 100 MB bulk transfer pays ~96k polls
  × ~5k dictionary lookups); `firePtoTimers` iterates live `keys` while
  assigning (dictionary CoW per assignment); ACK bitmaps probe 256
  slots even when `buffered` is empty.
- **Host encode path per-shard allocation** —
  `Host/Sources/HostWire/VideoChannel.swift:771-780`: three arrays per
  shard (~700 allocations per protected ceiling IDR) on the capture
  thread under the session lock; single pre-sized in-place encode is
  the win.
- **Ratchet-mode per-frame packet copy** —
  `Host/Sources/lyte-host/main.swift:1213-1217`: full packet
  (`~300 KB` worst case) copied per frame for a once-per-idle-episode
  consumer; `removeAll(keepingCapacity:)` + `append` kills the malloc.
- **FEC recovery double copy + double NAL walk** (Wire) —
  `NanorsBackend.swift:69-73` + `FecCoder.swift:95-101` copy the
  recovered frame twice; `VideoAssembler.swift:393-401` then scans it
  twice (`isFrameShaped` + `containsIrap` each re-run `nalUnits`).
- **Client per-frame triple copy** —
  `Sources/LyteTransport/VideoRenderFactory.swift:55-69`: annexB →
  lengthPrefixed → CMBlockBuffer copy chain; in-place start-code
  rewrite + custom block source removes two of three.
- **Estimator hot-read allocations** —
  `RateEstimator.swift:561-563` (full 10 s window map/max per read),
  :950-952 (`recentNackShards` rebuilt per report), :1095-1150 (four
  throwaway arrays per train); `HostCore/Histogram.swift:43-49`
  (full-pool sort per percentile call, ×3 for p50/p95/p99).
- **Noise crypto: one lock for both directions** —
  `Sources/LyteTransport/NoiseTransportCrypto.swift:290-322` serializes
  seal behind unseal (disjoint state); `ReceiveDemux.ingest` holds its
  lock across the unseal. Two-line split decouples send from receive.
- **Menu validation re-reads the pinned-host store from disk** —
  `Sources/Lyte/ConnectionModel.swift:842-855, 910-939` +
  `LyteCommands.swift:50-91`: three file reads + JSON decodes per menu
  pass on the main actor.

## Architecture & clarity (no rework — named seams and debts)

- **ARQ repack + plaintext budget duplicated verbatim across packages**
  (`HostWire/Session.swift:2484, 887` ≡
  `LyteTransport/ReliableCtrlEndpoint.swift:391, 76`) — every input is
  a LyteWire type; the natural home is Wire, beside `WireBudget`. The
  anticipated DPLPMTUD change currently must land in two packages that
  cannot see each other.
- **No test drives the real client core against the real host core** —
  each end gates against a hand-built stand-in (admitted at
  `NackRepairClientGateTests.swift:17`). The seam exists: Host vends
  HostCore/HostWire as macOS-buildable libraries; a test-only
  `.package(path: "Host")` gives a both-ends-in-one-process gate.
- **No mechanical vector guard** — `CtrlMessageType` (36 constants) is
  not enumerable and no test cross-checks the registry against
  `Wire/Vectors/`; a new wire message ships green with zero vector
  coverage. One "every registered type byte is named by a vector file"
  gate converts the (excellent) convention into a contract.
- **Host `AudioWire` shadows Wire's `AudioWire`** — the wire audio
  dialect's constants are unreachable by name in `lyte-host`, and the
  C leaf's 48000/2/240 (`COpusEncode/include`) are bound to Wire's
  values by nothing. Rename the host class; add one equality pin.
- **~1,127 lines of corpus-harness code ship in the production app** —
  `CorpusFrames/CorpusGates/CorpusPNG/VideoReadbackTap` live in
  LyteTransport but are consumed only by lyte-cli and tests. A
  `LyteCorpus` target restores the boundary (the `COpus` precedent).
- **Noise rekey machinery is dead code** — epoch bump, grace keys,
  `rekeyDatagramThreshold` have no production caller on either end and
  no CTRL message exists to coordinate; session keys live for the
  session. Nonce uniqueness is still sound (64-bit counter). Either
  drive it or mark the header "primitive exists; no shell drives it."
- **Giant files with named split seams** —
  `HostWire/Session.swift` (2,974: bulk lane, repair lane, congestion
  seam, keyframe-demand latch as a value type, ~400 lines of pure
  declarations); `lyte-host/main.swift` (2,140: Options / Sink / Run —
  and the ratchet policy is pure logic stranded in an untestable
  executable target; HostCore is the precedent); `ConnectionModel.swift`
  (1,252: `statsLines()` alone is ~180 lines of pure formatting,
  extractable and pinnable).
- **Sundry clarity debts** — lyte-cli's UI-command comment documents
  the inverse of the code's allow-list (`CLI.swift:29` vs
  `WireViewCommand.swift:21-24`); stale rate-seam comments
  (`Pacer.swift:126-129`, `VideoChannelConfig`) describe pre-HS-16
  law; `PathMessages` is the one codec without the ArraySlice
  discipline; `CapabilityNegotiator.declarationSent` is dead state and
  the header's ordering promise is unenforced; idle frames bypass the
  Annex-B shape gate both other video paths enforce (safe under
  ARQ+Noise; the invariant should be stated or held); wire-view's
  finish latch is a non-atomic test-and-set (double summary print can
  corrupt the probe's machine-parse block); `RateEstimator.fecRegime`
  is hard-coded `.clean` regardless of session config (armed by a
  future `.lossy` config); fall purge doesn't invalidate the repair
  store (purged frames partially re-admitted as `.videoTail` — bounded
  by the budget gate); in-fps meter and delivery-books hop stats
  survive session swaps and can print a ~1.8e19 fps row for ~3 s after
  a roam; helper `version` probe is declared, implemented, and never
  called; `AudioJitterBuffer` duplicates feed the skew window while
  the doc comment says they don't; kernel wall-clock vs monotonic
  fallback mixed in one arrival-stamp field can blind a whole
  dispersion report; `VideoAssemblerConfig` validates none of its five
  knobs (`maxTrackedGroups: 0` traps on first shard).

## Addendum — items compressed out of the first cut (same review)

*Restored after a fidelity audit of this file against the six raw agent
reports; numbering continues from Tier 2.*

18. **MED — `applyIdrPacing` leaves the belief and probe cadence stale
    across RECOVERY/migration** —
    `Host/Sources/HostWire/RateEstimator.swift:862-880`: the one place
    the estimator *knows* its evidence is stale halves only
    `rateBitsPerSecond`; `beliefBits` (which never ages), the cadence
    hold, and the band floor all survive the path change. Migrate from
    90 Mbps Wi-Fi to a 5 Mbps tether and the probe ceiling
    (`min(cap, belief×1.1)`) is still ~99 Mbps — HS-29's damping is
    inert on exactly the transition where the wall moved; symmetric: a
    stale band floor can hold rises on the new path for 10 s.

19. **MED — PipeWire round-trips with no timeout wedge startup and
    shutdown** — `Host/Sources/CPipeWireCapture/capture.c:261-289`
    (`resolve_target_serial` runs `pw_main_loop_run` inside
    `lyte_pw_capture_new` with no timer armed — the safety timeout only
    exists later, in `_run`) and
    `Host/Sources/lyte-host/audio.c:117-123` (the shutdown `roundtrip`
    in `lyte_pw_audio_restore`): a wedged compositor/wireplumber hangs
    the host before its first frame, or hangs exit with the desktop's
    default sink still pointed at "Lyte Audio". Both want the bounded
    timer source `lyte_pw_capture_run` already demonstrates.

20. **MED-LOW — delivery trains are segmented channel-blind while the
    delay side is deliberately per-channel** —
    `RateEstimator.swift:1084-1091, 1216-1222` vs :1228-1257: trains
    mix fast-lane audio (131 B) with video (1152 B) under DSCP, skewing
    the measured rate that drives the honest/censored trichotomy — and
    at the 500 kbps floor the rate-scaled gap (~55 ms) chains audio's
    5 ms cadence into every train, re-opening the door
    `minTrainPackets` was added to close. Consider single-channel
    trains or per-channel classification.

21. **Shell — quality-probe's wire leg cannot fail when the host never
    starts** — `Host/Scripts/quality-probe.sh:187-209`: the readiness
    loop falls through after 20 s with no verdict (no `-e`, launch
    unchecked), then runs the full 195 s leg against nothing and prints
    FAIL rows with blank numbers that read like a measured regression.
    One `|| exit 1` after the loop closes it.

22. **Shell — the secrets rail false-alarms on a never-paired host** —
    `Host/Scripts/quality-probe.sh:103-107`: a missing
    `paired_clients` shifts the `sha256sum` line positions, so the rail
    compares the portal token (which rotates by design) and prints
    `*** CHANGED — INVESTIGATE ***` on every clean run. Key the
    comparison by filename. Neighboring: `corpus-harness.sh:206`
    interpolates an env-overridable path unquoted into a remote
    `rm -rf`.

23. **Latent — `SessionWire.init` late throw double-frees and orphans
    the drain thread** —
    `Host/Sources/lyte-host/SessionWire.swift:359-388` + `deinit`
    :403-407: a throw after the allocations and thread start repeats
    `scratch.deallocate()`/`lyte_netio_free` and leaves the drain
    thread on a freed object. Unreachable today (the `--insecure`
    validation happens to run first) — armed by any new throw added to
    `init`. Move validation above the allocations.

24. **LOW — `lyte_pw_audio_quit` races the loop's exit reason** —
    `audio.c:495-504`: plain-`int` cross-thread store can overwrite a
    concurrent stream-error reason, silently suppressing the
    `run error` line. Make it `_Atomic` (companion:
    `capture.c:212-217` passes a possibly-NULL `spa_dict_lookup` to
    `%s`).

25. **LOW/clarity — the arrival-stamp decoy parameter** —
    `LyteUdpSession.handleDatagram(_:arrivalMicroseconds:)` never reads
    the parameter (deliberately — the echo responder forbids the
    wall-clock stamp for t2), but `UdpReceiveEndpoint`'s doc still
    promises it's "the same arrival stamp the demux got"; a future
    reader wiring t2 from it corrupts every RTT sample. Drop or
    annotate it.

26. **LOW/architecture residue** — `Sniff.swift` (and two others)
    import CHevcEncode solely for `lyte_stdout_linebuf` — process
    stdio config living in the NVENC leaf; a two-function `CStdio`
    frees the dissector from libavcodec. `LatencyHistogram` ≡
    `HostCore.Histogram` and `AnnexBCheck` ≡ `HostCore.AnnexB` are
    documented-in-code duplications (retiring `HostCore.AnnexB` onto
    the Wire copy is mechanical today). The host's crypto and ARQ
    carriage are inlined switches where the client has named seams
    (`TransportCrypto` protocol, `ReliableCtrlEndpoint`) — the missing
    host-side seam is why the repack duplication exists.

27. **Test-gap residue** — `HostClockModel.estimate` picks `anchor` by
    max timestamp but `offset0` by array position; out-of-order
    `ingest` has no pin.

## Test-coverage gaps worth closing (hardware-independent)

Client/host composition gate (see above); ARQ receive-group lifecycle
(admission after spray, abandoned one-shots); config-validation
boundaries (VideoAssemblerConfig, ArqConfig, horizonGroups); foreign-k
audio adversity; concurrent same-channel sealing; receive-loop errno
taxonomy; unauthenticated-retarget policy; ring write-side wrap at
capacity; duplicate/late packets must not move the jitter target;
exactTighten within-band rise; `applyIdrPacing`'s effect on belief and
cadence state; NACK-arm rate bounding; purge↔repair-store interaction;
`Sink`'s pure policies (ratchet convergence, backpressure bound, IDR
cause attribution, starvation tripwire, the thrice-duplicated `pct`
helper) once extracted to HostCore; the C leaves' pure repack functions
via lyte-encode-check hashing.

## Strengths — what to protect

- Sans-IO discipline **mechanically enforced** (`lint-no-foundation.sh`
  runs under `swift test`); Wire's only imports are its FEC leaf and
  scoped Crypto.
- Phantom-typed clock domains (`WireTimestamp<Domain>`) make cross-end
  time mixing a **compile error**; every core takes `now:` and returns
  actions + deadline; randomness injected throughout.
- Clean dependency directions everywhere; LyteUI has zero Lyte deps;
  the app layer never constructs wire bytes.
- The vector contract: external oracles where they exist, hand-computed
  anchors, per-file inventories with counts, a freeze policy that
  treats disagreement as a finding, and WASM third-platform
  attestation.
- Lock discipline on both session cores: events fire strictly outside
  locks on both ends — the re-entrant deadlock is structurally
  impossible. `SessionWire`'s documented lock→condition order is
  actually acyclic at every call site.
- The audio render callback is exemplary real-time code (preallocated
  declick state, ring-captured closure, no locks/allocation, underrun
  counting gated on stream liveness).
- `audio.c` teardown: restore-before-disconnect with reasons,
  connection-owned sink (SIGKILL-proof), on-disk crash ledger written
  *before* the switch with a next-start sweep.
- `encode.c`'s single `goto fail` idiom makes every error path
  leak-free by construction; unknown knob values fail the open loudly.
- Wrap-aware serial arithmetic at essentially every comparison that
  matters; the replay window commits only after AEAD success.
- The epoch fence in ConnectionModel (session-generation stamping)
  kills cross-session event resurrection — the one place the unordered
  MainActor hop would have bitten.
- Estimator internals verified subtle-and-correct where it counts: the
  send-ledger recycling guard, the HS-30 belief cap as the load-bearing
  overflow bound, recusal evaluated before the purge mutates the queue.

## Landed

- **T1-2 capture geometry validation** — PR #24, merged 2026-07-30.
  Two laws at the top of `Sink.onFrame`: the buffer-bounds law (no
  frame, including frame 0, reaches an encode until `stride > 0`,
  extents nonzero, and `size >= (h-1)*stride + w*4`; Int64 arithmetic,
  no unsigned underflow) and the geometry pin (any frame whose extent
  differs from the opened encoder's fails the session via `fail()` →
  typed teardown; reconnect renegotiates). No in-suite pin possible
  (executable target); suites 241/241 Mac AND pup plus a live pup
  probe — 186 frames at 2048×1280/8192 through the new validation.

- **T1-3 AudioWire thread lifetime** — PR #23, merged 2026-07-30.
  `stop()` joins the audio thread unconditionally (bounded by the C
  run loop's own `seconds` deadline even if the quit eventfd were
  lost); `deinit` refuses to free while the thread lives — it quits
  and joins first when the owner never reached `stop()` (the
  throw-after-start unwind); both init-throw paths free nothing, so
  deinit owns capture + encoder cleanup exactly once and the
  no-default-sink host degrades to video-only instead of aborting in
  `free()`. No in-suite pin possible (executable target + live
  PipeWire required) — the gate is structural single-owner cleanup;
  suites 241/241 Mac AND pup.

- **T1-4 chan-0 seq/seal race** — PR #22, merged 2026-07-30. Seq
  allocation and seal are one critical section in TransportSender
  (allocation order = commit order; transmit stays outside the lock;
  sender→crypto lock order, no deadlock). New concurrency gate: strict
  Noise-law crypto, 4 threads × 2,000 sends, zero seal failures, 8,000
  unique wire seqs. Root suite 219/219 (was 218).

- **T1-5 estimator baseline witness** — PR #21, merged 2026-07-30. The
  per-channel delay floor is the second-smallest report minimum in the
  10 s window (lowest CORROBORATED delay): a lone freak-fast report is
  a witness awaiting its partner, so the clean-air poison fall dies at
  the source; genuine improvements re-base on the second confirming
  report. Fall-side honesty law untouched. 2 new pins (poison rejected
  with rate unmoved; two-witness control re-bases and real inflation
  still fires); suite 241/241 Mac AND pup, all pre-existing
  overuse/dwell/stall gates unchanged.

- **T1-6 `exactTighten` rising edge** — PR #20, merged 2026-07-30.
  `materialRise` mirrors `materialFall` (rate-judged loosen want past
  the deadband above the applied max); exact mode's sustained climb
  lands exactly on the held-minimum ceiling; ladder mode and the
  sustain/restore discipline untouched. 3 new pins (exact climb after
  sustain, deadband-parked rise, ladder control); suite 239/239 Mac AND
  pup.

## Closed

(none yet)

## Suggested action shape

The proven pattern: commit this file as the ledger and run the PR
train — Tier 1 first (six PRs, each landing with its reproducing pin),
then Tier 2's hardening, with Tier 3 and the architecture/clarity items
as a follow-on sweep. Items 6 (exactTighten) and the fall-purge/store
interaction are findings against sweep PRs #7/#6 and should credit
that lineage in their fixes.
