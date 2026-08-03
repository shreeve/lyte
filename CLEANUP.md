# CLEANUP — the unification program

The phase where the v1 walls come down. Every item below removes
duplication or welds a missing seam **without changing behavior**:
each step is move + delete + re-point, gated by the existing suites
(Wire 513 · client 293 · host 300 · analyzer 25) staying green.
No feature work rides in these PRs; no cleanup PR mixes two themes.

Ground truth for every claim here: the 2026-08-03 structural sweep
(file:line evidence throughout). The destination module plan is the
standing v2 ruling (docs/20260730-115707-lyte-v2-rulings.md):

- **`LyteCore`** — sans-IO shared logic: one Histogram, one AnnexB,
  the HEVC bit vocabulary, injected time. No-Foundation lint travels
  here. WASM-buildable.
- **`LyteIO`** — OS adapters BOTH ends share: clock providers,
  socket/DSCP helpers, file stores. Admission rule: both ends use
  it, or it goes to Client/ or Host/. Adapters, never policy.
- **`LyteTestKit`** — SimNet, vector loaders, virtual-time drivers,
  the corpus harness (evicts ~1,346 LOC from the shipping app).

## Laws (non-negotiable)

1. **No functionality degrades.** Every PR is provably
   behavior-neutral: suites green, live smoke where a shell moved.
2. **Wire/ stays frozen.** LyteWire is the wire's home; LyteCore
   sits BESIDE it, never inside it. Vectors append-only, as ever.
3. **Doctrine asymmetries are NOT duplication.** Recorded rulings
   stay split: audio's clock is the DAC (never HostClockModel);
   audio's cushion statistic is window spread, not p99; ChromaTier
   (client ask) and ChromaPosture (host answer) are two ROLES —
   only their shared pairing rule moves to common code.
4. **Tests are the ratchet.** A utility moves only when its old
   call sites compile against the new home and the old copy is
   DELETED in the same PR. No transition shims that outlive a PR.

---

## Theme 1 — One copy of each utility (the LyteCore extraction)

The mechanical phase. Each row is one small PR: move, re-point,
delete, suites green.

