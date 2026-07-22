# LyteWire test vectors

These files are first-class, versioned wire-contract artifacts (master plan
§4.12), not test fixtures: the client's `LyteTransport` (CL-1) verifies its
codecs against exactly these bytes before the host ever sends a datagram,
and `Wire/Tests` verifies `LyteWire` against them on macOS and Linux —
byte-exact equality on both platforms is part of gate W-G1.

**Freeze policy.** A committed vector file is frozen. If the codec and a
vector ever disagree, that is a wire-contract break to investigate — never a
prompt to regenerate. New cases append; changed semantics mean a new file
version (`envelope-v2.json`) and a wire-version discussion first. The
authoring tool (`swift run lyte-wire-vectorgen <envelope|fec|video> <path>`)
exists for adding files, and its output is anchored against hand-computed
bytes in `EnvelopeTests`/`FecFieldTests` (and the k=1,m=1 parity-identity
case in `FecCoderTests`, the hand-walked datagram in
`VideoPacketizerTests`) so the codec never grades its own homework.

## Files

- `envelope-v1.json` — envelope + TLV codec vectors for wire major
  version 1, plus the (chan, seq) serial-arithmetic table.
- `fec-v1.json` — fec-field codec vectors, the resiliency §5.2 parity
  ladder as data, and RS recovery matrices (W1).
- `video-v1.json` — video-interior vectors (W2): packetize vectors
  (frame → frozen shard datagrams) and assembly scenarios (scripted
  delivery → expected DecodeUnits and decision outputs).
- `video-corpus-v1/` — real HEVC access units from the H0a host, the
  golden corpus the video vectors pin by sha256 (own README inside).
- `beacon-v1.json` — the W4a codecs: CTRL clock-beacon pair and the
  chan=3 feedback report, plus the offset/RTT worked example.
- `noise-v1.json` — the W5 crypto layer (gate W-G6): external published
  `Noise_IK_25519_ChaChaPoly_SHA256` handshake vectors (snow +
  cacophony) plus the pinned Lyte transport-extension vectors
  (extended-counter nonces, epoch rekey). Provenance rules below.
