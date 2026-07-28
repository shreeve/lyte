# Lyte Bulk-Transfer Channel — W10 / F-2 design record (2026-07-28)

*The F-2 slice ruling of record: the chunked, resumable, backpressured
bulk-transfer channel in LyteWire — the H3 wave's long pole
(`docs/20260723-051223-lyte-h3-plan.md` §3), designed so both end slices
(F-3 host, F-4 client) code against the frozen `bulk-v1.json` vectors and
never against each other (master plan ruling 12). Authorities: the
transport pillar (`docs/20260720-191704`) for channel/priority semantics,
the resiliency pillar §1 for the ARQ-vs-FEC fork, H3 §0 owner decision 1
(client→host only in v1, standing per-host consent toggle), and the J-G3
bar (a ≥100 MB file lands sha-identical through loss and a mid-transfer
blackout while audio NIC cadence p99 holds within 5±2 ms).*

## 0. Scope

A **transfer** is one offered blob — name, byte count, SHA-256, MIME
hint — moving whole from a **sender** to a **receiver**. The vocabulary
is deliberately direction-neutral (every message speaks sender/receiver,
never client/host) so a v2 can flip or duplex the direction without new
bytes; **v1 gates host→client OFF at the ends** (owner decision 1): the
client is the only sender, the host the only receiver, and the standing
per-host consent toggle lives in the end shells — Wire carries
capability and refusal vocabulary, never consent policy.

Out of scope here, owned by F-3/F-4: where dropped files land, atomic
tmp+rename, fsync-before-ack, disk-space refusal, consent UX, progress
UI. Out of scope everywhere in Wire: sockets, threads, clocks it did not
inject, file IO, hashing of actual payloads (the ends hash; the engines
compare 32-byte digests).

## 1. The channel ruling: chan 8, and a new tail rung below telemetry

