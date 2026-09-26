# LyteWire test vectors

These files are first-class, versioned wire-contract artifacts, not test
fixtures: `Wire/Tests` verifies `LyteWire` against them byte-for-byte on
macOS and Linux, and `Wire/Scripts/wasm-test.sh` runs the same suite for
wasm32-unknown-wasip1 under wasmtime. This README describes every file and
gives the normative byte layout for the layers with a section below; the
other codecs' layouts are the header comments of their `LyteWire` sources
(for example `Control/InputMessages.swift` for InputEvent 0x16).
[docs/PROTOCOL.md](../../docs/PROTOCOL.md) is the living overview that ties
each protocol layer to its file.

**Freeze policy.** A committed vector file is frozen. If the codec and a
vector ever disagree, that is a wire-contract break to investigate — never a
prompt to regenerate. New cases go in a new file; changed semantics mean a
new file version (`envelope-v2.json`) and a wire-version discussion first.
The macOS gate (`Scripts/CI/test-all-macos.sh`) fails when a committed
file here is modified, deleted, renamed or retyped; new files and edits to
this README pass.

**Authoring.** Every file is built by a builder in the `LyteWireVectorGen`
library, listed once in its `vectorFileBuilders` registry.
`VectorRegenerationTests` requires the registry to name every committed
`*.json` here exactly once, and each committed file to be byte-for-byte
what its builder writes today. The one exemption is `cursor-v1.json`,
committed with a single `/` the encoder writes as `\/`; its comparison
un-escapes that and forgives nothing else. A builder that drifts from its
frozen file therefore fails the suite, so builders list enum values
literally rather than enumerating `allCases`. The `lyte-wire-vectorgen`
CLI writes one NEW file and refuses to replace an existing path unless
given `--force` (for scratch copies only):

```sh
swift run --package-path Wire lyte-wire-vectorgen <kind> <output-path>
# kind: a registry entry's kind; the usage line lists them all
```

`video` always reads the committed corpus, `video-corpus-v1/`.

**Hand-computed anchors.** Builder output is anchored against bytes
computed by hand in each codec's tests — `EnvelopeTests`/`FecFieldTests`,
the k=1,m=1 parity-identity case in `FecCoderTests`, the hand-walked
datagram in `VideoPacketizerTests`, and the anchor test named with each
file below — so the codec never grades its own homework. Each vector's
name and description are in the file.

**Impairment fixtures.** `LyteWireTestKit.SimNet` scenarios are deterministic
test machinery, not wire contracts: schedules and seeds normally live beside
their tests. If a reusable impairment trace is promoted into `Vectors/`, it
inherits the same append-only rule — add a new named case or a new versioned
file; never rewrite a committed replay.

## Files

Each `*VectorFileTests` suite replays its file; the anchor named here holds
the hand-computed bytes.

- `envelope-v1.json` — the envelope and TLV codec plus the (chan, seq)
  serial-arithmetic table. Layout and format below; anchor `EnvelopeTests`.
- `fec-v1.json` — the fec-field codec, the adaptive parity ladder as data,
  and RS recovery matrices. Layout and format below; anchor
  `FecFieldTests`.
- `video-v1.json` — packetize vectors (frame → frozen shard datagrams) and
  assembly scenarios (scripted delivery → expected DecodeUnits and
  fec-impossible verdicts). Format below; anchor `VideoPacketizerTests`.
- `video-corpus-v1/` — real HEVC access units, the golden corpus
  `video-v1.json` pins by sha256 (own README inside).
- `video-decisions-v1.json` — for every `video-v1.json` scenario, the
  default assembler's whole ordered event stream, one line per event
  (decodes, skipped ranges, fec-impossible verdicts, NACK candidates,
  repairs, evictions, dropped shards). Pinned self-consistent: it makes
  any drift in the recovery policy loud.
- `beacon-v1.json` — the CTRL clock-beacon pair, the chan 3 feedback
  report, and the offset/RTT worked example. Layouts and format below;
  anchors `ClockBeaconTests`/`FeedbackReportTests`.
- `noise-v1.json` — external `Noise_IK_25519_ChaChaPoly_SHA256` handshake
  vectors plus pinned transport-extension vectors. Provenance and format
  below.
- `session-v1.json` — path challenge/response 0x03/0x04, the IDR request
  0x10, and the conn-id TLV 0x01 value codec riding whole envelope
  datagrams; anchor `SessionCodecTests`. The Noise handshake carriage
  0x05/0x06 needs no vectors of its own: the payload is the type byte
  followed by the raw Noise message `noise-v1.json` pins.
