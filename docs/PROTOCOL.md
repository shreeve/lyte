# Lyte-UDP

The current wire protocol, summarized from `LyteWire` and the frozen
vectors. Byte layouts are normative in
[`Wire/Vectors/README.md`](../Wire/Vectors/README.md) and in the vector
files themselves; each section below names the file that pins it. When this
page and a vector disagree, the vector wins and this page is wrong.

Why the protocol has this shape is recorded in the
[Lyte-UDP decision](decisions/20260720-215100-lyte-udp-decision.md) and the
historical pillar documents under [history/](history/). Those pillars
predate the code (they assume QUIC, full-range color and a PipeWire master
clock); do not read them as the current contract.

## Principles

- One protocol over plain UDP datagrams. No QUIC, RTP, GameStream or
  plaintext mode.
- Every datagram after the handshake is sealed with ChaCha20-Poly1305; the
  envelope header is the AAD.
- Feature messages are capability-negotiated, session-scoped,
  size-bounded, consent-gated and never payload-logged.
- New semantics ship as new CTRL types, new capability keys or new vector
  files. Committed vector files never change (see
  [Versioning](#versioning-and-vectors)).

## Datagram budget

| Limit | Bytes | Source |
|---|---|---|
| Envelope header | 24 (+ TLV block) | `WireBudget.envelopeByteCount` |
| Plaintext shard | ≤ 1112 | `WireBudget.maxPlaintextShardByteCount` |
| Wire payload (ciphertext + 16 B tag) | ≤ 1128 | `WireBudget.maxWirePayloadByteCount` |
| Datagram | ≤ 1152 | `WireBudget.maxDatagramByteCount` |

The datagram ceiling can be raised per session only through capability key
8 (`maxDatagramBytes`), host-proposed at an IDR boundary.

## Envelope

24 bytes, little-endian: `chan u8 ‖ flags u8 ‖ seq u16 ‖ frame u32 ‖
timestamp u64 ‖ fec u64`, then an optional TLV block
(`count u8 (type u8 len u8 value)*`) when flags bit 0 is set. `seq` is a
per-channel serial number; `frame` is the frame number, audio packet number
or FEC group id; `timestamp` is microseconds in the sender's monotonic
domain.

TLV types: `0x00` invalid, `0x01` connection id (migration), `0x02` wire
major version, `0x03` last input seq. Unknown TLV types are skipped by
consumers and preserved by the codec.

Pinned by `envelope-v1.json`, `session-v1.json` (conn-id TLV),
`control-v1.json` (lastInputSeq TLV).

## Channels and priority

| chan | Name | Delivery | Send priority |
|---|---|---|---|
| 0 | CTRL | ARQ ordered stream (group 0) + ARQ-exempt datagrams | control |
| 1 | audio | unreliable, RS-FEC | audio |
| 2 | video-active | unreliable, RS-FEC + NACK repair | fresh video (repairs: video tail) |
| 3 | feedback | unreliable, 25–50 ms reports | telemetry |
| 4 | video-idle | ARQ one-shot groups | video tail |
| 5–7 | reserved | never sent; dropped on receive | — |
| 8 | bulk transfer | ARQ ordered stream | bulk (last) |
| 9–255 | feature channels | ARQ | feature |

Priority order, highest first: control/input > audio > fresh video > video
tail and retransmits > refinement > feature > telemetry > bulk
(`LyteWire/ChannelId.swift`, `WirePriority`). Refinement has no channel of
its own; the pacer demotes it by content.

## FEC

The envelope's `fec` field is `shardIndex u8 ‖ dataShards u8 ‖
parityShards u8 ‖ scheme u8 ‖ groupByteCount u24 ‖ reserved u8`. Scheme
`0x01` is Reed-Solomon over GF(2⁸) (nanors); one group is at most 255
shards. Shards are balanced: every data shard but the last is
`ceil(group / k)` bytes. Video groups are one frame; audio groups are four
5 ms Opus packets plus two parity (RS 4+2).

Pinned by `fec-v1.json` (field, geometry ladder, recovery matrices) and
`video-v1.json` (packetize and assembly scenarios over
`video-corpus-v1/`).

## Handshake

```text
client                                   host
0x05 ‖ Noise IK msg1          ──►
                              ◄──        0x13 retry challenge (cookie mode only)
0x14 ‖ cookie ‖ msg1          ──►
                              ◄──        0x06 ‖ Noise IK msg2
sealed traffic, both ways; each side's first ARQ message is 0x0F
```

- Suite `Noise_IK_25519_ChaChaPoly_SHA256`. The client knows the host's
  static key from pairing. The first handshake payload byte each way is
  the wire major version (1); a mismatch aborts before any transport key.
- The client sends one message 1 and retransmits the same bytes (5
  transmissions, 1 s apart, `ClientHandshakeInitiator.Retry`), so a late
  answer to any copy completes the transcript. Answering a retry challenge
  spends no attempt.
- The host rate-limits message 1 (`HostSession.HandshakeGate`). Under a
  flood it switches to cookie mode: a stateless 24-byte HMAC cookie binds
  the client tuple, a timestamp (30 s lifetime) and message 1 verbatim.
  A verified cookie is admitted once; replays are dropped.
- Message 1 carries no freshness, so a replayed one authenticates again.
  The host therefore commits to a client only when it proves key
  possession: its first authenticated transport datagram. Until then a
  verbatim repeat of the answered message 1 gets the same message 2 again
  (on the tuple that sent it), and a newer message 1 that authenticates
  replaces the unconfirmed handshake. The listening host also drops any
  message 1 it already answered earlier in the process, so a captured one
  replays at most once per host run and cannot hold the host against a
  real client's next dial.
- Handshake carriage (0x05, 0x06, 0x13, 0x14) is bare: it is not sealed and
  not ARQ-carried. A bare 0x05/0x06 after the client is confirmed is
  dropped.

Pinned by `noise-v1.json` (external IK vectors plus Lyte's transport
extension) and `retry-v1.json`.

## Transport sealing

The AEAD nonce is `chan u8 ‖ epoch u24 ‖ extendedCounter u64`. The
extended counter is rebuilt from the 16-bit envelope seq, SRTP-ROC style.
The receiver keeps a 64-deep replay window per channel and commits window
state only after the tag verifies. After eight consecutive open failures it
also tries the next four forward wraps, so a long one-way gap cannot kill a
channel; the tag arbitrates, so a forgery never moves the anchor. Rekey is
Noise REKEY plus an epoch increment, with the previous epoch kept as a
grace key.

Pinned by `noise-v1.json`.

## Pairing

A first connect runs trust-on-first-use Noise, then CPace
(CPACE-X25519-SHA512) over the sealed ARQ CTRL stream, bound to the Noise
handshake hash and both statics. The host shows a 6-digit PIN; the client
submits exactly six ASCII digits (`PairingPin.normalize` strips spaces and
hyphens and refuses every other digit form). Messages: 0x0B share A, 0x0C
share B + tag, 0x0D confirm, 0x0E reject. Success pins both statics; later
connects are plain Noise IK. Hosts admit unpaired clients unless started
with `--require-paired` (see [TODO.md](../TODO.md)).

Pinned by `pairing-v1.json` (draft-irtf-cfrg-cpace-21 vectors, pinned runs,
the message codecs).

## Capabilities

Each side's first ARQ message is a capability declaration (0x0F): a
deterministic-CBOR map. The agreed set is the intersection, computed the
same way on both ends; there is no accept round. Unknown keys are ignored
and preserved, and survive intersection only when both sides declare
byte-equal values.

| Key | Name | Type / intersect | Gates |
|---|---|---|---|
| 1 | wireMinor (required) | u16, min | — |
| 2 | videoCodecs (required) | id list, ∩ (1 = HEVC) | — |
| 3 | chromaModes (required) | id list, ∩ (1 = 4:2:0, 2 = 4:4:4) | chroma posture |
| 4 | idleSilence | bool, AND | idle-mode video |
| 5 | featureChannels | id list, ∩ (1 clipboard, 2 files, 3 printing) | — |
| 6 | audioExpress | bool, AND | — |
| 7 | resume | bool, AND | — |
| 8 | maxDatagramBytes | u32 ≥ 1152, min; the one renegotiable key (0x11/0x12) | datagram ceiling |
| 9 | hostAudioRouting | flag | 0x18/0x19 |
| 10 | clipboardText | flag | 0x1A/0x1B |
| 11 | bulkTransfer | flag | chan 8, 0x1C–0x21 |
| 12 | clipboardImages | flag (image gate is 10 ∧ 12) | 0x22 |
| 13 | cursorShape | flag | 0x24 |
| 14 | audioStreamOff | flag | routing mode 0x04 |
| 15 | audioQuietPosture | flag | 0x25 |
| 16 | videoQuietPosture | flag | 0x26 |

Keys 9–16 are "flags": a canonical `key: true` entry carried as an unknown
entry of the v1 set, so `capabilities-v1.json` never moves.

Pinned by `capabilities-v1.json` (keys 1–8, the CBOR profile, the
intersection algebra) and the spine pins in `control-v1.json` (9),
`clipboard-v1.json` (10), `bulk-v1.json` (11), `clipboard-images-v1.json`
(12), `cursor-v1.json` (13) and `postures-v1.json` (15, 16). Key 14 has no
spine pin yet; `control-v1.json` pins routing mode 0x04 and the reserved
0x03.

## CTRL message registry

Every CTRL payload starts with a type byte. "ARQ" means the message rides
the reliable ordered stream; "bare" means a datagram outside ARQ (sealed
after the handshake unless noted).

| Type | Message | Direction | Carriage | Vector file |
|---|---|---|---|---|
| 0x00 | invalid (never assigned) | — | — | — |
| 0x01 | ClockBeacon | host → client | bare, 1 Hz | `beacon-v1.json` |
| 0x02 | BeaconEcho | client → host | bare | `beacon-v1.json` |
| 0x03 | PathChallenge | host → client | bare, on the probed tuple | `session-v1.json` |
| 0x04 | PathResponse | client → host | bare | `session-v1.json` |
| 0x05 | Noise IK message 1 | client → host | bare, unsealed | `noise-v1.json` |
| 0x06 | Noise IK message 2 | host → client | bare, unsealed | `noise-v1.json` |
| 0x07 | ARQ data segment | both | ARQ frame | `arq-v1.json` |
| 0x08 | ARQ ACK | both | ARQ frame (itself exempt) | `arq-v1.json` |
| 0x09 | ModeTransition (ACTIVE/IDLE) | host → client | ARQ | `lifecycle-v1.json` |
| 0x0A | SessionTeardown | both | ARQ | `lifecycle-v1.json` |
| 0x0B–0x0E | Pairing share A, share B, confirm, reject | both | ARQ | `pairing-v1.json` |
| 0x0F | CapabilityDeclaration | both | ARQ, first message | `capabilities-v1.json` |
| 0x10 | IdrRequest | client → host | bare | `session-v1.json` |
| 0x11 | CapabilityUpdate | host → client | ARQ | `capabilities-v1.json` |
| 0x12 | CapabilityUpdateAck | client → host | ARQ | `capabilities-v1.json` |
| 0x13 | RetryChallenge | host → client | bare, unsealed | `retry-v1.json` |
| 0x14 | RetryHandshake1 | client → host | bare, unsealed | `retry-v1.json` |
| 0x15 | IdleFrame | host → client | ARQ one-shot group | `control-v1.json` |
| 0x16 | InputEvent | client → host | ARQ | `control-v1.json`, `input-coordinates-v1.json` |
| 0x17 | InputEcho | host → client | ARQ | `control-v1.json` |
| 0x18 | AudioRoutingRequest | client → host | ARQ, key 9 | `control-v1.json` |
| 0x19 | AudioRoutingStatus | host → client | ARQ, key 9 | `control-v1.json` |
| 0x1A | ClipboardSet | client → host | ARQ, key 10 | `clipboard-v1.json` |
| 0x1B | ClipboardAnnounce | host → client | ARQ, key 10 | `clipboard-v1.json` |
| 0x1C–0x21 | Bulk offer, accept, chunk, ack, complete, abort | both | chan 8 ARQ, key 11 | `bulk-v1.json` |
| 0x22 | ClipboardImageCargo | both | chan 8 ARQ, keys 10 ∧ 12 | `clipboard-images-v1.json` |
| 0x23 | RepairRefusal | host → client | bare | `repair-refusal-v1.json` |
| 0x24 | CursorShape | host → client | ARQ, key 13 | `cursor-v1.json` |
| 0x25 | AudioTrackState | host → client | ARQ, key 15 | `postures-v1.json` |
| 0x26 | VideoPostureState | host → client | ARQ, key 16 | `postures-v1.json` |

An unknown CTRL type is skipped (bare) or counted and dropped (ARQ), so a
new host-to-client message degrades to "not supported" on an older client.
Source: `LyteWire/Control/CtrlMessage.swift`.

## Reliable delivery (ARQ)

A reliable-channel payload that starts with 0x07 or 0x08 is a sequence of
ARQ frames; an ACK can ride ahead of fresh segments in one datagram.
Sequencing is per group: group 0 is the channel's ordered stream, non-zero
groups are independent one-shot messages allocated by the endpoint
(`ArqEndpoint.sendOneShot`). Segments are retransmitted byte-identical in
fresh datagrams (fresh seq, fresh nonce). An ACK describes at most 256
segments past its cumulative point, which is also the widest receive
window; a sender never exceeds the peer's window. One send group holds at
most 32,512 segments; past that `send` throws `ArqSendError.queueFull`,
which every shell treats as backpressure, not as a fatal error.

Pinned by `arq-v1.json`.

## Session lifecycle

- Wire modes are ACTIVE and IDLE (0x09). FROZEN and RECOVERY are local
  path-loss overlays and never appear on the wire.
- Teardown (0x0A) carries `takenOver` (0x01) or `shuttingDown` (0x02). The
  macOS client roams (re-dials) on `shuttingDown` and ends the window on
  `takenOver`.
- Liveness: 30 s without authenticated peer evidence ends a session; the
  timeout sends nothing. Blackout (FROZEN) starts after 350 ms without
  media-path evidence (`SessionStateMachine`).
- Path migration: a datagram from a new tuple carrying the connection-id
  TLV draws a PathChallenge (0x03) after it unseals; a matching
  PathResponse (0x04) promotes the tuple, and video restarts from an IDR.

Pinned by `lifecycle-v1.json` and `session-v1.json`.

## Clock and feedback

The host sends a ClockBeacon every second; the client echoes it, and
`HostClockModel` fits offset and skew from the four timestamps. The client
sends a feedback report on chan 3 every 25–50 ms: per-channel counters,
per-packet arrival dispersion (kernel monotonic stamps) and up to six NACK
entries. The host's `RateEstimator` prices the path from these reports;
there is no client-side rate control.

Pinned by `beacon-v1.json`.

## Media

- **Video:** HEVC access units, 4:2:0 or 4:4:4 (key 3, fixed per session;
  changing chroma means reconnecting), BT.709 limited range. One frame per
  FEC group; lost shards beyond parity draw a NACK or an IdrRequest, and
  the host may answer with a RepairRefusal (0x23) instead of a late repair.
  A still screen sends a keepalive re-encode about once a second, and less
  often under an announced quiet posture (0x26).
- **Audio:** Opus, 5 ms packets, hard CBR, RS 4+2 groups on chan 1. The
  host may gate transmission during announced silence (0x25) and replays a
  pre-roll ring on wake.
- **Cursor:** shape and hotspot as metadata (0x24), up to 256 × 256 BGRA.

Pinned by `video-v1.json` + `video-corpus-v1/`, `postures-v1.json`,
`cursor-v1.json`; the audio interior composes the envelope and FEC formats
and is pinned by hand-built bytes in `AudioInteriorTests`.

## Features

| Feature | Messages | Channel | Key | Record |
|---|---|---|---|---|
| Input | 0x16 / 0x17, lastInputSeq TLV | CTRL | always | — |
| Host audio routing | 0x18 / 0x19 | CTRL | 9 (mode 0x04 needs 14) | — |
| Clipboard text | 0x1A / 0x1B | CTRL | 10 | [clipboard](decisions/20260722-231500-lyte-clipboard.md) |
| File transfer | 0x1C–0x21 | 8 | 11 | [bulk channel](decisions/20260728-053300-lyte-bulk-channel.md) |
| Clipboard images | 0x22 + a bulk transfer | 8 | 10 ∧ 12 | [clipboard](decisions/20260722-231500-lyte-clipboard.md) |

InputEvent pointer coordinates and scroll deltas are f64 and must be
finite: a NaN or ±Inf coordinate rejects the event
(`input-coordinates-v1.json`). Finite values of any magnitude decode;
bounding them to the screen is the host injector's job.

Bulk transfers are chunked, resumable across sessions and credit-driven;
the sender reads at most 128 unconfirmed chunks ahead, and the receive
window is clamped to 256 chunks.

## Versioning and vectors

- Wire major version 1 rides in the first handshake payload byte; wire
  minor rides in capability key 1.
- `Wire/Vectors/*.json` files are append-only contracts. The macOS gate
  fails if a committed vector file is modified, deleted, renamed or
  retyped; new files and README prose may be added. Changed semantics need
  a new versioned file and a wire-version decision.
- `VectorRegenerationTests` rebuilds every committed file from its builder
  in `LyteWireVectorGen`, so builders cannot drift from the bytes.
- The same vectors verify byte-for-byte on macOS, Linux (pup) and
  wasm32-wasip1 (`Wire/Scripts/wasm-test.sh`).
- A banked set of wire-v2 changes is recorded in the
  [wire-v2 study](history/20260728-175200-lyte-wire-v2-study.md); none is
  scheduled.
