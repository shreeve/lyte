import XCTest
import HostCore
import HostSession
@_spi(Testing) import HostWire
import LyteWire
import LyteWireTestKit

// Pins the lost-recovery-IDR stall: encode/ingest advances
// lastKeyframeNumber before delivery, so a wholly lost host IDR must
// not suppress client 0x10 forever when the episode keeps naming older
// pre-IDR damage (static desktop — no newer undecodable frames arrive).
// Storm control remains the in-flight offer window; stale-NACK host IDR
// arming stays off.

final class IdrOfferInFlightGateTests: XCTestCase {

    private static let ceiling = 20_000_000
    private static let ms: UInt64 = 1_000_000
    private static let inFlightNS: UInt64 = 500 * ms

    private static let tuple = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_210,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    private final class Box {
        var sent: [VideoChannelDatagram] = []
    }

    private func makeSession(box: Box) -> Session {
        Session(
            config: SessionConfig(
                crypto: .testPassthrough,
                rateBitsPerSecond: Self.ceiling,
                // Keep the lifecycle machine out of this pin: the stall is
                // about 0x10 vs encode-time lastKeyframeNumber, not FROZEN.
                lifecycle: SessionMachineConfig(
                    blackoutSilenceMicroseconds: 1 << 44,
                    livenessTimeoutMicroseconds: 1 << 45
                ),
                clientIdrOfferInFlightNS: Self.inFlightNS
            ),
            clientTuple: Self.tuple,
            now: 0,
            rng: SplitMix64(seed: 0x1010)
        ) { [box] datagram in
            box.sent.append(datagram)
        }
    }

    private func syntheticFrame(
        byteCount: Int, irap: Bool = false
    ) -> [UInt8] {
        [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
            + (0..<(byteCount - 6)).map {
                UInt8(truncatingIfNeeded: $0 &* 131 &+ 7)
            }
    }

    private var ctrlSeq: UInt16 = 0

    private func feedIdrRequest(
        _ session: Session,
        request: IdrRequest,
        now: UInt64
    ) -> [SessionEvent] {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: ctrlSeq),
            frame: FrameNumber(rawValue: 0),
            timestamp: now / 1_000,
            fec: 0
        )
        ctrlSeq &+= 1
        return session.receive(
            try! envelope.encode(payload: request.encode()),
            from: Self.tuple,
            now: now,
            hostMicroseconds: now / 1_000
        )
    }

    /// Advance through opening CTRL, then build a chain so the next
    /// ingest is frame 10: opening IDR at 0, P-frames 1…9.
    private func establishThroughFrameNine(
        _ session: Session, box: Box, now: inout UInt64
    ) throws {
        _ = session.advance(now: now, hostMicroseconds: 0)
        session.pump(now: now)
        box.sent.removeAll()
        _ = session.takeFreshKeyframeRequest()

        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 4_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true,
            now: now
        )
        for _ in 1...9 {
            now &+= Self.ms
            _ = try session.ingestVideoFrame(
                syntheticFrame(byteCount: 2_000),
                captureTimestampMicroseconds: now / 1_000,
                isKeyframe: false,
                now: now
            )
        }
        XCTAssertEqual(session.lastAdmittedVideoFrameNumber?.rawValue, 9)
        _ = session.takeFreshKeyframeRequest()
    }

    func testLostRecoveryIdrDoesNotSupersedeOlderDamageForever() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishThroughFrameNine(session, box: box, now: &now)

        // 1. Client 0x10 naming damage F=7.
        let first = IdrRequest(
            requestSeq: 0, frame: FrameNumber(rawValue: 7), coalescedCount: 1
        )
        let firstEvents = feedIdrRequest(session, request: first, now: now)
        XCTAssertTrue(firstEvents.contains(.idrRequested(first)))
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
                      "the first 0x10 must arm a recovery IDR")

        // 2. Host commits recovery IDR as F=10; all shards "lost" —
        //    ingest advances lastKeyframeNumber without any delivery proof.
        now &+= Self.ms
        let offerAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 4_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true,
            now: now
        )
        XCTAssertEqual(session.lastAdmittedVideoFrameNumber?.rawValue, 10)
        _ = session.takeFreshKeyframeRequest()

        // Inside the in-flight window: older-named retry coalesces.
        now = offerAt &+ Self.inFlightNS &- 1
        let earlyRetry = IdrRequest(
            requestSeq: 1, frame: FrameNumber(rawValue: 7), coalescedCount: 2
        )
        _ = feedIdrRequest(session, request: earlyRetry, now: now)
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
            "in-flight offer still suppresses older-named retries")
        XCTAssertEqual(session.counters.idrRequestsSupersededByKeyframe, 1)

        // 3. After the window: the same older damage must re-arm —
        //    encode-time lastKeyframeNumber is not delivery proof.
        now = offerAt &+ Self.inFlightNS
        let lateRetry = IdrRequest(
            requestSeq: 2, frame: FrameNumber(rawValue: 7), coalescedCount: 3
        )
        _ = feedIdrRequest(session, request: lateRetry, now: now)
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
            "a wholly lost recovery IDR must not strand the episode")
        XCTAssertEqual(session.counters.idrRequestsSupersededByKeyframe, 1)
    }

    func testLaterDamageStillArmsInsideOfferWindow() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishThroughFrameNine(session, box: box, now: &now)

        now &+= Self.ms
        let offerAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 4_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true,
            now: now
        )
        _ = session.takeFreshKeyframeRequest()

        // Genuine later damage (≥ offered anchor) earns a new IDR even
        // while older-named retries would still coalesce.
        now = offerAt &+ Self.inFlightNS / 2
        let later = IdrRequest(
            requestSeq: 0, frame: FrameNumber(rawValue: 10), coalescedCount: 1
        )
        _ = feedIdrRequest(session, request: later, now: now)
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
            "damage at/after the offered anchor remains eligible")

        let older = IdrRequest(
            requestSeq: 1, frame: FrameNumber(rawValue: 7), coalescedCount: 2
        )
        _ = feedIdrRequest(session, request: older, now: now)
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
            "older damage still coalesces inside the offer window")
        XCTAssertEqual(session.counters.idrRequestsSupersededByKeyframe, 1)
    }
}
