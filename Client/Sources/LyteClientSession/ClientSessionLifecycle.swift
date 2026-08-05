import LyteWire

/// One pure client-side lifecycle decision. The session shell executes the
/// wire actions and surfaces the optional state/mode edges after releasing
/// its synchronization boundary.
public struct ClientSessionLifecycleDecision: Hashable, Sendable {
    public let actions: [SessionAction]
    public let state: SessionState
    public let wireMode: SessionWireMode
    public let stateChange: SessionState?
    public let wireModeChange: SessionWireMode?

    public init(
        actions: [SessionAction],
        state: SessionState,
        wireMode: SessionWireMode,
        stateChange: SessionState?,
        wireModeChange: SessionWireMode?
    ) {
        self.actions = actions
        self.state = state
        self.wireMode = wireMode
        self.stateChange = stateChange
        self.wireModeChange = wireModeChange
    }
}

/// IO-free initiator-side lifecycle orchestration over LyteWire.
///
/// Time arrives as a client-domain wire timestamp. Inputs enter as values and
/// decisions leave as values; the platform shell owns clocks, locks, timers,
/// reliable sends, and event delivery.
public struct ClientSessionLifecycle: Sendable {
    private var machine: SessionStateMachine<ClientClock>
    private var reportedState: SessionState
    private var reportedWireMode: SessionWireMode

    public init(
        config: SessionMachineConfig,
        now: ClientTimestamp
    ) {
        let machine = SessionStateMachine<ClientClock>(
            role: .mediaReceiver,
            config: config,
            now: now
        )
        self.machine = machine
        self.reportedState = machine.state
        self.reportedWireMode = machine.wireMode
    }

    public var state: SessionState { machine.state }
    public var wireMode: SessionWireMode { machine.wireMode }
    public var isFrozen: Bool { machine.state == .frozen }

    /// Applies at most one input, fires every deadline due at `now`, and
    /// reports each resulting edge exactly once.
    public mutating func advance(
        _ input: SessionInput? = nil,
        now: ClientTimestamp
    ) -> ClientSessionLifecycleDecision {
        var actions: [SessionAction] = []
        if let input {
            actions += machine.apply(input, now: now)
        }
        let (polled, _) = machine.poll(now: now)
        actions += polled

        let stateChange =
            machine.state == reportedState ? nil : machine.state
        let wireModeChange =
            machine.wireMode == reportedWireMode ? nil : machine.wireMode
        reportedState = machine.state
        reportedWireMode = machine.wireMode

        return ClientSessionLifecycleDecision(
            actions: actions,
            state: machine.state,
            wireMode: machine.wireMode,
            stateChange: stateChange,
            wireModeChange: wireModeChange
        )
    }

    /// Rebuilds the receiver detector around a new timing policy while
    /// preserving the peer's last announced wire mode. Edge reporting remains
    /// deferred until the next `advance`, matching ordinary machine input.
    @discardableResult
    public mutating func reconfigure(
        _ config: SessionMachineConfig,
        now: ClientTimestamp
    ) -> Bool {
        guard machine.state != .closed else { return false }
        let preservedMode = machine.wireMode
        var rebuilt = SessionStateMachine<ClientClock>(
            role: .mediaReceiver,
            config: config,
            now: now
        )
        _ = rebuilt.apply(.modeMessage(preservedMode), now: now)
        machine = rebuilt
        return true
    }
}
