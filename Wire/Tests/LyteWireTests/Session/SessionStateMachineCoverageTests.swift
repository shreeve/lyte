import XCTest
import LyteWire

// W-G5b's core artifact: the transition-coverage table. Every state ×
// every input × both roles has an asserted outcome — including the
// illegal/ignored ones (core plan §4: "every state × every input has
// an asserted outcome — including the illegal ones"). The table rows
// are explicit data, not a re-implementation of the machine: each row
// pins the next state and the exact action list.
//
// Timer coverage (poll) rides in a second table: silence → FROZEN from
// every streaming state, liveness → closed from everywhere, closed is
// absorbing.

final class SessionStateMachineCoverageTests: XCTestCase {

    typealias Machine = SessionStateMachine<HostClock>
    typealias Instant = WireTimestamp<HostClock>

    static let t0 = Instant(microseconds: 1_000_000)

    /// Drives a fresh machine into `state`, returning it plus a `now`
    /// safely past the driving inputs and safely before any timer.
    func machine(
        role: SessionRole, in state: SessionState
    ) -> (Machine, Instant) {
        var m = Machine(role: role, now: Self.t0)
        var now = Self.t0
        switch state {
        case .active:
            break
        case .idle:
            if role == .mediaSender {
                _ = m.apply(.ratchetConverged, now: now)
                _ = m.apply(.finalFrameAcknowledged, now: now)
            } else {
                _ = m.apply(.modeMessage(.idle), now: now)
            }
        case .frozen:
            now = now.advanced(byMicroseconds: 350_000)
            _ = m.poll(now: now)
        case .recovery:
            precondition(role == .mediaSender)
            now = now.advanced(byMicroseconds: 350_000)
            _ = m.poll(now: now)
            _ = m.apply(.mediaPathEvidence, now: now)
        case .closed:
            _ = m.apply(.teardownRequest(.shuttingDown), now: now)
        }
        precondition(m.state == state, "drive failed for \(role)/\(state)")
        return (m, now.advanced(byMicroseconds: 1_000))
    }

    struct Row {
        let role: SessionRole
        let state: SessionState
        let input: SessionInput
        let expectState: SessionState
        let expectActions: [SessionAction]
        let line: UInt

        init(
            _ role: SessionRole, _ state: SessionState,
            _ input: SessionInput,
            _ expectState: SessionState,
            _ expectActions: [SessionAction],
            line: UInt = #line
        ) {
            self.role = role
            self.state = state
            self.input = input
            self.expectState = expectState
            self.expectActions = expectActions
            self.line = line
        }
    }

    /// Inputs whose outcome is identical in every non-closed state.
    static let teardownRows: [(SessionInput, [SessionAction])] = [
        (
            .teardownMessage(.takenOver),
            [.sessionClosed(.peerTeardown(.takenOver))]
        ),
        (
            .teardownRequest(.shuttingDown),
            [
                .sendTeardownMessage(.shuttingDown),
                .sessionClosed(.localTeardown(.shuttingDown)),
            ]
        ),
    ]

