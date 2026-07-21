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