Bulk rides **channel 8** — the first feature channel, exactly the
architecture the transport pillar reserved ("separate streams so a file
transfer never blocks a clipboard paste") and the reason clipboard v1
deliberately did NOT claim a feature-channel id. Chan 8 is already
`reliableOrdered` in the registry; this slice names it
(`ChannelId.bulkTransfer`) and assigns its send class.

**Priority: a new `WirePriority.bulk = 7`, strictly below telemetry.**
The H3 plan left the exact rung as F-2's ruling ("at or below telemetry
— the doctrine is that bulk never costs audio or fresh video"). The
ruling is BELOW, for one load-bearing reason: the telemetry class
carries the 25–50 ms feedback reports that feed the congestion
estimator, and a starved estimator mis-prices the path for every media
class — telemetry is tiny but its freshness protects audio and video,
while bulk is arbitrarily large and infinitely patient. A 100 MB
transfer through a 20 Mbps pacer takes ~40 s; nothing about it may
delay a 100-byte report by even one pacer batch. So the unified ladder
becomes: CTRL/input > audio > fresh video > video tail > refinement >
feature > telemetry > **bulk**. Chan 8 takes `.bulk`; later feature
channels (9+) keep `.feature` — small interactive feature messages
(clipboard v2 control, printing control) should not queue behind a
file. DSCP is end-side policy with zero protocol bytes (the HS-20
precedent: videoTail repairs took CS6 as a host cmsg call): the host
plan should mark chan 8 datagrams best-effort or CS1 background; Wire
pins only the rank.

CTRL is untouched: the input/lifecycle ordered stream never carries a
chunk, so a file cannot head-of-line-block a keystroke by construction
— the whole reason F-2 exists rather than growing clipboard's carriage.

## 2. Reliability ruling: ARQ selective retransmission, not FEC/fountain

The fork the H3 plan ordered weighed (dedicated retransmit lane vs
fountain-code alternative, resiliency §1.1):

- **Chosen: the W3 ARQ sublayer, verbatim, on chan 8's ordered
  stream.** Each end runs one `ArqEndpoint` on chan 8 (the endpoint was
  built channel-generic for exactly this day); every bulk message —
  chunks included — is one ARQ message on group 0. That buys, for zero
  new wire surface: exactly-once in-order delivery, RFC 9002-shaped
  RTT-adaptive retransmission (SRTT/PTO/fast-retransmit already
  gate-proven at W-G4 with exhaustive interleavings and seeded storms),
  the replay/forgery bounds, and segment-level selective repair via the
  existing cumulative+bitmap ACKs. In-session loss recovery is
  therefore ARQ's job; the bulk layer's own ack-bitmap exists for
  cross-session resume and flow control, not per-datagram repair.
- **Rejected: FEC / fountain codes.** Bulk is throughput-elastic and
  latency-tolerant — the one traffic class where retransmit RTTs cost
  nothing, which is precisely the class FEC's proactive overhead is
  wrong for: parity bytes spent on the lowest-priority lane are bytes
  stolen from the pacer budget the media classes live on. The vendored
  nanors RS is block-limited to 255 shards (~272 KB protected per
  group) — the wrong shape for 100 MB — and a real fountain (RaptorQ)
  is a new algorithmic dependency with patent history, no exact
  "which chunks are missing" answer for sha-exact resume, and nothing
  the J-G3 gate can measure that ARQ doesn't already deliver. Written
  down per the plan; revisit only if a future radio-lossy profile
  demands it.

Sizing sanity: a chunk message (≤ 128 KiB + 17 B header) fits ARQ's
262,144 B message budget with a wide margin; a 64 KiB chunk segments
into 60 × ≤1,104 B segments, well inside the 256-segment ACK-describable
receive window, and the default 128-segment send window paces ~2 chunks
in flight at the ARQ layer.

## 3. The vocabulary — CTRL types 0x1C–0x21, all on chan 8's stream

Six messages, all riding chan 8's ARQ ordered stream (group 0), all
little-endian, each exactly its layout (truncation, trailing bytes, and
foreign type bytes reject with what they found — the house rule).
Offer/chunk flow sender→receiver; accept/ack/complete flow
receiver→sender; abort flows either way. Ordering within each direction
is the ARQ stream's guarantee, which is what makes the handshake sound:
chunks can never overtake their offer, and a complete can never
overtake the final ack.

**BulkOffer (0x1C), sender→receiver** — "I hold this blob; may I send
it?" Also the resume probe (§5).

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x1C |
| 1 | 8 | transferId | u64, non-zero (zero = the loud zero-fill bug), sender-minted from injected randomness, stable across sessions |
| 9 | 8 | totalByteCount | u64, ≥ 1 (v1 does not transfer empty blobs); NO ceiling by design — 100 MB+ is the J-G3 bar, the protocol imposes none |
| 17 | 4 | chunkByteCount | u32, 4,096…131,072 (§4); every chunk but the last is exactly this, the last is the remainder (1…chunkByteCount) |
| 21 | 32 | sha256 | digest of the whole blob — the completion contract |
| 53 | 1 | nameLen | 1…255 (a nameless offer is unreviewable by a consent UI) |
| 54 | … | name | UTF-8, byte-exact-re-encode validated; SANITIZATION IS THE RECEIVER END'S JOB (path separators, dotfiles — F-3's loud-refusal territory, not codec territory) |
| … | 1 | mimeLen | 0…255 — the hint is optional |
| … | … | mimeHint | UTF-8 |

**BulkAccept (0x1D), receiver→sender** — consent granted; carries the
receiver's existing possession (empty for a fresh transfer, the
persisted chunk map for a resume) and the opening credit.

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x1D |
| 1 | 8 | transferId | echoed |
| 9 | 8 | creditTotal | u64 — chunks the sender may dispatch this session (§4); 0 is legal (accept-but-hold, backpressure from the first byte) |
| 17 | 8 | contiguousCount | chunk map (§5): chunks 0…contiguousCount−1 are held |
| 25 | 2 | bitmapLen | u16, 0…1,024 |
| 27 | … | bitmap | bit n (byte n/8, bit n%8) set = chunk contiguousCount+1+n held; canonical: final byte non-zero |

