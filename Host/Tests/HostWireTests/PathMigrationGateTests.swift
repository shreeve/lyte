import XCTest
import Foundation
import HostSession
@_spi(Testing) import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-12 row): rebind mid-stream → resume ≤ 400 ms,
// run deterministically against the sans-IO PathValidator (the socket
// rebind is lyte-host's). The simulation feeds the machine datagrams from 4-tuple A, then the same
// connection ID from 4-tuple B, and asserts: a challenge is issued on B
// and never before; the anti-amplification cap holds pre-validation; the
// echo promotes B within the modeled time; the fresh-IDR signal fires
// exactly once; and the old path is retained then aged out. The
// validator's spoof, withholding and foreign-traffic legs live in
// HostSessionTests/PathValidatorTests.
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
            fileURLWithPath: Self.corpusDirectory + "/\(name)"
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

        // Anti-amplification pre-validation: the challenge is the only
        // datagram B receives, and it fits 3 × what B sent.
        let config = validator.config
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
        print("""
            HS-12 gate: modeled resume \
            \(String(format: "%.1f", Double(resume) / 1e6)) ms ≤ 400 ms \
            (rtt 30 + encoder tick 16.7 + IDR drain \
            \(String(format: "%.1f", Double(drain) / 1e6)) + one-way 15 \
            + decode 10); \(emitted.count) conn-id-tagged IDR datagrams
            """)

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
        XCTAssertNil(validator.nextDeadline)
    }

    // MARK: The estimator after a promotion

    /// A validated migration lands on a path with 35 ms more base delay.
    /// The old path's delay baseline must not read that as standing
    /// queue: before the estimator forgot it, the rate fell every 500 ms.
    func testPromotionForgetsTheOldPathsDelayBaseline() throws {
        final class Box {
            var sent: [(datagram: VideoChannelDatagram, at: UInt64)] = []
            var now: UInt64 = 0
        }
        let box = Box()
        let session = Session(
            config: SessionConfig(
                crypto: .testPassthrough,
                rateBitsPerSecond: 20_000_000,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x9A7B)
        ) { box.sent.append(($0, box.now)) }
        let ms: UInt64 = 1_000_000
        var now: UInt64 = 0
        var reported = 0
        var clientSeq: UInt16 = 0
        func datagram(
            _ channel: ChannelId, _ body: [UInt8],
            extensions: [WireExtension] = []
        ) throws -> [UInt8] {
            defer { clientSeq &+= 1 }
            return try Envelope(
                channel: channel, seq: ChannelSeq(rawValue: clientSeq),
                frame: FrameNumber(rawValue: 0), timestamp: now / 1_000,
                fec: 0, extensions: extensions
            ).encode(payload: body)
        }
        // One 25 ms beat: a small frame paced out, then a report of its
        // arrivals `oneWayMicros` after release.
        func beat(from tuple: FourTuple, oneWayMicros: UInt64) throws
            -> [SessionEvent] {
            _ = try session.ingestVideoFrame(
                [0, 0, 0, 1, 0x02, 0x01]
                    + [UInt8](repeating: 0x42, count: 4_000),
                captureTimestampMicroseconds: now / 1_000,
                isKeyframe: false, now: now)
            for step in 0..<25 as Range<UInt64> {
                box.now = now + step * ms
                session.pump(now: box.now)
            }
            let video = box.sent[reported...]
                .filter { $0.datagram.pacerClass == .freshVideo }
            reported = box.sent.count
            now += 25 * ms
            let arrivals = video.map {
                9_000_000_000 + $0.at / 1_000 + oneWayMicros
            }
            let base = arrivals.min() ?? 0
            let report = FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: now / 1_000),
                dispersion: FeedbackReport.Dispersion(
                    base: ClientTimestamp(microseconds: base),
                    samples: zip(video, arrivals).map {
                        FeedbackReport.Dispersion.Sample(
                            channel: .videoActive, seq: $0.0.datagram.seq,
                            arrivalDeltaMicroseconds: UInt32($0.1 - base))
                    }))
            return session.receive(
                try datagram(.feedback, try report.encode()), from: tuple,
                now: now, hostMicroseconds: now / 1_000)
        }

        for _ in 0..<10 {
            _ = try beat(from: Self.tupleA, oneWayMicros: 5_000)
        }
        XCTAssertEqual(session.queuingDelayMicroseconds, 0)

        // The client roams to B: a conn-id datagram draws the challenge,
        // the echo from B promotes it.
        let probe = session.receive(
            try datagram(.ctrl, [0x00],
                         extensions: [session.connectionId.wireExtension]),
            from: Self.tupleB, now: now, hostMicroseconds: now / 1_000)
        var token: UInt64?
        for case .path(.sendChallenge(_, let challenge)) in probe {
            token = challenge.token
        }
        let promotion = session.receive(
            try datagram(
                .ctrl, PathResponse(token: try XCTUnwrap(token)).encode(),
                extensions: [session.connectionId.wireExtension]),
            from: Self.tupleB, now: now, hostMicroseconds: now / 1_000)
        XCTAssertTrue(promotion.contains {
            if case .path(.promoted) = $0 { return true }
            return false
        })

        for _ in 0..<60 {
            for event in try beat(from: Self.tupleB, oneWayMicros: 40_000) {
                if case .rateChanged(_, .overuse) = event {
                    XCTFail("the new path's base delay read as a queue")
                }
            }
        }
        XCTAssertEqual(session.queuingDelayMicroseconds, 0)
        XCTAssertEqual(session.estimatedRateBitsPerSecond, 20_000_000)
    }
}
