# Lyte — Session Handoff

*Current as of 2026-08-04 (post-E5, tag `self-hosted`). The session
ledger — update freely; commit updates in the ledger voice. This file
carries ONLY what is live and actionable. Frozen history: the H2→H4
wave ledger and Beauty Bar forensics are
`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`; the
pre-overhaul file is commit `a54ab69`; the last pre-slim version of
THIS file (the 2026-07-30 pre-pivot resume, the portal-era live-ops
playbook, and the full Beauty Bar table with its eight dated rows) is
`git show 0753cbc:HANDOFF.md`.*

# SESSION RESUME — START HERE (2026-08-02: SELF-HOSTED)

**The direct-eye epoch is COMPLETE.** Phases E0–E6b all landed
(#45–#57 and friends), and the E5 portal demolition merged as **PR #72**
with the annotated tag **`self-hosted`** on merge `860369a`: the portal
and mutter ScreenCast backends, PipeWire video, the libav NVENC seat,
and the vendored no-reset FFmpeg are deleted. Capture is the direct
eye (KMS doorbell → EGL blit → native VAAPI through our own HEVC
pens); `ldd lyte-host` shows zero libav; a plain `swift build` (no
ffmpeg env) is itself a gate. The earlier tag `first-light` marks the
first NO-DROPS real session (cushion 0–150 ms slider, honest
link-health pill, avahi pinned to the wired NIC).

**Live ops:** pup runs the standing systemd service `lyte-host.service`
from `~/src/lyte-host/.build/debug/lyte-host`, configured by
`/etc/lyte/lyte-host.conf`, on `--backend direct --encoder native
--wire-listen 41151 --ratchet --clipboard=images
--advertise-interface enxf8e43b7ede7c`
(`--backend`/`--encoder`/`--ratchet` are accepted no-ops since E5) —
wired at 10.0.0.232. After EVERY rebuild:
`sudo -n systemctl restart lyte-host`; the unit grants the direct eye its
ambient CAP_SYS_ADMIN, so the service binary needs no file capability.
Hand-run `lyte-eye` still needs `setcap`. Never stop the owner's 41151
service except through an explicit, restoring live gate; test hosts use
fresh 41xxx ports with `--no-advertise`.

**Where the work lives now:** the v1-final ANALYSIS remainder is
**CLOSED** (2026-08-03): every Tier-2 item done (eight in
the hardening waves #27/#30/#33/#38/#43, T2-10 → #75, T2-13 → #76)
and the A-train batch landed as #77 (bounded audio roundtrips +
atomic exit reason), #78 (init validation above allocations), #79
(clock-model anchor pairing + pinned order-invariance, decoy stamp
discarded by contract). A-20's delivery trains have been channel- and
fresh-video-frame isolated since #27. A-26's histogram and Annex-B twins
closed in #96/#97, its duplicate ARQ carriage closed in #127, and its final
host-crypto-seam residue closed as inspected/not earned after #128: the Host
has one single-threaded owner and one crypto path, unlike the Client's three
concurrent consumers. Suites at HEAD: Common 83 Mac / 84 pup, Wire 513,
Host 334 Mac / 335 pup, Client 258,
SystemTests 17, and analyzer 25. docs/README.md is the doc catalog (twenty
finished records retired to git history 2026-08-02;
`git show 4bb3e11:docs/<name>`).

**The active track is the postures design**
(docs/20260802-013946-postures-design.md): audio first —
mute-at-source LANDED (#71, key 14, `streamOff` 0x04, WIRE strip
button); **tripwire + pre-roll LANDED (#80, 2026-08-02)**: capability
key 15 + CTRL 0x25 track-state, HostCore AudioTripwire (5 s hold /
100 ms trip / 200 ms ring / 5 s check-ins), client relaxes the 350 ms
detector on announced quiet and re-tightens on wake evidence; live
smoke 3572 encoded / 999 sent / 2573 gated. Deferred by design:
Settings dials, DTX warm rung, DSP fades. The REWIND was RE-SIZED by
the owner (2026-08-02): "more like 2–5 seconds" — an instant-replay
button, not a DVR; the tripwire's ring already banks the mechanism
(deepen to ~5 s ≈ 80 KB when demand shows up), so it's PARKED behind
demand, not next. **Video quiet posture LANDED (#81, 2026-08-02)**:
capability key 16 + CTRL 0x26 posture-state, HostCore VideoQuietPacer
(keepalive 1→2→4→8→16→30 s, one rung per 30 s stillness, each step
announced once; FB damage or client input IS the wake and collapses
to 1 s with one active announcement); client stores
announcedVideoPosture, drops unnegotiated 0x26 — no detector change
needed (#66 already gap-normalized video freshness). Live smoke:
`posture_announcements=0` at pup's 1 Hz clock repaint (honest —
ladder pinned by unit + in-vivo legs instead). **Native-seat quality
witness LANDED (#82, 2026-08-02)**: motion + quality-static legs read
the displayed buffer back from the GPU, decode the presenter's 24-bit
marker, regenerate the authored frame from the client twin
(SyntheticMotionReference), and PSNR/SSIM the glass; the three
renderers (GTK canvas / numpy twin / Swift mirror) are pinned
byte-identical by shared SHA-256 fixtures in both suites. Client
exports hostAnnouncedAudioQuiet so the analyzer books tripwire
stillness as announced_quiet_stillness, not blackout. **THE
CONDUCTOR's video part LANDED (#83, 2026-08-03)** — the model of
record is docs/20260803-050422-metronome-playout-design.md (owner
naming, use verbatim: the score, cue/beat/late/hole/slip/chain,
rubato filed): VideoBeatConductor replaced AdaptiveVideoPlayout
(retired outright; queue policies live on as RendererHandoffPolicy).
The grid advances ordinally (round(sourceStep/period) beats), late
parts keep their passed beat, holes re-cue whole beats once, the
ceiling cuts with whole-beat hysteresis (a pinned slider chattered
the grid — pinned by test), slip repays drift. Witness verdict PASS:
gap p50=p95=p99 = 16.667 ms EXACTLY, lateness p99 0.4–4.6 ms (bar 8,
was ~18), 30.76 dB / SSIM 0.9989, 29/29 phase-locked, 0 IDR — owner
confirmed by eye ("ABSOLUTELY SOLVED"). **The beat-skip hunt CLOSED
(#84, 2026-08-03, CaptureBeatBook):** the host grew a sans-IO beat
book (HostCore; every doorbell poll and flip stamped; gap ≥ 1.5
beats books a skip with a verdict — `source` when the doorbell
watched the FB hold still, `loop` when the doorbell went blind) plus
per-stage clocks in DirectEyeLeg (service/cursor/grab/blit/encode/
deliver, skip lines + closing beat-book books). Rig verdict: the
HOST LOOP IS EXONERATED in steady state (all stages < 9 ms; one
106 ms wire.service() stall at connect — audio-routing/clipboard
setup on the capture thread, inside client warm-up). The source
skips are a STRICT 10.000-second comb: GNOME Shell 50.1 itself burns
20–30 ms of flat-out CPU at monotonic X4.958 every 10 s — present on
an IDLE desktop, no presenter, no client, no encode (10 ms
schedstat sampler; python GC and every daemon acquitted). The
compositor misses two beats every ten seconds machine-wide: the
owner's residual "occasional shudder" is pup's shell housekeeping
(gjs full-GC signature), not Lyte. Mitigation is a system decision
(shell extension diet / newer shell / accept). **The janitor LANDED
(#85, 2026-08-03): wire.service() moved off the capture thread onto
"lyte-shell-service" (10 ms sweep, default priority, only caller of
service(), semaphore-joined through every exit door); live smoke on
a 41199 test host: loop skips 0 across 1495 flips, service_max
2.8 ms on the janitor (was a 106 ms capture-thread stall at
connect), remaining skips all source class (the shell's comb).**
Still filed: GNOME focus
denial still covers the witness marker after remote input
(benchmark needs a focus story; owner's desktop-click is the
workaround). **Conductor tier 2 LANDED (#86, 2026-08-03):
ConductorPrimitives.swift — BeatTailRing (video's private p99 ring
retired, parity-pinned), ProofCounter (one law, was four spellings:
video slip proof + audio decay hold/step/retarget cadence), audio's
private 5 ms constant now the wire's, LatencyHistogram rehomed.
Doctrine asymmetries KEPT and recorded: audio's clock = the DAC
(lattice detrend, never HostClockModel); audio's cushion statistic
= window spread, not p99 (p99 discarded exactly the late/PLC
events). Root suite 293 with every pre-existing audio/video pin
unchanged — nothing moved. Tier 3 = LyteCore module in v2.**
**E2 LANDED (#87, 2026-08-03): kernel uinput is the PRIMARY AND
SOLE input injector — MutterInputInjector deleted (~170 lines of
D-Bus choreography; --input mutter fails loudly at parse),
UinputInjector grew the release-all law (held-code set drained at
stop — the ⌘Tab latch) plus a 150 ms device-settle, and the new
lyte-uinput-check harness reads the three virtual devices back
from evdev — routing, absolute scaling/clamping, v120 half-detent
accumulation, ALL PASS on pup first run (run it under sudo). The
client already spoke evdev codes and monitor pixels on the wire,
so no translation layer anywhere; everything above the
InputInjector seam untouched. The clipboard's OWN RemoteDesktop
session survives by design (its Wayland helper stays filed —
now the LAST Mutter-session tenant in the process). Owner
feel-check PASSED (2026-08-03, live session on the uinput binary):
typing/⌘Tab/aim/scroll all felt normal — E2 is fully closed.** **REXT 4:4:4 LANDED — the Best tier
is LIVE (#89 + #90, 2026-08-03).** #89: the HEVC pens grew a
`chroma444` recipe (profile_idc 4, the §A.3.5 Main 4:4:4 constraint
row, SPS chroma_format_idc 3; BitReader pin tests walk every field,
4:2:0 oracle bytes proven untouched); the VAAPI encoder grew the
matching mode (VAProfileHEVCMain444 — Arc probe GREEN, std
entrypoint — packed AYUV surfaces, triple coded buffer, single-layer
export); EyeGL converts in ONE pass (AYUV imports as ARGB8888, the
byte layouts coincide: vec4(y,u,v,1) IS the AYUV plane), and
`lyte-eye capture --chroma 444` gates it: M5 decode-probe HARDWARE
5/5, '444v' output, frame eyeballed AS PIXELS (Chrome's four colors
in order, the red record pill red — no chroma swap). #90: the host
declares on PROOF — `probesMain444()` asks the silicon at startup,
green → declares [420, 444]; the agreement lands after the leg's
encoder opens, so the leg polls the agreed posture and flips ONCE
(Best agreement → NV12 targets destroyed, encoder reopened Rext
4:4:4, lastFB zeroed so a static desktop still delivers its IDR);
stats line reports the encoder that RAN. Live gate both ways:
`wire-view --chroma 444` → agreed [2], client SPS audit of the
received stream read "stream chroma 4:4:4", 16 decoded / 0 skipped /
first frame 19.2 ms; `--chroma 420` stayed 4:2:0, zero flips. NO
Wire changes — the rails (yuv444 id, ChromaTier UI/persistence/
re-dial/fallback, ChromaPosture) shipped earlier and lit up
unchanged. OWNER VERDICT (2026-08-03, live session at Best from the
app): "Screen crispness is undeniable!" — the eyeball gate is
PASSED; the Best tier is the rig's daily posture. SccMain444 follow-up
CLOSED RED (2026-08-03): the Arc encodes it but NO Mac can decode it —
JCT-VC conformance streams (IBC/palette/4:4:4, Apple's own HT
contributions beside them) all fail on M5 VideoToolbox with -12909
per access unit, and ffmpeg's software decoder doesn't implement SCC
either; probe-both-ends-first saved the pens a wasted day.**
**E6a NVENC PARKED BEHIND HARDWARE (2026-08-03):** pup is verified
no-MUX Optimus (the RTX 4050 owns zero connectors), the
cross-adapter copy stays rejected, no NVIDIA-panel box exists →
no gate is possible; the full productionize scoping is banked in
TODO.md (encoder seam, zero-copy registration, recipe revival,
scanout-CRTC ordinal mapping, topology doctor). **THE QUALITY
BLOCK LANDED (#91 + #92, 2026-08-03):** the A/B measurement
rewrote A-20 — Best tier reads 57.6 dB static / 56.8 dB motion
min-channel (SSIM 0.99999+) at zero cadence cost, converged from
the FIRST observation, so the explicit QP ratchet is obsolete for
stills; #91 made the witness grade PER TIER (streamChroma in the
benchmark sample, 4:4:4 floors 45/50 dB + SSIM 0.9995, pinned
both directions, live Best run passed under its own floors), #92
reshaped the overlay into the two-column ledger (owner's
stats-for-nerds steal: dimmed right-aligned labels, ruled grammar
intact, session row now says "hevc 4:4:4", glass row gains the
conductor's cushion ms). Owed: owner's visual on the ledger
overlay. Then: E4 packaging aimed at Lyte OS (first measured
requirement banked 2026-08-03: no stop-the-world runtime in the
display path — the shell's 10 s comb is the evidence). AV1 stays
a 4:2:0 lane (no 4:4:4 hardware encoders exist anywhere,
2026-08).

**CLEANUP THEME 1 IS COMPLETE (#95–#102, #104–#105, 2026-08-03): one clock,
one histogram, one Annex-B walker, one HEVC bit vocabulary, one
SHA-256 state, one hex vocabulary, one TOS vocabulary, one chroma
pairing rule, one libopus module.** The v2
`Common/` package now exists
with sibling targets `LyteCore` (sans-IO shared policy) and `LyteIO`
(shared OS adapters); `SystemMonotonicClock` is the one OS adapter for
ns/µs/s.
Every client and Linux shell call site moved to it and the six raw
`clock_gettime` copies, inline `DispatchTime` reads, and three private
helpers were deleted in the same PR. A cross-tree ratchet refuses a
new bypass; the Linux gate brackets the provider between direct
`CLOCK_MONOTONIC` reads and proved the absolute domain unchanged.
Build provenance and pup sync now include Common. #96 moved all five
named percentile dialects into generic `LyteCore.Histogram` and
deleted every old copy: host telemetry explicitly keeps its
prefix/drop-past-cap doctrine; client telemetry, the Conductor tail,
and the delivery gauge explicitly keep rolling/wrap. Nearest-rank
stays the general rule; the delivery gauge's historical exact-boundary
promotion is named and pinned separately (its 100-sample p99 still
carries one stall). The old parallel tests moved into Common beside a
production-twin ratchet, and LyteCore's no-Foundation lint now runs
automatically on both platforms. #97 moved the richer slice-relative,
allocation-free Annex-B walker plus the production first-slice
access-unit splitter into LyteCore; Wire, Host, client, corpus, and
vector tooling all consume it. The Host and Wire walkers (whose types
had been renamed solely to dodge collisions), the client splitter, and
their parallel test copies were deleted in the same PR — 694 lines out,
431 in. The merged Core gates pin 3/4-byte start codes, malformed
prefixes, short NALs, emulation prevention, relative offsets, bootstrap
shape, prefix/suffix attribution, and multi-slice pictures against 500
seeded hostile streams; the cross-tree ratchet rejects another twin.
Wire bytes and every frozen vector stayed untouched. #98 moved the Host
writer, client SPS reader/unescaper, and Host test reader into one
bounds-checked `LyteCore` vocabulary, then deleted all three private
codecs. The Host's real VAAPI VPS/SPS/PPS/slice byte oracles and the
client's real-SPS/truncation gates stayed exact; fixed-width and signed/
unsigned Exp-Golomb round trips, hostile bounds, the canonical escape
anchors, and 513 seeded RBSP escape/unescape inverses now live beside
the implementation. A production-source ratchet refuses another writer,
reader, or unescaper. The rebuilt pup service is active and both binaries
were re-armed after the Linux gate. #99 made streaming
`LyteCore.Sha256` the one digest model for Host file verification,
both identity advertisements, client and Host clipboard images, bulk
transfer, vector tooling, corpus pins, and every harness. The HostWire
and TestKit FIPS tables plus the Host identity wrapper and both client
wrappers were deleted; root and Host no longer declare direct crypto
dependencies for digest-only calls. Published empty, `abc`, and
million-`a` FIPS answers are exact on Mac and Linux; 15 streaming split
geometries cross every block edge over a 200,001-byte seeded payload.
The source ratchet refuses another table, SHA type, or digest wrapper;
frozen vectors stayed byte-exact. The rebuilt pup service is active and
both binaries were re-armed after the Linux gate. #100 made
`LyteCore.Hex` the one byte and integer spelling for the six chartered
encoders and the equivalent copies found behind them. TestKit's public
duplicate and the private Host/client/vector helpers were deleted with
no transition alias. Lowercase, uppercase, width, prefix, every byte,
and the permissive vector/CLI decode grammar are pinned in Common; the
trust store deliberately retains its strict 64-character policy at its
own boundary. A production-source ratchet rejects another Hex type,
helper-shaped encoder, or `%02x` loop. Frozen vectors stayed byte-exact;
the rebuilt pup service is active and both binaries were re-armed after
the Linux gate. #101 made `LyteCore.WireTos` the one four-lane product
vocabulary: unmarked/CS1/CS5/CS6 remain 0x00/0x20/0xA0/0xC0 with ECN
clear. The Host-private type was deleted; only its exhaustive,
role-specific `PacerClass` mapping remains as an extension over the shared
bytes. The client now uses that same protected lane, and Darwin's raw
socket-option numbers became SDK names. Common pins every byte and DSCP;
the macOS socket reads back CS6 + VI, pup's netio witness round-tripped
12/12 markings, and its pacer witness read back CS6 30/30 + CS5 32/32.
The source ratchet rejects another vocabulary or the retired literals.
Wire and frozen vectors were untouched; pup's rebuilt systemd host is
active and its identity files are unchanged. #102 made
`LyteCore.ChromaPairing.bestSingleton` the one spelling of Best's exact
4:4:4 singleton declaration. The client tier and Host posture both consume
that shape, while their role-specific policy remains split: Good/Better stay
client choices, and nil, empty, 4:2:0, and multi-mode agreements still open
the Host's conservative 4:2:0 posture. Common pins the generic singleton and
the existing role suites pin both interpretations; a production-source
ratchet rejects the retired `[CapabilityChroma.yuv444]` twin. Wire and frozen
vectors were untouched; pup's rebuilt systemd host is active and its identity
files are unchanged. #104 repaired the eight cleanup source ratchets after the
next row exposed their shared off-by-one `#filePath` walk: they had resolved
`Common/` as the repository root and scanned nonexistent children. Each now
resolves and asserts the real root; pup's split deployment layout supplies an
explicit clean source mirror. Clock, histogram, Annex-B, HEVC bits, SHA-256,
hex, TOS, and chroma scanners all traversed the production trees on Mac and
Linux, and the full package matrix stayed green. No production code changed.
#105 made `Common/Sources/COpus` the one pkg-config system-library product for both
platforms. The client decoder/PLC and real Opus tests plus the Host's
`COpusEncode` leaf consume it; the root and Host declarations, both private
module maps, and both divergent shims were deleted in the same PR. The
cardinality ratchet requires exactly one manifest declaration and one module
map. `lyte-cli` resolved Homebrew's `libopus.0.dylib`; pup's rebuilt
`lyte-host` resolved the system `libopus.so.0`, its systemd service is active,
and its identity files are unchanged.

**CLEANUP THEME 2 IS COMPLETE (#106–#107, #109–#110, 2026-08-03): renderer
handoff and video scheduling policy are sans-IO; pipeline telemetry borrows
time.** #106 moved
`RendererFrameDescriptor`, `BoundedRendererHandoff`, and
`RendererRecoveryFlushBarrier` into LyteCore.
Policy now sees only random-access and submission facts; the client's
`VideoSampleTiming` adapter alone sees `CMSampleBuffer`, attachments, and the
CoreMedia timebase. All five queue/recovery verdict tests moved with the type,
the LyteCore lint passes on both platforms, and a production-source ratchet
rejects another policy twin. The real renderer shell and media-isolation gate
consume the descriptor with every previous verdict intact. Wire and frozen
vectors were untouched; pup's rebuilt systemd host is active and its identity
files are unchanged. #107 made the pipeline's clock seam explicit:
`LyteVideoPipeline` now requires one injected nanosecond clock, the session
forwards its existing virtualizable clock, and every convenience timestamp,
lock duration, and sample-build duration derives from it. A stepping-clock
test proves exact 1 µs telemetry and a source ratchet rejects another direct
system-clock read; there is no default initializer or transition shim. Wire
and frozen vectors were untouched; the standing pup service remained active
and its identity files are unchanged. #109 moved `ProofCounter`,
`VideoBeatConductor`, the trailing `RateMeter`, and the new
`VideoDeliveryGauge` into LyteCore as single-threaded values. Their old
LyteTransport declarations and tests were retired in the same PR with no
aliases. The conductor controller keeps one client-shell lock; delivery
accounting fell from two nested locks to one shell lock and still copies its
evidence before the percentile sort, preserving the short critical section.
All conductor and gauge verdicts moved beside policy; a new ratchet rejects
production twins and synchronization in core. Wire and frozen vectors were
untouched; pup's rebuilt system host is active and re-armed, and its identity
files are unchanged. #110 made `VideoFlightRecorder` require one injected
microsecond clock and removed its LyteIO import plus both direct system reads.
The client shell forwards the existing provider; a stepping clock pins the two
recovery-lifecycle stamps at exactly 1,000,000 and 1,250,000 µs, and the clock
ratchet now covers both pipeline and recorder. No default initializer or shim
survives. Wire and frozen vectors were untouched; the standing pup binary was
left untouched, its system service and capability remain active, and its
identity files are unchanged. Theme 4 opened immediately below.

**CLEANUP THEME 4'S AVAILABLE SEAMS ARE COMPLETE (#111–#112, #114,
2026-08-03): client video has one render organ and host video has one capture
organ.** #111 introduced `VideoSink`
as the sole ready-sample boundary across pipeline, session core, and production
session. The app's bounded `VideoRendererHandoff` conforms directly;
wire-view uses the named AVFoundation leaf; every display-free gate uses one
`HeadlessVideoSink`. The raw `(CMSampleBuffer, DecodeUnit) -> Void` production
seam and all `onSample` plumbing were deleted without an overload or shim.
Recovery filtering, input delivery, chroma audit, dimension updates, async
teardown forwarding, sample order, and build telemetry stayed pinned. The
named headless async gate preserved exact order and telemetry, and a
cross-platform source ratchet rejects a second protocol or raw production
callback. #112 reconciled the concurrent #108 landing before ledger close:
the new ratchet now consumes LyteTestKit's one fail-closed source scanner, and
the canonical Mac gate fingerprints an overrideable Python 3.9–3.12 bootstrap
with NumPy's requirements instead of accidentally selecting Homebrew 3.14.
Canonical Mac passed all packages, 25 analyzer tests, and signed debug/release
artifacts; isolated pup passed all packages, the plain host build, netio and
pacing harnesses, and protected-state verification. Wire and frozen vectors
were untouched. #114 introduced the pure `HostCore.ScreenDoorbell` and made
`DirectScreenSource` the one owner of DRM device lifetime, primary-plane
discovery, FB_ID transition state, and GETFB2 scanout tickets. Production's
`DirectEyeLeg` and the standalone `lyte-eye capture` witness both consume the
source; their encoder/session/reporting policy remains separate. Both private
doorbell/capture loops, their framebuffer state, and their direct DRM calls
were deleted without an alias. Unit pins cover first/change/hold, failed reads,
and reset; the cross-tree ratchet refuses a second seam or a rebuilt loop in
either consumer. Canonical Mac passed Common 78, Wire 507, Host 286, client
262, analyzer 25, and both signed products; isolated pup passed Common 79,
Wire 507, Host 287, the plain build, netio/pacing, and protected-state gates.
The deployed hardware witness captured 4 frames from the 2048×1280 scanout in
3 s, wrote 99,244 HEVC bytes, and missed zero grabs; the systemd host is active
and all protected identity hashes are unchanged. `EncoderSeat` remains parked
until NVENC hardware exists and `AudioSource` belongs to the Lyte OS track,
exactly as chartered. **NEXT CLEANUP SLICE: Theme 3's cross-end composition
gates land first, before any session-spine extraction.**

**CLEANUP THEME 3 OPENED (#116 + #118, 2026-08-03): pairing policy and
targeted repair began meeting real peers in the client gates.** #116 made the root package
admit `HostWire` only to
`LyteTransportTests`; `LyteTransport` and every shipping client product remain
Host-free. The existing client pairing gate still drives the real Noise
initiator, demux, sealed sender, reliable CTRL endpoint, and
`PairingInitiatorService` through the W-G4 loss/duplication/reorder storm, but
its host transport shell now delegates every pairing message to the shipping
`PairingResponderService`. The test-private `PairingPakeResponder` lifecycle,
result state, rejection counters, and abort decoder were deleted. Correct PIN
pins the exact Noise-authenticated static at both ends; wrong PIN produces the
client's typed no-oracle abort and leaves both real services unpaired. The
focused five-test composition gate passed after rebase. Canonical Mac passed
Common 78, Wire 507, Host 286, client 262, analyzer 25, and both signed
products; isolated pup passed Common 79, Wire 507, Host 287, the plain build,
netio/pacing, and protected-state gates. No production source, wire byte,
vector, or persisted format changed. #118 completed the first repair half:
all thirteen client NACK verdicts now use the shipping
`HostWire.VideoChannel` for original packetization, repair retention,
fresh-sequence/fresh-seal retransmission, and once-only shard discipline. The
gate-local `VideoPacketizer`, retained-shard dictionary, repaired-shard set,
and retransmission loop were deleted. Noise carriage and explicit network
stimuli (loss, stragglers, duplication, and refusal) correctly remain in the
test shell. Past-parity loss still heals byte-exact, the seeded storm still
converges, late/duplicate/superseded answers retain their exact books, and the
typed refusal still ends the wait immediately. Focused 13/13 passed after
rebase; canonical Mac and pup repeated the same 78/507/286/262 and
79/507/287 matrices above, including analyzer, signed products, Linux
build/harnesses, and protected state. No production source, wire byte, vector,
or persisted format changed. #125 closed the other repair half in the
migration ledger below. The shipping pairing services were real after #116,
but the gate's private host transport shell still reconstructed Noise, ARQ,
envelopes, startup control, and pacing; #126 closes that final carriage debt
below.

**THE TREE MIGRATION OPENED (#103 + #108 + #115 + #117 + #119 + #120 + #121, 2026-08-03): every move has
a gate, and Common now speaks one filesystem grammar.** #103 recorded the
owner-approved `Sources` / `Tests` / `TestKit` hierarchy and added the full
Mac + isolated-pup equivalence gates. #108 moved every Common production
byte unchanged into `Sources/LyteCore`, `Sources/LyteIO`, and
`Sources/COpus`; `LyteTestKit` now owns the one fail-closed repository source
scanner used by all cross-tree ratchets. SwiftPM resolution is tracked, app
and host provenance includes Wire, and manifest-graph changes invalidate
stale package build state once. Pup's deterministic mirror is fixed,
symlink-checked, locked, separate from the live deployment tree, and brackets
every exit with protected-state verification. #115 repaired the last two
pre-migration safety surfaces: handshake-only now restarts the authoritative
systemd unit and proves its fresh PID, UDP ownership, executable, and protected
state; the impairment gate runs the current motion leg and diverts only host
UDP source port 41151 toward the exact client `/32` through an owned prio/u32
topology whose unaffected band retains `fq_codel`. Fake-command tests pin
rollback, foreign/changed topology refusal, invalid selectors, and removal of
the retired supervisor and interface-wide netem paths. The Python analyzer
and shell safety tests now live under canonical `Scripts/Tests`. Canonical Mac
and isolated pup gates passed on the combined #114/#115 tree; no live service
restart or impairment was performed. #117 made source-path topology part of
every dependent SwiftPM cache key, so a move cannot reuse a stale product when
the package graph itself is unchanged. #119 organized all four Wire Swift
targets with one mirrored, precise domain grammar: Arq, Audio, Bulk,
Capabilities, Clipboard, Control, Crypto/{Noise,Pairing,Retry}, Fec, Session,
Telemetry, and Video, with Simulation confined to TestKit/tests and only the
module-wide spine left at target roots. The vector generator's Swift target
is now `LyteWireVectorGen` under the canonical UpperCamelCase source root;
the public `lyte-wire-vectorgen` product is unchanged. Production, TestKit,
and generator sources moved byte-identically; all frozen vectors remained
untouched. Nineteen depth-sensitive vector locators collapsed into one
fail-closed package-root locator, and `WireLayoutTests` pins root allowlists,
exact domains, nested Crypto families, and leaf depth. Canonical Mac passed
Common 78, Wire 508, Host 286, client 262, analyzer 25, benchmark safety, and
both signed products; isolated pup passed Common 79, Wire 508, Host 287, the
plain build, netio/pacing, and protected-state gates. The final Wire head also
passed 506 tests under WASI/wasmtime and an explicit vector-generator build.
No public module, product, runtime behavior, wire byte, or persisted format
changed. #120 moved all 77 production client Swift files byte-identically into
`Client/Sources`, the client tests into `Client/Tests`, and their goldens into
the test-only `Fixtures/Goldens` hierarchy. The manifest and resolution lock
now live at `Client/`; the repository root is no longer a Swift package. Every
operator-facing contract remains rooted where it was: explicit SwiftPM
package/scratch paths preserve `.build`, the signed CLI/app wrappers preserve
their identities, provenance still covers every package, and VS Code invokes
only the signed paths. Client test path walks now use the one fail-closed
`LyteTestKit` repository locator, while Common, CI, benchmark, and layout
ratchets pin the new topology and pup retires stale root-client paths only in
its locked disposable mirror. Canonical Mac passed Common 78, Wire 508, Host
286, client 264, analyzer 25, benchmark safety, and both signed products;
isolated pup passed Common 79, Wire 508, Host 287, the plain build,
netio/pacing (19.193 ms IDR drain against the 25 ms ceiling), and protected
state. Frozen vectors were untouched; no public module, product, runtime
behavior, wire byte, persisted format, signed identity, or artifact location
changed. #121 made that new pup mirror cleanup fail closed: every cleanup
target must be a canonical, non-symlinked directory; a required `findmnt`
snapshot rejects mounts anywhere below the gate root; a fresh snapshot runs
immediately before stale root-client deletion; and the bounded cleanup cannot
cross a filesystem boundary. The deterministic shell pin proves every guard
and rejects the retired broad recursive deletion. Canonical Mac and isolated
pup gates passed again on the landed tree, including signed products,
netio/pacing, and protected-state verification; independent review found no
blocker. #122 closed the migrated CLI's last working-directory seam:
`wire-send` preserves every explicit corpus path, but its unchanged default now
walks to the repository-owned frozen Wire corpus when invoked from `Client/`.
The signing guide pins the exact direct package/scratch invocation beside the
stable-signature wrappers. The client delta passed the full canonical Mac and
isolated-pup gates before #121 integrated; after reconciliation, benchmark
safety and the focused 13-test repair gate passed again. **That migration
slice completed immediately below.** #123 established the canonical
`SystemTests/` boundary as a fifth SwiftPM package. `LyteTransport` is now an
additive library product without changing either shipping executable, and the
five-test pairing composition gate moved byte-identically from Client into
`SystemTests/Tests/LyteClientHostTests`. The macOS-only package imports both
real roles; it owns no private vectors and deliberately has no empty
`LyteSystemTestKit`. Its layout ratchet recognizes attributed, access-level,
and scoped Swift imports, rejects new role crossings in Client or Host tests,
forbids production-package back-edges and noncanonical SystemTests
directories, proves pairing still imports both peers, and names the client
NACK gate as the sole remaining Host import debt. Canonical Mac passed Common
78, Wire 508, Host 286, Client 259, SystemTests 8, analyzer 25, benchmark
safety, and both signed products. The deterministic pup mirror now includes
SystemTests in safety checks and cache identity while correctly leaving its
macOS-only suite unexecuted; pup passed Common 79, Wire 508, Host 287, the
plain build, netio/pacing, and protected-state verification. Independent
inventory and adversarial reviews found no blocker; frozen vectors and all
production behavior stayed unchanged. **NEXT MIGRATION SLICE: earn
`LyteClientTestKit` from the reusable headless video sink and client test-path
equipment, move the 13-test NACK composition gate into SystemTests, then
remove Client's final Host package dependency. Keep that move mechanical;
the real-client-report → real-Host-Session consolidation follows in its own
Theme 3 PR.** #124 completed that slice: `LyteClientTestKit` now owns the
reusable `HeadlessVideoSink`, repository/corpus paths, and one
`LockedBytePile` replacing three synchronized byte accumulators. All thirteen
NACK test names and verdicts were conserved while ownership became honest:
four pure `NackPolicy` gates remain in Client and nine real client/host repair
compositions live in SystemTests. Client's final Host package dependency is
gone; layout ratchets pin the empty role back-edges, both SystemTests gates
importing both peers, and the TestKit product staying out of shipping sources.
The production-source scanner now excludes only immediate SwiftPM `*TestKit`
target roots, with a synthetic nested-name evasion pinned visible. Canonical
Mac passed Common 80, Wire 508, Host 286, Client 250, SystemTests 17, analyzer
25, benchmark safety, and both signed products; isolated pup passed Common 81,
Wire 508, Host 287, the plain build, netio/pacing, and protected-state
verification. Independent architecture and adversarial reviews found no
blocker; frozen vectors and production behavior stayed unchanged. **That
cleanup slice completed as #125.** #125 carries the real client's Noise-sealed
NACK report untouched into the real Host `Session` judgement, then returns the
Session's real `.videoTail` repairs and split-entry 0x23 refusals through the
client demux. The gate-local repair host, direct `VideoChannel` construction,
manual feedback decoding, refusal construction, and control preclassification
are gone. The headline gate pins the dropped shard indices, original
frame/FEC/geometry/capture stamp, fresh repair sequences, and byte-exact healed
frame; refusal, storm, stale, straggler, superseded, and accepted-IRAP legs all
cross the same production boundary. Client arrival time is monotonically
coupled to Host release time, and both clocks fail loudly on retreat. Feedback
overflow, refusal bookkeeping, and assembler-to-policy duplicate routing now
live in their owning Client suites; two redundant Host round trips were
deleted, shrinking the two large repair suites by 177 lines together. A
target-wide lexical ratchet—pinned against comments plus ordinary, raw, and
multiline-string evasions—prevents a reconstructed Noise responder, direct
video channel, feedback decoder, or refusal path from growing back anywhere under
SystemTests. No production source, manifest, package edge, frozen vector, wire
byte, or persisted format changed. Canonical Mac passed Common 80, Wire 508,
Host 284, Client 253, SystemTests 16, analyzer 25, benchmark safety, and both
signed products; isolated pup passed Common 81, Wire 508, Host 285, the plain
build, netio/pacing, and protected-state verification. Independent architecture
and adversarial reviews found no blocker. **That carriage cleanup completed as
#126.** One shared `SystemHostSession` now backs both cross-end gates with the
shipping `HostWire.Session`; only UDP release and monotonic time are virtual.
Pairing binds `PairingResponderService` from the Session's actual
`.handshakeCompleted` event and handshake hash, feeds actual `.reliableCtrl`
events into the service, sends its answers through `Session.sendReliable`, and
forwards the real startup beacon/capability flight before the client share.
The old pairing `HostStandIn` and the NACK gate's second Session wrapper are
deleted. A target-wide, Swift-aware ratchet now rejects relocated direct Noise,
ARQ, connection-ID, envelope, beacon, feedback, repair, and control-sequence
construction while requiring the real handshake and reliable-control seams.
No production source, manifest, package edge, frozen vector, wire byte, or
persisted format changed. The slice is +429/-408 (net +21 test lines): two
rebuilt carriers became one production-Session harness plus stronger boundary
enforcement. Canonical Mac passed Common 80, Wire 508, Host 284, Client 253,
SystemTests 16, analyzer 25, benchmark safety, and both signed products;
isolated pup passed Common 81, Wire 508, Host 285, the plain build,
netio/pacing, and protected-state verification. Two independent reviews found
no blocker. **The ARQ carriage cleanup completed as #127.** `ArqEndpoint` now
packs once at its configured carrier ceiling, even after configuration is
mutated post-init; `WireBudget.maxConnectionIdTaggedPlaintextByteCount` owns
the one 1,101-byte connection-ID-tagged plaintext ceiling, and the Host and
Client clamp caller budgets to it. The five downstream Host, Client, and test
repackers and their duplicate budget arithmetic are deleted. Endpoint
normalization also closes the latent zero-body enqueue loop while preserving
the default 1,112-byte wire ceiling and every frozen vector. A SystemTests
source ratchet requires the canonical configuration at both production
carriers and rejects any returning production decode-and-repack path. The
slice is +311/-319 overall (net -8) and +93/-149 across production Sources
(net -56: Client -48, Host -52, Wire +44). Canonical Mac passed Common 80,
Wire 510, Host 285, Client 254, SystemTests 17, analyzer 25, benchmark safety,
and both signed products; isolated pup passed Common 81, Wire 510, Host 286,
the plain build, netio/pacing, and protected-state verification. Three
independent reviews found no blocker. A-26's ARQ duplication is closed; only
the named-host-crypto-seam judgement remains for the session-spine work.
**NEXT CLEANUP SLICE: begin the Client session spine by removing CoreMedia
from `LyteUdpSessionCore` behind the existing `VideoSink` organ, with behavior
held by the real cross-end SystemTests gates.**

**That first Client session-spine cut completed as #128.** The native
`SessionVideoSink` adapter moved from `LyteUdpSession.swift` into the owning
`VideoSink.swift` leaf. `LyteUdpSessionCore` now gives a pure
`admitVideoUnit(_:)` verdict over `DecodeUnit` and contains neither a
CoreMedia import nor `CMSampleBuffer`; the adapter alone carries the native
sample downstream. Recovery rejection, explicit renderer-enqueue recovery
closure, input-to-photon accounting, IDR chroma audit ordering, and weak-owner
teardown forwarding are unchanged. A Client lifecycle pin proves the chroma
audit completes before native submission, and Common's `VideoSink` source
ratchet prevents the native type or adapter definition from leaking back into
the session core. No wire byte, frozen vector, persisted format, manifest, or
product behavior changed. Production is +35/-34 (net +1); the stronger tests
make the total +64/-36. Canonical Mac passed Common 81, Wire 510, Host 285,
Client 254, SystemTests 17, analyzer 25, benchmark safety, and both signed
products; isolated pup passed Common 82, Wire 510, Host 286, the plain build,
netio/pacing, and protected-state verification. Independent adversarial review
found no blocker. The final A-26 judgement is **do not manufacture a Host
`TransportCrypto` twin**: all four seal callers and the one unseal caller
already funnel through two private `Session` helpers, while the Client seam
exists for three separate concurrent organs. Reconsider only when a real Host
sender/receiver spine creates a second owner. **NEXT CLEANUP SLICE: finish the
small Client shell-wrapper cleanup—move `InputSendTiming` beside
`OrderedInputSender`, replace `SessionFlag` with `Atomic<Bool>`, and remove
`SessionCoreBox` through the existing session-instance late-binding seam.**

**That Client shell-wrapper cleanup completed as #129.** `InputSendTiming`
now lives beside the `OrderedInputSender` that owns it. The private
`SessionFlag` lock wrapper is deleted in favor of a relaxed `Atomic<Bool>`
exchange—the same once-only claimant law, without implying that losing callers
wait for teardown completion. `SessionCoreBox` is also deleted, but its
synchronized startup publication was not weakened: `LyteUdpSession` owns
`Mutex<LyteUdpSessionCore?>`, publishes and reads through the same mutex, and
the endpoint callback captures the session weakly. Early datagrams still see
either nil or a fully published core, the endpoint/session graph is acyclic,
and stop order remains ordered input → queued audio stop → core timers →
endpoint join. A Client source ratchet pins the Mutex publication and weak
callback seam. No wire byte, frozen vector, persisted format, manifest, or
product behavior changed. Production is +49/-79 (net -30); the complete slice
is +62/-79 (net -17). Canonical Mac passed Common 81, Wire 510, Host 285,
Client 255, SystemTests 17, analyzer 25, benchmark safety, and both signed
products; isolated pup passed Common 82, Wire 510, Host 286, the plain build,
netio/pacing, and protected-state verification. Independent concurrency review
found no blocker. **NEXT CLEANUP SLICE: extract HostWire's sans-IO
`SessionBeaconClock`—the one owner of 1 Hz cadence, successful-send sequence
advance, echo mirroring, and offset/RTT/min-RTT statistics. Keep sealing,
CTRL sequence, counters/events, and estimator policy in `Session`; pin failed
send, no-drift late wake, and clock-sample laws directly.**

**That Host clock extraction completed as #130.** `SessionBeaconClock` is
now the one sans-IO owner of the beacon deadline, successful-send sequence,
last-echo mirror, and raw offset/RTT/min-RTT books. `Session` retains the
transport boundary: it seals and schedules CTRL, reports send failures,
increments counters, emits events, and feeds accepted samples into the
congestion estimator. The direct pins prove that a refused send retries the
same sequence on the next beat, a slightly late wake preserves cadence, a
long stall schedules exactly one fresh interval rather than a burst, and the
minimum-RTT sample supplies the retained offset while the newest echo is
mirrored byte-for-byte. The Session source ratchet rejects the four retired
owner spellings. No wire byte, frozen vector, persisted format, manifest, or
product behavior changed. Canonical Mac passed Common 81, Wire 510, Host 289,
Client 255, SystemTests 17, analyzer 25, benchmark safety, and both signed
products; isolated pup passed Common 82, Wire 510, Host 290, the plain build,
netio/pacing, and protected-state verification. **NEXT CLEANUP SLICE: extract
HostWire's sans-IO `SessionInputEchoBook`—the one owner of the last injected
sequence stamp and pending 0x17 tuples. Keep reliable transport, counters, and
events in `Session`; pin 32-tuple batching and success-only dequeue so refused
sends cannot lose input-to-photon evidence.**

**That injected-input extraction completed as #131.**
`SessionInputEchoBook` now owns the latest shell-confirmed input sequence and
the ordered pending 0x17 tuples. Its next-message seam is nonmutating and
wire-bounded at 32 tuples; `Session` commits that exact prefix only after
reliable CTRL accepts it, so a refused admission cannot erase input-to-photon
evidence. `Session` retains ARQ transport, counters, events, and the public
last-input stamp view consumed by video preparation. Direct pins cover empty
state, stamp/tuple ordering, 32+8 batching, refusal-safe retry, and the source
ownership ratchet; the real 40-event lossy input storm still delivered,
echoed, and stamped every event exactly once. No wire byte, frozen vector,
persisted format, manifest, or product behavior changed. Canonical Mac passed
Common 81, Wire 510, Host 293, Client 255, SystemTests 17, analyzer 25,
benchmark safety, and both signed products; isolated pup passed Common 82,
Wire 510, Host 294, the plain build, netio/pacing, and protected-state
verification. **NEXT CLEANUP SLICE: collapse the Host session's five parallel
fresh-keyframe latches into one sans-IO `SessionFreshKeyframeBook` backed by
the existing `FreshKeyframeDemand` OptionSet. Move the demand vocabulary
beside its owner; keep path polling, estimator rate application, counters, and
events in `Session`; pin coalescence and take-once clearing directly.**

**That fresh-keyframe consolidation completed as #132.**
`SessionFreshKeyframeBook` now owns the one pending
`FreshKeyframeDemand`: client requests, machine wake/recovery, stale NACKs,
unprotectable drops, fall purges, and path promotion union into it and drain
exactly once per encoder poll. The five parallel booleans/optionals and the
hand-written merge/reset list are gone. `Session` retains path polling,
estimator repricing, NACK throttling, counters, and events. Direct pins cover
all-cause coalescence, stable names, duplicate arms, take-once clearing, and
the source-ownership ratchet. No wire byte, frozen vector, persisted format,
manifest, or product behavior changed. Production Host code is 15 lines
smaller. Canonical Mac passed Common 81, Wire 510, Host 296, Client 255,
SystemTests 17, analyzer 25, benchmark safety, and both signed products;
isolated pup passed Common 82, Wire 510, Host 297, the plain build,
netio/pacing, and protected-state verification. **NEXT CLEANUP SLICE: extract
HostWire's sans-IO `SessionRepairBudgetBook`—the one owner of feedback-cadence
EWMA, opening-IDR delivery evidence, and bounded opening repair exemptions.
Keep report decoding, estimator ingestion, repair-store access, counters, and
events in `Session`; pin cadence clamping/EWMA, sticky glass evidence, and
attempt/byte exhaustion directly.**

**That repair-budget extraction completed as #133.**
`SessionRepairBudgetBook` now owns the feedback-cadence EWMA, first opening-IDR
geometry, sticky client-glass evidence, and bounded opening-exemption attempt/
byte books. `Session` delegates the existing freeze-budget derivation and
opening-exemption verdict while retaining report decoding, estimator and
repair-store access, counters, events, and unknown-frame IDR throttling. Direct
pins cover the 25–50 ms clamp, α=1/8 EWMA, override precedence, first-only
opening geometry, sticky evidence, both exemption bounds, and the ownership
ratchet; the 18-leg Host repair gate and the seven cross-end repair gates stay
unchanged. No wire byte, frozen vector, persisted format, manifest, or product
behavior changed. `Session.swift` is 39 lines smaller; total production is
+44 because the formerly implicit six-field policy now has a named documented
API. Canonical Mac passed Common 81, Wire 510, Host 300, Client 255,
SystemTests 17, analyzer 25, benchmark safety, and both signed products;
isolated pup passed Common 82, Wire 510, Host 301, the plain build,
netio/pacing, and protected-state verification. **NEXT CLEANUP SLICE: extract
HostWire's sans-IO `SessionSocketPendingBook`—the one owner of pacer-released
datagrams awaiting socket acceptance, their release-rate evidence, and their
per-frame video totals. Collapse the duplicated confirm/discard decrement
paths; keep kernel acceptance, estimator ingestion, fall-purge policy,
counters, and events in `Session`; pin EAGAIN retry, confirmation, discard,
frame recusal, and aggregate drain directly.**

**That socket-pending extraction completed as #134.**
`SessionSocketPendingBook` now owns the release-rate evidence, per-frame NACK
recusal, and aggregate datagram/byte backlog for pacer-released datagrams still
awaiting kernel acceptance. Confirmation and explicit discard share one
idempotent removal path, so a repeated removal cannot underflow a frame or
erase its sibling; off-primary challenges remain excluded. `PacerClass` has
one channel mapping for both pending identity and estimator ingestion.
`Session` retains kernel acceptance, estimator policy, fall-purge decisions,
counters, and events. Direct pins cover every pacer-class mapping, exact
rate/frame/byte accounting, off-primary exclusion, complete drain, repeated
removal, and the ownership ratchet; the existing EAGAIN, confirmation,
discard, frame-recusal, and fall-purge gates stay unchanged. No wire byte,
frozen vector, persisted format, or manifest changed. `Session.swift` is 68
lines smaller; total production is +10 after introducing the named owner.
Canonical Mac passed Common 81, Wire 510, Host 304, Client 255, SystemTests 17,
analyzer 25, benchmark safety, and both signed products; isolated pup passed
Common 82, Wire 510, Host 305, the plain build, netio/pacing, and
protected-state verification. **NEXT CLEANUP SLICE: extract HostWire's sans-IO
`SessionIdleHandoffBook`—the one owner of the retained converged frame, damage
quiet clock, pending idle-flip deadline, final-frame group, and nonzero
one-shot group allocation. Keep ARQ admission/service, lifecycle-machine
events, counters, and transport errors in `Session`; pin fresh-damage abort,
quiet-window release, refused-send retry, group wrap, foreign acknowledgment,
and exact final-frame retirement directly.**

**That idle-handoff extraction completed as #135.**
`SessionIdleHandoffBook` now owns the retained `IdleFrame`, last-damage quiet
clock, pending release deadline, exact in-flight group, and nonzero one-shot
group allocation. Final-frame preparation is non-consuming: refused ARQ
admission retries the same frame/group, and only a successful admission moves
the allocator. Exact acknowledgment retires the episode; foreign or late
groups cannot clear a newer handoff. Fresh damage now explicitly forgets both
pending and in-flight handoffs, making the existing observable damage-abort
law direct rather than leaving a dead group named until its late ack.
`Session` retains ARQ admission/service, lifecycle-machine effects, counters,
and transport errors. Direct pins cover exact `IdleFrame` bytes, refusal-safe
reuse, quiet-boundary release, fresh-damage abort, foreign/late ack isolation,
exact retirement, and UInt16 wrap skipping group zero; every existing HS-11/
HS-22 idle, metronome, abort, and wake gate stays green. No wire byte, frozen
vector, persisted format, or manifest changed. `Session.swift` is 29 lines
smaller; total production is +61 after introducing the documented owner.
Canonical Mac passed Common 81, Wire 510, Host 309, Client 255, SystemTests 17,
analyzer 25, benchmark safety, and both signed products; isolated pup passed
Common 82, Wire 510, Host 310, the plain build, netio/pacing, and
protected-state verification. **NEXT CLEANUP SLICE: collapse the parallel CTRL
and bulk reliable-carrier books behind one sans-IO `SessionArqLane` shape—one
endpoint, PTO deadline, and envelope sequence per channel—then unify their
duplicated poll/deadline/send loops without merging their message consumers or
negotiation gates. Keep sealing, pacer selection, counters, decoded-message
policy, and lifecycle effects in `Session`; pin lane isolation, group-0 versus
one-shot behavior, refusal/PTO recovery, sequence wrap, and quiescence.**

**That reliable-carrier extraction completed as #136.**
`SessionArqLane` is now the one sans-IO shape for a reliable carrier's
`ArqEndpoint`, PTO deadline, and channel-envelope sequence. `Session` owns one
CTRL lane and, only when key 11 or 12 is locally declared, one independent
bulk lane; their endpoint, clock, and sequence state never merge. The two
parallel poll/deadline/emission loops are one service path while sealing,
pacer selection, negotiation gates, decoded-message policy, counters, failure
labels, and lifecycle effects remain in `Session`. Every CTRL shape—bare
handshake message 2, beacon, path traffic, ordinary CTRL, and ARQ—borrows the
same channel-wide sequence and commits it only after final encoding and pacer
admission, preserving the Noise nonce law. Direct pins cover endpoint/lane
isolation, ordered versus one-shot groups, exact PTO arming/backoff/clearing,
refusal, quiescence, sequence wrap, and carrier geometry; integration pins
make handshake/beacon/declaration sequences exactly 0/1/2 and a PTO retry the
next fresh sequence. No wire byte, frozen vector, persisted format, or
manifest changed. `Session.swift` is net +16 lines; the documented 62-line
owner makes total production net +78—this slice removes duplicated state and
control flow, not raw LOC. Canonical Mac passed Common 81, Wire 510, Host 315,
Client 255, SystemTests 17, analyzer 25, benchmark safety, and both signed
products; isolated pup passed Common 82, Wire 510, Host 316, the plain build,
netio/pacing (19.185 ms IDR drain against the 25 ms ceiling), and
protected-state verification. Independent adversarial review found no
blocker. **NEXT CLEANUP SLICE: extract HostWire's sans-IO
`SessionLifecycleLane`—the one owner of the W4b state machine, its projected
timer deadline, and the local video-freeze projection. Keep reliable sends,
estimator repricing, pacer changes, fresh-keyframe causes, counters, events,
and every other external effect in `Session`; pin dormant-before-establishment,
apply-before-poll ordering, exact deadline conversion, ACTIVE/FROZEN/RECOVERY/
CLOSED projections, the deliberate FROZEN-video-only suppression asymmetry,
and one state-change verdict.**

**That lifecycle extraction completed as #137.**
`SessionLifecycleLane` now owns when the Host's W4b media-sender machine
exists, its exact microsecond-to-nanosecond timer projection, the due-service
verdict, and the local freeze/resume projection. `Session` retains reliable
mode and teardown sends, estimator repricing, pacer changes, fresh-keyframe
causes, counters, and events; it receives one final state-change verdict per
apply-then-poll pass. FROZEN still suppresses video only while audio remains
the path probe; CLOSED suppresses both. Direct pins cover dormant
pre-establishment, exact deadline boundaries, apply-before-poll evidence at a
coincident blackout edge, ACTIVE/FROZEN/RECOVERY/CLOSED projections, IDLE
wake, and terminal quiescence. Every existing lifecycle/capability loopback
gate stayed unchanged. No wire byte, frozen vector, persisted format,
manifest, or product behavior changed. `Session.swift` is 12 lines smaller;
the documented 120-line owner makes total production net +108—this slice
names and seals an IO-free organ rather than chasing raw LOC. Canonical Mac
passed Common 81, Wire 510, Host 320, Client 255, SystemTests 17, analyzer 25,
benchmark safety, and both signed products; isolated pup passed Common 82,
Wire 510, Host 321, the plain build, netio/pacing (19.206 ms IDR drain against
the 25 ms ceiling), and protected-state verification. The merged source was
rebuilt onto the standing systemd host; UDP 41151, Main444, Avahi, and the
protected identity books are green. **NEXT CLEANUP SLICE: move the remaining
unknown-frame stale-NACK admission clock into `SessionFreshKeyframeBook`,
beside the demand it governs. Keep NACK classification, counters, refusal
traffic, and events in `Session`; pin the exact interval boundary, known-frame
stale verdicts remaining unthrottled, demand-taking not resetting peer
pressure, clock wrap, and the existing in-vivo NACK gates.**

**That peer-pressure consolidation completed as #138.**
`SessionFreshKeyframeBook` now owns the last admitted unknown-frame timestamp
beside the coalesced `.staleNackArm` demand it governs. Unknown-frame guesses
retain the exact wrapping interval law; a rejected guess neither arms nor moves
the window. Stale verdicts tied to real retained-frame history remain
unthrottled and do not move that window, and taking the pending encoder demand
does not reset peer pressure. `Session` retains NACK classification, repair
and refusal traffic, counters, and events. Direct pins cover the exact interval
boundary, demand-taking persistence, clock wrap, known/unknown independence,
and the ownership ratchet; the existing 40-guess in-vivo gate remains green.
No wire byte, frozen vector, persisted format, manifest, or product behavior
changed. `Session.swift` is 11 lines smaller; total production is net +11
after moving the policy into its named owner. Canonical Mac passed Common 81,
Wire 510, Host 324, Client 255, SystemTests 17, analyzer 25, benchmark safety,
and both signed products; isolated pup passed Common 82, Wire 510, Host 325,
the plain build, netio/pacing (19.364 ms IDR drain against the 25 ms ceiling),
and protected-state verification. Independent adversarial review found no
blocker. **NEXT CLEANUP SLICE: delete `Session`'s stored `phase` and derive the
public compatibility view from `SessionLifecycleLane.isEstablished`. #137 left
two mutable establishment truths initialized and advanced in parallel; this
slice removes one outright with no new type or wrapper. Move lane establishment
to the old `phase = .established` point so message-2/beacon sink callbacks still
observe `.established`; keep CLOSED reporting established because the lane
remains instantiated. Pin Noise/insecure initialization, hostile message-1
non-establishment, callback-visible ordering, CLOSED compatibility, and a
source ratchet rejecting stored phase or a second latch; then run lifecycle,
session, cookie, pairing, and handshake-sequence focused gates before both full
platform gates. Explicitly do not wrap `CapabilityNegotiator` or
`HandshakeGate`: Wire and the existing gate already own those policies.**

**That establishment-truth cleanup completed as #139.** `Session.phase`
is now a read-only compatibility view of
`SessionLifecycleLane.isEstablished`; the independently stored phase and both
of its initialization/handshake writes are gone. Insecure sessions still begin
established, rejected or failed Noise attempts remain awaiting, and successful
Noise creates the lifecycle machine at the exact old phase-flip point: after
message 2 is queued and transport creation succeeds, before the opening beacon
and capability word. CLOSED remains `.established` because its terminal machine
still exists; it never regresses to handshake dormancy. Direct source ratchets
reject a stored phase or assignment, the lane pins terminal establishment, and
the liveness gate pins the public CLOSED compatibility view. No wire byte,
frozen vector, persisted format, manifest, or product behavior changed.
Production is three lines smaller with no new type or state. Canonical Mac
passed Common 81, Wire 510, Host 324, Client 255, SystemTests 17, analyzer 25,
benchmark safety, and both signed products; isolated pup passed Common 82,
Wire 510, Host 325, the plain build, netio/pacing (19.210 ms IDR drain against
the 25 ms ceiling), and protected-state verification. Independent adversarial
review found no blocker. **NEXT CLEANUP SLICE: make the existing
`HandshakeGate.admitMessage1` return its cookie-mode transition beside the
admission, then delete `Session.lastCookieMode` and
`noteCookieModeTransition()`. Snapshot the authoritative gate posture before
its flood-window update and compute the optional transition immediately after,
so admit/challenge/drop branches all carry the same at-most-once verdict. Add
no wrapper and no replacement mirror. Pin stable nil, exact enter/exit once,
nil-secret immobility, and unchanged admission/counter verdicts in
`CookieGateTests`, then run Cookie/Pairing/Session focused gates and both full
platform gates. `SessionCapabilityBook` remains explicitly rejected as a
wrapper around Wire's existing `CapabilityNegotiator`.**

**That cookie-transition cleanup completed as #140.**
`HandshakeGate.admitMessage1` now returns one named `Decision`: the unchanged
admission verdict beside the authoritative optional cookie-mode edge computed
immediately after the flood-window update. Every path carries the same edge—
token admit/throttle, challenge, verified cookie, and invalid cookie—before
branch-specific counters or effects. `Session.lastCookieMode` and
`noteCookieModeTransition()` are deleted; Session emits the returned edge
before its handshake/challenge/drop event exactly as before. Direct pins cover
disabled mode, exact enter/hold/exit, invalid-cookie entry, valid-cookie exit,
Session event order, admission/counter invariance, and the ownership ratchet.
No replacement mirror, wrapper, wire byte, frozen vector, persisted format,
manifest, or product behavior changed. Production is two lines smaller.
Canonical Mac passed Common 81, Wire 510, Host 326, Client 255, SystemTests 17,
analyzer 25, benchmark safety, and both signed products; isolated pup passed
Common 82, Wire 510, Host 327, the plain build, netio/pacing (19.185 ms IDR
drain against the 25 ms ceiling), and protected-state verification.
Independent adversarial review found no blocker. **HOST SESSION EXTRACTION IS
EXHAUSTED FOR NOW—pivot rather than wrap the remaining real duties. NEXT
CLEANUP SLICE: make Wire's existing `CapabilityNegotiator` the sole owner of
declaration-once and agreed capability state on both ends. Make `start()`
return `CapabilityDeclaration?` (first call returns and consumes it; later
calls return nil), delete Host `capabilitiesDeclared`, and preserve Host's
current consume-before-send/no-retry behavior. Delete Client's mirrored
`agreed` and read `negotiator.agreed` under the existing lock everywhere.
Pin first/second start, opening declaration order, every rule-3 gate, and
source ownership across Wire/Host/Client; then run focused cross-end capability
gates and every full platform gate. Add no `SessionCapabilityBook`: it remains
explicitly rejected as wrapper-only.**

**That capability-ownership cleanup completed as #141.**
`CapabilityNegotiator.start()` now returns and consumes the exact local
declaration once; later calls return nil. Host deleted its parallel
`capabilitiesDeclared` latch and asks the negotiator on every relevant wake,
which becomes a no-op after the first declaration. Client deleted its mirrored
`agreed` set and reads `negotiator.agreed` under the existing session lock at
every rule-3 gate and snapshot. Both ends preserve the prior
consume-before-send/no-retry posture, the declaration remains the first
reliable word, and its encoded bytes are unchanged. Direct pins cover the
first exact declaration, second-call nil, Host and Client source ownership,
full Noise/insecure session establishment, capability intersection, and every
existing feature gate. No replacement book, wrapper, wire byte, frozen vector,
persisted format, manifest, or product behavior changed. Production is three
lines smaller. Canonical Mac passed Common 81, Wire 511, Host 327, Client 256,
SystemTests 17, analyzer 25, benchmark safety, and both signed products;
isolated pup passed Common 82, Wire 511, Host 328, the plain build,
netio/pacing (19.330 ms IDR drain against the 25 ms ceiling), and protected-state
verification. Independent adversarial review found no blocker. **NEXT CLEANUP
SLICE: inventory current cross-end ownership after the Host Session and
capability-state tracks; prefer an existing owner absorbing duplicate state or
policy, and reject wrapper-only extraction.**

**That video-frame cursor cleanup completed as #142.** Host `Session` no
longer mutates `nextVideoFrameNumber` beside
`lastAdmittedVideoFrameNumber`; next is derived from the one public admitted
frame owner, with nil still naming opening frame 0. Only a successful prepared
frame commit moves that owner. Stale prepared contexts remain loud, while
unprotectable and lifecycle-suppressed frames consume no number. Idle handoff
now carries the owned last frame directly; its `last.next > 0` guard preserves
the previous UInt32-wrap refusal exactly. Direct pins cover nil→0→1,
old-context replay, unprotectable and frozen non-consumption, final-frame
identity, and a source ratchet rejecting another stored cursor. No new book,
wrapper, wire byte, frozen vector, persisted format, manifest, lock boundary,
or product behavior changed. Production is one line smaller. Canonical Mac
passed Common 81, Wire 511, Host 328, Client 256, SystemTests 17, analyzer 25,
benchmark safety, and both signed products; isolated pup passed Common 82,
Wire 511, Host 329, the plain build, netio/pacing (19.118 ms IDR drain against
the 25 ms ceiling), and protected-state verification. Independent adversarial
review found no blocker. **NEXT CLEANUP SLICE: re-inventory after this tiny
deletion; keep choosing existing owners over wrapper-only extraction.**

**That audio-posture latch cleanup completed as #143.** Client
`LyteUdpSessionCore` no longer maintains `sessionStartAudioAskDone` beside the
confirmed `hostAudioPosture`: nil now directly names that no valid negotiated
0x19 status has landed, and the first valid status consumes the session-start
request seam by setting the posture before the lock opens. Decode and
capability rejection still return before that assignment, so malformed and
unnegotiated status words do not consume the seam; the counter, event, and
optional follow-up request retain their previous ordering. A source ratchet
rejects another startup latch and pins the authoritative optional-state check.
No replacement book, wrapper, wire byte, frozen vector, persisted format,
manifest, lock boundary, or product behavior changed. Production is three
lines smaller. Focused audio-routing/layout gates passed 21 tests; the full
Client suite passed 257 and SystemTests passed 17. Canonical Mac passed Common
81, Wire 511, Host 328, Client 257, SystemTests 17, analyzer 25, benchmark
safety, and both signed products; isolated pup passed Common 82, Wire 511,
Host 329, the plain build, netio/pacing (19.246 ms IDR drain against the 25 ms
ceiling), and protected-state verification. Independent adversarial review
found no blocker. **NEXT CLEANUP SLICE: re-inventory current ownership across
Client, Host, Common, and Wire; choose another existing owner that can delete a
parallel truth, and reject wrapper-only or merely cosmetic movement.**

**That chroma-audit edge cleanup completed as #144.**
`ChromaStreamAudit.observedIdc` now owns both the last parsed stream posture and
whether that posture has been reported; the synchronized `reported` Boolean,
its re-arm, and its consume writes are gone. Nil still makes the first sighting
report, equal idc repeats stay silent even if the agreed set changes, every idc
change reports once, and A→B→A naturally re-arms from the observation itself.
The exact confirmation/DOCTOR/no-singleton wording, SPS parser, session lock,
capability judgment, and UI surface are unchanged. Direct pins cover all those
edges and a source ratchet rejects another report latch. No new type, helper,
wrapper, wire byte, frozen vector, persisted format, manifest, lock boundary,
or product behavior changed. Production is five lines smaller. Focused
chroma/layout/session gates passed 25 tests, the adversarial agreement-change
pin passed in the 19-test focused rerun, the full Client suite passed 258, and
SystemTests passed 17. Canonical Mac passed Common 81, Wire 511, Host 328,
Client 258, SystemTests 17, analyzer 25, benchmark safety, and both signed
products; isolated pup passed Common 82, Wire 511, Host 329, the plain build,
netio/pacing (19.239 ms IDR drain against the 25 ms ceiling), and
protected-state verification. Independent adversarial review found no blocker.
**NEXT CLEANUP SLICE: assess whether production `AudioWire` and
`lyte-audio-check` can share one zero-extra-copy, sans-IO HostCore owner for PCM
buffering, graph-clock marks, exact 5 ms slicing, and timestamp derivation. Do
not land it unless the API removes both real copies without moving Opus,
PipeWire, tripwire, or harness verdict policy into HostCore; prefer a smaller
deletion if that seam cannot stay allocation- and IO-free.**

**That histogram saturation cleanup completed as #145.** `Histogram` no
longer stores a `saturated` Boolean beside its cumulative `count`: saturation
has always meant that the recording lifetime crossed the bounded retention
capacity, so `count > capacity` is now the sole owner. The exact boundary is
unchanged — false through the capacity-th sample, true at the first sample
past capacity — and `removeAll()` restores false naturally by resetting count.
Direct pins cover that edge and a source ratchet rejects another saturation
assignment. No new type, wrapper, wire byte, frozen vector, persisted format,
manifest, lock boundary, or product behavior changed. Production drops one
stored field and two maintenance writes. Focused histogram/ratchet gates
passed 12 tests and the full Common suite passed 83 on Mac. Canonical Mac
passed Common 83, Wire 511, Host 328, Client 258, SystemTests 17, analyzer 25,
benchmark safety, and both signed products; isolated pup passed Common 84,
Wire 511, Host 329, the plain build, netio/pacing (19.308 ms IDR drain against
the 25 ms ceiling), and protected-state verification. **NEXT CLEANUP SLICE:
extract the duplicated production/audio-check PCM buffering, graph-clock mark,
exact 5 ms slicing, and timestamp mechanism into one synchronous, sans-IO
HostCore owner. Keep Opus, PipeWire, tripwire, delivery, and harness verdicts
in their role shells; preserve the one unavoidable input copy and add no PCM
packet copy.**

**That host audio-slicing cleanup completed as #146.** Production `AudioWire`
and `lyte-audio-check` no longer carry parallel retained-PCM tails, graph-clock
marks, frame cursors, exact 5 ms drain loops, or first-sample timestamp math.
The synchronous, sans-IO `HostCore.InterleavedPcmSlicer` now owns that one
mechanism: it makes the one unavoidable copy from PipeWire's expiring capture
pointer, lends each exact packet-sized view without a second PCM copy, and
multiplies before dividing to preserve 48 kHz timestamp rounding. A normal
callback return consumes the packet, preserving production's historical
encode-failure behavior; a throw retains the current head and stops, preserving
the checker's fail-and-quit transaction. PipeWire, Opus, tripwire, delivery,
decode evidence, and verifier verdicts remain in their role shells. Six direct
pins cover fragmented and empty input, interleaved sample order, discontinuous
graph marks, chunking invariance, exact rounding, transactional retry, and a
source ratchet proving both real consumers have no second slicer state.
Canonical Mac passed Common 83, Wire 511, Host 334, Client 258, SystemTests 17,
analyzer 25, benchmark safety, and both signed products (one existing
no-output-device client test skipped); isolated pup passed Common 84, Wire 511,
Host 335, the plain build, netio/pacing (19.195 ms IDR drain against the 25 ms
ceiling), and protected-state verification. The exact-tree live audio checker
delivered 370 packets at 200.0 packets/s with exact 80-byte hard-CBR payloads,
exact 5000 us graph-clock deltas, and clean decode-back. A fresh-port production
smoke encoded 1,577 packets and sent/received 999 with zero encode, send, or
mailbox failures; protected host identity files stayed byte-identical. Two
independent reviews found no blocker. **NEXT CLEANUP SLICE: re-inventory the
current tree after #146 and choose the smallest earned deletion or existing
owner that removes a parallel truth; reject wrapper-only movement.**

**That bulk-admission counter cleanup completed as #147.**
`BulkReceiveEngine` no longer stores `admittedChunkCount` beside the two books
that already own the answer: consumed chunks and stores awaiting durability.
Every receiver transition maintained `admitted == consumed + pending`; the
credit guard now derives that debt at its only use, and both synchronized
counter mutations are gone. Resume under-claim tolerance, slow storage,
monotonic credit refresh, duplicate refusal, aborts, and verification retain
their exact transactions. A direct mixed-state pin consumes one tolerated
resume chunk, holds two fresh stores at the refreshed grant, and refuses the
next admission; a source ratchet rejects another parallel counter. No public
API, wire byte, frozen vector, transfer state, storage policy, allocation,
manifest, or shell behavior changed. Production loses one stored field and two
writes. Canonical Mac passed Common 83, Wire 513, Host 334, Client 258,
SystemTests 17, analyzer 25, benchmark safety, and both signed products (one
existing no-output-device client test skipped); isolated pup passed Common 84,
Wire 513, Host 335, the plain build, netio/pacing (19.189 ms IDR drain against
the 25 ms ceiling), and protected-state verification. Independent transition
and overflow review found no blocker. **NEXT CLEANUP SLICE: make Host
`EncoderVbvPolicy.squeezeEngaged` a projection of its authoritative applied
rung, deleting the synchronized posture bit while preserving its public API.**

**Suites at HEAD:** Wire 513 Mac / 513 pup; Common 83 Mac / 84 pup;
client 258; SystemTests 17 Mac; host 335 pup / 334 Mac — all green. Eighteen conductor/gauge
tests moved from root to Common; LyteTestKit adds three fail-closed scanner
pins; the VideoSink and ScreenSource ratchets add four more; HostCore's pure
screen doorbell adds three pins; SystemTests now owns both cross-role gates;
benchmark safety adds one deterministic shell suite beside the 25 analyzer
tests.

# STANDING RULINGS (owner decisions of record — do not re-litigate)

- **Chroma**: three-tier control, Good = 4:2:0 / Better = 4:2:2
  (DORMANT — no reference hardware encodes 4:2:2; grayed "not offered
  by this host") / Best = 4:4:4; flip = clean reconnect. A `yuv422` id
  is a contract-safe append when hardware exists (wire today:
  `CapabilityChroma` yuv420 = 1, yuv444 = 2). Post-E5 status: the
  native pens serve 4:2:0 only — Best is dormant until Rext lands in
  the pens (queued on the postures track).
- **Color path**: `rgb_mode` 601-limited ships (glass-correct,
  quality-equal); gbrp is OUT (CoreMedia has no identity-matrix
  vocabulary — structural); the full-range row is named-and-queued,
  not gating.
- **FEC ceiling**: keep the capped-CQ posture (conform IDRs to the
  ceiling; the ratchet heals). Banked: the fec group-index rides the
  pre-written wire-v2 batch (ceiling dies free if v2 ships);
  intra-refresh is the named experiment if ceiling-IDR quality ever
  bothers the eyeball.
- **P-2 (monitor selection) and P-3 (resolution change): DROPPED
  outright** (2026-07-30). P-2 revives with no wire debt if a
  multi-monitor host ever exists; P-3's law is chroma's law — fixed
  at ANNOUNCE, change = clean reconnect. The residual belt's code
  half LANDED (PR #24: a mid-session geometry change fails the
  session with a typed teardown); the remaining half is the live
  watch in TODO.md — one deliberate monitor-mode flip.
- **Split-groups wire contract**: don't re-litigate multi-group
  frames without a wire-v2 discussion first (finding in the archived
  HS-25 wave entry).
- **Reconfigure-IDR family: CLOSED** (HS-33). Rate moves apply with
  zero reset and zero IDR. The law was proven on the vendored
  no-reset libavcodec (the twin `--no-vbv-reconfigure` control leg:
  glass frozen without the directives); since E5 the property is
  STRUCTURAL — our own pens simply never emit a reset — but the
  ruling stands: nobody gets to "simplify" rate-change handling into
  something that mints IDRs.

# LIVE OPS — the owner's rig (direct-eye era)

- **pup standing host is a SYSTEMD SERVICE since E4 (2026-08-03)**:
  `lyte-host.service` (system unit, `User=shreeve`,
  `AmbientCapabilities=CAP_SYS_ADMIN`, `Restart=always`) on port
  **41151** — the owner's eyeball host; leave it alive. The bash
  `~/lyte-loop.sh` supervisor is RETIRED. Config:
  `/etc/lyte/lyte-host.conf` (operator-owned; `LYTE_HOST_BIN` points
  at the build tree, `LYTE_HOST_ARGS` is the old loop command line).
  Session log: `/tmp/lyte-host-session.log` unchanged (the redirect
  rides inside the unit's shell — Ubuntu's fs.protected_regular
  forbids root append: into another user's /tmp file). **The deploy
  loop is now: `swift build` then `sudo -n systemctl restart
  lyte-host` — NO setcap step**: the capability is ambient on the
  service (gate-proven on a caps-stripped binary). setcap remains
  ONLY for hand-run hosts (test ports, lyte-eye probes:
  `sudo -n setcap cap_sys_admin+ep .build/debug/lyte-eye`).
  Restart/status: `systemctl is-active lyte-host`,
  `sudo -n journalctl -u lyte-host` for unit lifecycle. Install/
  repair: `bash ~/src/lyte-host/Scripts/install-host.sh`
  (idempotent; never overwrites the conf).
- **The owner's client** is the app bundle at `.build/Lyte.app` —
  launch with `open .build/Lyte.app` (NEVER run the raw binary under
  a parent process; it needs its own bundle for a proper macOS
  window/menu bar). Client & host are PAIRED (client static
  `357a83cc…`) — a healthy reconnect shows **no PIN**. If a 6-digit
  pairing box appears, the client lost its pinned identity: restart the
  systemd host with `--pair` in its operator-owned `LYTE_HOST_ARGS` so it
  mints+prints a PIN to the session log (3 wrong guesses burn it); remove the
  temporary flag and restart the unit after pairing.
- **Secrets law**: NEVER touch pup's
  `~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`.
  sha-verify around live runs: `noise_static.key 72860390…cfed`,
  `paired_clients 8dc1f88a…55fd` must stay byte-identical;
  `portal_token` is a portal-era leftover, inert but protected.
- **Harness discipline**: test lyte-hosts MUST run `--no-advertise`
  on fresh 41xxx ports — an advertised test host is a second "pup"
  in discovery and the owner's app WILL connect to it. Never kill or
  connect to the owner's 41151 service. When a slice runs live legs on
  pup while the owner might connect, both hosts capture the same
  physical screen — tell the owner BEFORE the leg, not after they
  report black.
- *(The portal-wedge black-screen playbook and the
  `MUTTER_DEBUG_PAINT=disable-direct-scanout` flag died with E5 — the
  direct eye reads the scanout itself, wedge-proof; `setup-host.sh`
  now REMOVES the leftover env flag. The old playbook is in the
  pre-slim file, `git show 0753cbc:HANDOFF.md`.)*

# BUILD/TEST RECIPES (the law — deviations lose builds silently)

- Mac tests need `DEVELOPER_DIR=/Applications/Xcode.app swift test`
  (xcode-select points at CLT, which lacks XCTest). Capture exit
  codes as `rc=$?` after a redirect — never pipe `swift test` to
  grep directly (masks the code; `status` is zsh read-only).
- pup host build/test: rsync `Wire/` → `pup:src/Wire/`, `Common/` →
  `pup:src/Common/`, and `Host/` → `pup:src/lyte-host/` (exclude
  `.build`), then on pup:
  `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build` (or
  `test`). No ffmpeg env exists anymore — a plain build succeeding is
  itself an E5 gate. Restart the systemd unit for standing deployment;
  setcap is only for hand-run hardware probes (see live ops). Good-build marker in
  any host run: the session books print
  `encoder 4:2:0 (native VAAPI)`.
- Wire/ vectors are frozen contracts — append-only, never mutate.
- Stage per package (`git add Wire/`, `git add Host/`), never
  `git add -A`. No AI-attribution trailers in commits, ever.

# WORKERS (background subagents)

Session-bound: a subagent from a previous chat CANNOT be resumed from
a new chat — relaunch a fresh worker with a full task prompt. Its file
edits, commits, and pup-side state persist on disk regardless; only
the live agent handle is lost. Resuming = inspect what the stopped
worker left on disk, keep or revert it, relaunch fresh. Standing infra
that is NOT a worker and stays up: the pup 41151 loop and the owner's
client app bundle.

# THE BEAUTY BAR — the standing quality gate, new instrument era

The instrument is `Scripts/benchmark-app.sh` (#82): GPU readback of
the displayed buffer, marker-locked against the byte-pinned authored
frame. The old corpus-era bars (static ≥ 50 dB · motion ≥ 55 dB) do
NOT carry over. FLOORS ARE PER CHROMA TIER since 2026-08-03 (the
sample's `streamChroma` = the wire's SPS-audit truth; absent = a
pre-tier recording, graded 4:2:0):
  · 4:2:0 — min-channel 28 dB active / 30 dB converged / SSIM 0.995
    (the synthetic pattern is chroma-adversarial: thin saturated
    lines pin R/B near 31 dB at 4:2:0 regardless of encoder health)
  · 4:4:4 — 45 dB active / 50 dB converged / SSIM 0.9995 (the
    Best-tier commissioning, below)
Pin the leg's tier with `LYTE_BENCHMARK_CHROMA_TIER=good|best`
(empty = the pinned host's persisted tier — ambiguous for an A/B).
Baseline rows (panel at 60 Hz — REQUIRED for motion legs; at 120 Hz
Mutter presents the 60 fps pattern unevenly and the preflight
refuses): 4:2:0 at `0410e16` (2026-08-02): quality-static PASS
31.2 dB / SSIM 0.9991, 29/29 phase-locked; motion PASS at `61fb56b`
(#83's metronome): gap p50=p95=p99 16.667 ms exactly, lateness p99
1.68 ms, 30.76 dB / SSIM 0.9989, 59.5 fps, 0 IDR. 4:4:4 BEST-TIER
COMMISSIONING (2026-08-03, post-#90): quality-static 57.6 dB
min-channel / SSIM 0.999994; motion 56.8 dB / SSIM 0.99999 at
59.97 fps, gap 16.667 ms exact, lateness p99 1.92 ms — +26 dB over
4:2:0 at zero cadence cost. RATCHET FINDING (closes the A-20
quality-refinement ambition for stills): Best-tier static quality
converges from the FIRST observation — the VBR envelope at
keepalive cadence already floors QP, so the portal-era explicit
QP-descent ratchet has nothing left to fetch; the refinement work
became these floors. ENVIRONMENT WART on the books: macOS
resurrects awdl0 mid-run (~1×/30 s some days); the helper's
re-engage costs a ~100 ms audio window → `audio_steady_state_late_
or_plc` FAILs that are tier-independent and environmental — check
stderr for "awdl0 UP while streaming" before blaming the wire.
The libav-era eight-row table with footnotes:
`git show 0753cbc:HANDOFF.md`; per-row forensics:
`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`.
Never massage a red cell: a FAIL at HEAD is a finding.