    func testEveryStateInputRolePairing() {
        let S = SessionRole.mediaSender
        let R = SessionRole.mediaReceiver

        var rows: [Row] = [
            // ───────────── sender / ACTIVE ─────────────
            Row(S, .active, .mediaPathEvidence, .active, []),
            Row(S, .active, .ctrlEvidence, .active, []),
            Row(S, .active, .feedbackWindow(clean: true), .active, []),
            Row(S, .active, .feedbackWindow(clean: false), .active, []),
            Row(S, .active, .preArmInput, .active, []),
            Row(S, .active, .damage, .active, []),
            Row(S, .active, .ratchetConverged, .active,
                [.sendFinalFrameReliably]),
            // The base drive leaves no one-shot awaiting an ack, so a
            // stray ack is ignored (the flip path is asserted in the
            // behavior suite).
            Row(S, .active, .finalFrameAcknowledged, .active, []),
            Row(S, .active, .modeMessage(.active), .active, []),
            Row(S, .active, .modeMessage(.idle), .active, []),

            // ───────────── sender / IDLE ─────────────
            Row(S, .idle, .mediaPathEvidence, .idle, []),
            Row(S, .idle, .ctrlEvidence, .idle, []),
            Row(S, .idle, .feedbackWindow(clean: true), .idle, []),
            Row(S, .idle, .feedbackWindow(clean: false), .idle, []),
            // WAKE, both triggers: mode flip on CTRL + pre-armed IDR
            // at the healthy-path rate.
            Row(S, .idle, .preArmInput, .active,
                [.sendModeMessage(.active),
                 .armNextDamageAsIdr(.lastGoodRate)]),
            Row(S, .idle, .damage, .active,
                [.sendModeMessage(.active),
                 .armNextDamageAsIdr(.lastGoodRate)]),
            Row(S, .idle, .ratchetConverged, .idle, []),
            Row(S, .idle, .finalFrameAcknowledged, .idle, []),
            Row(S, .idle, .modeMessage(.active), .idle, []),
            Row(S, .idle, .modeMessage(.idle), .idle, []),

            // ───────────── sender / FROZEN (froze in ACTIVE) ────────
            // Any authenticated evidence — feedback OR beacon-class —
            // exits to RECOVERY: sends resume, the IDR is forced at
            // the half-stale rate; no mode message (the wire mode was
            // already ACTIVE).
            Row(S, .frozen, .mediaPathEvidence, .recovery,
                [.resumeDatagramSends, .forceIdr(.halfStaleEstimate)]),
            Row(S, .frozen, .ctrlEvidence, .recovery,
                [.resumeDatagramSends, .forceIdr(.halfStaleEstimate)]),
            Row(S, .frozen, .feedbackWindow(clean: true), .frozen, []),
            Row(S, .frozen, .feedbackWindow(clean: false), .frozen, []),
            // The pre-arm persists silently (flag asserted below).
            Row(S, .frozen, .preArmInput, .frozen, []),
            Row(S, .frozen, .damage, .frozen, []),
            Row(S, .frozen, .ratchetConverged, .frozen, []),
            Row(S, .frozen, .finalFrameAcknowledged, .frozen, []),
            Row(S, .frozen, .modeMessage(.active), .frozen, []),
            Row(S, .frozen, .modeMessage(.idle), .frozen, []),

            // ───────────── sender / RECOVERY ─────────────
            Row(S, .recovery, .mediaPathEvidence, .recovery, []),
            Row(S, .recovery, .ctrlEvidence, .recovery, []),
            // One clean window of the required two: still RECOVERY
            // (graduation is asserted in the behavior suite).
            Row(S, .recovery, .feedbackWindow(clean: true), .recovery, []),
            Row(S, .recovery, .feedbackWindow(clean: false), .recovery, []),
            Row(S, .recovery, .preArmInput, .recovery, []),
            Row(S, .recovery, .damage, .recovery, []),
            Row(S, .recovery, .ratchetConverged, .recovery,
                [.sendFinalFrameReliably]),
            Row(S, .recovery, .finalFrameAcknowledged, .recovery, []),
            Row(S, .recovery, .modeMessage(.active), .recovery, []),
            Row(S, .recovery, .modeMessage(.idle), .recovery, []),

            // ───────────── receiver / ACTIVE ─────────────
            Row(R, .active, .mediaPathEvidence, .active, []),
            Row(R, .active, .ctrlEvidence, .active, []),
            Row(R, .active, .feedbackWindow(clean: true), .active, []),
            Row(R, .active, .feedbackWindow(clean: false), .active, []),
            Row(R, .active, .preArmInput, .active, []),
            Row(R, .active, .damage, .active, []),
            Row(R, .active, .ratchetConverged, .active, []),
            Row(R, .active, .finalFrameAcknowledged, .active, []),
            Row(R, .active, .modeMessage(.active), .active, []),
            Row(R, .active, .modeMessage(.idle), .idle, []),

            // ───────────── receiver / IDLE ─────────────
            Row(R, .idle, .mediaPathEvidence, .idle, []),
            Row(R, .idle, .ctrlEvidence, .idle, []),
            Row(R, .idle, .feedbackWindow(clean: true), .idle, []),
            Row(R, .idle, .feedbackWindow(clean: false), .idle, []),
            Row(R, .idle, .preArmInput, .idle, []),
            Row(R, .idle, .damage, .idle, []),
            Row(R, .idle, .ratchetConverged, .idle, []),
            Row(R, .idle, .finalFrameAcknowledged, .idle, []),
            Row(R, .idle, .modeMessage(.active), .active, []),
            Row(R, .idle, .modeMessage(.idle), .idle, []),

            // ───────────── receiver / FROZEN (froze in ACTIVE) ──────
            // The receiver has no RECOVERY: returning evidence lands
            // back on the wire mode; a delivered mode message is
            // itself evidence AND a mode change.
            Row(R, .frozen, .mediaPathEvidence, .active, []),
            Row(R, .frozen, .ctrlEvidence, .active, []),
            Row(R, .frozen, .feedbackWindow(clean: true), .frozen, []),
            Row(R, .frozen, .feedbackWindow(clean: false), .frozen, []),
            Row(R, .frozen, .preArmInput, .frozen, []),
            Row(R, .frozen, .damage, .frozen, []),
            Row(R, .frozen, .ratchetConverged, .frozen, []),
            Row(R, .frozen, .finalFrameAcknowledged, .frozen, []),
            Row(R, .frozen, .modeMessage(.active), .active, []),
            Row(R, .frozen, .modeMessage(.idle), .idle, []),
        ]

        // Teardown pairs behave identically in every live state.
        for role in [S, R] {
            let states: [SessionState] = role == .mediaSender
                ? [.active, .idle, .frozen, .recovery]
                : [.active, .idle, .frozen]
            for state in states {
                for (input, actions) in Self.teardownRows {
                    rows.append(
                        Row(role, state, input, .closed, actions)
                    )
                }
            }
        }

        // Closed is absorbing: every input no-ops, nothing is emitted.
        for role in [S, R] {
            for input in Self.allInputs {
                rows.append(Row(role, .closed, input, .closed, []))
            }
        }

        for row in rows {
            var (m, now) = machine(role: row.role, in: row.state)
            let actions = m.apply(row.input, now: now)
            XCTAssertEqual(
                m.state, row.expectState,
                "state: \(row.role)/\(row.state) ← \(row.input) (row at line \(row.line))"
            )
            XCTAssertEqual(
                actions, row.expectActions,
                "actions: \(row.role)/\(row.state) ← \(row.input) (row at line \(row.line))"
            )
        }
    }