- `arq-v1.json` — the data segment 0x07, the ACK 0x08, and the
  frame-sequence payload rule. Layout and format below; anchor
  `ArqCodecTests`.
- `lifecycle-v1.json` — the mode transition 0x09 and the session teardown
  0x0A. Layout and format below; anchor `SessionLifecycleCodecTests`.
- `pairing-v1.json` — external draft-irtf-cfrg-cpace-21 vectors, the pinned
  PairingPake exchange, and the pairing codecs 0x0B–0x0E. Provenance and
  format below; anchor `PairingCodecTests`.
- `capabilities-v1.json` — the deterministic CBOR profile, the typed
  capability set, the intersect algebra as data, and the capability codecs
  0x0F/0x11/0x12. Format below; anchors RFC 8949 appendix A (in
  `CborTests`), `CapabilitiesTests` and `CapabilityCodecTests`.
- `retry-v1.json` — the RetryCookie transcript MAC as data plus the retry
  codecs 0x13/0x14. Layout and format below; anchors `RetryCodecTests` and,
  for the MAC, an independent RFC 2104 HMAC in `RetryCookieTests`.
- `control-v1.json` — the idle frame 0x15, the input pair 0x16/0x17 with
  the lastInputSeq TLV 0x03, the audio-routing pair 0x18/0x19 (every mode,
  0x03 pinned as the unknown-mode tombstone), and the key-9 spine; anchor
  `ControlCodecTests`. The audio interior (AudioFramer/AudioDepacketizer)
  composes the envelope and fec formats and has no file of its own; its
  layout is hand-built in `AudioInteriorTests`.
- `clipboard-v1.json` — ClipboardSet 0x1A and ClipboardAnnounce 0x1B
  (`type ‖ UTF-8 text`, text the sole trailing field, at most 65,536 B)
  plus the key-10 spine; anchor `ClipboardCodecTests`.
- `bulk-v1.json` — the bulk-channel messages 0x1C–0x21, the key-11 spine,
  and worked multi-session transfer traces replayed through
  `BulkTransferHarness` with every per-direction emission frozen (traces
  pinned self-consistent); anchor `BulkCodecTests`.
