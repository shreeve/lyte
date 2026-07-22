// SessionStateMachine (W4b): the shared session-lifecycle core — the
// ACTIVE/IDLE/FROZEN/RECOVERY pure logic the core plan pinned (§2) and
// the overview ruled into one four-state machine (§2 "Mode machine",
// conflict 14). Both ends instantiate it: the host as `mediaSender`
// (it drives the wire modes and the IDR decisions), the client as
// `mediaReceiver` (it mirrors mode messages and derives the FROZEN
// pill). Handshake sequencing is NOT here — NoiseSession (W5) owns it,
// and this machine begins at establishment, in ACTIVE. Connection
// migration is not an input either: HS-12's PathValidator owns the
// tuple change, and to this machine a migrated peer is simply
// media/CTRL evidence returning (resiliency §6 — migration only
// requires that feedback from a new 4-tuple be attributable).
//
// The state model, exactly the overview's ruling:
//   - ACTIVE / IDLE are the wire modes, signaled on CTRL's ARQ ordered
//     stream via ModeTransition (0x09). The session stays ACTIVE while
//     the ratchet runs.
//   - FROZEN / RECOVERY are the path-loss overlay, entered from either
//     wire mode, NEVER signaled on the wire — each end derives them
//     from its own silence detector.
//   - WAKE is the IDLE→ACTIVE transition, not a state.
//
// Sender transitions (resiliency §4, overview conflicts 5 and 14):
//   - ACTIVE, ratchet converges (all-skip stop) → send the final
//     converged frame on a video-idle reliable ONE-SHOT group and wait;
//     only its acknowledgement (ArqEvent.oneShotAcknowledged) flips to
//     IDLE and emits mode=idle — one-shot groups are unordered against
//     the CTRL stream, so waiting for the ack is what guarantees the
//     receiver holds the converged frame before it learns the session
//     went idle. New damage before the ack aborts the pending flip;
//     the session never left ACTIVE.
//   - IDLE, injected input or fresh damage → WAKE: mode=active on
//     CTRL, next damage frame is an IDR paced at min(btlRate,
//     lastGoodRate) — the healthy-path rate (conflict 14).
//   - any streaming state, 350 ms with no feedback and no audio acks →
//     FROZEN: datagram video stops, audio continues as the path probe,
//     CTRL stays alive. The 350 ms detector runs on the media-path
//     evidence stream (25–50 ms feedback cadence + audio acks), NOT on
//     the 1 Hz beacon — a beacon could never drive a 350 ms detector
//     (conflict 10), which is why the two evidence kinds are separate
//     inputs.
//   - FROZEN, any evidence returns (feedback OR a beacon ack, possibly
//     from a new address) → RECOVERY: the path is unknown — force a
//     fresh IDR paced at max(floor, 0.5 × stale estimate), re-enter
//     mode=active if the freeze happened in IDLE. A pre-arm input that
//     arrived during the blackout persists through FROZEN and is
//     consumed exactly once by this IDR (conflict 14) — a keypress
//     during a blackout is never lost semantics.
//   - RECOVERY, two consecutive clean feedback windows → ACTIVE (the
//     overlay clears; the wire mode never changed). A dirty window
//     resets the count. Renewed silence re-freezes.
//   - A converged ratchet during RECOVERY is accepted like ACTIVE's:
//     the final frame rides its one-shot, and an acknowledged delivery
//     through the recovering path is path evidence at least as strong
//     as a clean window, so the flip to IDLE clears the overlay too.
//     (This machine's ruling — the pillars leave the overlap open.)
//
// Liveness and teardown (transport §4, overview conflict 10): the slow
// session-liveness clock runs on ANY authenticated peer evidence; ≥30 s
// of nothing closes the session locally — no wire message, because the
// peer that would read it is the one that died. Orderly ends send the
// typed SessionTeardown (0x0A) on the ARQ stream — `takenOver` is the
// multi-client ruling's `taken-over-by`, and reliable ordered carriage
// means a teardown can never overtake the messages that explain it.
//
// Sans-IO, the ArqEndpoint discipline exactly: inputs are applied with
// an injected `now`, timers fire in `poll(now:)` which returns actions
// plus the next deadline, and the clock-domain phantom makes a
// host-clock machine and a client-clock machine different types.