**BulkChunk (0x1E), sender→receiver** — one chunk, data the sole
trailing field (the RetryHandshake1 self-delimiting precedent; the ARQ
message boundary is the length).

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x1E |
| 1 | 8 | transferId | |
| 9 | 8 | chunkIndex | u64 (u32 would cap a no-ceiling blob at 512 GB with 4 KiB chunks — u64 removes the conversation) |
| 17 | … | data | 1…131,072 bytes; EXACT size against the offer's geometry is the engine's check (the codec doesn't know the offer) |

**BulkAck (0x1F), receiver→sender** — possession + credit, the
flow-control heartbeat. Same layout as accept minus nothing: the
accept IS the first ack plus consent.

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x1F |
| 1 | 8 | transferId | |
| 9 | 8 | creditTotal | monotonic within a session; a stale (lower) value is ignored, never a violation — acks are cumulative state, not deltas |
| 17 | 8 | contiguousCount | |
| 25 | 2 | bitmapLen | |
| 27 | … | bitmap | as in accept |

**BulkComplete (0x20), receiver→sender** — the success verdict, sent
only after the receiver's own digest of the assembled blob equals the
offer's sha256. Exactly 9 bytes: `type ‖ transferId`. Failure is never
a complete-with-status — it is an abort with a reason (one message, one
meaning; the lifecycle discipline).

**BulkAbort (0x21), either direction** — `type ‖ transferId ‖ reason`,
exactly 10 bytes. The reason space, pinned whole (the lifecycle rule —
a value added without a vector-file discussion fails loudly):

| reason | name | meaning |
|---|---|---|
| 0x01 | declined | receiver consent says no (toggle off, user refused) |
| 0x02 | cancelled | a human cancelled, either end, any time |
| 0x03 | resumeMismatch | offer reused a known transferId with different size/sha/geometry (§5) |
| 0x04 | shaMismatch | assembled blob's digest ≠ the offer's — the transfer failed at the finish line |
| 0x05 | storageFailure | receiver's disk said no (full, write error) |
| 0x06 | busy | a transfer is already active — v1 runs ONE transfer at a time per direction (§6); the ends queue, the wire refuses |
| 0x07 | protocolViolation | the peer broke the state machine (out-of-range chunk, credit overrun, wrong-size chunk…) |

0x00 rejects (zero-fill), unknown values reject.

## 4. Chunk and window sizes, bounded and justified

**chunkByteCount ∈ [4,096, 131,072], default 65,536**, sender-chosen
per transfer, fixed for the transfer's whole life (resume included —
it is part of the resume identity, §5).

- The floor keeps bookkeeping honest: at 4 KiB a 100 MB blob is 25,600
  chunks — chunk-map and dispatch structures stay trivial; anything
  smaller buys per-chunk overhead with no gate-measurable win.
- The ceiling keeps one chunk message (≤ 131,089 B with header) inside
  ARQ's 262,144 B message budget with 2× headroom, and bounds the
  receiver's single-chunk staging buffer.
- The default (64 KiB) is the sweet spot the ARQ geometry suggests: 60
  segments per chunk, ~1,600 chunks per 100 MB (a 25-byte final ack),
  and per-chunk header overhead of 0.026%.

**Credit: receiver-driven, cumulative, chunk-denominated,
session-scoped.** `creditTotal` = the total number of chunk messages
the sender is authorized to have dispatched *in this session* (counted
from the accept, from zero, every session — resume resets both ends'
counters by construction). Cumulative-absolute rather than incremental
so a lost-then-ARQ-retransmitted ack can never double-grant; monotonic
within the session, stale values ignored. The receiver grants
`storedCount + window` and refreshes the grant whenever it has advanced
by at least max(1, window/2) since the last ack (plus always once more
when possession completes, so the sender always learns the end
arrived). The sender consumes credit at *read-request* time — chunk
reads it asks its shell for count against the budget immediately — so
sender-side memory is bounded by the same window that bounds the
receiver.

**Window default: 16 chunks** (1 MiB at the default chunk size),
receiver-configured. Why 16: it bounds the receiver's worst-case
un-persisted buffering at ~1 MiB (a slow disk never balloons memory —
the credit simply stops arriving), while 1 MiB per RTT sustains ~400
Mbps at a 20 ms RTT — an order of magnitude past what the tail of a 20
Mbps pacer will ever hand bulk, so the window is never the throughput
limiter in practice; the pacer is, by design. A stingier receiver may
run window 1 (fully serialized, one chunk in flight) and the engines
must honor it — that is a pinned test, not a hope.

No transfer-size ceiling exists anywhere in the design: every counter
is u64, the chunk map's cumulative field describes any prefix, and the
bitmap bounds are describability bounds, not size bounds (§5).

## 5. Resume: transfer id + chunk map, sha-exact, survives teardown