- `clipboard-images-v1.json` — the ClipboardImageCargo marker 0x22
  (`type ‖ transferId u64 LE ‖ mimeLen u8 ‖ mime UTF-8`, riding chan 8's
  ordered stream just before its transfer's BulkOffer) plus the key-12
  spine; anchor `ClipboardImageCodecTests`. An unsupported but well-formed
  mime decodes: format policy belongs to the channel, not the codec.
- `repair-refusal-v1.json` — RepairRefusal 0x23 (`type ‖ frame u32 LE ‖
  reason u8`, fixed 6 bytes), host→client, sealed, ARQ-exempt: a lost
  refusal degrades to the client's own repair deadline, and a client that
  ignores the unknown type lands on the same behavior, so no capability
  key gates it; anchor `RepairRefusalCodecTests`.
- `cursor-v1.json` — CursorShape 0x24 (`type ‖ width u16 ‖ height u16 ‖
  hotspotX u16 ‖ hotspotY u16 ‖ BGRA pixels`) plus the key-13 spine;
  anchor `CursorCodecTests`.
- `postures-v1.json` — AudioTrackState 0x25 (`type ‖ state`, active 0x01 /
  quiet 0x02) and VideoPostureState 0x26 (`type ‖ posture ‖
  keepaliveSeconds`, 1–255) plus the key-15/16 spine; anchors in
  `PostureVectorFileTests`.
- `input-coordinates-v1.json` — the coordinate domain of InputEvent 0x16:
  the f64 coordinates of the motion and axis kinds must be finite. Vectors
  reuse the control file's shape (`codec = inputEvent`).
- `audio-stream-off-v1.json` — the key-14 (`audioStreamOff`) capability
  spine declared, absent, and composed with key 9 (`09 F5 0E F5`); each
  vector's `flags` name the accessors and what they must read. Routing
  mode 0x04 itself is pinned in `control-v1.json`. Anchors in
  `AudioStreamOffVectorFileTests`.

The message files share one shape: `roundtrip` encodes the typed fields to
exactly `messageHex` and decodes back; `decodeReject` decoding `messageHex`
throws `error`; `encodeReject` constructing the typed value from the fields
throws `error`. `error` is always the codec error's Swift case name,
without associated values. u64s ride as hex strings because JSON numbers
lose their precision.

## The 24-byte envelope (wire v1)

All multi-byte fields little-endian. The header (these 24 bytes plus the
optional TLV block) rides as AAD; the payload is the AEAD ciphertext + 16 B
tag. Vectors that pin whole datagrams carry the bare shard instead — an
unsealed test-passthrough datagram; live sessions always seal it.

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | chan | 0 CTRL, 1 audio, 2 video-active, 3 feedback/telemetry, 4 video-idle (registered, unused), 5–7 reserved, 8 bulk, 9+ features |
| 1 | 1 | flags | bit0: TLV block present; bits 1–7 reserved — 0 on send, ignored on receive |
| 2 | 2 | seq | per-channel serial u16 (RFC 1982-shaped comparison; see `seqComparisons`) |
| 4 | 4 | frame | frame number / audio packet number / FEC group id |
| 8 | 8 | timestamp | µs; host monotonic (CLOCK_MONOTONIC) host→client, client monotonic client→host |
| 16 | 8 | fec | interior layout below (`FecField.swift`) |
| 24 | … | TLV block (if flags bit0), then payload | |

TLV block: `count:u8 (type:u8 len:u8 value)*`. Unknown TLV types MUST be
skipped by consumers and are preserved verbatim by the codec. Assigned
types: `0x00` invalid (never assigned), `0x01` connection ID (migration,
Lyte-UDP decision §8.4), `0x02` wire major version — reserved and unused in
v1: nothing sends it, and the major rides the first Noise handshake payload
byte instead (§8.3), where it must match exactly — and `0x03` last input
seq (`control-v1.json`).

Byte budgets, enforced at encode time and covered by reject vectors:
plaintext shard ≤ **1112 B**, wire payload (ciphertext + tag) ≤ **1128 B**,
datagram ≤ **1152 B**. TLV bytes count against the datagram budget.

## File format: envelope-v1.json

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

The envelope's offset-16 u64. Byte n below is bit
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

`geometryRows` freeze the adaptive parity ladder as data:
(`dataShards`, `regime` clean|lossy) → `parityShards`, null where no
ladder ratio fits the 255-shard block (lookup throws; clean protects
k ≤ 231, lossy k ≤ 204 — `frameByteCeiling` derives from these).

`recoveryMatrices` freeze the C leaf's bytes: `FecEncoder` on `groupHex`
must produce `shardsHex` byte-exact; decoding with `erasedIndices` nil'd
out must return `groupHex` byte-exact (`expect` "recovered") or throw
`unrecoverableGroup` (`expect` "unrecoverable") — honest failure, never
garbage. The matrices must be byte-identical on macOS, Linux and
WebAssembly.

## File format: video-v1.json

Top-level: `format` ("lyte-wire-video-vectors"), `formatVersion` (1),
`wireVersion` (1), `frames`, `scenarios`.

`frames` are packetize vectors: `VideoPacketizer` on the source bytes
(with the vector's frameNumber, `timestampHex` µs, isIDR, regime,
firstSeq) must produce exactly the listed shards — seq and `fecHex`
field-exact, the full unsealed test-passthrough datagram (header + bare
shard; live sessions seal it) matching `datagramSha256`, and
`datagramHex` byte-exact where present. Inline sources carry `annexBHex` (counting-byte filler, auditable by eye);
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

## The CTRL message-type registry and the clock-beacon pair (wire v1)

The complete registry, 0x00–0x26, with each type's direction, carriage and
vector file, is the table in [docs/PROTOCOL.md](../../docs/PROTOCOL.md#ctrl-message-registry)
(source: `LyteWire/Control/CtrlMessage.swift`). This section pins the
registry's rules and the beacon pair.

Every CTRL (chan 0) message starts with one type byte, whether it rides
a bare ARQ-exempt datagram or an ARQ-delivered message body. `0x00` is
invalid (never assigned, the zero-fill rule), `0x01` the clock beacon,
`0x02` the beacon echo. The beacon pair is ARQ-exempt fire-and-forget by
design: clock mapping wants fresh timestamps, not reliable old ones — a
lost beacon is superseded by the next 1 Hz send. It is the ONE beacon
(clock mapping + slow liveness); blackout detection is each end's local
policy, not a message.

ClockBeacon (host→client, 1 Hz plus session start), fixed 34 bytes,
little-endian:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 1 | type | 0x01 |
| 1 | 1 | flags | bit0: lastEcho populated; bits 1–7 reserved — 0 on send, ignored on receive |
| 2 | 4 | beaconSeq | u32, from 0 at session start |
| 6 | 8 | hostSend | t1: host monotonic µs (CLOCK_MONOTONIC) at send |
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
the client's HostClockModel (min-filtered offset + regression skew):

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
| 0 | 1 | pathId | 0 in v1 (single path), carried verbatim |
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

## The ARQ frames (wire v1)

The reliable ordered-retransmit sublayer that CTRL, bulk (chan 8) and
the feature channels ride; chan 4 (video-idle) is registered but unused.
Two frame types in the CTRL type space,
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
independent one-shot message groups (defined for sparse idle frames and
the final ratchet frame; no v1 end sends one yet), ids allocated
ascending per direction — a
fully-lost group leaves no hole in any other group's sequence space,
which is the no-cross-group-HOL ruling (decision record §8.1) as
arithmetic. Retransmission unit is the SEGMENT, re-sent byte-identical
inside a fresh datagram (fresh envelope seq, fresh AEAD nonce): no nonce
reuse, single admission and no ACK ambiguity, without the Noise
replay-window liveness hazard a byte-identical datagram resend would hit.

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

## The session-lifecycle messages (wire v1)

Both CTRL types ride the ARQ ordered stream (group 0) rather than bare
datagrams, which is what makes their ordering guarantees real: a mode flip can never reorder against the
messages around it, and a teardown can never overtake the messages
that explain it. Both are exactly their fixed 2-byte layout: truncation
and trailing bytes reject, a foreign type byte rejects with what it
found.

Mode transition (type 0x09): `type:u8 mode:u8` — mode 0x01 ACTIVE,
0x02 IDLE; anything else rejects (`unknownMode`; 0x00 is the loud
zero-fill bug). ACTIVE⇄IDLE are the only wire modes: FROZEN/RECOVERY
are each end's local path-loss overlay and must never appear on the
wire. The sender flips to IDLE only after the converged frame's
one-shot is acknowledged — one-shot groups are unordered against the
CTRL stream, so the ack is what guarantees the receiver holds the frame
before it learns the session went idle. The IDLE half is dormant in v1:
the host has no convergence ratchet, so it stays ACTIVE and never sends
mode 0x02.

Session teardown (type 0x0A): `type:u8 reason:u8` — reason 0x01
taken-over-by (a newer client took the host), 0x02
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
ENTIRE legal value spaces; a new value needs a new file and a
wire-version discussion.

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

**Provenance honesty** (as in `noise-v1.json`).

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
bytes in `PairingCodecTests`; the reject codec's whole value space is
pinned.

## The capability layer (wire v1)

The capability handshake: right after establishment, each end sends one
capability declaration as the first ARQ-carried CTRL message; the session's effective capabilities are the
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

**The key registry** — numbers, types, intersect rules and what each key
gates — is the table in
[docs/PROTOCOL.md](../../docs/PROTOCOL.md#capabilities) (source:
`Capabilities.swift`). Keys 9–16 are not typed fields of the v1 set: each
is one canonical `key: true` entry (`09 F5` … `10 F5`) carried through the
unknown-entry rule below, so `capabilities-v1.json` never moves; each has
its spine pin in the file named in the Files list.

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
`maxDatagramBytes` — the path-MTU raise, host→client
proposals only (the media sender owns geometry), one outstanding at a
time, values within [1152, agreed ceiling], applied at an IDR
boundary. The operative value starts at 1152 regardless of the agreed
ceiling, and in v1 it stays there: the raise is negotiated but no layer
carries a datagram past 1152. Everything else is connect-time only; a proposal naming a
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

## The stateless retry cookie (wire v1)

The msg1-flood defense: LyteWire provides a stateless HMAC retry-cookie
codec for the first handshake datagram, and the host shell decides when
to demand it — QUIC Retry's shape without QUIC. Under a
Noise msg1 flood the host escalates from its per-source token bucket to
cookie mode: each msg1 draws a RetryChallenge whose cookie is minted purely
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
over LyteCore's `Sha256`): `mint` rows re-mint from (`tupleHex`,
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
handshake hash the pairing PAKE binds to (§8.2).

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
so in-flight datagrams survive. Rekey is a pinned primitive only: wire v1
has no CTRL message that triggers it, so no v1 end rekeys and every
session runs at epoch 0. Budgets enforced at the seam: plaintext
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
