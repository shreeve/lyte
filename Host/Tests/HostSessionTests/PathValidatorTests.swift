import HostSession
import LyteWire
import LyteWireTestKit
import XCTest

// PathValidator's pure legs (HS-12): the probe slot against spoofed
// conn-ids, the anti-amplification withholding of its own challenge, and
// the refusal to answer foreign traffic. The session-level roam and the
// modeled resume budget live in HostWireTests/PathMigrationGateTests.

final class PathValidatorTests: XCTestCase {
    private func makeConnectionId(seed: UInt64 = 0xC1D) -> ConnectionId {
        var rng = SplitMix64(seed: seed)
        return ConnectionId.random(using: &rng)
    }

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 47_998,
        remoteAddress: "10.0.0.23", remotePort: 55_001
    )
    private static let tupleB = FourTuple(
        localAddress: "10.0.0.249", localPort: 47_998,
        remoteAddress: "10.0.0.87", remotePort: 61_444
    )
    private static let tupleC = FourTuple(
        localAddress: "10.0.0.249", localPort: 47_998,
        remoteAddress: "203.0.113.66", remotePort: 4_444
    )

    /// A full video shard's wire size with the conn-id TLV attached:
    /// 24 B envelope + 11 B TLV block + 1112 B shard.
    private static let fullDatagramBytes = 1_147

    // MARK: The spoof case

    func testSpoofedConnIdNeverPromotes() throws {
        let connId = makeConnectionId()
        let millisecond: UInt64 = 1_000_000
        var validator = PathValidator(
            connectionId: connId,
            initialPath: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x77)
        )

        // A replayed conn-id from C: the session only reports datagrams
        // that unsealed, but the validator alone must still never promote
        // without the echo.
        let events = validator.datagramReceived(
            from: Self.tupleC, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: 0
        )
        guard case .sendChallenge(_, let challenge)? = events.first else {
            return XCTFail("the probe itself is expected — promotion is not")
        }

        // While C's probe is outstanding, a second attacker tuple is
        // ignored outright: one probe slot, no eviction by flooding.
        XCTAssertTrue(validator.datagramReceived(
            from: Self.tupleB, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: millisecond
        ).isEmpty)

        // A wrong-token response does nothing.
        let wrongToken = validator.pathResponseReceived(
            from: Self.tupleC,
            response: PathResponse(token: challenge.token &+ 1),
            now: 2 * millisecond
        )
        XCTAssertTrue(wrongToken.isEmpty)
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)

        // The right token from the WRONG tuple does nothing either: the
        // echo must arrive from the probed address.
        let wrongTuple = validator.pathResponseReceived(
            from: Self.tupleB,
            response: PathResponse(echoing: challenge),
            now: 3 * millisecond
        )
        XCTAssertTrue(wrongTuple.isEmpty)
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)

        // No valid echo ever comes: the probe times out and is abandoned.
        let timeout = validator.advance(
            now: validator.config.validationTimeoutNS + millisecond
        )
        XCTAssertEqual(timeout, [.probeAbandoned(Self.tupleC)])
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)
        XCTAssertNil(validator.fallback)
        XCTAssertFalse(validator.takeFreshKeyframeRequest(),
                       "a spoofed path must never trigger an IDR")

        // A later probe mints a NEW token, so the stale one is dead
        // forever — echoing it after re-probe still cannot promote.
        let tRetry = validator.config.validationTimeoutNS + 2 * millisecond
        let retry = validator.datagramReceived(
            from: Self.tupleC, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: tRetry
        )
        guard case .sendChallenge(_, let fresh)? = retry.first else {
            return XCTFail("expected a re-probe with a fresh token")
        }
        XCTAssertNotEqual(fresh.token, challenge.token,
                          "every probe mints a fresh token")
        XCTAssertTrue(validator.pathResponseReceived(
            from: Self.tupleC,
            response: PathResponse(echoing: challenge),
            now: tRetry + millisecond
        ).isEmpty)
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)
    }

    // MARK: Anti-amplification withholding

    func testRuntDatagramWithholdsChallengeUntilBudgetAffordsIt() throws {
        let connId = makeConnectionId()
        var validator = PathValidator(
            connectionId: connId,
            initialPath: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x9)
        )
        let config = validator.config

        // A 10 B runt: 3 × 10 = 30 < the 61 B challenge — withheld.
        XCTAssertGreaterThan(
            config.challengeDatagramByteCount, 10 * config.amplificationFactor
        )
        let runt = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId, byteCount: 10, now: 0
        )
        XCTAssertTrue(runt.isEmpty,
                      "the reflection guard applies to our own challenge")

        // More bytes arrive; the budget now affords the (same-token)
        // challenge and it is released.
        let second = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId, byteCount: 45,
            now: 1_000_000
        )
        guard case .sendChallenge(let on, let challenge)? = second.first,
              second.count == 1
        else {
            return XCTFail("expected the withheld challenge, got \(second)")
        }
        XCTAssertEqual(on, Self.tupleB)
        XCTAssertLessThanOrEqual(
            config.challengeDatagramByteCount,
            (10 + 45) * config.amplificationFactor
        )

        // The released challenge validates normally.
        let promoted = validator.pathResponseReceived(
            from: Self.tupleB,
            response: PathResponse(echoing: challenge),
            now: 2_000_000
        )
        XCTAssertEqual(promoted.count, 2)
        XCTAssertEqual(validator.primary.tuple, Self.tupleB)
    }

    // MARK: Returning to the fallback

    /// A→B→A inside the retention window, the usual Wi-Fi flap: the
    /// client's next authenticated datagram from A puts media back on A
    /// at once, with a fresh keyframe and no probe round trip; B becomes
    /// the fallback and can come back the same way. Past the window A is
    /// a stranger again and must answer a probe.
    func testDatagramFromTheRetainedFallbackRepromotesIt() throws {
        let connId = makeConnectionId()
        let millisecond: UInt64 = 1_000_000
        var validator = PathValidator(
            connectionId: connId,
            initialPath: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xAB)
        )
        guard case .sendChallenge(_, let challenge)? = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: millisecond
        ).first else { return XCTFail("B must be probed") }
        XCTAssertEqual(validator.pathResponseReceived(
            from: Self.tupleB, response: PathResponse(echoing: challenge),
            now: 2 * millisecond
        ).count, 2)
        XCTAssertTrue(validator.takeFreshKeyframeRequest())
        let promotedB = validator.primary

        let back = validator.datagramReceived(
            from: Self.tupleA, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: 3 * millisecond
        )
        XCTAssertEqual(back, [
            .promoted(primary: SessionPath(tuple: Self.tupleA, validatedAt: 0),
                      fallback: promotedB),
            .freshKeyframeNeeded,
        ])
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)
        XCTAssertEqual(validator.fallback, promotedB)
        XCTAssertTrue(validator.takeFreshKeyframeRequest())
        XCTAssertEqual(validator.nextDeadline,
                       3 * millisecond + validator.config.fallbackRetentionNS,
                       "the demoted path gets a fresh retention window")

        // A foreign conn-id from the fallback is still not ours.
        XCTAssertTrue(validator.datagramReceived(
            from: Self.tupleB, connectionId: makeConnectionId(seed: 0xFEED),
            byteCount: Self.fullDatagramBytes, now: 4 * millisecond
        ).isEmpty)
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)

        let expiry = 3 * millisecond + validator.config.fallbackRetentionNS
        XCTAssertEqual(validator.advance(now: expiry),
                       [.fallbackExpired(Self.tupleB)])
        guard case .sendChallenge(let on, _)? = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: expiry + millisecond
        ).first else { return XCTFail("an expired fallback is probed again") }
        XCTAssertEqual(on, Self.tupleB)
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)
        XCTAssertFalse(validator.takeFreshKeyframeRequest())
    }

    // MARK: Foreign traffic

    func testUnknownConnIdAndBareDatagramsNeverProbe() throws {
        let connId = makeConnectionId()
        var validator = PathValidator(
            connectionId: connId,
            initialPath: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x3)
        )
        // A different session's conn-id: not ours to challenge — the
        // host must not become a reflector toward arbitrary sources.
        XCTAssertTrue(validator.datagramReceived(
            from: Self.tupleC,
            connectionId: makeConnectionId(seed: 0xFEED),
            byteCount: 1_000, now: 0
        ).isEmpty)
        // No conn-id TLV at all: same.
        XCTAssertTrue(validator.datagramReceived(
            from: Self.tupleC, connectionId: nil, byteCount: 1_000, now: 0
        ).isEmpty)
        XCTAssertNil(validator.nextDeadline)
    }
}