- `session-v1.json` — the promoted end-side session codecs (the
  codec-unification slice): path challenge/response CTRL 0x03/0x04
  (HS-12), the IDR request CTRL 0x10 (CL-3/HS-7, reconciled), and the
  conn-id TLV 0x01 value codec riding whole envelope datagrams. Format
  mirrors the beacon file (`roundtrip`/`decodeReject` over `messageHex`,
  typed fields per codec, `error` = the codec's error-case name);
  anchored against the hand-computed bytes in `SessionCodecTests`. The
  Noise handshake carriage 0x05/0x06 needs no vectors of its own — the
  payload is the type byte followed by the raw Noise message, whose
  bytes noise-v1.json already pins.
- `arq-v1.json` — the W3 reliable-sublayer frame formats: the data
  segment 0x07, the ACK 0x08, and the frame-sequence payload rule.
  Anchored against the hand-computed bytes in `ArqCodecTests`.
- `lifecycle-v1.json` — the W4b session-lifecycle CTRL messages: the
  ACTIVE⇄IDLE mode transition 0x09 and the typed session teardown
  0x0A, the first ARQ-carried CTRL types. Anchored against the
  hand-computed bytes in `SessionLifecycleCodecTests`.
- `pairing-v1.json` — the W6 CPace PIN-PAKE (gate W-G7): external
  draft-irtf-cfrg-cpace-21 vectors (CPACE-X25519-SHA512, appendix
  A/B.1 plus the B.1.10 low-order table), the pinned PairingPake
  exchange runs, and the pairing CTRL codecs 0x0B–0x0E. Provenance
  rules below.
- `capabilities-v1.json` — the W7 capability layer (gate W-G8): the
  deterministic CBOR profile, the typed capability set and its
  unknown-key rules, the intersect algebra frozen as data, and the
  capability CTRL codecs 0x0F/0x11/0x12. Anchored against RFC 8949's
  appendix-A examples (transcribed in `CborTests`) and the
  hand-computed set/message bytes in `CapabilitiesTests` /
  `CapabilityCodecTests`.
- `retry-v1.json` — the stateless retry cookie (HS-9's deferred
  msg1-flood hardening; core plan §5): the RetryCookie transcript MAC
  frozen as data (mint bytes, lifetime window, tuple/msg1 binding,
  secret rotation) plus the retry CTRL codecs 0x13/0x14. Anchored
  against the hand-built layouts in `RetryCodecTests` and, for the MAC
  itself, an independent RFC 2104 HMAC-SHA256 built over TestKit's
  FIPS-verified `Sha256` in `RetryCookieTests`. Details below.

## The 24-byte envelope (wire v1)

All multi-byte fields little-endian. The header (these 24 bytes plus the
optional TLV block) rides as AAD once crypto lands (W5); the payload is the
AEAD ciphertext + 16 B tag, or the bare shard in `--insecure` mode.

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | chan | 0 CTRL, 1 audio, 2 video-active, 3 feedback/telemetry, 4 video-idle, 5–7 reserved, 8+ features |
| 1 | 1 | flags | bit0: TLV block present; bits 1–7 reserved — 0 on send, ignored on receive |
| 2 | 2 | seq | per-channel serial u16 (RFC 1982-shaped comparison; see `seqComparisons`) |
| 4 | 4 | frame | frame number / audio packet number / FEC group id |
| 8 | 8 | timestamp | µs; host PipeWire monotonic domain host→client, client monotonic client→host |
| 16 | 8 | fec | interior layout below (pinned at W1, `FecField.swift`) |
| 24 | … | TLV block (if flags bit0), then payload | |

TLV block: `count:u8 (type:u8 len:u8 value)*`. Unknown TLV types MUST be
skipped by consumers and are preserved verbatim by the codec. Reserved
types, pinned at W0 for later slices: `0x00` invalid (never assigned),
`0x01` connection ID (migration, Lyte-UDP decision §8.4), `0x02` wire major
version (first handshake datagram, §8.3 — replaces ALPN).

Byte budgets, enforced at encode time and covered by reject vectors:
plaintext shard ≤ **1112 B**, wire payload (ciphertext + tag) ≤ **1128 B**,
datagram ≤ **1152 B**. TLV bytes count against the datagram budget.

## File format

Top-level: `format` ("lyte-wire-envelope-vectors"), `formatVersion` (1),
`wireVersion` (1), `vectors`, `seqComparisons`.

`timestampHex`/`fecHex` are hex strings because u64 values do not survive
JSON number precision. `payloadHex`/`datagramHex`/TLV `valueHex` are plain
lowercase hex. Long payloads use a counting byte pattern
(`byte[i] = (start + i) & 0xFF`) so a hex dump is auditable by eye.

Each vector's `kind` selects the check:

- `roundtrip` — encoding `envelope` + `payloadHex` must produce exactly
  `datagramHex`; decoding `datagramHex` must produce `envelope` +
  `payloadHex`.
- `decodeLenient` — `datagramHex` must decode to `envelope` + `payloadHex`,
  but is a non-canonical encoding (reserved flag bits set, empty TLV block):
  decode-only, no byte-exact re-encode.
- `encodeReject` — encoding `envelope` + `payloadHex` through `encoder`
  (`payload` or `plaintextShard`) must fail with `error`.
- `decodeReject` — decoding `datagramHex` must fail with `error`.

`error` names are the `WireError` case names: `truncatedEnvelope`,
`truncatedExtensions`, `shardOverBudget`, `payloadOverBudget`,
`datagramOverBudget`.

`seqComparisons` rows pin the serial arithmetic: `aBeforeB` is
`ChannelSeq(a) < ChannelSeq(b)`, `distance` the signed serial distance a→b.
The two rows exactly `0x8000` apart document the one unordered case (both
comparisons false, distance reports −32768 from either side).

## The 8-byte fec field (wire v1)

The envelope's offset-16 u64, interior pinned at W1. Byte n below is bit
range [8n, 8n+8) of the little-endian u64 — `Envelope` owns the byte order
on the wire, this table owns the interior:

| byte | field | notes |
|---|---|---|
| 0 | shardIndex | 0…k−1 data shards in group byte order, k…k+m−1 parity |
| 1 | dataShards | k, 1…255 |
| 2 | parityShards | m, 0…255−k (one RS block ≤ 255 total shards, GF(2⁸)) |
| 3 | scheme | 0x00 none, 0x01 Reed-Solomon GF(2⁸) (nanors codebook); others reject |
| 4–6 | groupByteCount | u24: total payload bytes across the group's k data shards |
| 7 | reserved | MUST be 0 on send, ignored on receive |

Scheme `none` is the all-zero field (byte 7 excepted); non-zero geometry
bytes under scheme none are rejected as malformed. The FEC group is bound
by the envelope `frame` field; this field carries only the shard's place
within it. Shard split is **balanced**: shardByteCount = ceil(group / k),
every shard except the trailing data shard is exactly that size, the
trailing shard carries the remainder unpadded (parity shards are always
full size), and a geometry whose trailing shard would be empty is invalid.

## File format: fec-v1.json

Top-level: `format` ("lyte-wire-fec-vectors"), `formatVersion` (1),
`wireVersion` (1), `fieldVectors`, `geometryRows`, `recoveryMatrices`.

`fieldVectors` mirror the envelope kinds: `roundtrip` (field ↔ `rawHex`
byte-exact both ways), `decodeLenient` (non-zero reserved byte 7 decodes,
re-encode differs), `decodeReject` (decoding `rawHex` throws `error`,
a `FecError` case name). `rawHex` is the u64 value in hex, same
convention as the envelope file's `fecHex`.

`geometryRows` freeze the resiliency §5.2 adaptive parity ladder as data:
(`dataShards`, `regime` clean|lossy) → `parityShards`, null where no
ladder ratio fits the 255-shard block (lookup throws; clean protects
k ≤ 231, lossy k ≤ 204 — `frameByteCeiling` derives from these).

`recoveryMatrices` freeze the C leaf's bytes: `FecEncoder` on `groupHex`
must produce `shardsHex` byte-exact; decoding with `erasedIndices` nil'd
out must return `groupHex` byte-exact (`expect` "recovered") or throw
`unrecoverableGroup` (`expect` "unrecoverable") — honest failure, never
garbage. Byte-identical matrices on macOS and Linux are gate W-G2's
cross-platform requirement.

## Vector inventory (fec-v1.json, 17 field vectors + 32 geometry rows + 10 matrices)

Field round trips: `none` (all-zero), `rs-nominal-parity-shard` (the
hand-computed anchor: k=4 m=2 over 4000 B, shard 5),
`rs-nominal-first-data-shard`, `rs-tiny-frame` (k=1 m=1, 100% parity),
`rs-audio-4-2` (the W8 shape), `rs-parity-free` (m=0 mechanism),
`rs-max-block` (k=204 m=51, 255 shards, shard 254).

Field lenient decodes: `rs-reserved-byte-ignored`,
`none-reserved-byte-ignored`.

Field decode rejects: `unknown-scheme`, `non-zero-none`,
`zero-data-shards`, `over-gf256-block` (k=200 m=60),
`group-over-budget` (k=1, 1113 B), `zero-group-bytes`,
`over-provisioned-shards` (k=4 over 5 B), `shard-index-out-of-range`.

Geometry rows: both regimes at k = 1, 2, 3, 4, 5, 8, 9, 20, 32, 33, 100,
204, 205, 231, 232, 255 — every bucket edge plus the GF(2⁸) truncation
points.

Recovery matrices: `k4m2-all-present` (pins the reference parity bytes),
`k4m2-data-erasures-1-3`, `k4m2-mixed-erasure`,
`k4m2-parity-only-erasures` (fast path), `k4m2-unrecoverable` (3 erased,
honest failure), `k3m1-trailing-pad` (short shard recovered and
trimmed), `k1m1-identity` (parity = data, the eye-verifiable anchor),
`k1m2-tiny-lossy`, `k5m2-balanced-split` (53 B over k=5),
`k2m1-full-budget-shards` (2 × 1112 B, the budget interaction).

## Vector inventory (envelope-v1.json, 17 vectors)

Round trips: `nominal-video-shard` (the hand-computed anchor),
`nominal-audio`, `empty-payload` (0 B), `max-plaintext-shard` (1112 B),
`max-wire-payload` (1128 B → exactly 1152 B datagram), `seq-wrap-high`
(seq 0xFFFF) / `seq-wrap-low` (0x0000), `tlv-reserved-types`
(connectionId + wireVersion), `tlv-unknown-skipped` (type 0x7F).

Lenient decodes: `reserved-flag-bits-ignored`, `tlv-flag-empty-block`.

Encode rejects: `shard-over-budget` (1113 B), `payload-over-budget`
(1129 B), `datagram-over-budget-tlv` (TLV pushes total past 1152 B).

Decode rejects: `truncated-envelope` (23 B), `truncated-tlv-block`,
`oversize-datagram` (1153 B).

## File format: video-v1.json

Top-level: `format` ("lyte-wire-video-vectors"), `formatVersion` (1),
`wireVersion` (1), `frames`, `scenarios`.

`frames` are packetize vectors: `VideoPacketizer` on the source bytes
(with the vector's frameNumber, `timestampHex` µs, isIDR, regime,
firstSeq) must produce exactly the listed shards — seq and `fecHex`
field-exact, full `--insecure` datagram (header + bare shard) matching
`datagramSha256`, and `datagramHex` byte-exact where present. Inline
sources carry `annexBHex` (counting-byte filler, auditable by eye);
corpus sources name a `video-corpus-v1/` file pinned by sha256 —
hash-only to keep the repo lean, with the hash covering the whole
datagram (envelope bytes included), so header drift is as loud as
payload drift. Seq allocation is contiguous ascending in shard-index
order across each frame's k+m shards — that contiguity is wire contract
(the assembler infers a group's full seq range from any one shard).

`scenarios` are assembly scripts over those frames: deliver `steps`
(frame name + shardIndex; omitted indices are lost, repeats are
duplicate datagrams) in order at one injected instant into a
default-config `VideoAssembler`, then one `evictStale` tick at
`finalTickMicroseconds` when set. Assertions: decoded units come out
exactly as `expectDecoded` in that order, each byte-identical to its
source with the vector's frameNumber/timestamp/isIDR; the
`expectFecImpossible` frames (and only they) raise the fec-impossible
event. Anchored against the hand-walked datagram in
`VideoPacketizerTests.testHandWalkedTinyFrame`.

## Vector inventory (video-v1.json, 9 frames + 10 scenarios)

Frames: `inline-tiny-idr` (48 B, k=1 m=1), `inline-p-k3` /
`inline-p-k3-lossy` (2500 B, k=3 m=2 both regimes), `inline-p-tail`
(follow-on traffic), `inline-p-seq-wrap` (k=2 m=1 across the u16 wrap,
seqs 0xFFFF 0x0000 0x0001), `corpus-idr` (18400 B, k=17 m=3, carries
VPS/SPS/PPS), `corpus-p-large` (20786 B, k=19 m=3), `corpus-p-small`
(4367 B, k=4 m=2), `corpus-p-small-lossy` (same bytes, lossy regime).

Scenarios: `in-order-tiny-idr`, `shuffled-k3`, `loss-at-parity-limit-k3`,
`duplicates-k3`, `seq-wrap-loss`, `interleaved-frames-emit-in-order`
(late stragglers must not draw a write-off), `fec-impossible-then-eviction`
(the CL-3 IDR-request trigger plus stale eviction), `corpus-idr-in-order`,
`corpus-sequence-with-loss` (parity-limit loss under G4-model reorder),
`corpus-small-p-lossy-regime`.

## The CTRL message-type registry and the clock-beacon pair (wire v1)

Every CTRL (chan 0) payload starts with one message-type byte — in
today's bare datagrams and, once W3 lands, at the start of each
ARQ-framed message body alike. Types pinned at W4a: `0x00` invalid
(never assigned, the zero-fill rule), `0x01` clock beacon, `0x02` beacon
echo. The beacon pair is ARQ-exempt fire-and-forget by design (master
plan §4.6): clock mapping wants fresh timestamps, not reliable old ones —
a lost beacon is superseded by the next 1 Hz send. It is the ONE beacon
(clock mapping + slow liveness); the 350 ms blackout detector is
feedback-stream silence, a different mechanism.

ClockBeacon (host→client, 1 Hz plus session start), fixed 34 bytes,
little-endian:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x01 |
| 1 | 1 | flags | bit0: lastEcho populated; bits 1–7 reserved — 0 on send, ignored on receive |
| 2 | 4 | beaconSeq | u32, from 0 at session start |
| 6 | 8 | hostSend | t1: host PipeWire monotonic µs at send |
| 14 | 4 | lastEchoBeaconSeq | the echo this beacon reports |
| 18 | 8 | lastEchoClientSend | its t3, echoed verbatim (client µs) |
| 26 | 8 | lastEchoHostReceive | its t4, measured at arrival (host µs) |

With flags bit0 clear the lastEcho fields MUST be zero; non-zero bytes
there reject (the fec-field none rule). Truncation and trailing bytes
reject — the message is exactly its layout.

BeaconEcho (client→host, one per beacon), fixed 29 bytes:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x02 |
| 1 | 4 | beaconSeq | copied from the beacon |
| 5 | 8 | hostSend | t1, copied verbatim |
| 13 | 8 | clientReceive | t2: client µs at beacon arrival |
| 21 | 8 | clientSend | t3: client µs at echo send |

t4 (host receive) is measured locally by the host, never on the wire.
Offset and RTT from one pair, the classic four-timestamp shape feeding
CL-10's HostClockModel (min-filtered offset + regression skew):

```
rtt    = (t4 − t1) − (t3 − t2)
offset = ((t2 − t1) + (t3 − t4)) / 2        (client − host, µs)
```

Worked example (`clockWorkedExample` in the file, checked by test): true
offset 250,000 µs, forward path 3,000 µs, reverse 5,000 µs, turnaround
500 µs → t1=1,000,000 t2=1,253,000 t3=1,253,500 t4=1,008,500, so
rtt = 8,500 − 500 = **8,000 µs** and offset = (253,000 + 245,000) / 2 =
**249,000 µs** — 1,000 µs shy of truth, exactly the path asymmetry / 2
the timing doc's min-filter accepts.

## The chan=3 feedback report (wire v1)

The whole payload of every 25–50 ms client→host feedback datagram
(telemetry class, unreliable by design — a lost report is superseded).
Fixed 21-byte header, little-endian:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | pathId | 0 in v1 (resiliency §6), carried verbatim |
| 1 | 1 | flags | bit0: TLV block present; bits 1–7 reserved |
| 2 | 8 | clientTimestamp | client µs at report build |
| 10 | 8 | dispersionBase | client µs base for sample deltas; MUST be 0 when sampleCount is 0 |
| 18 | 1 | channelBlockCount | 0…8 |
| 19 | 1 | sampleCount | 0…112 |
| 20 | 1 | nackCount | 0…6 |

then, in order: channel blocks (15 B each: `chan:u8 highestSeq:u16
received:u32 missing:u32 duplicates:u32`, cumulative session counters),
dispersion samples (6 B each: `chan:u8 seq:u16 arrivalDelta:u24` µs past
the base — RFC 8888-style per-packet arrivals for the burst-dispersion
estimator), NACK entries (`frame:u32 bitmapByteCount:u8 bitmap`, bit n
set = shard index n missing; 1…32 bytes, canonical: sized by the highest
set bit, zero final byte rejects), and the envelope's exact TLV scheme
when flags bit0 (`count:u8 (type:u8 len:u8 value)*`, unknown types
skipped by consumers, preserved by the codec) — the v1.x escape hatch.
Trailing bytes reject; over-bounds counts reject on the count byte.

Bounds rationale: 112 samples cover a worst-case protected IDR train
(~80 data + ~20 parity shards) plus the 10-packet audio probe of a 50 ms
window; 6 NACK entries — more FEC-impossible frames in flight than that
is IDR-request territory; 8 channel blocks = 5 registered channels plus
feature headroom. All bounds maxed the structural encoding is **1035 B**
(21 + 8×15 + 112×6 + 6×37), inside the 1112 B plaintext shard budget
with 77 B of TLV headroom; encode additionally enforces the 1112 B
ceiling against fat TLV sets.

## File format: beacon-v1.json

Top-level: `format` ("lyte-wire-beacon-vectors"), `formatVersion` (1),
`wireVersion` (1), `beaconVectors`, `feedbackVectors`,
`clockWorkedExample`.

`beaconVectors` carry `decoder` ("beacon" or "echo") plus the envelope
file's kinds (`roundtrip`, `decodeLenient`, `decodeReject`) over
`messageHex`; struct fields ride as `beacon`/`echo` objects with hex
u64 timestamps. `feedbackVectors` mirror the envelope kinds including
`encodeReject` over `report`/`reportHex`. `error` names are
`BeaconError`/`FeedbackError` case names. `clockWorkedExample` pins the
computation above: decoding `echoHex` plus the local `hostReceiveHex`
must yield exactly `offsetMicroseconds`/`rttMicroseconds`.

## Vector inventory (beacon-v1.json, 13 beacon + 19 feedback + 1 example)

Beacon round trips: `beacon-first` (session start, no echo, flags 0),
`beacon-steady` (the hand-computed anchor), `beacon-seq-max` (u32/u64
maxima), `echo-nominal` (the anchor), `echo-worked-example`.

Beacon lenient decode: `beacon-reserved-flags-ignored`.

Beacon decode rejects: `beacon-truncated` (33 B), `beacon-trailing-byte`
(35 B), `beacon-bad-type` (echo type at beacon length),
`beacon-nonzero-absent-echo`, `echo-truncated`, `echo-trailing-byte`,
`echo-bad-type` (0x7f).

Feedback round trips: `feedback-nominal` (the hand-computed anchor,
80 B), `feedback-empty-sections` (21 B header only),
`feedback-bounds-maxed` (1035 B structural ceiling),
`feedback-full-budget` (maxed + 74 B TLV = exactly 1112 B).

Feedback lenient decode: `feedback-reserved-flags-ignored`.

Feedback encode rejects: `feedback-too-many-channels` (9),
`feedback-too-many-samples` (113), `feedback-too-many-nacks` (7),
`feedback-delta-overflow` (2²⁴ µs), `feedback-over-budget-tlv` (1113 B).

Feedback decode rejects: `feedback-truncated-header` (20 B),
`feedback-truncated-sections`, `feedback-sample-count-over-bounds`
(count byte 200), `feedback-nonzero-base-no-samples`,
`feedback-nack-bitmap-count-zero`, `feedback-nack-bitmap-count-oversize`
(33), `feedback-nack-bitmap-noncanonical` (zero final byte),
`feedback-trailing-bytes`, `feedback-truncated-tlv`.

## The ARQ frames (wire v1)

The reliable ordered-retransmit sublayer (W3) that CTRL, video-idle,
and the feature channels ride. Two frame types in the CTRL type space,
used identically on every reliable channel: a reliable-channel datagram
payload starting with 0x07 or 0x08 is wholly ARQ — a SEQUENCE of
self-delimiting frames (an ACK piggybacks ahead of fresh segments in
one datagram). Messages the ARQ delivers start with their own CTRL
type byte; ARQ-exempt CTRL traffic (beacons, path messages, handshake
carriage, IDR requests) never starts with 0x07/0x08, so the shell's
one-byte peek routes cleanly.

Sequencing is **group-scoped**, not channel-scoped: envelope seqs on a
reliable channel are shared with ARQ-exempt traffic, so each group
numbers its own segments with a serial u16 from 0 (wire v1). Group 0 is
the channel's long-lived ordered message stream; non-zero groups are
independent one-shot message groups (sparse idle frames, the final
ratchet frame), ids caller-allocated ascending per direction — a
fully-lost group leaves no hole in any other group's sequence space,
which is the no-cross-group-HOL ruling (decision record §8.1) as
arithmetic. Retransmission unit is the SEGMENT, re-sent byte-identical
inside a fresh datagram (fresh envelope seq, fresh AEAD nonce) — the
core-plan pin §2.2's guarantees (no nonce reuse, single admission, no
ACK ambiguity) preserved while clearing the Noise replay-window
liveness hazard a byte-identical datagram resend would hit.

Data segment (type 0x07), fixed 8-byte header then body, little-endian:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x07 |
| 1 | 1 | flags | bit0: endOfMessage; bits 1–7 reserved — 0 on send, ignored on receive |
| 2 | 2 | group | u16; 0 = ordered stream, non-zero = one-shot |
| 4 | 2 | segSeq | u16 group-scoped serial |
| 6 | 2 | bodyLen | 1…1104 (zero-length bodies reject — the fill-bug rule) |
| 8 | … | body | |

ACK (type 0x08), 3-byte header then 1…16 blocks. ACKs are themselves
ARQ-exempt: a lost ACK is superseded by the next (the receiver re-ACKs
on every arrival, duplicates included).

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x08 |
| 1 | 1 | flags | reserved — 0 on send, ignored on receive |
| 2 | 1 | blockCount | 1…16 |

Block (6 + bitmapLen bytes): `chan:u8 group:u16 cumulative:u16
bitmapLen:u8 bitmap`. Every segSeq serially ≤ cumulative was received
("nothing yet" = initial − 1); bitmap bit n (byte n/8, bit n%8) set
means segSeq cumulative+1+n received. Canonical: sized by the highest
set bit, zero final byte rejects; 32 bytes cap the describable receive
window at 256 segments. A truncated frame, an unknown frame type where
a frame must start, and trailing garbage after the last frame all
reject — the payload is exactly its frames.

## File format: arq-v1.json

Top-level: `format` ("lyte-wire-arq-vectors"), `formatVersion` (1),
`wireVersion` (1), `vectors`. Each vector's `payloadHex` is a whole
reliable-channel datagram payload; `roundtrip` decodes to exactly the
typed `frames` (each `{segment:{group, seq, endOfMessage, bodyHex}}` or
`{ack:{blocks:[{chan, group, cumulative, bitmapHex}]}}`) and re-encodes
byte-exactly; `decodeLenient` decodes (reserved flag bits set) but
re-encodes differently; `decodeReject` throws `error`, an
`ArqFrameError` case name.

## Vector inventory (arq-v1.json, 21 vectors)

Round trips: `segment-nominal` (the hand-computed anchor),
`segment-stream-first` (group 0, seq 0, mid-message),
`segment-max-body` (1104 B — the frame fills the 1112 B shard budget
exactly), `segment-seq-wrap-high` (seq 0xFFFF), `ack-nominal` (the
hand-computed anchor: cumulative + bitmap bits 0 and 2),
`ack-nothing-in-order` (cumulative = initial − 1 with an out-of-order
bit), `ack-two-blocks`, `coalesced-ack-then-segments` (the
frame-sequence rule as bytes).

Lenient decodes: `segment-reserved-flags-ignored`,
`ack-reserved-flags-ignored`.

Decode rejects: `empty-payload`, `unknown-frame-type`,
`segment-truncated-header`, `segment-truncated-body`,
`segment-zero-length-body`, `trailing-garbage-after-frame`,
`ack-zero-blocks`, `ack-too-many-blocks` (17), `ack-bitmap-too-long`
(33), `ack-bitmap-noncanonical` (zero final byte),
`ack-truncated-block`.

## The session-lifecycle messages (wire v1)

The W4b CTRL types — the first messages that ride the ARQ ordered
stream (group 0) rather than bare datagrams, which is what makes their
ordering guarantees real: a mode flip can never reorder against the
messages around it, and a teardown can never overtake the messages
that explain it. Both are exactly their fixed 2-byte layout: truncation
and trailing bytes reject, a foreign type byte rejects with what it
found.

Mode transition (type 0x09): `type:u8 mode:u8` — mode 0x01 ACTIVE,
0x02 IDLE; anything else rejects (`unknownMode`; 0x00 is the loud
zero-fill bug). ACTIVE⇄IDLE are the only wire modes: FROZEN/RECOVERY
are each end's local path-loss overlay (overview §2's mode-machine
ruling) and must never appear on the wire. The sender flips to IDLE
only after the converged frame's video-idle one-shot is acknowledged —
one-shot groups are unordered against the CTRL stream, so the ack is
what guarantees the receiver holds the frame before it learns the
session went idle.

