import LyteClientCore
import XCTest

// The roaming policy's pure, virtual-time legs. Persistence, the path
// watcher and the real session core are LyteTransportTests'.
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

    // MARK: The silence threshold, and evidence cancelling

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
    }

    // MARK: Host moved: same pkh, NEW address, immediate dial

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
    }

    // MARK: Same address: the redial threshold, and the
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
    }

    // MARK: Backoff arithmetic: capped ladders, never hot

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
    }

    // MARK: A sighting that lands while a dial is in flight

    /// The browse (2 s) usually finishes before the probe dial (3 × 700 ms)
    /// fails, so the host's new address arrives mid-dial. It must survive
    /// the dial, be dialed when the probe fails, and the scan ladder must
    /// keep running either way.
    func testMovedHostSightedMidDialIsDialedWhenTheProbeFails() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        let closed = policy.sessionClosed(now: 10_000_000)
        XCTAssertTrue(closed.contains(.beginScan))
        XCTAssertTrue(closed.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))

        XCTAssertEqual(policy.scanCompleted(
            sightings: [sighting("10.0.0.99")], now: 12_000_000), [])
        XCTAssertNotNil(policy.nextDeadline,
                        "the scan ladder stays armed through the dial")

        XCTAssertEqual(policy.dialFailed(now: 12_100_000), [
            .dial(address: "10.0.0.99", port: 41_161, discovered: true),
        ])
        XCTAssertEqual(policy.status,
                       .reconnecting(address: "10.0.0.99", discovered: true))

        // That dial fails too: scanning resumes on its ladder.
        var now: UInt64 = 14_000_000
        var scanned = policy.dialFailed(now: now).contains(.beginScan)
        while now < 40_000_000, !scanned,
              let due = policy.nextDeadline {
            now = max(now + 1, due)
            let actions = policy.tick(now: now)
            scanned = actions.contains(.beginScan)
            if actions.contains(where: {
                if case .dial = $0 { return true }; return false
            }) {
                _ = policy.dialFailed(now: now)
            }
        }
        XCTAssertTrue(scanned, "a failed discovered dial resumes scanning")
    }

    /// Reconnect resets every ladder, the scan ladder included, even
    /// while the policy already believes it is scanning.
    func testManualReconnectRestartsTheScan() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.sessionClosed(now: 10_000_000)
        _ = policy.scanCompleted(
            sightings: [sighting("10.0.0.99")], now: 12_000_000)
        let reconnect = policy.manualReconnect(now: 13_000_000)
        XCTAssertTrue(reconnect.contains(.beginScan))
    }

    // MARK: Client-side path change: grace, heal, escalate

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
    }

    // MARK: Dial answers only settle dials the policy issued

    func testDialFailureWithNoDialInFlightIsInert() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(policy.dialFailed(now: 1_000_000), [],
                       "a straggler's failure must not start a hunt")
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline)
    }

    // MARK: The manual Reconnect verb

    func testManualReconnectResetsLaddersAndActsNow() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.sessionClosed(now: 10_000_000)
        // Grow both ladders.
        _ = policy.dialFailed(now: 11_000_000)
        XCTAssertTrue(policy.tick(now: 13_000_000).contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
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
    }

    // MARK: The first connect: a dial before any session

    /// The connect dials at once; its silence hunts like a lost
    /// session (scan, follow the identity to a new address), and the
    /// first establishment retires the budget for good.
    func testFirstConnectDialsAtOnceAndHuntsLikeALostSession() {
        var policy = makePolicy()
        XCTAssertEqual(policy.connect(now: 0), [
            .dial(address: "10.0.0.60", port: 41_161, discovered: false),
        ])
        XCTAssertEqual(policy.status,
                       .reconnecting(address: "10.0.0.60", discovered: false))
        XCTAssertNil(policy.nextDeadline,
                     "the budget waits for the dial in flight")

        // Silence: the quiet browse begins, the next probe waits out
        // the dial ladder's floor.
        XCTAssertEqual(policy.dialFailed(now: 10_000_000), [.beginScan])
        XCTAssertEqual(policy.status, .searching)
        XCTAssertEqual(policy.nextDeadline, 12_000_000)

        // The restarted host advertises at a new address: dial it now.
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.0.0.61")], now: 10_500_000),
            [.dial(address: "10.0.0.61", port: 41_161, discovered: true)])
        _ = policy.sessionEstablished(
            address: "10.0.0.61", port: 41_161, now: 11_000_000)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline)

        // Long after the budget, a lost session still hunts — no expiry.
        let closed = policy.sessionClosed(now: 100_000_000)
        XCTAssertTrue(closed.contains(
            .dial(address: "10.0.0.61", port: 41_161, discovered: false)))
        XCTAssertFalse(closed.contains(.expired))
        XCTAssertFalse(policy.dialFailed(now: 101_000_000).contains(.expired))
    }

    /// The budget ends the connect between dials, never under one: a
    /// dial in flight at the deadline finishes, and its failure expires
    /// the policy even with a sighting waiting to be dialed.
    func testFirstConnectBudgetExpiresBetweenDials() {
        var gap = makePolicy()
        _ = gap.connect(now: 0)
        XCTAssertEqual(gap.dialFailed(now: 44_000_000), [.beginScan])
        XCTAssertEqual(gap.scanCompleted(sightings: [], now: 44_500_000), [])
        XCTAssertEqual(gap.nextDeadline, 45_000_000,
                       "the budget comes due before the next probe")
        XCTAssertEqual(gap.tick(now: 44_999_999), [])
        XCTAssertEqual(gap.tick(now: 45_000_000), [.expired])
        XCTAssertNil(gap.nextDeadline, "an expired policy pends nothing")
        XCTAssertEqual(gap.tick(now: 90_000_000), [])
        XCTAssertEqual(
            gap.scanCompleted(sightings: [sighting("10.0.0.61")],
                              now: 90_000_000),
            [], "no dial rises after expiry")

        var inFlight = makePolicy()
        _ = inFlight.connect(now: 0)
        _ = inFlight.dialFailed(now: 10_000_000)
        XCTAssertTrue(inFlight.tick(now: 12_000_000).contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
        XCTAssertEqual(
            inFlight.scanCompleted(sightings: [sighting("10.0.0.61")],
                                   now: 13_000_000),
            [], "the sighting waits on the dial in flight")
        XCTAssertFalse(inFlight.tick(now: 50_000_000).contains(.expired),
                       "the dial in flight is not cut short")
        XCTAssertEqual(inFlight.dialFailed(now: 50_000_000), [.expired])
        XCTAssertNil(inFlight.nextDeadline)
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
