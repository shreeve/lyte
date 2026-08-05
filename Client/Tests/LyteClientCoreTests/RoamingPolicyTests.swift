import LyteClientCore
import XCTest

// Pure, virtual-time legs of the F-5 client roaming gate. Integration with
// persistence, Network.framework, and the real session core remains in
// LyteTransportTests.
final class RoamingPolicyTests: XCTestCase {

    private func makePolicy(
        address: String = "10.0.0.60", port: UInt16 = 41_161
    ) -> RoamingPolicy {
        RoamingPolicy(
            targetPublicKeyHash: "ab12", address: address, port: port)
    }

    private func sighting(
        _ address: String, pkh: String = "ab12", port: UInt16 = 41_161
    ) -> RoamingSighting {
        RoamingSighting(publicKeyHash: pkh, address: address, port: port)
    }

    // MARK: Leg 1 — the silence threshold, and evidence cancelling

    func testSilenceThresholdBeginsQuietScanAndEvidenceCancels() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline, "healthy session pends nothing")

        // FROZEN at t=1 s: the silence clock starts, nothing happens
        // yet — the pill's tier.
        XCTAssertEqual(policy.wentSilent(now: 1_000_000), [])
        XCTAssertEqual(policy.status, .silent)
        XCTAssertEqual(policy.nextDeadline, 4_000_000,
                       "the scan threshold is silence onset + 3 s")

        // Below the threshold: still nothing.
        XCTAssertEqual(policy.tick(now: 3_999_999), [])
        // At it: exactly one quiet scan begins.
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])
        XCTAssertEqual(policy.status, .searching)

        // Evidence returns while the browse is in flight: the hunt
        // stands down, and the pass's late completion is ignored —
        // no dial can rise from a cancelled scan.
        XCTAssertEqual(policy.evidenceReturned(now: 4_500_000), [])
        XCTAssertEqual(policy.status, .attached)
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9")], now: 5_000_000),
            [])
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline)
        print("F-5 gate (threshold): FROZEN+3 s → one scan; evidence "
            + "cancels; a cancelled scan's sighting is inert")
    }

    // MARK: Leg 2 — host moved: same pkh, NEW address, immediate dial

    func testSameIdentityAtNewAddressDialsImmediately() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.wentSilent(now: 1_000_000)
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])

        // A FOREIGN identity at a new address is somebody else's
        // host: no dial, the ladder just schedules the next pass.
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9", pkh: "ffff")],
                now: 6_000_000),
            [])
        XCTAssertEqual(policy.status, .searching)

        // The next pass sights OUR identity at a NEW address: the
        // standing session is unreachable by construction — dial now,
        // well before the 8 s same-address threshold.
        XCTAssertEqual(policy.tick(now: 7_000_000), [.beginScan])
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9")], now: 7_500_000),
            [.dial(address: "10.9.9.9", port: 41_161, discovered: true)])
        XCTAssertEqual(
            policy.status,
            .reconnecting(address: "10.9.9.9", discovered: true))

        // Establishment at B resets everything; B is the new baseline.
        _ = policy.sessionEstablished(
            address: "10.9.9.9", port: 41_161, now: 8_000_000)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertEqual(policy.lastKnownAddress, "10.9.9.9")
        print("F-5 gate (host moved): same pkh at a new address → "
            + "immediate dial; foreign pkh inert; new baseline adopted")
    }

    // MARK: Leg 3 — same address: the redial threshold, and the
    // dead-session shortcut

    func testSameAddressSightingWaitsOutRedialThreshold() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.wentSilent(now: 1_000_000)
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])

        // The host is visible at the SAME address at 5 s of silence:
        // the network path works, evidence may still return — hold.
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 6_000_000),
            [])
        XCTAssertEqual(policy.status, .searching)
        // The remembered sighting graduates at silence onset + 8 s.
        XCTAssertEqual(
            policy.tick(now: 9_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)])

        // The dead-session variant: once the liveness verdict landed
        // there is nothing left to save — a same-address sighting
        // dials at once.
        var closed = makePolicy()
        _ = closed.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        let onClose = closed.sessionClosed(now: 60_000_000)
        XCTAssertTrue(onClose.contains(.beginScan))
        XCTAssertTrue(onClose.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)),
            "a dead session probes the last-known address immediately")
        _ = closed.dialFailed(now: 61_000_000)
        XCTAssertEqual(
            closed.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 62_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)])
        print("F-5 gate (same address): standing session holds 8 s "
            + "before the redial; a closed one dials at sight")
    }

    // MARK: Leg 4 — backoff arithmetic: capped ladders, never hot

    func testBackoffLaddersCapAndNeverSpinHot() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        let actions = policy.sessionClosed(now: 10_000_000)
        XCTAssertTrue(actions.contains(.beginScan))
        XCTAssertTrue(actions.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))

        // Fruitless scans: the gap doubles 1 → 2 → 4 → 8 → 15 (cap).
        var now: UInt64 = 11_000_000
        var expectedGap: Int64 = 1_000_000
        for _ in 0..<6 {
            XCTAssertEqual(
                policy.scanCompleted(sightings: [], now: now), [])
            let deadline = policy.nextDeadline
            XCTAssertNotNil(deadline)
            XCTAssertGreaterThan(deadline!, now,
                                 "deadlines live in the future — never hot")
            // The scan deadline is now + the current gap (the dial
            // ladder may pend sooner; find the scan by advancing).
            now = now &+ UInt64(expectedGap)
            let due = policy.tick(now: now)
            XCTAssertTrue(due.contains(.beginScan),
                          "the next pass comes due after the gap")
            expectedGap = min(expectedGap * 2, 15_000_000)
            // Answer any probe dial the tick fired so the dial ladder
            // stays out of the scan ladder's way.
            if due.contains(where: {
                if case .dial = $0 { return true }; return false
            }) {
                _ = policy.dialFailed(now: now)
            }
        }

        // Dial retries: 2 → 4 → 8 → 16 → 30 (cap) between attempts.
        var dialPolicy = makePolicy()
        _ = dialPolicy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = dialPolicy.sessionClosed(now: 100_000_000)   // probe fires
        var at: UInt64 = 100_000_000
        var expectedRetry: Int64 = 2_000_000
        for _ in 0..<5 {
            _ = dialPolicy.dialFailed(now: at)
            // One microsecond early: nothing.
            let early = dialPolicy.tick(
                now: at &+ UInt64(expectedRetry) &- 1)
            XCTAssertFalse(early.contains(where: {
                if case .dial = $0 { return true }; return false
            }), "no dial before the retry gap")
            at = at &+ UInt64(expectedRetry)
            let due = dialPolicy.tick(now: at)
            XCTAssertTrue(due.contains(
                .dial(address: "10.0.0.60", port: 41_161,
                      discovered: false)))
            expectedRetry = min(expectedRetry * 2, 30_000_000)
        }
        print("F-5 gate (backoff): scan gap 1→15 s, dial retry "
            + "2→30 s, every deadline strictly future")
    }

    // MARK: Leg 5 — client-side path change: grace, heal, escalate

    func testPathChangeGraceHealsOrEscalatesWithWaiver() {
        // Healed: the path change never froze the session — the grace
        // dissolves and the waiver stands down.
        var healed = makePolicy()
        _ = healed.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(healed.pathChanged(now: 1_000_000), [])
        XCTAssertEqual(healed.nextDeadline, 4_000_000,
                       "the migration grace is 3 s")
        XCTAssertEqual(healed.tick(now: 4_000_000), [])
        XCTAssertEqual(healed.status, .attached)
        XCTAssertNil(healed.nextDeadline)

        // Escalated: the path froze and stayed frozen through the
        // grace — scanning begins AT grace expiry (not the 3 s
        // silence threshold), and the same-address redial threshold
        // is waived: our own address moved, a fresh handshake is the
        // mechanism when migration didn't carry.
        var moved = makePolicy()
        _ = moved.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(moved.pathChanged(now: 1_000_000), [])
        XCTAssertEqual(moved.wentSilent(now: 1_500_000), [])
        XCTAssertEqual(moved.tick(now: 4_000_000), [.beginScan])
        XCTAssertEqual(
            moved.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 5_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)],
            "the waiver dials the same address at sight")

        // Already-silent variant: a path change over a frozen session
        // escalates immediately — no grace to grant.
        var dark = makePolicy()
        _ = dark.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = dark.wentSilent(now: 1_000_000)
        XCTAssertEqual(dark.pathChanged(now: 2_000_000), [.beginScan])
        print("F-5 gate (path change): grace heals silently, "
            + "escalates over a frozen path, waives the same-address hold")
    }

    // MARK: Leg 6 — the manual Reconnect verb

    func testManualReconnectResetsLaddersAndActsNow() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.sessionClosed(now: 10_000_000)
        // Grow both ladders.
        _ = policy.dialFailed(now: 11_000_000)
        _ = policy.dialFailed(now: 15_000_000)
        _ = policy.scanCompleted(sightings: [], now: 16_000_000)
        _ = policy.scanCompleted(sightings: [], now: 18_000_000)

        // The human reaches for Reconnect: everything fires NOW —
        // no waiting out a 30 s retry gap.
        let actions = policy.manualReconnect(now: 20_000_000)
        XCTAssertTrue(actions.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
        XCTAssertEqual(
            policy.status,
            .reconnecting(address: "10.0.0.60", discovered: false))
        // And the ladders are back at their floors: the NEXT failure
        // retries after the 2 s floor, not the grown gap.
        _ = policy.dialFailed(now: 21_000_000)
        XCTAssertTrue(policy.tick(now: 23_000_000).contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
        print("F-5 gate (manual): Reconnect acts immediately and "
            + "resets both ladders to their floors")
    }

    func testStatusLinesDescribePolicyState() {
        XCTAssertNil(RoamingStatusLine.line(for: .attached, hostName: "pup"))
        XCTAssertNil(RoamingStatusLine.line(for: .silent, hostName: "pup"),
                     "the FROZEN pill owns the blip tier")
        XCTAssertEqual(
            RoamingStatusLine.line(for: .searching, hostName: "pup"),
            "Connection lost — looking for pup…")
        XCTAssertEqual(
            RoamingStatusLine.line(
                for: .reconnecting(address: "10.9.9.9", discovered: true),
                hostName: "pup"),
            "pup found at 10.9.9.9 — reconnecting…")
        XCTAssertEqual(
            RoamingStatusLine.line(
                for: .reconnecting(address: "10.0.0.60", discovered: false),
                hostName: "pup"),
            "Reconnecting to pup at 10.0.0.60…")
    }
}
