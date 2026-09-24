// What lyte-host does when a session ends. The listening service serves
// sessions in turn inside one process (scanout, GL context, socket,
// advertisement and input devices stay up) with no wall-clock bound.
// Every other posture serves one session and exits.
//
// A failure never loops: it may have left the GPU or encoder in an
// unknown state, so the process exits non-zero and the service manager
// starts a fresh one. A display mode change also exits.
//
// Sans-IO: the shell reports how each session ended; this decides.

public struct HostServiceLoop: Sendable {
    public enum Posture: Equatable, Sendable {
        /// Serve one session, its leg bounded by `seconds`, then exit.
        case singleSession(seconds: Double)
        /// Serve sessions in turn, each unbounded, until termination or
        /// a failure.
        case service
    }

    /// Why a session's leg stopped.
    public enum SessionEnd: Equatable, Sendable {
        /// Termination was requested before any client completed a
        /// handshake; no leg ran.
        case terminatedBeforeHandshake
        /// The session itself ended: the client tore it down, went
        /// silent past the liveness timeout, or its socket closed.
        case sessionEnded
        /// A single session's `seconds` bound elapsed.
        case clockExpired
        /// SIGINT or SIGTERM arrived during the session.
        case terminationRequested
        /// The display geometry changed under the warm scanout.
        case displayModeChanged
        /// The leg or its session failed.
        case failed(String)
    }

    /// What the leg produced, for the stream-startability checks.
    public struct LegEvidence: Equatable, Sendable {
        public var frames: Int
        /// Whether the first encoded packet began with VPS/SPS/PPS and
        /// an IRAP picture (meaningless when `frames` is 0).
        public var firstPacketStartsStream: Bool

        public init(frames: Int, firstPacketStartsStream: Bool) {
            self.frames = frames
            self.firstPacketStartsStream = firstPacketStartsStream
        }
    }

    public enum Next: Equatable, Sendable {
        case serveAnother
        /// Exit the process; a non-nil failure exits non-zero.
        case exit(failure: String?)
    }

    public let posture: Posture
    public private(set) var sessionsServed = 0

    public init(posture: Posture) {
        self.posture = posture
    }

    /// The posture a command line asks for: only a listening session
    /// without an explicit clock and without pairing is the service.
    /// A pairing run mints one PIN, which one session consumes.
    public static func posture(
        listening: Bool, secondsGiven: Bool, pairing: Bool, seconds: Double
    ) -> Posture {
        listening && !secondsGiven && !pairing
            ? .service : .singleSession(seconds: seconds)
    }

    /// The bound on the next session's leg, in seconds.
    public var sessionSeconds: Double {
        switch posture {
        case .service: .infinity
        case .singleSession(let seconds): seconds
        }
    }

    public mutating func sessionEnded(
        _ end: SessionEnd, leg: LegEvidence
    ) -> Next {
        sessionsServed += 1
        switch end {
        case .terminatedBeforeHandshake:
            return .exit(failure: nil)
        case .failed(let why):
            return .exit(failure: why)
        case .sessionEnded, .clockExpired, .terminationRequested,
             .displayModeChanged:
            break
        }
        if leg.frames > 0, !leg.firstPacketStartsStream {
            return .exit(failure: """
                the first packet does not begin with VPS/SPS/PPS and an \
                IRAP picture
                """)
        }
        switch posture {
        case .singleSession(let seconds):
            // Zero frames is a host fault only when the leg ran its
            // course; a client that leaves first (a pairing client always
            // does) owed the eye nothing.
            guard leg.frames > 0 || end == .sessionEnded else {
                return .exit(
                    failure: "direct eye produced no frames in \(Int(seconds))s")
            }
            return .exit(failure: nil)
        case .service:
            // A client may leave before the first frame; that is not a
            // fault of the host.
            return end == .sessionEnded ? .serveAnother : .exit(failure: nil)
        }
    }
}
