import HostCore
import HostSession
@_spi(Testing) import HostWire
import LyteWire
import LyteWireTestKit
import XCTest

final class SenderWaitTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func timeout(
        now: UInt64, latency: UInt64?, all: UInt64?,
        _ hold: SenderWait.Hold = .none
    ) -> Int64 {
        SenderWait.timeoutNS(
            nowNS: now, latencyWakeNS: latency, allWakeNS: all, hold: hold)
    }

    func testTheSenderSleepsUntilTheNextTimer() {
        XCTAssertEqual(timeout(now: 1_000, latency: nil, all: 1_750_000),
                       1_749_000)
    }

    func testADueTimerMeansNoWait() {
        XCTAssertEqual(timeout(now: 5_000, latency: nil, all: 4_000), 0)
        XCTAssertEqual(timeout(now: 5_000, latency: nil, all: 5_000), 0)
    }

    func testNoTimerAndFarTimersAreBoundedByTheBackstop() {
        XCTAssertEqual(timeout(now: 0, latency: nil, all: nil),
                       SenderWait.maxWaitNS)
        XCTAssertEqual(timeout(now: 0, latency: nil, all: 5_000_000_000),
                       SenderWait.maxWaitNS)
    }

    func testENOBUFSRetriesAfterTheBackoff() {
        XCTAssertEqual(timeout(now: 0, latency: 50 * ms, all: 50 * ms, .noBuffer),
                       SenderWait.noBufferBackoffNS)
    }

    /// A full socket: POLLOUT is video's wake; only latency work and
    /// session timers bound the wait.
    func testAFullSocketWaitsOnTheLatencyWakeOnly() {
        XCTAssertEqual(timeout(now: 1 * ms, latency: 3 * ms, all: 1 * ms,
                               .socketFull), Int64(2 * ms))
        XCTAssertEqual(timeout(now: 1 * ms, latency: nil, all: 1 * ms,
                               .socketFull), SenderWait.maxWaitNS)
        XCTAssertEqual(timeout(now: 1 * ms, latency: 1 * ms, all: 1 * ms,
                               .socketFull), 0,
                       "due audio still goes at once")
    }

    /// Kernel pressure: due video is re-sampled on a bounded cadence,
    /// never in a zero-timeout loop; latency work still wakes on time.
    func testKernelPressureRechecksVideoOnABoundedCadence() {
        XCTAssertEqual(timeout(now: 1 * ms, latency: nil, all: 1 * ms,
                               .pressure), SenderWait.pressureRecheckNS)
        XCTAssertEqual(timeout(now: 1 * ms, latency: nil, all: 9 * ms,
                               .pressure), Int64(8 * ms))
        XCTAssertEqual(timeout(now: 1 * ms, latency: 1 * ms + 100_000,
                               all: 1 * ms, .pressure), 100_000)
    }

    /// An IDR's worth of video sits in the pacer behind a full socket.
    /// One refill later the bucket reads "due now", but the wait must
    /// not collapse to zero (EAGAIN and ENOBUFS alike) or the SCHED_RR
    /// sender spins. The latency-bounded wake ignores it.
    func testABlockedOutboxDoesNotSpinOnceTheBucketRefills() {
        let pacer = Pacer(rateBitsPerSecond: 50_000_000, now: 0)
        for _ in 0..<100 { pacer.enqueue(.freshVideo, bytes: 1_152, now: 0) }
        XCTAssertNotNil(pacer.nextBatch(now: 0))
        let now = 1 * ms
        let all = pacer.nextWake(now: now)
        XCTAssertEqual(all, now, "video is due")
        let latency = pacer.nextWake(now: now, upThrough: .audio)
        XCTAssertNil(latency, "no latency work is queued")
        XCTAssertEqual(timeout(now: now, latency: latency, all: all, .socketFull),
                       SenderWait.maxWaitNS,
                       "EAGAIN: ppoll(POLLOUT) blocks until the socket drains")
        XCTAssertEqual(timeout(now: now, latency: latency, all: all, .noBuffer),
                       SenderWait.noBufferBackoffNS,
                       "ENOBUFS: the back-off holds")
        XCTAssertEqual(timeout(now: now, latency: latency, all: all, .pressure),
                       SenderWait.pressureRecheckNS)

        // Audio queued behind the held video still wakes the sender.
        pacer.enqueue(.audio, bytes: 200, now: now)
        XCTAssertEqual(pacer.nextWake(now: now, upThrough: .audio), now)
    }

    /// The session's latency-bounded wake keeps its timers (beacons,
    /// ARQ, lifecycle) and drops only the video it will not release.
    func testSessionLatencyWakeKeepsTimersAndDropsHeldVideo() throws {
        let session = Session(
            config: SessionConfig(
                crypto: .testPassthrough, rateBitsPerSecond: 50_000_000),
            clientTuple: FourTuple(
                localAddress: "0.0.0.0", localPort: 41_151,
                remoteAddress: "10.0.0.23", remotePort: 61_000),
            now: 0, rng: SplitMix64(seed: 2)) { _ in }
        let frame = [0, 0, 0, 1, 0x26, 0x01]
            + [UInt8](repeating: 0xAA, count: 200_000)
        _ = try session.ingestVideoFrame(
            frame, captureTimestampMicroseconds: 1, isKeyframe: true, now: 0)
        _ = session.advance(now: 0, hostMicroseconds: 0)
        session.pump(now: 0)
        let now = 1 * ms
        XCTAssertEqual(session.nextWake(now: now), now, "video is due")
        let latency = try XCTUnwrap(session.nextWake(now: now, upThrough: .audio),
                                    "the session's timers remain")
        XCTAssertGreaterThan(latency, now)
    }
}
