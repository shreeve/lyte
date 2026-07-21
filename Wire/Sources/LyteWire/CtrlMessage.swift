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
    /// Client→host IDR request (IdrRequest). Sealed, ARQ-exempt; 0x10 is
    /// CL-3's original pin, clear of the 0x07…0x0F range left for W3's
    /// session machinery.
    public static let idrRequest: UInt8 = 0x10

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
