import LyteWire

/// One lifecycle service pass: the machine's externally executable actions
/// and, when the pass crossed a state boundary, its single final projection.
public struct SessionLifecycleVerdict: Sendable {
    public var actions: [SessionAction]
    public var stateChangedTo: SessionState?
}

/// The sans-IO owner of the Host session's W4b lifecycle projection.
///
/// The shared Wire machine owns transition policy. This Host-role lane owns
/// when that machine exists, converts its microsecond timer into the session's
/// nanosecond domain, and projects its local freeze/resume actions into video
/// admission. `Session` retains every external effect: reliable messages,
/// estimator and pacer changes, keyframe causes, counters, and events.
///
/// FROZEN deliberately suppresses video only. Audio remains admitted as the
/// path probe until the terminal CLOSED state suppresses both media lanes.
public struct SessionLifecycleLane: Sendable {
    private let config: SessionMachineConfig
    private var machine: SessionStateMachine<HostClock>?

    public private(set) var nextDeadlineNanoseconds: UInt64?

    public init(
        config: SessionMachineConfig,
        establishedAtNanoseconds: UInt64? = nil
    ) {
        self.config = config
        if let now = establishedAtNanoseconds {
            machine = SessionStateMachine(
                role: .mediaSender,
                config: config,
                now: Self.instant(now)
            )
        }
    }

    public var isEstablished: Bool { machine != nil }
    public var state: SessionState? { machine?.state }
    public var wireMode: SessionWireMode? { machine?.wireMode }
    public var closeReason: SessionCloseReason? { machine?.closeReason }
    public var isRecovering: Bool { machine?.state == .recovery }

    /// A newly established machine needs one first service pass to project
    /// its timer. Thereafter only the exact due boundary runs; CLOSED is
    /// absorbing and owns no timer.
    public func shouldService(at now: UInt64) -> Bool {
        guard let machine, machine.state != .closed else { return false }
        return nextDeadlineNanoseconds.map { now >= $0 } ?? true
    }

    /// Before establishment neither media lane exists. FROZEN then blocks
    /// only video; CLOSED blocks both.
    public var videoSendsSuppressed: Bool {
        machine == nil || machine?.state == .frozen || machine?.state == .closed
    }

    public var audioSendsSuppressed: Bool {
        machine == nil || machine?.state == .closed
    }

    /// Begins the machine in ACTIVE without inventing a state-change event.
    /// The first `drive` projects its timer, matching the machine's rule that
    /// apply/poll service starts only after establishment is complete.
    public mutating func establish(at now: UInt64) {
        guard machine == nil else { return }
        machine = SessionStateMachine(
            role: .mediaSender,
            config: config,
            now: Self.instant(now)
        )
        nextDeadlineNanoseconds = nil
    }

    /// Applies one input first, then polls timers at the same injected instant.
    /// Freeze/resume actions are consumed into the local projection; all other
    /// actions return to `Session` in their original order.
    public mutating func drive(
        _ input: SessionInput?, now: UInt64
    ) -> SessionLifecycleVerdict {
        guard machine != nil else {
            return SessionLifecycleVerdict(actions: [], stateChangedTo: nil)
        }
        let before = machine!.state
        var actions: [SessionAction] = []
        if let input {
            actions += machine!.apply(input, now: Self.instant(now))
        }
        let (polled, deadline) = machine!.poll(now: Self.instant(now))
        actions += polled
        nextDeadlineNanoseconds = deadline.map {
            $0.microseconds &* 1_000
        }

        var external: [SessionAction] = []
        external.reserveCapacity(actions.count)
        for action in actions {
            switch action {
            case .freezeDatagramSends, .resumeDatagramSends:
                break
            default:
                external.append(action)
            }
        }
        return SessionLifecycleVerdict(
            actions: external,
            stateChangedTo: machine!.state == before ? nil : machine!.state
        )
    }

    private static func instant(_ nanoseconds: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: nanoseconds / 1_000)
    }
}
