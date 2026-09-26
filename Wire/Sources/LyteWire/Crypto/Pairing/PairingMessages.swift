// The pairing wire messages: CPace's one round plus explicit key
// confirmation, as CTRL types 0x0B–0x0E, on the sealed ARQ ordered stream
// of an established Noise session. The CPace run is bound to that
// session's handshake hash and statics (PairingPake owns the binding), so
// a MITM'd session fails confirmation instead of getting pinned.
//
// Pake share A (type 0x0B), client→host, fixed 33 bytes:
//
//   offset size field
//   0      1    type   0x0B
//   1      32   Ya     the initiator's CPace public share
//
// Pake share B (type 0x0C), host→client, fixed 97 bytes:
//
//   offset size field
//   0      1    type   0x0C
//   1      32   Yb     the responder's CPace public share
//   33     64   Tb     the responder's §10.4 confirmation tag —
//                      HMAC-SHA-512, so the client learns wrong-PIN
//                      one message earlier than a separate round
//
// Pake confirm (type 0x0D), client→host, fixed 65 bytes:
//
//   offset size field
//   0      1    type   0x0D
//   1      64   Ta     the initiator's confirmation tag
//
// Pake reject (type 0x0E), either direction, fixed 2 bytes:
//
//   offset size field
//   0      1    type   0x0E
//   1      1    reason 0x01 confirmation-failed (wrong PIN or tampered
//                      binding — deliberately indistinguishable),
//                      0x02 invalid-share (G.I abort); others reject
//
// All four are exactly their fixed layout: truncation and trailing
// bytes reject, a foreign type byte rejects with what it found. The
// shares and tags are opaque bytes at this layer — validity is
// PairingPake's business, framing is this file's.

/// Why a pairing run was refused, as the wire carries it. One value for
/// every authentication failure on purpose: distinguishing "wrong PIN"
/// from "tampered transcript" would hand an active attacker an oracle.
public enum PairingRejectReason: UInt8, Hashable, CaseIterable, Sendable {
    case confirmationFailed = 0x01
    case invalidShare = 0x02
}

/// The client's CPace share (type 0x0B).
public struct PairingShareA: Hashable, Sendable, SliceDecodable {
    public var share: [UInt8]

    public static let encodedByteCount = 1 + CPace.elementByteCount

    public init(share: [UInt8]) {
        self.share = share
    }

    /// Encodes the 33-byte message. Throws on a mis-sized share.
    public func encode() throws -> [UInt8] {
        guard share.count == CPace.elementByteCount else {
            throw PairingMessageError.invalidShareLength(share.count)
        }
        return [CtrlMessageType.pairingShareA] + share
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> PairingShareA {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.pairingShareA,
            byteCount: encodedByteCount, PairingMessageError.self
        )
        return PairingShareA(
            share: Array(payload[(base + 1)..<(base + encodedByteCount)])
        )
    }
}

/// The host's CPace share plus its confirmation tag (type 0x0C).
public struct PairingShareB: Hashable, Sendable, SliceDecodable {
    public var share: [UInt8]
    public var confirmationTag: [UInt8]

    public static let encodedByteCount =
        1 + CPace.elementByteCount + CPace.tagByteCount

    public init(share: [UInt8], confirmationTag: [UInt8]) {
        self.share = share
        self.confirmationTag = confirmationTag
    }

    /// Encodes the 97-byte message. Throws on mis-sized fields.
    public func encode() throws -> [UInt8] {
        guard share.count == CPace.elementByteCount else {
            throw PairingMessageError.invalidShareLength(share.count)
        }
        guard confirmationTag.count == CPace.tagByteCount else {
            throw PairingMessageError.invalidTagLength(confirmationTag.count)
        }
        return [CtrlMessageType.pairingShareB] + share + confirmationTag
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> PairingShareB {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.pairingShareB,
            byteCount: encodedByteCount, PairingMessageError.self
        )
        let shareEnd = base + 1 + CPace.elementByteCount
        return PairingShareB(
            share: Array(payload[(base + 1)..<shareEnd]),
            confirmationTag: Array(
                payload[shareEnd..<(base + encodedByteCount)]
            )
        )
    }
}

/// The client's confirmation tag (type 0x0D) — the message whose
/// verification completes pairing on the host.
public struct PairingConfirm: Hashable, Sendable, SliceDecodable {
    public var confirmationTag: [UInt8]

    public static let encodedByteCount = 1 + CPace.tagByteCount

    public init(confirmationTag: [UInt8]) {
        self.confirmationTag = confirmationTag
    }

    /// Encodes the 65-byte message. Throws on a mis-sized tag.
    public func encode() throws -> [UInt8] {
        guard confirmationTag.count == CPace.tagByteCount else {
            throw PairingMessageError.invalidTagLength(confirmationTag.count)
        }
        return [CtrlMessageType.pairingConfirm] + confirmationTag
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> PairingConfirm {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.pairingConfirm,
            byteCount: encodedByteCount, PairingMessageError.self
        )
        return PairingConfirm(
            confirmationTag: Array(
                payload[(base + 1)..<(base + encodedByteCount)]
            )
        )
    }
}

/// The typed pairing refusal (type 0x0E) — how "wrong PIN" gets loud
/// without becoming an oracle.
public struct PairingReject: Hashable, Sendable, SliceDecodable {
    public var reason: PairingRejectReason

    public static let encodedByteCount = 2

    public init(reason: PairingRejectReason) {
        self.reason = reason
    }

    /// Encodes the 2-byte message. Cannot fail.
    public func encode() -> [UInt8] {
        [CtrlMessageType.pairingReject, reason.rawValue]
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> PairingReject {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.pairingReject,
            byteCount: encodedByteCount, PairingMessageError.self
        )
        guard let reason = PairingRejectReason(
            rawValue: payload[base + 1]
        ) else {
            throw PairingMessageError.unknownReason(payload[base + 1])
        }
        return PairingReject(reason: reason)
    }
}

/// Everything the pairing codecs can refuse. Hostile bytes throw,
/// never trap.
public enum PairingMessageError: FixedFrameError, Hashable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
    case unknownReason(UInt8)
    case invalidShareLength(Int)
    case invalidTagLength(Int)
}
