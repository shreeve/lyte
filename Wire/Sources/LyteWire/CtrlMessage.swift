// The CTRL message-type registry (W4a). Every CTRL (chan 0) payload starts
// with one type byte — that byte, not the envelope, says what the message
// is. The rule holds in both carriage modes: today's bare fire-and-forget
// datagrams, and the ARQ stream framing that arrives with W3, where each
// framed message body starts with the same type byte.
//
// The beacon pair is ARQ-EXEMPT by design (master plan §4.6, overview
// conflict 10): clock mapping wants fresh timestamps, not reliable old
// ones, so beacon and beacon-echo ride CTRL as plain datagrams (fec = 0)
// and a lost one is simply superseded by the next 1 Hz send. Everything
// else on CTRL (handshake, capabilities, input, mode transitions, IDR
// requests) waits for W3's ArqEndpoint and registers its types then.

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
