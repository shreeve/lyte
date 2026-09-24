import HostCore
import HostSession
@testable import HostWire
import LyteWire
import XCTest

final class SocketOutboxTests: XCTestCase {
    private final class Ledger: SocketOutboxLedger {
        var primaryTuple = FourTuple(
            localAddress: "0.0.0.0", localPort: 41151,
            remoteAddress: "10.0.0.2", remotePort: 50000)
        var confirmed: [VideoChannelDatagram] = []
        var discarded: [VideoChannelDatagram] = []
        var shed: [(datagrams: Int, bytes: Int)] = []

        func confirmDatagramSent(_ datagram: VideoChannelDatagram, now: UInt64) {
            confirmed.append(datagram)
        }
        func discardPendingDatagram(_ datagram: VideoChannelDatagram) {
            discarded.append(datagram)
        }
        func noteKernelPressureFreshVideoShed(datagrams: Int, bytes: Int) {
            shed.append((datagrams, bytes))
        }
    }

    private var nextSeq: UInt16 = 0

    private func datagram(
        _ pacerClass: PacerClass, frame: UInt32 = 0,
        destination: FourTuple? = nil
    ) -> VideoChannelDatagram {
        nextSeq &+= 1
        return VideoChannelDatagram(
            bytes: [UInt8](repeating: UInt8(truncatingIfNeeded: nextSeq), count: 100),
            pacerClass: pacerClass,
            frameNumber: FrameNumber(rawValue: frame),
            seq: ChannelSeq(rawValue: nextSeq),
            isKeyframe: false,
            destination: destination)
    }

    private func flush(
        _ outbox: inout SocketOutbox, _ ledger: Ledger,
        maxBatch: Int = 64,
        write: (SocketLane, ArraySlice<VideoChannelDatagram>) -> SocketWriteResult
    ) -> SocketFlushOutcome {
        outbox.flush(
            ledger: ledger, now: { 1_000 }, maxBatch: maxBatch,
            sendOffPrimary: { _, _ in .accepted(1) },
            write: write, log: { _ in })
    }

