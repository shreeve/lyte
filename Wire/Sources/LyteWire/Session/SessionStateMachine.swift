// SessionStateMachine: the shared ACTIVE/IDLE/FROZEN/RECOVERY session
// core. The host runs it as `mediaSender` (drives wire modes and IDR
// decisions), the client as `mediaReceiver` (mirrors mode messages and
// derives FROZEN). It begins at establishment, in ACTIVE; handshake and
// path migration live elsewhere — a migrated peer is simply evidence
// returning.
//
// States:
//   - ACTIVE / IDLE are the wire modes, signaled via ModeTransition (0x09)
//     on CTRL's ARQ ordered stream. The session stays ACTIVE while the
//     ratchet runs.
//   - FROZEN / RECOVERY are the path-loss overlay, entered from either
//     wire mode and never signaled — each end derives them locally.
//   - WAKE is the IDLE→ACTIVE transition, not a state.
//
// Sender transitions:
//   - ACTIVE, ratchet converges → send the final frame on a video-idle
//     one-shot group; only its acknowledgement flips to IDLE and emits
//     mode=idle, so the receiver holds the converged frame first. New
//     damage before the ack aborts the pending flip.
//   - IDLE, input or damage → WAKE: mode=active, next damage frame is an
//     IDR paced at `.lastGoodRate`.
//   - ACTIVE/IDLE, `blackoutSilence` with no media-path evidence (feedback
//     or audio acks — never the 1 Hz beacon) → FROZEN: datagram video
//     stops, audio continues as the path probe, CTRL stays alive.
//   - FROZEN, any evidence returns → RECOVERY: force an IDR paced at
//     `.halfStaleEstimate`, re-send mode=active if frozen from IDLE. A
//     pre-arm input received while FROZEN is consumed exactly once by
//     this IDR.
//   - RECOVERY, `cleanWindowsToRecover` consecutive clean feedback windows
//     → ACTIVE; a dirty window resets the count. RECOVERY uses a longer
//     silence bar so the forced IDR can earn feedback before re-freezing.
//   - A converged ratchet during RECOVERY is accepted as in ACTIVE; the
//     acknowledged final frame is path evidence, so the IDLE flip clears
//     the overlay too.
//
// Liveness: `livenessTimeout` with no authenticated peer evidence closes
// the session locally with no wire message. Orderly ends send
// SessionTeardown (0x0A) on the ARQ stream.
//
// Sans-IO: inputs take an injected `now`, timers fire in `poll(now:)`,
// and the clock-domain phantom keeps host and client machines distinct.

public struct SessionMachineConfig: Hashable, Sendable {
    /// The blackout detector: this long with no media-path evidence
    /// (feedback datagrams, audio acks) freezes the session while
    /// ACTIVE or IDLE.
    public var blackoutSilenceMicroseconds: Int64
    /// Silence bar while RECOVERY, clamped to ≥ the ACTIVE bar. Default
    /// 2 s so a recovery IDR can finish and produce feedback before
    /// `freezeDatagramSends` aborts it.
    public var recoveryBlackoutSilenceMicroseconds: Int64
    /// The slow liveness clock: this long with no authenticated peer
    /// evidence of any kind closes the session.
    public var livenessTimeoutMicroseconds: Int64
    /// Consecutive clean feedback windows that graduate RECOVERY back
    /// to ACTIVE.
    public var cleanWindowsToRecover: Int

    public init(
        blackoutSilenceMicroseconds: Int64 = 350_000,
        recoveryBlackoutSilenceMicroseconds: Int64? = nil,
        livenessTimeoutMicroseconds: Int64 = 30_000_000,
        cleanWindowsToRecover: Int = 2
    ) {
        self.blackoutSilenceMicroseconds = blackoutSilenceMicroseconds
        self.recoveryBlackoutSilenceMicroseconds = max(
            recoveryBlackoutSilenceMicroseconds
                ?? max(blackoutSilenceMicroseconds, 2_000_000),
            blackoutSilenceMicroseconds
        )
        self.livenessTimeoutMicroseconds = livenessTimeoutMicroseconds
        self.cleanWindowsToRecover = max(cleanWindowsToRecover, 1)
    }
}

/// Which end of the session this machine runs. The sender (host)
/// drives wire modes and IDR decisions; the receiver (client) mirrors
/// mode messages and derives FROZEN for surfacing. Sender-only inputs
/// are ignored by a receiver and vice versa.
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
    /// WAKE from healthy IDLE: min(btlRate, lastGoodRate).
    case lastGoodRate
    /// RECOVERY from blackout: max(floor, 0.5 × stale estimate) — the
    /// path is unknown and the old estimate may far exceed it.
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
    /// the policy. The decision precedes the damage.
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

/// Everything the shell can tell the machine; one enum so tests can
/// enumerate state × input × role exhaustively.
public enum SessionInput: Hashable, Sendable {
    /// A media-path proof arrived: a feedback datagram or an audio
    /// ack. Feeds the 350 ms blackout detector and the liveness clock;
    /// exits FROZEN.
    case mediaPathEvidence
    /// Any other authenticated peer arrival (beacon echo, ARQ ack,
    /// sealed CTRL). Feeds the liveness clock and exits FROZEN, but
    /// deliberately NOT the blackout detector: 1 Hz beacons cannot drive it.
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
    /// The ratchet converged — the all-skip stop (sender).
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
    /// A pre-arm input arrived during FROZEN and awaits RECOVERY's IDR.
    /// Cleared exactly once, by that IDR.
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
        if let silenceLimit = silenceLimitMicroseconds,
           now.microseconds(since: lastMediaEvidenceAt) >= silenceLimit {
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

    /// ACTIVE/IDLE use the 350 ms bar; RECOVERY uses the longer grace.
    private var silenceLimitMicroseconds: Int64? {
        switch state {
        case .active, .idle:
            return config.blackoutSilenceMicroseconds
        case .recovery:
            return config.recoveryBlackoutSilenceMicroseconds
        case .frozen, .closed:
            return nil
        }
    }

    private func nextDeadline() -> Instant? {
        var earliest = lastPeerEvidenceAt.advanced(
            byMicroseconds: config.livenessTimeoutMicroseconds
        )
        if let silenceLimit = silenceLimitMicroseconds {
            let silence = lastMediaEvidenceAt.advanced(
                byMicroseconds: silenceLimit
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
        // The persisted pre-arm is consumed, exactly once, by this IDR —
        // the keypress's damage rides in the frame it carries.
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
