// The CTRL message-type registry. Every CTRL (chan 0) payload starts with
// one type byte that says what the message is, in both carriage modes:
// bare fire-and-forget datagrams, and ARQ-delivered messages, whose body
// starts with the same type byte.
//
// ARQ-exempt types travel as plain sealed datagrams: beacons (clock
// mapping wants fresh timestamps; a lost one is superseded by the next
// 1 Hz send), path messages (they must travel on the exact probed tuple),
// handshake and retry messages (the client's timer retries), and IDR
// requests and repair refusals (superseded by the next emission).
//
// Noise handshake carriage: each IK message is one CTRL datagram whose
// payload is the type byte followed by the raw Noise message (0x05 =
// message 1, 0x06 = message 2). Handshake payloads are NOT sealed (IK
// messages are self-protecting); everything after establishment is sealed
// with header-as-AAD, and a bare 0x05/0x06 post-establishment is dropped.

public enum CtrlMessageType {
    /// Never assigned — a zero type byte is always some other layer's
    /// zero-fill bug, and reserving it keeps that bug loud.
    public static let invalid: UInt8 = 0x00
    /// Host→client clock-mapping beacon, 1 Hz plus session start
    /// (ClockBeacon). ARQ-exempt.
    public static let clockBeacon: UInt8 = 0x01
    /// Client→host echo of a beacon (BeaconEcho). ARQ-exempt.
    public static let beaconEcho: UInt8 = 0x02
    /// Host→client path-validation challenge (PathChallenge — QUIC §9's
    /// PATH_CHALLENGE, on the exact unvalidated tuple). ARQ-exempt.
    public static let pathChallenge: UInt8 = 0x03
    /// Client→host echo of a challenge token (PathResponse). ARQ-exempt.
    public static let pathResponse: UInt8 = 0x04
    /// Client→host Noise IK message 1, bare (pre-transport). The payload
    /// after this byte is the raw handshake message.
    public static let noiseHandshake1: UInt8 = 0x05
    /// Host→client Noise IK message 2, bare (pre-transport).
    public static let noiseHandshake2: UInt8 = 0x06
    /// ARQ data segment (ArqFrames). A reliable-channel payload starting
    /// with 0x07 or 0x08 is wholly ARQ — a sequence of frames, not a single
    /// message; route it to `ArqEndpoint.ingest`. Messages the ARQ delivers
    /// start with their own CTRL type byte.
    public static let arqSegment: UInt8 = 0x07
    /// ARQ ACK frame: cumulative + bitmap receive state per (chan,
    /// group). Itself ARQ-exempt — a lost ACK is superseded.
    public static let arqAck: UInt8 = 0x08
    /// ACTIVE⇄IDLE mode transition (ModeTransition). Ordered stream — a
    /// reordered flip would desynchronize the ends' view of datagram video.
    public static let modeTransition: UInt8 = 0x09
    /// Typed session teardown (SessionTeardown): taken-over-by /
    /// shutting-down. Ordered behind everything it follows.
    public static let sessionTeardown: UInt8 = 0x0A
    /// Client→host CPace share Ya (PairingShareA). The pairing quartet
    /// 0x0B–0x0E rides the sealed ordered stream of the trust-on-first-use
    /// Noise session it authenticates — PairingPake binds the run to that
    /// session's handshake hash and statics.
    public static let pairingShareA: UInt8 = 0x0B
    /// Host→client CPace share Yb ‖ confirmation tag Tb (PairingShareB).
    public static let pairingShareB: UInt8 = 0x0C
    /// Client→host confirmation tag Ta (PairingConfirm) — verifying it
    /// completes pairing on the host.
    public static let pairingConfirm: UInt8 = 0x0D
    /// Either direction: typed pairing refusal (PairingReject) — loud
    /// wrong-PIN without an oracle.
    public static let pairingReject: UInt8 = 0x0E
    /// Both directions: the capability declaration
    /// (CapabilityDeclaration — `type ‖ deterministic CBOR map`), the first
    /// ordered-stream message each way after establishment.
    public static let capabilityDeclaration: UInt8 = 0x0F
    /// Client→host IDR request (IdrRequest). Sealed, ARQ-exempt.
    public static let idrRequest: UInt8 = 0x10
    /// Host→client renegotiation proposal (CapabilityUpdate) —
    /// renegotiable keys only. Ordered stream.
    public static let capabilityUpdate: UInt8 = 0x11
    /// Client→host answer to an update (CapabilityUpdateAck),
    /// echoing the proposal it accepts or rejects. Ordered stream.
    public static let capabilityUpdateAck: UInt8 = 0x12
    /// Host→client stateless retry challenge (RetryChallenge) — the
    /// msg1-flood defense. Bare pre-transport, ARQ-exempt: a lost challenge
    /// is answered by the client's msg1 retransmit drawing a fresh one.
    public static let retryChallenge: UInt8 = 0x13
    /// Client→host msg1 resubmission with the cookie echoed
    /// (RetryHandshake1). Bare pre-transport, ARQ-exempt.
    public static let retryHandshake1: UInt8 = 0x14
    /// Host→client reliable idle frame (IdleFrame) on a CTRL one-shot ARQ
    /// group: the sender's ACTIVE→IDLE flip is gated on that group being
    /// fully acknowledged.
    public static let idleFrame: UInt8 = 0x15
    /// Client→host input event (InputEvent). Ordered stream — a lost or
    /// reordered keystroke is corruption, not weather.
    public static let inputEvent: UInt8 = 0x16
    /// Host→client input echo tuples (InputEcho). Ordered stream.
    public static let inputEcho: UInt8 = 0x17
    /// Client→host audio-routing flip request (AudioRoutingRequest).
    /// Ordered stream, gated on capability key 9.
    public static let audioRoutingRequest: UInt8 = 0x18
    /// Host→client applied audio-routing posture (AudioRoutingStatus).
    /// Same carriage and gate.
    public static let audioRoutingStatus: UInt8 = 0x19
    /// Client→host clipboard push (ClipboardSet). Ordered stream, gated
    /// on capability key 10.
    public static let clipboardSet: UInt8 = 0x1A
    /// Host→client clipboard-change report (ClipboardAnnounce). Same
    /// carriage and gate.
    public static let clipboardAnnounce: UInt8 = 0x1B
    /// Sender→receiver bulk-transfer offer (BulkOffer). The bulk messages
    /// 0x1C–0x21 ride the ordered stream of CHANNEL 8
    /// (ChannelId.bulkTransfer), never CTRL — the type space is shared
    /// across reliable channels, the carriage is not. Gated on capability
    /// key 11.
    public static let bulkOffer: UInt8 = 0x1C
    /// Receiver→sender consent + possession + opening credit
    /// (BulkAccept). Chan 8.
    public static let bulkAccept: UInt8 = 0x1D
    /// Sender→receiver one chunk (BulkChunk). Chan 8 — never CTRL, so a
    /// file can never head-of-line-block a keystroke.
    public static let bulkChunk: UInt8 = 0x1E
    /// Receiver→sender possession + credit heartbeat (BulkAck). Chan 8.
    public static let bulkAck: UInt8 = 0x1F
    /// Receiver→sender success verdict after digest verification
    /// (BulkComplete). Chan 8.
    public static let bulkComplete: UInt8 = 0x20
    /// Either direction: typed transfer abort with reason (BulkAbort).
    /// Chan 8.
    public static let bulkAbort: UInt8 = 0x21
    /// Either direction: clipboard-image cargo marker
    /// (ClipboardImageCargo). Chan 8, immediately BEFORE its transfer's
    /// BulkOffer, so the receiver knows a transferId is clipboard cargo
    /// before the offer reaches the file machinery. Gated on keys 10 AND 12.
    public static let clipboardImageCargo: UInt8 = 0x22
    /// Host→client repair refusal (RepairRefusal): the NACK responder's
    /// stale verdicts made explicit so the client never blind-waits its
    /// repair deadline. Sealed, ARQ-exempt; a lost refusal degrades to the
    /// client's own deadline expiry.
    public static let repairRefused: UInt8 = 0x23
    /// Host→client cursor-shape announcement (CursorShape). Ordered
    /// stream — a reordered swap leaves a stale cursor — gated on key 13.
    public static let cursorShape: UInt8 = 0x24

    /// Host→client audio track-state announcement (AudioTrackState):
    /// quiet = transmission gated while capture continues, repeated as a
    /// ~5 s check-in; active = transmitting. Ordered stream, gated on key 15.
    public static let audioTrackState: UInt8 = 0x25

    /// Host→client video posture announcement (VideoPostureState): quiet
    /// = the keepalive backed off to the carried interval (a new 0x26 rides
    /// every step); active = damage-driven with the 1 s keepalive. Ordered
    /// stream, gated on key 16.
    public static let videoPostureState: UInt8 = 0x26

    /// The type byte of a CTRL payload, nil when the payload is empty.
    /// Dispatch on this, then hand the whole payload (type byte included)
    /// to the named codec's `decode`.
    public static func peek(_ payload: ArraySlice<UInt8>) -> UInt8? {
        payload.first
    }

    public static func peek(_ payload: [UInt8]) -> UInt8? {
        payload.first
    }
}