    func testLatencyClassesLeaveFirstOnTheirOwnLaneAndVideoOrderHolds() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let video = (0..<3).map { datagram(.freshVideo, frame: UInt32($0)) }
        let audio = datagram(.audio)
        let control = datagram(.control)
        for d in [video[0], audio, video[1], control, video[2]] {
            outbox.enqueue(d, now: 0)
        }
        var writes: [(SocketLane, [UInt16])] = []
        let outcome = flush(&outbox, ledger) { lane, batch in
            writes.append((lane, batch.map(\.seq.rawValue)))
            return .accepted(batch.count)
        }
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(writes.map(\.0), [.latency, .video])
        XCTAssertEqual(writes[0].1, [control.seq.rawValue, audio.seq.rawValue])
        XCTAssertEqual(writes[1].1, video.map(\.seq.rawValue))
        XCTAssertEqual(ledger.confirmed.count, 5)
        XCTAssertEqual(outbox.counters.datagramsSent, 5)
        XCTAssertTrue(outbox.isEmpty)
    }

    func testWouldBlockRequeuesTheUnsentTailInOrder() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let video = (0..<5).map { datagram(.freshVideo, frame: UInt32($0)) }
        video.forEach { outbox.enqueue($0, now: 0) }
        var calls = 0
        let outcome = flush(&outbox, ledger) { _, _ in
            calls += 1
            return calls == 1 ? .accepted(2) : .wouldBlock
        }
        XCTAssertEqual(outcome, .wouldBlock(.video))
        XCTAssertEqual(outbox.datagrams.map(\.seq), video[2...].map(\.seq))
        XCTAssertEqual(ledger.confirmed.map(\.seq), video[..<2].map(\.seq))
        XCTAssertEqual(outbox.counters.videoWouldBlockCount, 1)
        XCTAssertEqual(outbox.counters.pendingMaxDatagrams, 3)
    }

    func testBatchesNeverExceedTheSocketLimit() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        (0..<10).forEach { _ in outbox.enqueue(datagram(.videoTail), now: 0) }
        var sizes: [Int] = []
        _ = flush(&outbox, ledger, maxBatch: 4) { _, batch in
            sizes.append(batch.count)
            return .accepted(batch.count)
        }
        XCTAssertEqual(sizes, [4, 4, 2])
    }

    /// B7: an ICMP-driven soft error (EHOSTUNREACH/ENETUNREACH/EPERM) costs
    /// the head datagram, never the session.
    func testTransientErrorDropsTheHeadDatagramAndKeepsSending() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let video = (0..<3).map { datagram(.freshVideo, frame: UInt32($0)) }
        video.forEach { outbox.enqueue($0, now: 0) }
        var calls = 0
        let outcome = flush(&outbox, ledger) { _, batch in
            calls += 1
            return calls == 1 ? .transient : .accepted(batch.count)
        }
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(outbox.counters.transientErrors, 1)
        XCTAssertEqual(ledger.discarded.map(\.seq), [video[0].seq])
        XCTAssertEqual(ledger.confirmed.map(\.seq), video[1...].map(\.seq))
    }

    /// B8: the partial-accept book held every fresh frame ever sent
    /// (~430k entries per 2 h session). It now holds at most the frame
    /// currently straddling the socket.
    func testPartialAcceptBookStaysBoundedAcrossALongSession() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        for frame in 0..<2_000 {
            outbox.enqueue(datagram(.freshVideo, frame: UInt32(frame)), now: 0)
            outbox.enqueue(datagram(.freshVideo, frame: UInt32(frame)), now: 0)
            _ = flush(&outbox, ledger) { _, batch in .accepted(batch.count) }
        }
        XCTAssertEqual(outbox.framesPartiallyAccepted, [1_999])
    }

    func testAPartiallySentFrameIsNeverShed() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let straddling = (0..<3).map { _ in datagram(.freshVideo, frame: 7) }
        straddling.forEach { outbox.enqueue($0, now: 0) }
        var calls = 0
        _ = flush(&outbox, ledger) { _, _ in
            calls += 1
            return calls == 1 ? .accepted(1) : .wouldBlock
        }
        let stale = (0..<2).map { _ in datagram(.freshVideo, frame: 8) }
        stale.forEach { outbox.enqueue($0, now: 0) }
        // Everything is stale at the budget; only the untouched frame goes.
        outbox.shedOldestStaleFreshVideo(
            ledger: ledger, now: 100_000_000, budgetNS: 10_000_000)
        XCTAssertEqual(ledger.shed.map(\.datagrams), [2])
        XCTAssertEqual(outbox.datagrams.map(\.frameNumber.rawValue), [7, 7])
    }

    func testChallengesTravelOffPrimaryAndNeverReachTheBatchWriter() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let probe = FourTuple(
            localAddress: "0.0.0.0", localPort: 41151,
            remoteAddress: "10.0.0.9", remotePort: 50001)
        outbox.enqueue(datagram(.control, destination: probe), now: 0)
        outbox.enqueue(datagram(.control, destination: ledger.primaryTuple), now: 0)
        var offPrimary: [FourTuple] = []
        var batched = 0
        let outcome = outbox.flush(
            ledger: ledger, now: { 0 }, maxBatch: 64,
            sendOffPrimary: { _, tuple in
                offPrimary.append(tuple)
                return .accepted(1)
            },
            write: { _, batch in
                batched += batch.count
                return .accepted(batch.count)
            },
            log: { _ in })
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(offPrimary, [probe])
        XCTAssertEqual(batched, 1)
        XCTAssertEqual(outbox.counters.challengesSentOffPrimary, 1)
    }

    func testARefusedChallengeTupleIsNotAGonePeer() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let probe = FourTuple(
            localAddress: "0.0.0.0", localPort: 41151,
            remoteAddress: "10.0.0.9", remotePort: 50001)
        outbox.enqueue(datagram(.control, destination: probe), now: 0)
        outbox.enqueue(datagram(.freshVideo, frame: 1), now: 0)
        var batched = 0
        var lines: [String] = []
        let outcome = outbox.flush(
            ledger: ledger, now: { 0 }, maxBatch: 64,
            sendOffPrimary: { _, _ in .peerGone },
            write: { _, batch in
                batched += batch.count
                return .accepted(batch.count)
            },
            log: { lines.append($0) })
        XCTAssertEqual(outcome, .drained,
                       "a dead probe tuple is not a dead peer")
        XCTAssertEqual(batched, 1, "the primary datagram still leaves")
        XCTAssertEqual(ledger.confirmed.count, 1)
        XCTAssertEqual(lines.count, 1)
    }

    func testFallPurgeDropsOnlyVideoAndReleasesTheLedger() {
        var outbox = SocketOutbox()
        let ledger = Ledger()
        let audio = datagram(.audio)
        outbox.enqueue(datagram(.freshVideo, frame: 1), now: 0)
        outbox.enqueue(audio, now: 0)
        outbox.enqueue(datagram(.videoTail, frame: 1), now: 0)
        outbox.purgeVideo(ledger: ledger)
        XCTAssertEqual(outbox.datagrams.map(\.seq), [audio.seq])
        XCTAssertEqual(ledger.discarded.count, 2)
    }
}
