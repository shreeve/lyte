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
authoring tool (`swift run lyte-wire-vectorgen <envelope|fec> <path>`)
exists for adding files, and its output is anchored against hand-computed
bytes in `EnvelopeTests`/`FecFieldTests` (and the k=1,m=1 parity-identity
case in `FecCoderTests`) so the codec never grades its own homework.

## Files

- `envelope-v1.json` — envelope + TLV codec vectors for wire major
  version 1, plus the (chan, seq) serial-arithmetic table.
- `fec-v1.json` — fec-field codec vectors, the resiliency §5.2 parity
  ladder as data, and RS recovery matrices (W1).

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
