// The control-codec vector-file model and loader:
// `Wire/Vectors/control-v1.json` — the idle frame, the input pair and
// lastInputSeq TLV, the audio-routing pair, and capability key 9.

import LyteCore
import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/control-v1.json`.
public struct ControlVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [ControlVector]

    public static let expectedFormat = "lyte-wire-control-vectors"
    public static let fileName = "control-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One input-echo tuple as vector data (u64s ride as hex, the house
/// JSON-precision rule).
public struct ControlEchoTuple: Codable, Sendable {
    public var seq: UInt32
    public var receivedHex: String
    public var injectedHex: String
}

/// One control-codec vector. `codec` names the codec under test; kinds
/// match the session file (`error` is a case name of the codec's error
/// type). For `lastInputSeqTlv`, `messageHex` is a whole envelope datagram:
/// decode must yield exactly `lastInputSeq` and re-encode byte-exactly.
/// For `capabilitySet`, `messageHex` is a declaration's CBOR map: decode
/// must answer exactly `hostAudioRouting` through the key-9 accessor and
/// re-encode byte-exactly.
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
