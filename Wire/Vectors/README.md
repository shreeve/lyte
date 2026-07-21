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
authoring tool (`swift run lyte-wire-vectorgen <path>`) exists for adding
files, and its output is anchored against hand-computed bytes in
`EnvelopeTests` so the codec never grades its own homework.

## Files

- `envelope-v1.json` — envelope + TLV codec vectors for wire major
  version 1, plus the (chan, seq) serial-arithmetic table.

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
| 16 | 8 | fec | opaque; interior layout owned by resiliency, codec lands at W1 |
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
