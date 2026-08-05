/// Sans-IO state that distinguishes framebuffer replacement from a held
/// import. Identity changes invalidate the platform shell's dmabuf cache;
/// they say nothing about whether pixels changed inside the current buffer.
public struct FramebufferIdentityTracker: Sendable, Equatable {
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