public struct SessionMachineConfig: Hashable, Sendable {
    /// The blackout detector: this long with no media-path evidence
    /// (feedback datagrams, audio acks) freezes the session.
    /// Resiliency §4 pins 350 ms — covers office→kitchen roams, well
    /// past any aggregation stall.
    public var blackoutSilenceMicroseconds: Int64
    /// The slow liveness clock: this long with no authenticated peer
    /// evidence of any kind closes the session (transport's ≥30 s).
    public var livenessTimeoutMicroseconds: Int64
    /// Consecutive clean feedback windows that graduate RECOVERY back
    /// to ACTIVE (resiliency §4 pins 2).
    public var cleanWindowsToRecover: Int

    public init(
        blackoutSilenceMicroseconds: Int64 = 350_000,
        livenessTimeoutMicroseconds: Int64 = 30_000_000,
        cleanWindowsToRecover: Int = 2
    ) {
        self.blackoutSilenceMicroseconds = blackoutSilenceMicroseconds
        self.livenessTimeoutMicroseconds = livenessTimeoutMicroseconds
        self.cleanWindowsToRecover = max(cleanWindowsToRecover, 1)
    }
}

/// Which end of the session this machine runs. The sender (host)
/// drives wire modes and IDR decisions; the receiver (client) mirrors
/// mode messages and derives FROZEN for surfacing (CL-8's pill).
/// Sender-only inputs are ignored by a receiver and vice versa — the
/// coverage table asserts every such pairing.
public enum SessionRole: Hashable, CaseIterable, Sendable {
    case mediaSender
    case mediaReceiver
}

/// The four lifecycle states plus the terminal one. `active`/`idle`
/// track the wire mode; `frozen`/`recovery` are the local path-loss
/// overlay (`wireMode` remembers what the overlay sits on); `closed`
/// is absorbing — every input no-ops there.
public enum SessionState: Hashable, CaseIterable, Sendable {
    case active
    case idle
    case frozen
    case recovery
    case closed
}

/// How an emitted IDR must be paced. The machine names the policy;
/// the shell's estimator owns the numbers.
public enum IdrPacing: Hashable, Sendable {
    /// WAKE from healthy IDLE: min(btlRate, lastGoodRate) —
    /// overview conflict 14's healthy-path rate.
    case lastGoodRate
    /// RECOVERY from blackout: max(floor, 0.5 × stale estimate) —
    /// the path is unknown, the old estimate may be 10× the new
    /// path's capacity (resiliency §4).
    case halfStaleEstimate
}

/// Why the session closed.
public enum SessionCloseReason: Hashable, Sendable {
    /// This end requested teardown; the typed message was emitted.
    case localTeardown(SessionTeardownReason)
    /// The peer's SessionTeardown arrived on the ARQ stream.
    case peerTeardown(SessionTeardownReason)
    /// ≥ livenessTimeout with no authenticated peer evidence. No wire
    /// message — the peer that would read it is gone.
    case livenessTimeout
}

/// Everything the machine can ask its shell to do. Edge-triggered:
/// each action is emitted exactly once per cause; steady state is
/// observed via `state`/`wireMode`.
public enum SessionAction: Hashable, Sendable {
    /// Encode a ModeTransition and send it on CTRL's ARQ ordered
    /// stream (group 0).
    case sendModeMessage(SessionWireMode)
    /// Encode a SessionTeardown and send it on the ARQ stream.
    case sendTeardownMessage(SessionTeardownReason)
    /// Hand the converged ratchet frame to a fresh video-idle one-shot
    /// ARQ group; report its acknowledgement back as
    /// `.finalFrameAcknowledged`.
    case sendFinalFrameReliably
    /// WAKE: mark the next encoded damage frame as an IDR, paced per
    /// the policy. The decision precedes the damage (timing §7's
    /// pre-arm rule).
    case armNextDamageAsIdr(IdrPacing)
    /// RECOVERY: force a fresh IDR now, paced per the policy. This is
    /// the action that consumes a persisted pre-arm.
    case forceIdr(IdrPacing)
    /// FROZEN entry (sender): stop datagram video and retransmit
    /// sends; audio continues at CBR as the path probe; CTRL lives.
    case freezeDatagramSends
    /// RECOVERY entry (sender): datagram sends may flow again.
    case resumeDatagramSends
    /// The session reached `closed`.
    case sessionClosed(SessionCloseReason)
}

