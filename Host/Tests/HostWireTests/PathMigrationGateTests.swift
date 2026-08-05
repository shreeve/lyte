import XCTest
import Foundation
import HostSession
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-12 row): rebind mid-stream → resume ≤ 400 ms,
// run deterministically on the Mac against the sans-IO PathValidator (the
// live rebind on the host is the Linux send loop's thin job, deferred). The
// simulation feeds the machine datagrams from 4-tuple A, then the same
// connection ID from 4-tuple B, and asserts: a challenge is issued on B
// and never before; the anti-amplification cap holds pre-validation; the
// echo promotes B within the modeled time; the fresh-IDR signal fires
// exactly once; the old path is retained then aged out; and a SPOOFED
// conn-id from 4-tuple C with no valid echo never promotes.
//
// The ≤ 400 ms resume budget (resiliency gate G7: "IDR ≤ 400 ms after
// first packet from new path") is modeled on the injected clock with
// documented assumptions — hotel-grade RTT, worst-case encoder tick, the
// measured pacer drain, one-way delivery, client assemble+decode — and
// the sum is asserted against the budget, with the real VideoChannel
// pacing the real corpus IDR for the drain term.

final class PathMigrationGateTests: XCTestCase {

    // MARK: Fixtures

    private static var corpusDirectory: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(4)
        return components.joined(separator: "/")
            + "/Wire/Vectors/video-corpus-v1"
    }

    private func loadCorpus(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(
            fileURLWithPath: Self.corpusDirectory + "/" + name
        )))
    }

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

    // NOTE: the conn-id TLV and path-message CODEC tests moved to
    // Wire/Tests/LyteWireTests/Session/SessionCodecTests.swift with the codec
    // promotion; what stays here is the PathValidator behavior.

    // MARK: The gate — mid-stream rebind

    func testGateMidStreamRebindPromotesWithinBudget() throws {
        let connId = makeConnectionId()
        let millisecond: UInt64 = 1_000_000 // ns

        var validator = PathValidator(
            connectionId: connId,
            initialPath: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x12)
        )

        // Steady state on A: known tuple, no challenges, no events.
        for i in 0..<20 {
            let events = validator.datagramReceived(
                from: Self.tupleA, connectionId: connId,
                byteCount: Self.fullDatagramBytes,
                now: UInt64(i) * 5 * millisecond
            )
            XCTAssertTrue(events.isEmpty,
                          "no challenge may be issued before the rebind")
        }
        XCTAssertNil(validator.sendAllowance(to: Self.tupleA),
                     "the validated primary is uncapped")
        XCTAssertEqual(validator.sendAllowance(to: Self.tupleB), 0,
                       "an unseen tuple gets zero bytes")

        // t0: the client's address changes mid-stream — first datagram
        // bearing our conn-id from tuple B.
        let t0 = 100 * millisecond
        let events = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: t0
        )
        guard case .sendChallenge(let on, let challenge)? = events.first,
              events.count == 1
        else {
            return XCTFail("expected exactly one challenge, got \(events)")
        }
        XCTAssertEqual(on, Self.tupleB)

        // Anti-amplification pre-validation: what we may still send to B
        // is 3 × received minus the challenge already spent.
        let config = validator.config
        XCTAssertEqual(
            validator.sendAllowance(to: Self.tupleB),
            Self.fullDatagramBytes * config.amplificationFactor
                - config.challengeDatagramByteCount
        )
        XCTAssertLessThanOrEqual(
            config.challengeDatagramByteCount,
            Self.fullDatagramBytes * config.amplificationFactor,
            "the challenge itself must fit the reflection budget"
        )

        // More B datagrams before the echo: the outstanding token stands,
        // no challenge storm.
        let more = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId,
            byteCount: Self.fullDatagramBytes, now: t0 + 5 * millisecond
        )
        XCTAssertTrue(more.isEmpty)
        // Media must still be flowing to A only.
        XCTAssertEqual(validator.primary.tuple, Self.tupleA)
        XCTAssertFalse(validator.takeFreshKeyframeRequest(),
                       "no keyframe before promotion")

        // ── The modeled resume clock (documented assumptions) ─────────
        // rtt          30 ms  hotel-grade RTT (resiliency G5 profile;
        //                     LAN is ~2 ms — this is the worst case)
        // encoderTick  16.7 ms worst-case wait for the next capture tick
        //                     at 60 fps before the forced IDR encodes
        // drain        measured below: the real corpus IDR through the
        //                     real VideoChannel pacer at 20 Mbps
        // oneWay       15 ms  IDR shards' delivery on the new path (½ RTT)
        // clientDecode 10 ms  assemble + decode (M3 measured 60 fps
        //                     pipeline runs well under one frame interval)
        let rtt = 30 * millisecond
        let encoderTick = UInt64(16_666_667)
        let oneWay = 15 * millisecond
        let clientDecode = 10 * millisecond

        // The echo arrives one RTT after the challenge left.
        let tEcho = t0 + rtt
        let echoEvents = validator.pathResponseReceived(
            from: Self.tupleB,
            response: PathResponse(echoing: challenge),
            now: tEcho
        )
        guard case .promoted(let primary, let fallback)? = echoEvents.first
        else {
            return XCTFail("expected promotion, got \(echoEvents)")
        }
        XCTAssertEqual(echoEvents.count, 2)
        XCTAssertEqual(echoEvents.last, .freshKeyframeNeeded)
        XCTAssertEqual(primary.tuple, Self.tupleB)
        XCTAssertEqual(primary.validatedAt, tEcho)
        XCTAssertEqual(fallback.tuple, Self.tupleA)
        XCTAssertEqual(validator.primary.tuple, Self.tupleB)

        // Promotion lifts the cap; the retained fallback keeps its.
        XCTAssertNil(validator.sendAllowance(to: Self.tupleB))
        XCTAssertNil(validator.sendAllowance(to: Self.tupleA))

        // The fresh-IDR signal: exactly once.
        XCTAssertTrue(validator.takeFreshKeyframeRequest())
        XCTAssertFalse(validator.takeFreshKeyframeRequest(),
                       "the keyframe request must fire exactly once")

        // The IDR the signal forces, through the real HS-5 machinery:
        // conn-id-tagged shards, urgent class, paced at 20 Mbps.
        let idr = try loadCorpus("frame-000-idr.annexb")
        var emitted: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: 20_000_000, connectionId: connId
            ),
            now: 0
        ) { emitted.append($0) }
        try channel.ingest(
            frame: idr, frameNumber: FrameNumber(rawValue: 900),
            captureTimestampMicroseconds: 42, isKeyframe: true, now: 0
        )
        var drainClock: UInt64 = 0
        channel.pump(now: 0)
        while let wake = channel.nextWake(now: drainClock) {
            drainClock = max(drainClock &+ 1, wake)
            channel.pump(now: drainClock)
        }
        XCTAssertTrue(channel.isIdle)
        XCTAssertFalse(emitted.isEmpty)
        for datagram in emitted {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount
            )
            XCTAssertTrue(datagram.isKeyframe)
            let (env, _) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(
                try ConnectionId.decode(extensions: env.extensions), connId,
                "every migrated-session datagram carries the conn-id TLV"
            )
        }
        let drain = drainClock

        // The budget: first B datagram → decodable IDR at the client.
        let resume = rtt + encoderTick + drain + oneWay + clientDecode
        XCTAssertLessThanOrEqual(
            resume, 400 * millisecond,
            "modeled resume \(resume / millisecond) ms blew the budget"
        )
        print("HS-12 gate: modeled resume "
            + "\(String(format: "%.1f", Double(resume) / 1e6)) ms ≤ 400 ms "
            + "(rtt 30 + encoder tick 16.7 + IDR drain "
            + "\(String(format: "%.1f", Double(drain) / 1e6)) + one-way 15 "
            + "+ decode 10); \(emitted.count) conn-id-tagged IDR datagrams")

        // Old path retention, then age-out.
        let beforeExpiry = tEcho + validator.config.fallbackRetentionNS - 1
        XCTAssertTrue(validator.advance(now: beforeExpiry).isEmpty)
        XCTAssertEqual(validator.fallback?.tuple, Self.tupleA)
        XCTAssertEqual(validator.nextDeadline,
                       tEcho + validator.config.fallbackRetentionNS)
        let expiry = validator.advance(
            now: tEcho + validator.config.fallbackRetentionNS
        )
        XCTAssertEqual(expiry, [.fallbackExpired(Self.tupleA)])
        XCTAssertNil(validator.fallback)
        XCTAssertEqual(validator.sendAllowance(to: Self.tupleA), 0,
                       "an aged-out path is a stranger again")
        XCTAssertNil(validator.nextDeadline)
    }

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

        // The attacker replays our conn-id (plaintext until W5 seals the
        // TLV as AAD — exactly why promotion needs the echo) from C.
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
        let runt = validator.datagramReceived(
            from: Self.tupleB, connectionId: connId, byteCount: 10, now: 0
        )
        XCTAssertTrue(runt.isEmpty,
                      "the reflection guard applies to our own challenge")
        XCTAssertEqual(validator.sendAllowance(to: Self.tupleB),
                       10 * config.amplificationFactor)

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
        XCTAssertEqual(
            validator.sendAllowance(to: Self.tupleB),
            (10 + 45) * config.amplificationFactor
                - config.challengeDatagramByteCount
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
        XCTAssertEqual(validator.sendAllowance(to: Self.tupleC), 0)
        XCTAssertNil(validator.nextDeadline)
    }
}
