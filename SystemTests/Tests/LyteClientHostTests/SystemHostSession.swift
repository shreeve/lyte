import Foundation
import HostSession
import HostWire
import HostWireTestKit
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit
import XCTest

/// A shipping HostWire.Session behind its HandshakeAcceptor, with only UDP
/// IO and monotonic time replaced (HostWireTestKit's harness, on a virtual
/// µs clock that never retreats). Every cross-end gate uses this one host
/// boundary; feature policy remains in the real Session and its
/// production services.
final class SystemHostSession: NoiseHandshakeIO {
    static let initialClientTuple = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_081,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    let staticKeys = NoiseKeyPair.generate()
    let harness: HostSessionHarness
    private(set) var nowMicroseconds: UInt64 = 0
    private var nextFrameNumber: UInt32 = 0
    private var repairsTaken = 0
    private(set) var events: [SessionEvent] = []

    var session: Session { harness.session }

    init(tweak: (inout SessionConfig) -> Void = { _ in }) {
        var config = SessionConfig(rateBitsPerSecond: 1_000_000_000)
        tweak(&config)
        harness = HostSessionHarness(
            config: config,
            acceptor: HandshakeAcceptor.Config(hostStatic: staticKeys),
            tuple: Self.initialClientTuple,
            rng: SplitMix64(seed: 0xC1_12))
    }

    func sendToHost(_ datagram: [UInt8]) throws {
        events += harness.receive(datagram, at: nowMicroseconds)
    }

    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        service(for: UInt64(timeoutMilliseconds) * 1_000) {
            harness.forwarded < harness.sent.count
        }
        guard harness.forwarded < harness.sent.count else { return nil }
        harness.forwarded += 1
        return harness.sent[harness.forwarded - 1].bytes
    }

    @discardableResult
    func absorb(_ bytes: [UInt8], clientMicros: UInt64) throws
        -> [SessionEvent]
    {
        try advanceClock(to: clientMicros)
        let received = harness.receive(bytes, at: nowMicroseconds)
        events += received
        return received
    }

    /// Drives only due Session work at an externally chosen virtual instant.
    /// Pairing's SimNet owns this clock; no helper may silently run ahead.
    @discardableResult
    func advance(to hostMicros: UInt64) throws -> [SessionEvent] {
        try advanceClock(to: hostMicros)
        let advanced = harness.advance(to: nowMicroseconds)
        events += advanced
        return advanced
    }

    func takeReadyControlDatagrams() -> [[UInt8]] {
        session.pump(now: nowMicroseconds * 1_000)
        return harness.take { $0.pacerClass == .control }.map(\.bytes)
    }

    func takeControlDatagrams(maxAdvanceNS: UInt64) -> [[UInt8]] {
        service(for: maxAdvanceNS / 1_000)
        return takeReadyControlDatagrams()
    }

    func videoDatagrams(
        annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64
    ) throws -> [[UInt8]] {
        XCTAssertEqual(
            frameNumber, nextFrameNumber,
            "the shipping Session owns one ascending frame sequence"
        )
        guard frameNumber == nextFrameNumber else { return [] }
        nextFrameNumber &+= 1
        try advanceClock(to: hostMicros)
        let count = try session.ingestVideoFrame(
            annexB,
            captureTimestampMicroseconds: hostMicros,
            isKeyframe: AnnexBCheck.containsIrap(annexB),
            now: nowMicroseconds * 1_000
        )
        func isFrame(_ datagram: VideoChannelDatagram) -> Bool {
            datagram.pacerClass == .freshVideo
                && datagram.frameNumber.rawValue == frameNumber
        }
        service(for: 20_000) {
            harness.sent[harness.forwarded...].count(where: isFrame) >= count
        }
        let datagrams = harness.take(where: isFrame)
        XCTAssertEqual(
            datagrams.count, count,
            "the Session did not release its complete video flight"
        )
        return datagrams.map(\.bytes)
    }

    func takeRepairDatagrams() -> [[UInt8]] {
        let expected = session.counters.repairDatagramsEnqueued - repairsTaken
        service(for: 20_000) {
            harness.sent[harness.forwarded...]
                .count { $0.pacerClass == .videoTail } >= expected
        }
        let datagrams = harness.take { $0.pacerClass == .videoTail }
        repairsTaken += datagrams.count
        return datagrams.map(\.bytes)
    }

    private func service(for micros: UInt64, until done: () -> Bool = { false }) {
        events += harness.service(
            t: &nowMicroseconds, through: nowMicroseconds &+ micros,
            until: done)
    }

    private func advanceClock(to instantMicros: UInt64) throws {
        guard instantMicros >= nowMicroseconds else {
            throw NSError(
                domain: "LyteClientHostTests.hostClockRetreat",
                code: 1,
                userInfo: [
                    "hostNowMicroseconds": nowMicroseconds,
                    "requestedMicroseconds": instantMicros,
                ]
            )
        }
        nowMicroseconds = instantMicros
    }
}