Session teardown (type 0x0A): `type:u8 reason:u8` — reason 0x01
taken-over-by (the transport pillar's multi-client ruling), 0x02
shutting-down; anything else rejects (`unknownReason`). Liveness
timeouts (≥30 s without authenticated peer evidence) send nothing —
the peer that would read the message is the one that died.

## File format: lifecycle-v1.json

Top-level: `format` ("lyte-wire-lifecycle-vectors"), `formatVersion`
(1), `wireVersion` (1), `vectors`. Each vector carries `codec`
("modeTransition" or "sessionTeardown") plus the session file's kinds
over `messageHex`: `roundtrip` (typed `value` byte ↔ `messageHex`
byte-exact both ways) and `decodeReject` (`error`, a
`LifecycleMessageError` case name). The roundtrips pin the codecs'
ENTIRE legal value spaces — `LifecycleVectorFileTests` asserts the
file covers every enum case, so a value added to either enum without a
vector-file (and wire-version) discussion fails loudly.

## Vector inventory (lifecycle-v1.json, 14 vectors)

Round trips: `mode-active`, `mode-idle`, `teardown-taken-over`,
`teardown-shutting-down` — the complete value spaces.

Decode rejects: `mode-truncated`, `mode-trailing-byte`,
`mode-bad-type` (teardown byte at the mode decoder), `mode-zero`
(the zero-fill rule), `mode-unknown` (0x03 — FROZEN/RECOVERY never
ride the wire), `teardown-truncated`, `teardown-trailing-byte`,
`teardown-bad-type`, `teardown-zero`, `teardown-unknown` (0x7f).

## The pairing layer (wire v1)

Suite: **CPACE-X25519-SHA512** (draft-irtf-cfrg-cpace-21's recommended
small-message suite) in the initiator-responder setting — the client
is party A, the host party B; the symmetric o_cat ordering is
deliberately not implemented. X25519 and SHA-512 are swift-crypto's;
the Elligator 2 map onto Curve25519 (and the GF(2²⁵⁵−19) field
arithmetic beneath it) is hand-written in `Crypto/`, pinned by the
draft's own vectors.

Composition (Lyte-UDP decision §8.2 — "bind via TLS exporter" becomes
binding to the Noise transcript): pairing rides the sealed ARQ ordered
CTRL stream of the trust-on-first-use Noise session it authenticates,
with **sid = the Noise handshake hash** and **CI = lv_cat(
"lyte-pairing-v1", client static, host static)** — the exact
identities being pinned, initiator first (draft §10.1). Explicit key
confirmation (§10.4: mac_key = H(b"CPaceMac" ‖ sid ‖ ISK), tags =
HMAC-SHA-512 over each side's lv_cat(Y, AD)) rides inside the
messages, so wrong PIN and MITM'd session fail identically and loudly,
and the transcript yields nothing offline-testable. On success each
shell pins the statics the Noise session already carried; every later
connect is plain Noise IK against the pinned static.

Messages (CTRL types, fixed layouts, truncation/trailing/foreign-type
reject): 0x0B share A = `type ‖ Ya(32)`; 0x0C share B = `type ‖ Yb(32)
‖ Tb(64)`; 0x0D confirm = `type ‖ Ta(64)`; 0x0E reject = `type ‖
reason` (0x01 confirmation-failed — wrong PIN and tampered binding
share one value on purpose, 0x02 invalid-share, 0x00 the loud
zero-fill bug). A share that scalar_mult_vfy maps to G.I (low-order
point on curve or twist) aborts the run before any tag math.

## File format: pairing-v1.json

Top-level: `format` ("lyte-wire-pairing-vectors"), `formatVersion` (1),
`wireVersion` (1), `draftVectors`, `exchangeVectors`, `messageVectors`.

**Provenance honesty — the noise-v1 discipline.**

`draftVectors` are **external canonical vectors**, transcribed verbatim
from draft-irtf-cfrg-cpace-21 (`source` URL + `sourceSha256` of the
exact upstream txt, fetched 2026-07-22): the appendix-A string
utilities (prepend_len at the LEB128 boundary, lv_cat,
transcript_ir), the B.1.1 calculate_generator chain (generator string
and mapped generator), the B.1.2–B.1.5 exchange (both shares, K, and
ISK_IR), and the B.1.10 scalar_mult_vfy table — u0…u5 and u7 MUST
yield the neutral element, u6/u8…ub are non-canonical bit-#255-set
encodings that MUST yield the listed points on BOTH platforms. A
divergence is an implementation bug — these values never regenerate.

`exchangeVectors` cover Lyte's PairingPake composition (handshake-hash
binding, CI from the statics, tags in the message layouts), which no
published set can cover because the composition is ours. They are
**pinned self-consistent** (`provenance` says so): counting-byte
inputs, replayed through the real initiator/responder machines — the
0x0B/0x0C/0x0D bytes and the ISK must match exactly.

`messageVectors` carry `codec` ("shareA"/"shareB"/"confirm"/"reject")
plus the lifecycle file's kinds over `messageHex`; `error` names are
`PairingMessageError` case names. Anchored against the hand-built
bytes in `PairingCodecTests`. `PairingVectorFileTests` asserts the
reject codec's whole value space is pinned.

## Vector inventory (pairing-v1.json, 12 low-order + 1 exchange + 14 message)

Draft sections: 4 prepend_len, 1 lv_cat, 2 transcript_ir, the B.1.1
generator chain, the B.1.2–B.1.5 exchange, the 12-row B.1.10 table.

Exchange: `pairing-nominal` (PIN "482913", counting-byte statics /
handshake hash / scalars).

Message round trips: `share-a-nominal`, `share-b-nominal`,
`confirm-nominal`, `reject-confirmation-failed`,
`reject-invalid-share` (the reject codec's complete value space).

Message decode rejects: `share-a-truncated`, `share-a-trailing-byte`,
`share-a-bad-type`, `share-b-truncated`, `confirm-bad-type`,
`confirm-trailing-byte`, `reject-truncated`, `reject-zero`,
`reject-unknown` (0x7f).

## The capability layer (wire v1)

The W7 "superpowers handshake" (transport pillar §4): right after
establishment, each end sends one capability declaration as the first
ARQ-carried CTRL message; the session's effective capabilities are the
INTERSECTION, computed identically on both ends. There is no accept
round — the intersection is the agreement. Capabilities are
session-scoped and fixed after the exchange except where the key
registry marks a key renegotiable.

**The CBOR profile.** Declaration bodies are deterministic CBOR
(RFC 8949 §4.2.1 core requirements) restricted to the Lyte capability
profile: unsigned/negative integers, byte and text strings, arrays,
maps with strictly-ascending bytewise-ordered keys, false/true/null.
No indefinite lengths, no tags, no floats. Non-shortest arguments and
misordered/duplicate map keys REJECT even when well-formed — two ends
that disagree about bytes are a wire bug the codec refuses to paper
over. Decode nesting is bounded at depth 8.

**The key registry** (CBOR unsigned map keys; numbers are wire
contract; `Capabilities.swift`):

| key | field | type | intersect |
|---|---|---|---|
| 1 | wireMinor (required) | u16 | min |
| 2 | videoCodecs (required) | ascending id list — 1 HEVC | set ∩ |
| 3 | chromaModes (required) | ascending id list — 1 4:2:0, 2 4:4:4 | set ∩ |
| 4 | idleSilence | bool | AND |
| 5 | featureChannels | ascending id list — 1 clipboard, 2 files, 3 printing | set ∩ |
| 6 | audioExpress | bool | AND |
| 7 | resume | bool | AND |
| 8 | maxDatagramBytes | u32 ≥ 1152 | min |

Forward compatibility, three rules: unknown KEYS are ignored (never a
decode error) and preserved verbatim; unknown VALUES inside id lists
are carried, not rejected (intersection with the local set drops
them); new semantics ship as new keys gated by intersection, so
absence is always "not supported", never an error. Unknown entries
survive intersection only when present in BOTH declarations with
byte-equal values — the rule that keeps the algebra idempotent.
Omitted optional keys decode to unsupported / the 1152 B floor;
required keys (1–3) missing reject. Empty videoCodecs or chromaModes
intersection is negotiation failure (`CapabilityNegotiator`).

**Renegotiation.** v1 marks exactly one key renegotiable:
`maxDatagramBytes` — the DPLPMTUD raise (overview §2), host→client
proposals only (the media sender owns geometry), one outstanding at a
time, values within [1152, agreed ceiling], applied at an IDR
boundary. The operative value starts at 1152 regardless of the agreed
ceiling. Everything else is connect-time only; a proposal naming a
fixed or unknown key draws a rejected ack, not a teardown.

Messages (CTRL types, all ARQ-carried on the ordered stream):
0x0F declaration = `type ‖ CBOR map` (the full set); 0x11 update =
`type ‖ CBOR map` (renegotiable keys only, non-empty); 0x12 update
ack = `type ‖ status ‖ CBOR map` (status 0x01 accepted / 0x02
rejected, 0x00 the loud zero-fill bug; the map echoes the proposal
verbatim so the answer binds to bytes). Any capability message over
1024 B rejects before CBOR work — the anti-streaming stop.

## File format: capabilities-v1.json

Top-level: `format` ("lyte-wire-capability-vectors"), `formatVersion`
(1), `wireVersion` (1), `cborVectors`, `setVectors`,
`intersectVectors`, `messageVectors`.

`cborVectors`: `canonical` — `cborHex` must decode and re-encode
byte-exact (canonical admission + deterministic re-emission in one
check); `decodeReject` — decoding throws `error`, a `CborError` case
name. The circularity is broken by RFC 8949's own appendix-A examples
transcribed into `CborTests`.

`setVectors`: `roundtrip` — `cborHex` decodes to a set matching the
typed `set` fields and re-encodes byte-exact (and with
`unknownKeyCount` 0, encoding the typed fields must produce `cborHex`
exactly); `decodeLenient` — legal but not byte-stable (omitted
optional keys re-encode explicit), decode-only; `decodeReject` —
`error` is a `CapabilityError` case name.

`intersectVectors`: decoding `aHex` and `bHex` and intersecting IN
BOTH ORDERS must produce exactly `agreedHex` — commutativity frozen
as data, not assumed.

`messageVectors`: `codec` ("declaration"/"update"/"updateAck") plus
`roundtrip` (decode `messageHex`, re-encode byte-exact) and
`decodeReject` (`error`, a `CapabilityMessageError` case name).
Anchored against the hand-computed bytes in `CapabilityCodecTests`.

## Vector inventory (capabilities-v1.json, 17 cbor + 9 set + 4 intersect + 15 message)

CBOR canonical: `unsigned-argument-widths` (every shortest-form width
in one array), `negative-and-simple`, `bytes-and-text`,
`nested-arrays`, `map-key-order` (integer keys before text keys).

CBOR decode rejects: `non-shortest-u8`, `non-shortest-u16`,
`misordered-map-keys`, `duplicate-map-key`, `indefinite-array`,
`tag`, `float`, `undefined`, `truncated-argument`, `trailing-bytes`,
`invalid-utf8`, `nesting-too-deep`.

Set round trips: `wire-default` (the hand-computed anchor),
`full-house` (every key non-default, a foreign codec id carried),
`unknown-key-preserved` (the unknown-key-ignored rule as bytes).
Set lenient decode: `required-keys-only` (optional keys defaulted).
Set decode rejects: `missing-video-codecs`, `wrong-type-minor`,
`descending-id-list`, `ceiling-below-floor`, `not-a-map`.

Intersects: `nominal-asymmetric` (full-house ∩ modest),
`identical-idempotent` (the idempotence law as bytes),
`disjoint-features` (empty feature agreement is fine),
`unknown-entries-byte-equal-rule` (equal foreign values survive,
differing ones drop).

Message round trips: `declaration-wire-default`,
`declaration-full-house`, `update-geometry-raise`, `ack-accepted`,
`ack-rejected`. Message decode rejects: `declaration-truncated`,
`declaration-bad-type`, `declaration-body-not-a-map`,
`declaration-over-budget` (1025 B), `update-empty-map`,
`update-text-key`, `update-non-canonical-body`, `ack-unknown-status`
(0x03), `ack-zero-status`, `ack-truncated`.

## The stateless retry cookie (wire v1)

The msg1-flood defense (core plan §5: "Core provides a stateless HMAC
retry-cookie codec for the first handshake datagram; the host shell
decides when to demand it") — QUIC Retry's shape without QUIC. Under a
Noise msg1 flood the host escalates from HS-9's token bucket to cookie
mode: each msg1 draws a RetryChallenge whose cookie is minted purely
from (client tuple, now, secret) — no per-client state — and only a
resubmission whose cookie verifies against the tuple it actually
arrived from gets to cost X25519.

Cookie interior, 24 bytes (opaque to the client, echoed verbatim; both
mint and verify are host-side, but the bytes travel so the layout is
wire contract): `timestamp u64 LE` (host monotonic ns at mint) ‖
`mac(16)` = HMAC-SHA256 truncated to 16 bytes over the transcript
`"lyte-retry-cookie-v1" ‖ timestamp u64 LE ‖ tupleLen u8 ‖ tuple ‖
message1`, keyed by the host's 32-byte cookie secret. Bindings: the
tuple (address ownership — the point), the timestamp (verify enforces
`mintTime ≤ now ≤ mintTime + lifetime`, default 30 s; a future stamp
is a forgery since one monotonic clock mints and verifies), and msg1
whole and verbatim (one cookie authorizes one exact handshake attempt
— free for honest clients, whose retry rule already resends one msg1
byte-identical). Rotation: `verify` takes an ordered current-first
secret list; a cookie minted under the previous secret survives one
rotation until the lifetime closes it. Malformed input at verify is
quietly `false`, never a throw — the flood path stays cheap.

Messages (bare pre-transport CTRL datagrams like 0x05/0x06 —
ARQ-exempt; a lost challenge is superseded when the client's msg1
retransmit draws a fresh one): 0x13 retry challenge = `type ‖
cookieLen u8 (1…255, 0 rejects) ‖ cookie`, exactly its layout; 0x14
retry handshake 1 = `type ‖ cookieLen ‖ cookie ‖ message1`, msg1 the
sole trailing field (self-delimiting), rejected below IK msg1's 96 B
structural minimum before any cookie work. The cookie rides
length-prefixed so the interior may evolve host-side without touching
the codec; v1's vectors pin the 24-byte interior.

## File format: retry-v1.json

Top-level: `format` ("lyte-wire-retry-vectors"), `formatVersion` (1),
`wireVersion` (1), `cookieVectors`, `messageVectors`.

`cookieVectors` (all `provenance` "pinned-self-consistent" — no
published set covers our transcript; the HMAC beneath them is anchored
in `RetryCookieTests` against an independent RFC 2104 construction
over TestKit's `Sha256`): `mint` rows re-mint from (`tupleHex`,
`message1Hex`, `mintNowHex`, `secretHex`) and must reproduce
`cookieHex` byte-exact, then verify at `verifyNowHex` under
`secretsHex` (current-first) — with `lifetimeHex` overriding the
default window when present — and must answer `valid`; `verify` rows
present `cookieHex` as-is (tampered, foreign, truncated) with no mint
step. u64s ride as hex, the house JSON-precision rule.

`messageVectors` carry `codec` ("challenge"/"handshake1") plus the
lifecycle file's kinds over `messageHex`; roundtrips also pin the
decoded `cookieHex` (and `message1Hex` for handshake1); `error` names
are `RetryMessageError` case names. Anchored against the hand-built
bytes in `RetryCodecTests`.

## Vector inventory (retry-v1.json, 12 cookie + 14 message)

Cookie mint rows: `mint-nominal` (the reference bytes),
`mint-verify-at-lifetime-edge` (closed-ended window), `mint-expired`
(+1 ns past lifetime), `mint-future-stamp`, `mint-custom-lifetime`
(1 ms honored), `mint-rotation-previous-secret`, `mint-rotated-out`.

Cookie verify rows: `verify-foreign-tuple`, `verify-altered-message1`,
`verify-tampered-mac`, `verify-tampered-timestamp`,
`verify-truncated-cookie`.

Message round trips: `challenge-nominal` (the hand-computed anchor),
`challenge-min-cookie` (1 B), `challenge-max-cookie` (255 B),
`handshake1-nominal` (96 B msg1, the structural minimum),
`handshake1-real-msg1-shape` (122 B).

Message decode rejects: `challenge-truncated-header`,
`challenge-truncated-cookie`, `challenge-zero-cookie-len`,
`challenge-trailing-byte`, `challenge-bad-type`,
`handshake1-truncated-cookie`, `handshake1-zero-cookie-len`,
`handshake1-msg1-too-short`, `handshake1-bad-type`.

## The Noise layer (wire v1)

Suite: **`Noise_IK_25519_ChaChaPoly_SHA256`** — the IK pattern
(initiator knows the responder's static from pairing; mutual
authentication, 1-RTT, forward secrecy), X25519, ChaCha20-Poly1305,
SHA-256, all via swift-crypto (the one sanctioned dependency; `import
Crypto` is lint-confined to `Sources/LyteWire/Crypto/`).

Handshake on the wire: message 1 = `e(32) ‖ enc(s)(48) ‖ enc(payload)`;
message 2 = `e(32) ‖ enc(payload)`. There is no ALPN (Lyte-UDP decision
§8.3), so the first payload byte each way is the **wire major version**
— mismatch aborts with `versionMismatch` before any transport key
exists. The post-handshake transcript hash `h` is exposed as the
handshake hash the W6 PAKE binds to (§8.2).

Transport phase (the Lyte extension — this is NOT plain Noise transport
nonce discipline): the envelope header (24 B + TLVs) rides as AAD; the
AEAD nonce is `chan u8 ‖ epoch u24 LE ‖ extendedCounter u64 LE`, where
the extended counter is reconstructed from the u16 envelope seq
SRTP-ROC-style (serial distance from the last-seen position; first
datagram on a channel anchors at its raw seq). Receiver policy: 64-deep
sliding replay window per channel — each counter admitted exactly once,
reorder inside the window fine, older rejects `staleSequence`, repeats
reject `replayedSequence`; window state commits only after the tag
verifies. Rekey = Noise REKEY + epoch increment; the receive side keeps
the previous epoch's key as a grace key (trial-decrypt, tag arbitrates)
so in-flight datagrams survive. Budgets enforced at the seam: plaintext
≤ 1112 B, ciphertext+tag ≤ 1128 B.

## File format: noise-v1.json

Top-level: `format` ("lyte-wire-noise-vectors"), `formatVersion` (1),
`wireVersion` (1), `handshakeVectors`, `transportVectors`.

**Provenance honesty — two sections, two strengths.**

`handshakeVectors` are **external canonical vectors**, transcribed
verbatim from the two independent published implementations that carry
this suite, with `source` URL and `sourceSha256` of the exact upstream
file recorded per vector (fetched 2026-07-21):

- `snow-ik-25519-chachapoly-sha256` — snow (Rust), 4 messages.
- `cacophony-ik-25519-chachapoly-sha256` — cacophony (Haskell), 6
  messages plus `handshakeHashHex`.

The standard fields (`initStaticHex`, `initEphemeralHex`,
`respStaticHex`, … `messages[]` of `payloadHex`/`ciphertextHex`) drive
both roles byte-for-byte: message writes must equal the published
ciphertext exactly, reads must recover the payloads, and messages [2…]
verify the Split transport keys under sequential Noise nonces
(alternating directions, initiator first). A divergence is an
implementation bug — these files never regenerate.

`transportVectors` cover the Lyte nonce/rekey extension, which no
published set can cover because the discipline is ours. They are
**pinned self-consistent**: generated once by `lyte-wire-vectorgen
noise` from this implementation and frozen as a regression pin —
honestly weaker than an external oracle (each vector says so in its
`provenance` field), with the AEAD/handshake beneath them externally
verified by the section above. Each vector fixes both statics and
ephemerals (counting-byte private keys, auditable by eye), freezes
`message1Hex`/`message2Hex`/`handshakeHashHex`, then applies `steps` in
order: `seal` steps carry the envelope fields (whose `encode` output is
the AAD) and the exact expected `wirePayloadHex`; `rekey` steps bump
the named direction's epoch on both ends.

## Vector inventory (noise-v1.json, 2 external + 1 pinned)

`ik-transport-nominal` (pinned): CTRL and video both directions, a
1112 B max-budget shard sealing to exactly 1128 B, the u16 seq wrap on
chan 1 (anchored at 65534, walking 65535 → 0 → 1), a client→host rekey
to epoch 1, and post-rekey sends both ways proving the epoch key change
while host→client stays on epoch 0.