**Identity.** A transfer IS its `(transferId, totalByteCount, sha256,
chunkByteCount)` quadruple. The id is minted once (u64, non-zero,
injected randomness — collision is a 2⁻⁶⁴ non-event) and reused
verbatim on every re-offer of the same blob. The receiver persists, per
unfinished transfer, a `BulkResumeState`: the quadruple, the name, and
its chunk possession. On a fresh session's offer whose id it knows, the
receiver matches the WHOLE quadruple — any field differing means the
file changed under the id (or the sender is confused) and draws
`abort(resumeMismatch)`; the sender's recovery is a fresh id, never a
silent re-baseline. On a match, the accept carries the persisted
possession and the transfer proceeds from the gap — re-sending nothing
that landed, which is J-G3's "mid-transfer blackout, resumes, sha
matches" bar. The final digest check runs over the ASSEMBLED blob, so
resume correctness is proven at the same finish line as everything
else: sha-exact or abort.

**The chunk map** (`contiguousCount` + hole bitmap) is the possession
encoding shared by accept and ack. With in-order ARQ carriage and
ascending dispatch the possession set is a plain prefix in practice and
the bitmap rides empty; the bitmap exists because the RESUME state is
not guaranteed prefix-shaped (an end may persist possession with holes
— e.g. F-3's fsync audit drops a chunk it could not durably write) and
because a future carriage may not be ordered. Bitmap ceiling: 1,024
bytes = 8,192 chunks describable past the first hole (512 MiB of span
at the default chunk size). The rule that keeps the ceiling safe:
**under-claiming is always legal** — a receiver whose holes outrun the
window simply omits possession it cannot describe, and the sender
re-sends some chunks the receiver already holds; duplicates on resume
boundaries are tolerated by the receiver (already-held chunks arriving
from an under-claimed map are dropped and counted, not violations),
and the digest arbitrates the finish line regardless.

**What does NOT resume:** credit (session-scoped, re-granted at
accept), ARQ state (dies with the session by design), and verification
state (a resumed-complete transfer re-verifies — the digest is cheap
insurance exactly when a teardown interrupted the finish).

## 6. Capability key 11, and the consent posture

**Key 11, `bulkTransfer`, bool, riding the W7 forward-compat spine**
through `unknownEntries` as one canonical `0B F5` map entry — the key-9
and key-10 precedent, third verse: zero frozen bytes move,
capabilities-v1.json never regenerates, and the capability survives
intersection only on mutual byte-equal declaration. Deliberately NOT
`featureChannels` (key 5, id 2 "files") even though this slice finally
builds the chan ≥ 8 architecture that id promises: key 5's ids are
typed-set members whose fold-in semantics belong to the D-5
wire-version discussion, and key 11 gates the *mechanism* (the bulk
channel) while the file-drop *feature* is what the ends expose over it
— when clipboard v2 images ride the same channel in H4, they gate on
key 11 plus their own consent tier, not on "files".

Declaration is dialect, not consent (the clipboard rule verbatim): both
v1 ends declare key 11 when built with this slice; whether a given
OFFER is welcome is the receiving end's standing per-host toggle, and
the answer travels as `abort(declined)`. Direction gating is the same
posture: a v1 host never sends an offer, and a v1 client receiving one
declines it — no wire bytes encode "client→host only", so v2 flips the
gate without touching frozen vectors.

**One transfer at a time per direction (v1).** The engines are
single-transfer by construction (one engine instance = one transfer);
the ends' dispatcher answers a second concurrent offer with
`abort(busy)` and queues locally. Multiplexing is a v2 conversation the
vocabulary is already shaped for (every message carries the id).

## 7. The engines — sans-IO state machines, both roles

`BulkSendEngine` and `BulkReceiveEngine` (Wire/Sources/LyteWire/
BulkEngines.swift): pure value types, no clocks (deliberate ruling: the
bulk layer has no timers — retransmission and liveness are ARQ's and
the session layer's, consent latency is a human's; an engine consumes
peer messages and shell verdicts and emits actions), randomness only at
id mint (`BulkTransferId.mint(using:)`, injected generator). The ends
drive them with real IO later: every disk read, disk write, and hash is
an ACTION the engine requests and a verdict the shell reports back.

**Sender** (idle → offering → transferring → awaitingVerification →
completed | aborted): `begin()` emits the offer; accept sets
possession + credit and starts the read/dispatch loop (ascending
indices, skipping known possession, credit-gated at read-issue time);
`supplyChunk(index:data:)` turns a shell read into a chunk message;
acks merge possession monotonically and extend credit; possession
covering every chunk parks the engine awaiting the receiver's verify;
complete/abort terminate. `cancel()` emits `abort(cancelled)` any time
before terminal. Local API misuse throws (`BulkSendError`); remote
misbehavior emits `.violated(…)` + `abort(protocolViolation)` and
terminates — never traps.

**Receiver** (awaitingOffer → offered → receiving → verifying →
completed | aborted): an offer (resume-matched against the injected
`BulkResumeState` book) surfaces as `.offered(offer, resuming:)` for
the shell's consent verdict; `accept()`/`decline()` answer it; each
in-credit, in-range, correctly-sized, novel chunk becomes a
`.store(index:data:)` action and `chunkStored(index:)` advances
possession and the credit clock; completion emits the final ack plus
`.verify`, and `verificationResult(digest:)` becomes complete (match)
or `abort(shaMismatch)`. `storageFailed()`, `cancel()`, and the
violation path mirror the sender. `resumeState` is readable in any
mid-flight state — persisting it at teardown is the end's one resume
obligation.

Enforcement lives receiver-side where the memory is: chunks beyond
granted credit, out-of-range indices, wrong sizes, and duplicates
(outside the under-claim tolerance, §5) are violations that abort the
transfer — a hostile sender can waste its own credit, never the
receiver's memory.

## 8. Vectors and tests — frozen at birth

**`bulk-v1.json`** (new frozen file; the clipboard-file precedent —
appending to control-v1.json is legal but a new file keeps the existing
14 untouched), authored by the new `lyte-wire-vectorgen bulk`
subcommand, anchored against hand-computed bytes in `BulkCodecTests`
(the ControlCodec precedent — the codec never grades its own homework).
Three sections:

- `messageVectors` — roundtrip/decodeReject over `messageHex` for all
  six codecs: every layout's nominal anchor, the geometry edges
  (min/max chunk size, max name/mime, the exact 131,072 B chunk-data
  ceiling, the exact 1,024 B bitmap ceiling, credit 0), the abort
  reason space whole, and every `BulkMessageError` case name at least
  once.
- `capabilityVectors` — the key-11 spine as data: declared, absent,
  and composed beside keys 9 and 10 (frozen wireDefault bytes plus
  exactly the appended entries; the "no frozen bytes moved" claim as
  bytes).
- `transferVectors` — worked multi-session transfers, pinned
  self-consistent (the noise-transport provenance discipline: no
  external oracle can cover our composition; the codecs beneath are
  anchored by hand): the full per-direction message traces of (a) a
  two-session resume-after-teardown mid-transfer, (b) a resume from a
  holed possession map exercising the bitmap, driven by the
  deterministic TestKit replay harness both vectorgen and the suite
  share. Byte-exact on macOS AND Linux, per gate.

**Tests** (the long-pole bar: thoroughness over speed): codec pins with
hand-built anchors and full reject coverage; vector-file identity +
coverage-discipline + byte-exact replay; engine round-trips in virtual
time — happy path, teardown-resume-completes-sha-exact (TestKit Sha256
at the finish line), holed-map resume, backpressure under a stingy
window-1 receiver and under a slow disk (un-stored in-flight provably
bounded), zero-credit accept-then-release, abort all four ways
(sender cancel, receiver decline / storage failure / sha mismatch),
violation handling, credit monotonicity against stale acks; and the
composition proof — two bulk engines over two real chan-8 ArqEndpoints
through SimNet loss/reorder storms in virtual time, transfer completes
sha-exact, which is the "ARQ carries bulk" ruling made executable. The
no-Foundation lint stays green (nothing here imports anything).

## 9. What F-3 and F-4 build against

- The frozen `bulk-v1.json` — never regenerate; new cases append.
- Host (F-3, receiver): an `ArqEndpoint` on chan 8 + `BulkReceiveEngine`
  behind the consent toggle; actions map to tmp-file writes
  (fsync before `chunkStored`), the verify action to a streaming
  SHA-256 of the tmp file, complete to the atomic rename; persist
  `resumeState` on teardown keyed by transferId. `abort(declined)` when
  the toggle is off; `abort(busy)` for a second offer.
- Client (F-4, sender): `BulkSendEngine` per dropped file; mint the id
  once and keep it with the file handle for re-offer after
  blackout/reconnect; `readChunk` actions map to file reads; the
  control-strip progress/cancel drive `cancel()` and read the progress
  accessors. Send-side pacing falls out of `.bulk`'s ladder rank —
  the client's sender must honor `WirePriority.bulk` in its dispatch
  order so the R-G8 audio bar holds during transfer.
