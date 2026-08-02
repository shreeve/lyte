// The CTRL message-type registry (W4a). Every CTRL (chan 0) payload starts
// with one type byte — that byte, not the envelope, says what the message
// is. The rule holds in both carriage modes: today's bare fire-and-forget
// datagrams, and the ARQ stream framing that arrives with W3, where each
// framed message body starts with the same type byte.
//
// The beacon pair is ARQ-EXEMPT by design (master plan §4.6, overview
// conflict 10): clock mapping wants fresh timestamps, not reliable old
// ones, so beacon and beacon-echo ride CTRL as plain datagrams (fec = 0)
// and a lost one is simply superseded by the next 1 Hz send.
//
// Types 0x03–0x06 and 0x10 were pinned end-side first (0x03/0x04 in
// HS-12, 0x05/0x06 in HS-7, 0x10 in CL-3, all flagged for promotion)
// and land here with the codec-unification slice — the numbers are
// carried verbatim; both ends already speak them. All are ARQ-exempt
// fire-and-forget: path messages must travel on the exact probed tuple,
// handshake retries are the client's timer, and a lost IDR request is
// superseded by the requester's next coalesced emission. Everything
// else on CTRL (capabilities, input, mode transitions) waits for W3's
// ArqEndpoint and registers its types then.
//
// Noise handshake carriage (the HS-7 pin, now canonical): each IK
// message travels as one CTRL datagram whose payload is the type byte
// followed by the raw Noise message — 0x05 = message 1 (client→host),
// 0x06 = message 2 (host→client). Handshake payloads are NOT sealed (no
// transport key exists yet; IK messages are self-protecting, and the
// version byte rides inside per W5's first-payload rule). Everything on
// CTRL after establishment is sealed with header-as-AAD; a bare
// 0x05/0x06 arriving post-establishment is dropped, not interpreted.

