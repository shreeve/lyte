import Foundation
import HostWire
import LyteClientBrowserCore
import LyteWire
import XCTest

/// Video and audio playout driven by real host media through the session.
final class BrowserPlayoutTests: XCTestCase {
    private static let beatMicros: UInt64 = 16_667

    // MARK: Video

    /// A frame that arrives late is never presented, but its Annex-B must
    /// stay available: the page decodes strictly in order, and every later
    /// P-frame references it.
    func testLateFrameIsSkippedForPresentationButStaysDecodable() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let corpus = try Self.corpus()

        var scheduled = try send(corpus[0], keyframe: true, capture: 0, host, client)
        host.advance(microseconds: 5_000_000)
        scheduled += try send(corpus[1], keyframe: false, capture: Self.beatMicros, host, client)

        let late = try XCTUnwrap(scheduled.last)
        XCTAssertFalse(late.shouldPresent, "the second frame should arrive late")
        let far = host.nowMicros + 10_000_000
        var popped: [UInt32] = []
        while let frame = client.popDueFrame(nowMicros: far) {
            popped.append(frame.frameNumber)
        }
        XCTAssertFalse(popped.contains(late.frameNumber))
        XCTAssertEqual(client.videoCounters.framesSkippedLate, 1)
        XCTAssertNotNil(client.takeAnnexB(frameNumber: scheduled[0].frameNumber))
        XCTAssertNotNil(
            client.takeAnnexB(frameNumber: late.frameNumber),
            "a skipped frame's Annex-B must survive for the decode chain"
        )
        XCTAssertNil(client.takeAnnexB(frameNumber: late.frameNumber), "handed out once")
    }

    /// Frames the handoff refuses while it awaits an IRAP keep no
    /// presentation state, and the episode asks the host for an IDR.
    func testHandoffOverflowHoldsNoPresentationStateAndRequestsIdr() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let corpus = try Self.corpus()

        var scheduled = try send(corpus[0], keyframe: true, capture: 0, host, client)
        // Nothing is presented, so the 12-deep handoff overflows and every
        // later P-frame is refused until an IRAP.
        for index in 1..<40 {
            let frame = corpus[1 + (index - 1) % (corpus.count - 1)]
            scheduled += try send(
                frame, keyframe: false, capture: UInt64(index) * Self.beatMicros,
                host, client
            )
        }
        XCTAssertEqual(scheduled.count, 40)
        XCTAssertLessThanOrEqual(client.videoPresentationBacklog, 12)
        XCTAssertGreaterThan(client.videoCounters.framesNotPresentable, 0)

        // The page decodes everything it was told about.
        for frame in scheduled {
            XCTAssertNotNil(client.takeAnnexB(frameNumber: frame.frameNumber))
        }
        XCTAssertEqual(client.videoDecodeBacklog, 0)

        var notes: [String] = []
        host.deliver(client.tick(nowMicros: host.nowMicros), notes: &notes)
        XCTAssertEqual(client.counters.idrRequestsSent, 1, notes.joined(separator: " | "))
        XCTAssertTrue(host.events.contains {
            if case .idrRequested = $0 { return true }
            return false
        })
    }

    /// A backgrounded tab stops presenting: the handoff overflows and asks
    /// for an IDR, whose arrival closes the request episode. The tab is
    /// still stalled, so the IDR's own chain overflows and discards it —
    /// the stream must ask again, or it stays frozen when the tab returns.
    func testRecoveryIdrDiscardedByAStalledHandoffIsRequestedAgain() throws {
        try stallThroughRecovery(holdingIdrEarly: false)
    }

    /// The same stall after the page popped the recovery IDR early (held
    /// until its beat): handing that IDR off later cannot close the
    /// episode its discarded chain reopened, so the IDR is asked for again.
    func testRecoveryIdrHeldEarlyWhileItsChainOverflowsIsRequestedAgain() throws {
        try stallThroughRecovery(holdingIdrEarly: true)
    }

    private func stallThroughRecovery(holdingIdrEarly: Bool) throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let corpus = try Self.corpus()
        var capture: UInt64 = 0
        // One frame per beat: `send` itself spends a few milliseconds
        // delivering shards, so every frame arrives on time.
        func sendAtCadence(keyframe: Bool, _ index: Int) throws {
            host.advance(microseconds: Self.beatMicros - 4_000)
            capture += Self.beatMicros
            let frame = keyframe ? corpus[0] : corpus[1 + index % (corpus.count - 1)]
            let scheduled = try send(frame, keyframe: keyframe, capture: capture, host, client)
            XCTAssertEqual(scheduled.map(\.shouldPresent), [true], "on time")
        }
        func requestDueIdr() {
            var notes: [String] = []
            host.deliver(client.tick(nowMicros: host.nowMicros), notes: &notes)
        }

        try sendAtCadence(keyframe: true, 0)
        for index in 1...12 { try sendAtCadence(keyframe: false, index) }
        requestDueIdr()
        XCTAssertEqual(client.counters.idrRequestsSent, 1)

        try sendAtCadence(keyframe: true, 0) // the answer, accepted
        if holdingIdrEarly {
            XCTAssertNil(client.popDueFrame(nowMicros: host.nowMicros), "not due yet")
        }
        for index in 1...(holdingIdrEarly ? 13 : 12) {
            try sendAtCadence(keyframe: false, index)
        }
        requestDueIdr()
        XCTAssertEqual(
            client.counters.idrRequestsSent, 2,
            "the discarded recovery IDR must be asked for again")

        // The tab returns; the fresh IDR presents and its chain follows.
        try sendAtCadence(keyframe: true, 0)
        try sendAtCadence(keyframe: false, 1)
        let far = host.nowMicros + 10_000_000
        var presented: [Bool] = []
        while let frame = client.popDueFrame(nowMicros: far) {
            presented.append(frame.isRandomAccess)
        }
        XCTAssertEqual(presented, holdingIdrEarly ? [true, true, false] : [true, false])
    }

    /// When the page stops taking decode input, the backlog is bounded and
    /// the loss opens a recovery episode.
    func testUndrainedDecodeBacklogIsBounded() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let corpus = try Self.corpus()
        let total = BrowserVideoPlayout.decodeBacklogCapacity + 10

        _ = try send(corpus[0], keyframe: true, capture: 0, host, client)
        for index in 1..<total {
            let frame = corpus[1 + (index - 1) % (corpus.count - 1)]
            _ = try send(
                frame, keyframe: false, capture: UInt64(index) * Self.beatMicros,
                host, client
            )
        }
        XCTAssertEqual(client.framesAssembled, UInt64(total))
        XCTAssertEqual(client.videoDecodeBacklog, BrowserVideoPlayout.decodeBacklogCapacity)
        XCTAssertEqual(client.videoCounters.decodeBacklogEvicted, 10)
    }

    // MARK: Audio

    func testAudioQueueKeepsOnlyTheNewestPacketsWhenNotDrained() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let session = try XCTUnwrap(host.session)
        let sent = 50
        for index in 0..<sent {
            try session.ingestAudioPacket(
                [0xF8, 0xFF, 0xFE, UInt8(index)],
                captureTimestampMicroseconds: host.nowMicros,
                now: host.nowMicros * 1_000
            )
            host.advance(microseconds: 5_000)
            deliverAll(host, client)
        }

        XCTAssertEqual(client.audioPacketsAssembled, UInt64(sent))
        XCTAssertEqual(client.audioPending, BrowserAudioPlayout.defaultCapacity)
        XCTAssertEqual(
            client.audioPacketsDroppedStale,
            UInt64(sent - BrowserAudioPlayout.defaultCapacity)
        )
        var numbers: [UInt32] = []
        while let packet = client.popAudioPacket() { numbers.append(packet.number) }
        XCTAssertEqual(numbers.count, BrowserAudioPlayout.defaultCapacity)
        XCTAssertEqual(numbers, numbers.sorted(), "oldest first")
        XCTAssertEqual(numbers.last.map { Int($0) }, sent - 1, "newest kept")
    }

    // MARK: Helpers

    private static func corpus() throws -> [[UInt8]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../Wire/Vectors/video-corpus-v1")
            .standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("frame-00") && $0.hasSuffix(".annexb") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 2)
        return try names.map {
            [UInt8](try Data(contentsOf: root.appendingPathComponent($0)))
        }
    }

    /// Host ingests one frame; every shard crosses; returns what the
    /// client's Conductor scheduled.
    private func send(
        _ annexB: [UInt8], keyframe: Bool, capture: UInt64,
        _ host: BrowserHostPeer, _ client: BrowserControlSession
    ) throws -> [BrowserVideoPlayout.ScheduledFrame] {
        let session = try XCTUnwrap(host.session)
        try session.ingestVideoFrame(
            annexB, captureTimestampMicroseconds: capture,
            isKeyframe: keyframe, now: host.nowMicros * 1_000
        )
        var scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
        for _ in 0..<200 {
            host.advance(microseconds: 1_000)
            scheduled += deliverAll(host, client)
            if !scheduled.isEmpty { break }
        }
        return scheduled
    }

    @discardableResult
    private func deliverAll(
        _ host: BrowserHostPeer, _ client: BrowserControlSession
    ) -> [BrowserVideoPlayout.ScheduledFrame] {
        var scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
        var notes: [String] = []
        for datagram in host.drain() {
            let step = client.ingest(datagram: datagram, nowMicros: host.nowMicros)
            scheduled += step.scheduled
            host.deliver(step, notes: &notes)
        }
        return scheduled
    }
}