| Utility | Today (copies) | Evidence |
|---|---|---|
| Percentile/histogram/ring | **5**: HostCore/Histogram.swift:14 (non-rolling), ConductorPrimitives LatencyHistogram :92 + BeatTailRing :28 (rolling), VideoFlightRecorder.swift:462, VideoDeliveryBooks.swift:97 | The two "byte-for-byte" twins have DRIFTED (drop-past-cap vs wrap) — unify deliberately, pin both semantics by test |
| Annex-B NAL walker | **2** + 1 dependent: HostCore/AnnexB.swift:63, LyteWire/AnnexBCheck.swift:89 (types renamed to dodge collisions), AnnexBAccessUnits.swift:18 | Same constant table verbatim; parallel test suites merge |
| HEVC bit vocabulary | **3**: HostCore/HevcBitWriter.swift:10 (EPB insert), HevcSpsChroma.swift:100 (EPB strip), HevcParameterSetTests.swift:163 (EPB strip again, test-private) | Writer and readers are inverse functions in three places — one BitWriter + one BitReader, round-trip pinned |
| SHA-256 | **2 hand-rolled + 3 wrappers**: HostWire/Sha256Stream.swift:13, LyteWireTestKit/Sha256.swift:8, BulkSendShell.swift:401, IdentityHash.swift:12 | One streaming impl (or one swift-crypto wrapper where allowed); the FIPS constant tables exist twice today |
| Hex encode | **6** sites (HostStaticKey :43, BulkFileStore :259, SniffFormat :100, TestKit Hex, LyteDiscovery :78, netio-check :34) | One extension in LyteCore |
| Monotonic clock | **~44** idioms: ~35 inline DispatchTime.now()/1000 in Client/Sources/, 6 raw clock_gettime copies on the host, 3 private helper duplicates | One clock provider in LyteIO; cores take injected `now` (HostCore/HostWire already do — this is the shells' cleanup) |
| TOS/DSCP constants | HostCore/WireTos.swift vs client inline magic (UdpReceiveEndpoint.swift:98 `0x1116`, :113 IP_TOS) | One WireTos in shared code; client's magic numbers die |
| COpus system library | Declared twice (Client/Package.swift, Host/Package.swift) | One declaration once packages share a Common/ |
| Chroma pairing rule | Encoded twice: ChromaPosture.swift:27, ChromaTier.swift:29-33 | The `[yuv444]`-singleton-is-Best rule becomes one shared function; the two ROLE types stay (law 3) |

## Theme 2 — Finish the sans-IO conquest (LyteTransport)

The doctrine is proven where enforced: HostCore 14/14 pure imports,
HostWire 13/14, LyteWire lint-enforced. LyteTransport is the last
holdout — 30 of 44 files import Foundation and platform types leak
into policy:

- **RendererHandoffPolicy.swift** takes/returns CMSampleBuffer
  (:176-220) — a policy type untestable without CoreMedia. Split:
  policy speaks frame descriptors; the shell owns sample buffers.
- **LyteVideoPipeline.swift** welds DispatchTime.now() inline
  (:200/244/463) — take injected `now` like every host core does.
- **VideoBeatConductor.swift:333, VideoDeliveryBooks.swift:19/56**
  — conductors/books holding their own NSLocks; locking is the
  shell's concern (VideoDeliveryBooks has TWO locks in 100 lines).
- **VideoFlightRecorder.swift:317/350** — telemetry calling the
  clock instead of receiving it.
- The no-Foundation lint (Wire's Scripts/lint-no-foundation.sh
  pattern) travels to LyteCore so the boundary is mechanical.

## Theme 3 — The mirror pairs meet in the middle

The largest theme; LAST in sequence, cross-end gates built first.

- **Session spine**: HostWire/Session.swift (one 2,745-LOC class)
  and LyteUdpSessionCore (~1,399 LOC) both implement seal
  discipline, 1 Hz beacons, ARQ CTRL, path validation, IDR plumbing,
  capability declaration. Extract the shared rituals into one spine
  in LyteCore; initiator/responder policy stays role-specific.
- **Pairing**: PairingService.swift ("responder") and
  PairingInitiatorService.swift call themselves mirrors in their own
  headers, both around LyteWire.PairingPake*. Same spine treatment.
- **Trust stores**: ClientKeystore (line-hex format) vs
  PinnedHostStore (JSON) — same concept, two serializations. One
  store model, two thin format shims (formats are on-disk contracts;
  migrating them is NOT cleanup — keep both readers).
- **Capability declaration builder**: Session.declareCapabilities
  (:2459) vs the client's declaringChroma chain — one builder, two
  callers. (The NEGOTIATOR is already shared; only declaration
  construction is duplicated.)
- **Twin gate tests** — six named pairs, ~7,200 LOC (NackRepair
  host/client are both exactly 1,301 lines). They become the v2
  ruling's Tests/ cross-end composition gates: both ends in ONE
  build graph, real client core against real host core. This also
  closes the standing "no test drives real client against real
  host" gap — and it is the safety net theme 3 requires, so it
  lands FIRST within this theme.

## Theme 4 — The organ seams (7 protocols in 58k LOC today)

Rule: a seam per organ **where hardware varies and a second
implementation exists or is banked**. Not protocol-mania.

| Seam | Today | Second implementation (why now) |
|---|---|---|
| `VideoSink` (client) | Raw closure `(CMSampleBuffer, DecodeUnit) -> Void` (LyteVideoPipeline.swift:133); AVSampleBufferDisplayLayer wrapped directly | Headless/test renderer — pays immediately in gates; unblocks CI without a display |
| `EncoderSeat` (host) | DirectEyeLeg welded to EyeVaapiEncoder (:167, re-typed at the 4:4:4 flip :281); lyte-eye welds a second copy | NVENC (E6a scoping banked; the seam is item 1 of that scoping) |
| `ScreenSource` (host) | EyeDRM free functions; doorbell + capture loop written TWICE (DirectEyeLeg ~300 LOC vs EyeCapture ~100 LOC) | The Lyte OS compositor — when Lyte owns the output buffer, this is the swap point. Collapsing the two capture loops pays today |
| `AudioSource` (host) | AudioWire binds PipeWire+Opus concretely, holds a concrete SessionWire | The clipboard already HAS its seam (HostClipboardLeaf) — the asymmetry is the argument; PipeWire is also the first thing Lyte OS replaces |
| Books/snapshot spine | ~28 hand-rolled Stats+snapshot+lock triples (~20 client, ~8 host) | One snapshot mechanism in LyteCore; the ledger overlay, host stats block, and benchmark JSONL become three printers of ONE vocabulary |

## Theme 5 — One config grammar (small, cheap, do anytime)

- Host hand-rolls a ~150-line switch + hand-written help
  (main.swift:105/252); client uses swift-argument-parser;
  lyte-eye has a third variant; E4 added /etc/lyte/lyte-host.conf.
- Move host CLIs to swift-argument-parser (it already builds on
  Linux for lyte-cli's siblings); the conf file stays the
  operator's surface.

---

## Sequencing

1. **Theme 1** — mechanical, gate-checked, clears the ground.
   Order within: clock provider → histogram → AnnexB → HEVC bits →
   SHA/hex → TOS → chroma rule. One PR each.
2. **Theme 2** — rides along: each type that moves into LyteCore
   passes the lint at the door; the remaining LyteTransport
   holdouts get dedicated PRs (RendererHandoffPolicy split first —
   it unblocks the VideoSink seam).
3. **Theme 4** — seams pulled by their second implementations:
   VideoSink first (testing pays now), ScreenSource second
   (collapses the twin capture loops today), EncoderSeat when
   NVENC hardware exists, AudioSource with the Lyte OS track.
4. **Theme 3** — cross-end gates FIRST (they are the net), then
   the session spine, then pairing/stores/declaration.
5. **Theme 5** — anytime, as palate cleansers between phases.

## What this buys

- ~5 duplicate utility families deleted (¬hundreds of lines — the
  DRIFT RISK dies: the histogram twins already disagree).
- LyteTransport joins the sans-IO standard the other three modules
  already meet; policy becomes testable without CoreMedia.
- ~7,200 LOC of twin tests become cross-end gates that actually
  drive both ends together.
- The seams the next hardware (NVENC), the next platform (Lyte
  OS), and the next test tier (headless CI) each need are in place
  before they arrive.
- The books speak one vocabulary from the wire to the overlay.

## What this deliberately does NOT do

- No wire changes, no vector changes, no capability changes.
- No on-disk format migrations (paired_clients, pinned hosts).
- No unification of recorded doctrine asymmetries (law 3).
- No performance work disguised as cleanup (the conductor tiers
  already landed; rubato stays a feature, not a cleanup).
- No big-bang: if a PR can't keep every suite green on its own,
  it is two PRs.