    static let allInputs: [SessionInput] = [
        .mediaPathEvidence, .ctrlEvidence,
        .feedbackWindow(clean: true), .feedbackWindow(clean: false),
        .preArmInput, .damage,
        .ratchetConverged, .finalFrameAcknowledged,
        .modeMessage(.active), .modeMessage(.idle),
        .teardownMessage(.takenOver), .teardownRequest(.shuttingDown),
    ]

    /// The FROZEN-from-IDLE column: RECOVERY entry must additionally
    /// re-signal mode=active (datagram video restarts), for the sender;
    /// the receiver returns to IDLE.
    func testFrozenFromIdleExitColumn() {
        for role in SessionRole.allCases {
            var (m, now) = machine(role: role, in: .idle)
            now = now.advanced(byMicroseconds: 350_000)
            let (frozenActions, _) = m.poll(now: now)
            XCTAssertEqual(m.state, .frozen, "\(role)")
            XCTAssertEqual(
                frozenActions,
                role == .mediaSender ? [.freezeDatagramSends] : [],
                "\(role)"
            )
            let actions = m.apply(
                .mediaPathEvidence,
                now: now.advanced(byMicroseconds: 1_000)
            )
            if role == .mediaSender {
                XCTAssertEqual(m.state, .recovery)
                XCTAssertEqual(actions, [
                    .resumeDatagramSends,
                    .sendModeMessage(.active),
                    .forceIdr(.halfStaleEstimate),
                ])
                XCTAssertEqual(m.wireMode, .active)
            } else {
                XCTAssertEqual(m.state, .idle)
                XCTAssertEqual(actions, [])
            }
        }
    }

    // MARK: Timer coverage — poll per state

    func testSilenceFreezesEveryStreamingState() {
        for role in SessionRole.allCases {
            let states: [SessionState] = role == .mediaSender
                ? [.active, .idle, .recovery] : [.active, .idle]
            for state in states {
                var (m, now) = machine(role: role, in: state)
                let silence = state == .recovery
                    ? m.config.recoveryBlackoutSilenceMicroseconds
                    : m.config.blackoutSilenceMicroseconds
                now = now.advanced(byMicroseconds: silence)
                let (actions, deadline) = m.poll(now: now)
                XCTAssertEqual(m.state, .frozen, "\(role)/\(state)")
                XCTAssertEqual(
                    actions,
                    role == .mediaSender ? [.freezeDatagramSends] : [],
                    "\(role)/\(state)"
                )
                // FROZEN still arms the liveness deadline.
                XCTAssertNotNil(deadline, "\(role)/\(state)")
            }
        }
    }

    func testFrozenDoesNotRefreeze() {
        var (m, now) = machine(role: .mediaSender, in: .frozen)
        now = now.advanced(byMicroseconds: 1_000_000)
        let (actions, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertEqual(actions, [])
    }

    func testLivenessTimeoutClosesEveryState() {
        for role in SessionRole.allCases {
            let states: [SessionState] = role == .mediaSender
                ? [.active, .idle, .frozen, .recovery]
                : [.active, .idle, .frozen]
            for state in states {
                var (m, now) = machine(role: role, in: state)
                now = now.advanced(byMicroseconds: 30_000_000)
                let (actions, deadline) = m.poll(now: now)
                XCTAssertEqual(m.state, .closed, "\(role)/\(state)")
                XCTAssertEqual(
                    actions, [.sessionClosed(.livenessTimeout)],
                    "\(role)/\(state)"
                )
                XCTAssertNil(deadline, "\(role)/\(state)")
                XCTAssertEqual(m.closeReason, .livenessTimeout)
            }
        }
    }

    func testClosedPollsToNothingForever() {
        for role in SessionRole.allCases {
            var (m, now) = machine(role: role, in: .closed)
            now = now.advanced(byMicroseconds: 60_000_000)
            let (actions, deadline) = m.poll(now: now)
            XCTAssertEqual(actions, [])
            XCTAssertNil(deadline)
        }
    }

    /// The receiver can never reach RECOVERY: it exits FROZEN straight
    /// to the wire mode on every evidence kind (asserted above), and no
    /// other transition targets RECOVERY.
    func testReceiverNeverEntersRecovery() {
        var (m, now) = machine(role: .mediaReceiver, in: .frozen)
        for input in Self.allInputs {
            var probe = m
            _ = probe.apply(input, now: now)
            XCTAssertNotEqual(probe.state, .recovery, "\(input)")
        }
        now = now.advanced(byMicroseconds: 10_000_000)
        _ = m.poll(now: now)
        XCTAssertNotEqual(m.state, .recovery)
    }
}
