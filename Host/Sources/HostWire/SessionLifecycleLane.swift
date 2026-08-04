import LyteWire

/// One lifecycle service pass: the machine's externally executable actions
/// and, when the pass crossed a state boundary, its single final projection.
struct SessionLifecycleVerdict: Sendable {
    var actions: [SessionAction]
    var stateChangedTo: SessionState?
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
struct SessionLifecycleLane: Sendable {
    private let config: SessionMachineConfig
    private var machine: SessionStateMachine<HostClock>?

    private(set) var nextDeadlineNanoseconds: UInt64?
    private(set) var videoIsFrozen = false

    init(
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

    var isEstablished: Bool { machine != nil }
    var state: SessionState? { machine?.state }
    var wireMode: SessionWireMode? { machine?.wireMode }
    var closeReason: SessionCloseReason? { machine?.closeReason }
    var isRecovering: Bool { machine?.state == .recovery }

    /// A newly established machine needs one first service pass to project
    /// its timer. Thereafter only the exact due boundary runs; CLOSED is
    /// absorbing and owns no timer.
    func shouldService(at now: UInt64) -> Bool {
        guard let machine, machine.state != .closed else { return false }
        return nextDeadlineNanoseconds.map { now >= $0 } ?? true
    }

    /// Before establishment neither media lane exists. FROZEN then blocks
    /// only video; CLOSED blocks both.
    var videoSendsSuppressed: Bool {
        machine == nil || videoIsFrozen || machine?.state == .closed
    }

    var audioSendsSuppressed: Bool {
        machine == nil || machine?.state == .closed
    }

    /// Begins the machine in ACTIVE without inventing a state-change event.
    /// The first `drive` projects its timer, matching the machine's rule that
    /// apply/poll service starts only after establishment is complete.
    mutating func establish(at now: UInt64) {
        guard machine == nil else { return }
        machine = SessionStateMachine(
            role: .mediaSender,
            config: config,
            now: Self.instant(now)
        )
        nextDeadlineNanoseconds = nil
        videoIsFrozen = false
    }

    /// Applies one input first, then polls timers at the same injected instant.
    /// Freeze/resume actions are consumed into the local projection; all other
    /// actions return to `Session` in their original order.
    mutating func drive(
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
            case .freezeDatagramSends:
                videoIsFrozen = true
            case .resumeDatagramSends:
                videoIsFrozen = false
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