public enum CtrlMessageType {
    /// Never assigned — a zero type byte is always some other layer's
    /// zero-fill bug, and reserving it keeps that bug loud (the
    /// WireExtension.ReservedType.invalid rule).
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
    /// ARQ data segment (W3, ArqFrames). A reliable-channel payload
    /// starting with 0x07 or 0x08 is wholly ARQ — a sequence of frames,
    /// not a single message; route it to `ArqEndpoint.ingest`. Messages
    /// the ARQ delivers start with their own CTRL type byte.
    public static let arqSegment: UInt8 = 0x07
    /// ARQ ACK frame (W3): cumulative + bitmap receive state per
    /// (chan, group). Itself ARQ-exempt — a lost ACK is superseded.
    public static let arqAck: UInt8 = 0x08
    /// ACTIVE⇄IDLE mode transition (ModeTransition, W4b). The first
    /// ARQ-carried type: rides CTRL's ordered stream — a reordered mode
    /// flip would desynchronize the two ends' view of datagram video.
    public static let modeTransition: UInt8 = 0x09
    /// Typed session teardown (SessionTeardown, W4b): taken-over-by /
    /// shutting-down. ARQ-carried, ordered behind everything it follows.
    public static let sessionTeardown: UInt8 = 0x0A
    /// Client→host CPace share Ya (PairingShareA, W6). The pairing
    /// quartet 0x0B–0x0E rides the sealed ARQ ordered stream of the
    /// trust-on-first-use Noise session it authenticates — PairingPake
    /// binds the run to that session's handshake hash and statics.
    public static let pairingShareA: UInt8 = 0x0B
    /// Host→client CPace share Yb ‖ confirmation tag Tb (PairingShareB).
    public static let pairingShareB: UInt8 = 0x0C
    /// Client→host confirmation tag Ta (PairingConfirm) — verifying it
    /// completes pairing on the host.
    public static let pairingConfirm: UInt8 = 0x0D
    /// Either direction: typed pairing refusal (PairingReject) — loud
    /// wrong-PIN without an oracle.
    public static let pairingReject: UInt8 = 0x0E
    /// Both directions: the capability declaration (W7,
    /// CapabilityDeclaration — `type ‖ deterministic CBOR map`). The
    /// first ARQ-carried message each way after establishment; the
    /// session's agreed set is the intersection of the two.
    public static let capabilityDeclaration: UInt8 = 0x0F
    /// Client→host IDR request (IdrRequest). Sealed, ARQ-exempt; 0x10 is
    /// CL-3's original pin, clear of the 0x07…0x0F range left for W3's
    /// session machinery (0x07/0x08 taken by the ARQ frames, 0x09/0x0A
    /// by the W4b lifecycle messages, 0x0B–0x0E by the W6 pairing
    /// quartet, 0x0F by the W7 capability declaration).
    public static let idrRequest: UInt8 = 0x10
    /// Host→client session-parameter renegotiation proposal (W7,
    /// CapabilityUpdate) — renegotiable keys only (v1:
    /// maxDatagramBytes, the DPLPMTUD raise). ARQ-carried.
    public static let capabilityUpdate: UInt8 = 0x11
    /// Client→host answer to an update (CapabilityUpdateAck),
    /// echoing the proposal it accepts or rejects. ARQ-carried.
    public static let capabilityUpdateAck: UInt8 = 0x12
    /// Host→client stateless retry challenge (RetryChallenge) — the
    /// msg1-flood defense. Bare pre-transport like 0x05/0x06 (no
    /// session exists to seal it), ARQ-exempt: a lost challenge is
    /// answered by the client's msg1 retransmit drawing a fresh one.
    public static let retryChallenge: UInt8 = 0x13
    /// Client→host msg1 resubmission with the cookie echoed
    /// (RetryHandshake1). Bare pre-transport, ARQ-exempt — it IS the
    /// handshake attempt.
    public static let retryHandshake1: UInt8 = 0x14
    /// Host→client reliable idle frame (IdleFrame, HS-11 → CL-8,
    /// promoted by the second codec-promotion slice — the numbers are
    /// carried verbatim; both ends already speak them). Rides a CTRL
    /// one-shot ARQ group: the sender's ACTIVE→IDLE flip is gated on
    /// this message's group being fully acknowledged.
    public static let idleFrame: UInt8 = 0x15
    /// Client→host input event (InputEvent, HS-13 → CL-9, promoted).
    /// ARQ ordered stream — a lost or reordered keystroke is
    /// corruption, not weather.
    public static let inputEvent: UInt8 = 0x16
    /// Host→client input echo tuples (InputEcho, HS-13 → CL-9,
    /// promoted). ARQ ordered stream.
    public static let inputEcho: UInt8 = 0x17
    /// Client→host audio-routing flip request (AudioRoutingRequest,
    /// HS-18 → CL-13, promoted). ARQ ordered stream, gated on
    /// capability key 9 surviving intersection.
    public static let audioRoutingRequest: UInt8 = 0x18
    /// Host→client applied audio-routing posture (AudioRoutingStatus,
    /// HS-18 → CL-13, promoted). Same carriage and gate.
    public static let audioRoutingStatus: UInt8 = 0x19
    /// Client→host clipboard push (ClipboardSet, CL-15 — the first H3
    /// feature, born in the registry rather than promoted). ARQ
    /// ordered stream, gated on capability key 10 surviving
    /// intersection.
    public static let clipboardSet: UInt8 = 0x1A
    /// Host→client clipboard-change report (ClipboardAnnounce, CL-15).
    /// Same carriage and gate.
    public static let clipboardAnnounce: UInt8 = 0x1B
    /// Sender→receiver bulk-transfer offer (BulkOffer, W10 / F-2 —
    /// the bulk channel's vocabulary, born in the registry like
    /// CL-15's). The bulk sextet 0x1C–0x21 rides the ARQ ordered
    /// stream of CHANNEL 8 (ChannelId.bulkTransfer), never CTRL —
    /// the type space is shared across reliable channels (the W3
    /// rule), the carriage is not. Gated on capability key 11
    /// surviving intersection.
    public static let bulkOffer: UInt8 = 0x1C
    /// Receiver→sender consent + possession + opening credit
    /// (BulkAccept, W10). Chan 8 ordered stream.
    public static let bulkAccept: UInt8 = 0x1D
    /// Sender→receiver one chunk (BulkChunk, W10). Chan 8 ordered
    /// stream — deliberately not CTRL, so a file can never
    /// head-of-line-block a keystroke.
    public static let bulkChunk: UInt8 = 0x1E
    /// Receiver→sender possession + credit heartbeat (BulkAck, W10).
    /// Chan 8 ordered stream.
    public static let bulkAck: UInt8 = 0x1F
    /// Receiver→sender success verdict after digest verification
    /// (BulkComplete, W10). Chan 8 ordered stream.
    public static let bulkComplete: UInt8 = 0x20
    /// Either direction: typed transfer abort with reason
    /// (BulkAbort, W10). Chan 8 ordered stream.
    public static let bulkAbort: UInt8 = 0x21
    /// Either direction: clipboard-image cargo marker
    /// (ClipboardImageCargo, P-1 — clipboard v2). Rides CHAN 8's ARQ
    /// ordered stream immediately BEFORE its transfer's BulkOffer, so
    /// the receiver always knows a transferId is clipboard cargo (and
    /// its MIME) before the offer can reach the file machinery — the
    /// ordered stream is the race-free carriage. Gated on capability
    /// keys 10 AND 12 surviving intersection (the feature and the
    /// dialect; key 11 — the file-drop consent — is deliberately not
    /// in the gate).
    public static let clipboardImageCargo: UInt8 = 0x22
    /// Host→client repair refusal (RepairRefusal, HS-32): the HS-17
    /// NACK responder's stale verdicts made explicit so the client
    /// never blind-waits its full repair deadline on a repair the host
    /// already declined. Sealed, ARQ-exempt fire-and-forget like 0x10 —
    /// a lost refusal degrades to the client's own deadline expiry, by
    /// design; nothing may require a refusal to arrive.
    public static let repairRefused: UInt8 = 0x23
    /// Host→client cursor-shape announcement (CursorShape, E3 — the
    /// direct eye's cursor-as-metadata obligation, born in the
    /// registry like CL-15's pair). ARQ ordered stream — a reordered
    /// shape swap leaves the client wearing a stale cursor — gated on
    /// capability key 13 surviving intersection.
    public static let cursorShape: UInt8 = 0x24

    /// Host→client audio track-state announcement (AudioTrackState,
    /// the postures design's tripwire — silence with a signed IOU):
    /// quiet = transmission gated while capture continues, repeated
    /// as the ~5 s still-quiet check-in; active = transmitting. ARQ
    /// ordered stream, gated on capability key 15 surviving
    /// intersection.
    public static let audioTrackState: UInt8 = 0x25

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
