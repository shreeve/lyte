/// Sans-IO state behind a screen source's change doorbell. A framebuffer id
/// is captured once per transition; resetting makes the current buffer fresh
/// again after an encoder or posture reconfiguration.
public struct ScreenDoorbell: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case unavailable
        case held
        case changed(UInt32)
    }

    private var lastFramebufferId: UInt32 = 0

    public init() {}

    public mutating func observe(_ framebufferId: UInt32?) -> Verdict {
        guard let framebufferId else { return .unavailable }
        guard framebufferId != lastFramebufferId else { return .held }
        lastFramebufferId = framebufferId
        return .changed(framebufferId)
    }

    public mutating func reset() {
        lastFramebufferId = 0
    }
}