/// Everything the shell can tell the machine. One enum so the W-G5
/// transition-coverage table can enumerate state × input × role
/// exhaustively.
public enum SessionInput: Hashable, Sendable {
    /// A media-path proof arrived: a feedback datagram or an audio
    /// ack. Feeds the 350 ms blackout detector and the liveness clock;
    /// exits FROZEN.
    case mediaPathEvidence
    /// Any other authenticated peer arrival (beacon echo, ARQ ack,
    /// sealed CTRL). Feeds the liveness clock and exits FROZEN
    /// ("beacon acked" — resiliency §4), but deliberately NOT the
    /// 350 ms detector: 1 Hz beacons cannot drive it.
    case ctrlEvidence
    /// The estimator's verdict on one elapsed feedback window
    /// (sender). Clean windows graduate RECOVERY; a dirty one resets.
    case feedbackWindow(clean: Bool)
    /// An injected input event (sender): the WAKE pre-arm signal.
    /// In IDLE it wakes immediately; in FROZEN it persists until
    /// RECOVERY's IDR consumes it.
    case preArmInput
    /// Fresh damage exists (sender). Wakes IDLE; aborts a pending
    /// ACTIVE→IDLE flip (new damage during the ratchet handoff).
    case damage
    /// The ratchet converged — the all-skip stop (sender, HS-3's
    /// detector via HS-11).
    case ratchetConverged
    /// The final converged frame's one-shot group was fully
    /// acknowledged (sender; ArqEvent.oneShotAcknowledged).
    case finalFrameAcknowledged
    /// An ARQ-delivered ModeTransition (receiver).
    case modeMessage(SessionWireMode)
    /// An ARQ-delivered SessionTeardown (both roles).
    case teardownMessage(SessionTeardownReason)
    /// This end wants an orderly close (both roles).
    case teardownRequest(SessionTeardownReason)
}

public struct SessionStateMachine<ClockDomain>: Sendable {
    public typealias Instant = WireTimestamp<ClockDomain>

    public let role: SessionRole
    public let config: SessionMachineConfig

    public private(set) var state: SessionState
    /// The wire mode beneath the overlay — what the peer was last told
    /// (sender) or last said (receiver). Unchanged by FROZEN/RECOVERY
    /// except that RECOVERY entry forces it to `.active`.
    public private(set) var wireMode: SessionWireMode
    /// A pre-arm input arrived during FROZEN and awaits RECOVERY's IDR
    /// (overview conflict 14). Cleared exactly once, by that IDR.
    public private(set) var isPreArmed: Bool
    /// The converged frame's one-shot is in flight; its ack flips to
    /// IDLE. Cleared by new damage (abort) and by FROZEN entry.
    public private(set) var awaitingFinalFrameAcknowledgement: Bool
    /// RECOVERY's progress toward ACTIVE.
    public private(set) var consecutiveCleanWindows: Int
    public private(set) var closeReason: SessionCloseReason?

    private var lastMediaEvidenceAt: Instant
    private var lastPeerEvidenceAt: Instant

    /// The machine begins at establishment (post-Noise, post-
    /// capabilities), streaming: ACTIVE, both evidence clocks fresh.
    public init(
        role: SessionRole,
        config: SessionMachineConfig = SessionMachineConfig(),
        now: Instant
    ) {
        self.role = role
        self.config = config
        self.state = .active
        self.wireMode = .active
        self.isPreArmed = false
        self.awaitingFinalFrameAcknowledgement = false
        self.consecutiveCleanWindows = 0
        self.closeReason = nil
        self.lastMediaEvidenceAt = now
        self.lastPeerEvidenceAt = now
    }

    // MARK: - Inputs

    /// Applies one input. Returns the actions it caused, in order.
    /// Call `poll` afterwards — apply never fires timers.
    public mutating func apply(
        _ input: SessionInput, now: Instant
    ) -> [SessionAction] {
        guard state != .closed else { return [] }
        switch input {
        case .mediaPathEvidence:
            lastMediaEvidenceAt = now
            lastPeerEvidenceAt = now
            return exitFrozenIfNeeded(now: now)

        case .ctrlEvidence:
            lastPeerEvidenceAt = now
            return exitFrozenIfNeeded(now: now)

        case .feedbackWindow(let clean):
            guard role == .mediaSender, state == .recovery else { return [] }
            if clean {
                consecutiveCleanWindows += 1
                if consecutiveCleanWindows >= config.cleanWindowsToRecover {
                    state = .active
                    consecutiveCleanWindows = 0
                }
            } else {
                consecutiveCleanWindows = 0
            }
            return []

        case .preArmInput:
            guard role == .mediaSender else { return [] }
            switch state {
            case .idle:
                return wake()
            case .frozen:
                isPreArmed = true
                return []
            case .active, .recovery, .closed:
                return []
            }

        case .damage:
            guard role == .mediaSender else { return [] }
            switch state {
            case .idle:
                return wake()
            case .active, .recovery:
                // New damage during the convergence handoff aborts the
                // pending flip; the session never left ACTIVE.
                awaitingFinalFrameAcknowledgement = false
                return []
            case .frozen, .closed:
                // The path is dark; RECOVERY's forced IDR will carry
                // the current screen anyway.
                return []
            }

        case .ratchetConverged:
            guard role == .mediaSender,
                  state == .active || state == .recovery
            else { return [] }
            awaitingFinalFrameAcknowledgement = true
            return [.sendFinalFrameReliably]

        case .finalFrameAcknowledged:
            guard role == .mediaSender,
                  awaitingFinalFrameAcknowledgement,
                  state == .active || state == .recovery
            else { return [] }
            awaitingFinalFrameAcknowledgement = false
            state = .idle
            wireMode = .idle
            consecutiveCleanWindows = 0
            return [.sendModeMessage(.idle)]

        case .modeMessage(let mode):
            guard role == .mediaReceiver else { return [] }
            lastPeerEvidenceAt = now
            wireMode = mode
            if state == .frozen {
                // A delivered CTRL message is the path returning.
                lastMediaEvidenceAt = now
            }
            state = mode == .active ? .active : .idle
            return []

        case .teardownMessage(let reason):
            return close(.peerTeardown(reason))

        case .teardownRequest(let reason):
            return [.sendTeardownMessage(reason)]
                + close(.localTeardown(reason))
        }
    }

