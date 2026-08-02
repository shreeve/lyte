// The control-codec vector-file model and loader:
// `Wire/Vectors/control-v1.json` — the CTRL/TLV/capability codecs that
// were pinned end-side under mirror-and-flag during H2 (HS-11's idle
// frame, HS-13/CL-9's input pair + lastInputSeq TLV, HS-18/CL-13's
// audio-routing pair + capability key 9) and promoted into LyteWire by
// the second codec-promotion slice. Same doctrine as the other
// loaders: TestKit may import Foundation, LyteWire may not.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/control-v1.json`.
public struct ControlVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ControlVector]

    public static let expectedFormat = "lyte-wire-control-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [ControlVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

    public static func load(from path: String) throws -> ControlVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ControlVectorFile.self, from: data)
    }
}

/// One input-echo tuple as vector data (u64s ride as hex, the house
/// JSON-precision rule).
public struct ControlEchoTuple: Codable, Sendable {
    public var seq: UInt32
    public var receivedHex: String
    public var injectedHex: String

    public init(seq: UInt32, receivedHex: String, injectedHex: String) {
        self.seq = seq
        self.receivedHex = receivedHex
        self.injectedHex = injectedHex
    }
}

/// One control-codec vector. `codec` names the codec under test; kinds
/// match the session file (`roundtrip` encodes the typed fields to
/// exactly `messageHex` and decodes back; `decodeReject` throws
/// `error`, a case name of the codec's error type). For
/// `lastInputSeqTlv`, `messageHex` is a whole envelope datagram (the
/// conn-id TLV precedent): decode must yield exactly `lastInputSeq`,
/// and the datagram re-encodes byte-exactly. For `capabilitySet`,
/// `messageHex` is a declaration's CBOR map: decode must answer
/// exactly `hostAudioRouting` through the key-9 accessor and re-encode
/// byte-exactly.
public struct ControlVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: ControlCodec
    public var messageHex: String
    /// idleFrame fields.
    public var frame: UInt32?
    public var timestampHex: String?
    public var annexBHex: String?
    /// inputEvent fields (bodyKind selects which body fields apply;
    /// coordinates ride as f64 bit patterns in hex).
    public var seq: UInt32?
    public var clientMicrosHex: String?
    public var bodyKind: BodyKind?
    public var keycode: UInt32?
    public var button: UInt32?
    public var pressed: Bool?
    public var xBitsHex: String?
    public var yBitsHex: String?
    public var finish: Bool?
    /// inputEcho field.
    public var tuples: [ControlEchoTuple]?
    /// lastInputSeqTlv field.
    public var lastInputSeq: UInt32?
    /// audioRoutingRequest/audioRoutingStatus field.
    public var mode: RoutingMode?
    /// capabilitySet field.
    public var hostAudioRouting: Bool?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum ControlCodec: String, Codable, Sendable {
        case idleFrame
        case inputEvent
        case inputEcho
        case lastInputSeqTlv
        case audioRoutingRequest
        case audioRoutingStatus
        case capabilitySet
    }

    public enum BodyKind: String, Codable, Sendable {
        case keyKeycode
        case pointerMotionAbsolute
        case pointerMotionRelative
        case pointerButton
        case pointerAxis
    }

    public enum RoutingMode: String, Codable, Sendable {
        case hostAudible
        case hostMuted
        /// 0x04 — 0x03 is the tombstone the routing-mode-unknown
        /// vector pinned forever.
        case streamOff
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: ControlCodec,
        messageHex: String,
        frame: UInt32? = nil,
        timestampHex: String? = nil,
        annexBHex: String? = nil,
        seq: UInt32? = nil,
        clientMicrosHex: String? = nil,
        bodyKind: BodyKind? = nil,
        keycode: UInt32? = nil,
        button: UInt32? = nil,
        pressed: Bool? = nil,
        xBitsHex: String? = nil,
        yBitsHex: String? = nil,
        finish: Bool? = nil,
        tuples: [ControlEchoTuple]? = nil,
        lastInputSeq: UInt32? = nil,
        mode: RoutingMode? = nil,
        hostAudioRouting: Bool? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.frame = frame
        self.timestampHex = timestampHex
        self.annexBHex = annexBHex
        self.seq = seq
        self.clientMicrosHex = clientMicrosHex
        self.bodyKind = bodyKind
        self.keycode = keycode
        self.button = button
        self.pressed = pressed
        self.xBitsHex = xBitsHex
        self.yBitsHex = yBitsHex
        self.finish = finish
        self.tuples = tuples
        self.lastInputSeq = lastInputSeq
        self.mode = mode
        self.hostAudioRouting = hostAudioRouting
        self.error = error
    }
}

