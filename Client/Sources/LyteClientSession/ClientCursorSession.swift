import LyteWire

/// One client-role interpretation of a host cursor-shape word.
public enum ClientCursorSessionEvent: Hashable, Sendable {
    case shape(CursorShape)
    case malformedShape
    case unnegotiatedShape
}

/// IO-free client policy for the host cursor plane. The organ validates and
/// capability-gates wire shapes; platform shells merely project an accepted
/// value into their native cursor vocabulary.
public struct ClientCursorSession: Sendable {
    public init() {}

    /// Handles only 0x24. Malformed input is classified before capability
    /// judgment, preserving the wire contract's hostile-input semantics.
    public func receiveReliable(
        _ bytes: [UInt8],
        agreed: Capabilities?
    ) -> ClientCursorSessionEvent? {
        guard bytes.first == CtrlMessageType.cursorShape else { return nil }
        guard let shape = try? CursorShape.decode(bytes) else {
            return .malformedShape
        }
        guard agreed?.cursorShape == true else {
            return .unnegotiatedShape
        }
        return .shape(shape)
    }
}