    // MARK: - Timers

    /// Fires due timers and reports the next instant `poll` must run
    /// again, nil when none is armed (closed). Call after every apply
    /// and at the returned deadline.
    public mutating func poll(
        now: Instant
    ) -> (actions: [SessionAction], nextDeadline: Instant?) {
        guard state != .closed else { return ([], nil) }

        if now.microseconds(since: lastPeerEvidenceAt)
            >= config.livenessTimeoutMicroseconds {
            return (close(.livenessTimeout), nil)
        }

        var actions: [SessionAction] = []
        if silenceDetectorRuns,
           now.microseconds(since: lastMediaEvidenceAt)
               >= config.blackoutSilenceMicroseconds {
            // FROZEN entry: the pending idle flip dies with the path
            // (RECOVERY re-ratchets); the wire mode stays whatever it
            // was — FROZEN is never a wire mode.
            awaitingFinalFrameAcknowledgement = false
            state = .frozen
            if role == .mediaSender {
                actions.append(.freezeDatagramSends)
            }
        }
        return (actions, nextDeadline())
    }

    private var silenceDetectorRuns: Bool {
        switch state {
        case .active, .idle, .recovery: return true
        case .frozen, .closed: return false
        }
    }

    private func nextDeadline() -> Instant? {
        var earliest = lastPeerEvidenceAt.advanced(
            byMicroseconds: config.livenessTimeoutMicroseconds
        )
        if silenceDetectorRuns {
            let silence = lastMediaEvidenceAt.advanced(
                byMicroseconds: config.blackoutSilenceMicroseconds
            )
            if silence < earliest { earliest = silence }
        }
        return earliest
    }

    // MARK: - Transitions

    /// WAKE: IDLE→ACTIVE on input or damage. The IDR decision precedes
    /// the damage; the healthy-path pacing policy applies.
    private mutating func wake() -> [SessionAction] {
        state = .active
        wireMode = .active
        return [
            .sendModeMessage(.active),
            .armNextDamageAsIdr(.lastGoodRate),
        ]
    }

    /// FROZEN → RECOVERY (sender) or back to the wire mode (receiver)
    /// on returning evidence. Resets the silence clock — the fresh
    /// path gets a full window to produce feedback before it can
    /// re-freeze.
    private mutating func exitFrozenIfNeeded(
        now: Instant
    ) -> [SessionAction] {
        guard state == .frozen else { return [] }
        lastMediaEvidenceAt = now
        guard role == .mediaSender else {
            state = wireMode == .active ? .active : .idle
            return []
        }
        state = .recovery
        consecutiveCleanWindows = 0
        var actions: [SessionAction] = [.resumeDatagramSends]
        if wireMode == .idle {
            wireMode = .active
            actions.append(.sendModeMessage(.active))
        }
        actions.append(.forceIdr(.halfStaleEstimate))
        // The persisted pre-arm is consumed, exactly once, by this
        // IDR (overview conflict 14) — the keypress's damage rides in
        // the frame the IDR carries.
        isPreArmed = false
        return actions
    }

    private mutating func close(
        _ reason: SessionCloseReason
    ) -> [SessionAction] {
        state = .closed
        closeReason = reason
        return [.sessionClosed(reason)]
    }
}