/// The typed `InputEvent.Body` a vector's body fields describe, nil
/// when a field the kind requires is missing or malformed.
public func controlVectorBody(_ vector: ControlVector) -> InputEvent.Body? {
    switch vector.bodyKind {
    case .keyKeycode:
        guard let keycode = vector.keycode, let pressed = vector.pressed
        else { return nil }
        return .keyKeycode(keycode: keycode, pressed: pressed)
    case .pointerMotionAbsolute:
        guard let x = vector.xBitsHex.flatMap(Hex.uint64),
              let y = vector.yBitsHex.flatMap(Hex.uint64) else { return nil }
        return .pointerMotionAbsolute(
            x: Double(bitPattern: x), y: Double(bitPattern: y)
        )
    case .pointerMotionRelative:
        guard let x = vector.xBitsHex.flatMap(Hex.uint64),
              let y = vector.yBitsHex.flatMap(Hex.uint64) else { return nil }
        return .pointerMotionRelative(
            dx: Double(bitPattern: x), dy: Double(bitPattern: y)
        )
    case .pointerButton:
        guard let button = vector.button, let pressed = vector.pressed
        else { return nil }
        return .pointerButton(button: button, pressed: pressed)
    case .pointerAxis:
        guard let x = vector.xBitsHex.flatMap(Hex.uint64),
              let y = vector.yBitsHex.flatMap(Hex.uint64),
              let finish = vector.finish else { return nil }
        return .pointerAxis(
            dx: Double(bitPattern: x), dy: Double(bitPattern: y),
            finish: finish
        )
    case nil:
        return nil
    }
}

/// The vector-schema body descriptor for a typed `InputEvent.Body`
/// (the authoring direction of `controlVectorBody`).
public func controlVectorBodyFields(
    _ body: InputEvent.Body
) -> (
    kind: ControlVector.BodyKind, keycode: UInt32?, button: UInt32?,
    pressed: Bool?, xBitsHex: String?, yBitsHex: String?, finish: Bool?
) {
    switch body {
    case .keyKeycode(let keycode, let pressed):
        return (.keyKeycode, keycode, nil, pressed, nil, nil, nil)
    case .pointerMotionAbsolute(let x, let y):
        return (.pointerMotionAbsolute, nil, nil, nil,
                Hex.uint64String(x.bitPattern),
                Hex.uint64String(y.bitPattern), nil)
    case .pointerMotionRelative(let dx, let dy):
        return (.pointerMotionRelative, nil, nil, nil,
                Hex.uint64String(dx.bitPattern),
                Hex.uint64String(dy.bitPattern), nil)
    case .pointerButton(let button, let pressed):
        return (.pointerButton, nil, button, pressed, nil, nil, nil)
    case .pointerAxis(let dx, let dy, let finish):
        return (.pointerAxis, nil, nil, nil,
                Hex.uint64String(dx.bitPattern),
                Hex.uint64String(dy.bitPattern), finish)
    }
}

/// The typed routing mode a vector names.
public func controlVectorMode(
    _ mode: ControlVector.RoutingMode
) -> HostAudioRoutingMode {
    switch mode {
    case .hostAudible: return .hostAudible
    case .hostMuted: return .hostMuted
    case .streamOff: return .streamOff
    }
}

/// Stable names for `IdleFrameError` cases, as they appear in vectors.
public func idleFrameErrorName(_ error: IdleFrameError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    }
}

/// Stable names for `InputMessageError` cases, as they appear in vectors.
public func inputMessageErrorName(_ error: InputMessageError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .unknownKind: return "unknownKind"
    case .bodyLengthMismatch: return "bodyLengthMismatch"
    case .malformedFlag: return "malformedFlag"
    case .reservedBitsSet: return "reservedBitsSet"
    case .malformedTupleCount: return "malformedTupleCount"
    case .duplicateLastInputSeqTlv: return "duplicateLastInputSeqTlv"
    case .malformedLastInputSeqTlv: return "malformedLastInputSeqTlv"
    }
}

/// Stable names for `AudioRoutingMessageError` cases.
public func audioRoutingMessageErrorName(
    _ error: AudioRoutingMessageError
) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .unknownMode: return "unknownMode"
    case .trailingBytes: return "trailingBytes"
    }
}
