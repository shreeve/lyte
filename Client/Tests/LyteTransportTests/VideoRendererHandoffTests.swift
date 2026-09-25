import AVFoundation
import CoreMedia
import Foundation
import LyteClientTestKit
import LyteWire
import XCTest
@testable import LyteTransport

/// The production video sink, driven through a scripted renderer with real
/// HEVC corpus samples: in-order delivery, backpressure queueing, the
/// overflow → flush → await-IRAP episode (with its peer requests and the
/// decoder-reset attachment on the closing IRAP), stale-entry expiry, and
/// an inert, non-blocking stop.
final class VideoRendererHandoffTests: XCTestCase {
    private var corpus: [[UInt8]] = []

    override func setUpWithError() throws {
        corpus = try ClientTestPaths.videoCorpusFrames(8)
        XCTAssertGreaterThanOrEqual(corpus.count, 6)
    }

    // MARK: - Delivery

    func testIrapEnqueueClosesThePeersRecoveryEpisode() throws {
        let rig = Rig()
        try rig.submit(frame: 7, idr: true, bytes: corpus[0])
        try rig.submit(frame: 8, idr: false, bytes: corpus[1])
        rig.barrier()

        XCTAssertEqual(rig.renderer.enqueuedCount, 2)
        XCTAssertEqual(rig.peer.irapsEnqueued, [7],
                       "only an IRAP that reached the renderer closes the episode")
        XCTAssertEqual(rig.peer.gateClosingIraps, [],
                       "no gate was open, so this IRAP closed none")
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)
    }

    /// The production pairing: the core's demand opens the handoff's gate,
    /// and the IRAP that closes that gate ends the core's episode — no
    /// 500 ms retry storm after recovery.
    func testTheGateClosingIrapEndsTheCoresEpisode() throws {
        let rig = Rig()
        let core = rig.bindCore()
        core.beginVideoRecovery(
            cause: .fecAssemblerDamage, frame: FrameNumber(rawValue: 11),
            now: Rig.coreNow)
        rig.barrier()
        try rig.submit(frame: 12, idr: true, bytes: corpus[0])
        rig.barrier()

        XCTAssertEqual(rig.renderer.enqueuedFrames(), [12])
        XCTAssertFalse(core.idrStats.recoveryOutstanding)
        core.feedback.tick(
            now: Rig.coreNow.advanced(byMicroseconds: 500_000))
        XCTAssertEqual(core.idrStats.requestsSent, 1)
    }

    /// The core's demand reaches the handoff by a queue hop. An IRAP
    /// drained before that hop lands outside any gate; if it closed the
    /// core's episode, the gate that opens next would wait for an IRAP
    /// with no IDR request left to summon one.
    func testAnIrapAheadOfTheGateLeavesTheCoresEpisodeRetrying() throws {
        let rig = Rig()
        let core = rig.bindCore()
        rig.renderer.ready = false
        try rig.submit(frame: 12, idr: true, bytes: corpus[0])
        rig.barrier()

        rig.queue.suspend()
        rig.renderer.becomeReady()
        core.beginVideoRecovery(
            cause: .fecAssemblerDamage, frame: FrameNumber(rawValue: 11),
            now: Rig.coreNow)
        rig.queue.resume()
        rig.barrier()

        XCTAssertEqual(rig.renderer.enqueuedFrames(), [12])
        XCTAssertEqual(rig.peer.gateClosingIraps, [])
        XCTAssertTrue(core.idrStats.recoveryOutstanding,
                      "an IRAP outside the gate closed the core's episode")
        core.feedback.tick(
            now: Rig.coreNow.advanced(byMicroseconds: 500_000))
        XCTAssertEqual(core.idrStats.retryRequests, 1)

        try rig.submit(frame: 30, idr: true, bytes: corpus[0])
        rig.barrier()
        XCTAssertEqual(rig.peer.gateClosingIraps, [30])
        XCTAssertFalse(core.idrStats.recoveryOutstanding)
    }

    /// Damage that joins an open episode while its IRAP is pending: the
    /// IRAP closes the gate and the episode, then the late demand opens a
    /// fresh gate. The core's episode must reopen with it.
    func testAGateReopenedAfterItsIrapClosedTheEpisodeReassertsIt() throws {
        let rig = Rig()
        let core = rig.bindCore()
        core.beginVideoRecovery(
            cause: .fecAssemblerDamage, frame: FrameNumber(rawValue: 5),
            now: Rig.coreNow)
        rig.barrier()
        rig.renderer.ready = false
        try rig.submit(frame: 12, idr: true, bytes: corpus[0])
        rig.barrier()

        rig.queue.suspend()
        rig.renderer.becomeReady()
        core.beginVideoRecovery(
            cause: .fecAssemblerDamage, frame: FrameNumber(rawValue: 11),
            now: Rig.coreNow)
        rig.queue.resume()
        rig.barrier()

        XCTAssertEqual(rig.peer.gateClosingIraps, [12])
        let stats = core.idrStats
        XCTAssertTrue(stats.recoveryOutstanding,
                      "the handoff awaits an IRAP the core stopped asking for")
        XCTAssertEqual(stats.episodesStarted, 2)
        XCTAssertEqual(stats.requestsSent, 2)
    }

    /// An IRAP that finds the renderer failed answers the flush it trips:
    /// it is enqueued once the flush completes, and no IDR is requested.
    func testAnIrapThatTripsAFlushHealsItWithoutARequest() throws {
        let rig = Rig()
        let core = rig.bindCore()
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        rig.barrier()
        rig.renderer.failed = true
        try rig.submit(frame: 2, idr: true, bytes: corpus[0])
        rig.barrier()

        XCTAssertEqual(rig.renderer.recoveryFlushes, 1)
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [1, 2])
        XCTAssertEqual(rig.peer.gateClosingIraps, [2])
        let stats = core.idrStats
        XCTAssertEqual(stats.requestsSent, 0)
        XCTAssertFalse(stats.recoveryOutstanding)
    }

    /// A P-frame that trips the flush asks once, the handoff's own demand
    /// is not echoed back into it, and the next IRAP closes both gates.
    func testAPFrameThatTripsAFlushAsksOnceAndTheNextIrapHeals() throws {
        let rig = Rig()
        let core = rig.bindCore()
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        rig.barrier()
        rig.renderer.failed = true
        try rig.submit(frame: 2, idr: false, bytes: corpus[1])
        rig.barrier()
        try rig.submit(frame: 3, idr: true, bytes: corpus[0])
        rig.barrier()

        XCTAssertEqual(rig.renderer.recoveryFlushes, 1)
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [1, 3])
        XCTAssertEqual(rig.peer.recoveryRequests.map(\.frame), [2])
        let stats = core.idrStats
        XCTAssertEqual(stats.requestsSent, 1)
        XCTAssertFalse(stats.recoveryOutstanding)
    }

    func testBackpressureQueuesInOrderUntilTheRendererAsks() throws {
        let rig = Rig()
        rig.renderer.ready = false
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        try rig.submit(frame: 2, idr: false, bytes: corpus[1])
        try rig.submit(frame: 3, idr: false, bytes: corpus[2])
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedCount, 0)

        rig.renderer.becomeReady()
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [1, 2, 3])
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)
    }

    // MARK: - Recovery episodes

    func testOverflowFlushesAwaitsAnIrapAndResetsTheDecoder() throws {
        let rig = Rig()
        rig.renderer.ready = false
        rig.renderer.holdRecoveryFlush = true
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        for frame in 2...5 {
            try rig.submit(frame: UInt32(frame), idr: false, bytes: corpus[frame - 1])
        }
        rig.barrier()

        // Capacity 4: the fifth entry voided the episode.
        XCTAssertEqual(rig.renderer.recoveryFlushes, 1)
        XCTAssertEqual(rig.peer.recoveryRequests.map(\.frame), [5])
        XCTAssertEqual(rig.peer.recoveryRequests.map(\.cause), [.rendererBackpressure])

        // P-frames are refused while awaiting the IRAP…
        try rig.submit(frame: 6, idr: false, bytes: corpus[5])
        // …the IRAP is accepted but waits for the flush to complete.
        try rig.submit(frame: 7, idr: true, bytes: corpus[0])
        rig.renderer.ready = true
        rig.renderer.becomeReady()
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedCount, 0, "nothing dequeues mid-flush")

        rig.renderer.completeRecoveryFlush()
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [7])
        XCTAssertTrue(rig.renderer.lastEnqueueResetDecoder,
                      "the closing IRAP must reset the compressed decoder")
        XCTAssertEqual(rig.peer.irapsEnqueued, [7])
        XCTAssertEqual(rig.peer.gateClosingIraps, [7])
        XCTAssertEqual(rig.peer.recoveryRequests.count, 1, "one episode, one ask")
    }

    func testInterFramesQueuedBehindThePendingIrapAreNotViolations() throws {
        let rig = Rig()
        rig.renderer.ready = false
        rig.renderer.holdRecoveryFlush = true
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        for frame in 2...5 {
            try rig.submit(frame: UInt32(frame), idr: false, bytes: corpus[frame - 1])
        }
        try rig.submit(frame: 6, idr: true, bytes: corpus[0])
        try rig.submit(frame: 7, idr: false, bytes: corpus[1])
        rig.barrier()

        let kinds = rig.recorder.snapshot().recoveryLifecycle.map(\.kind)
        XCTAssertTrue(kinds.contains("handoffIrapAcceptedPendingEnqueue"))
        XCTAssertFalse(kinds.contains("invariantViolationNonIrapAcceptedDuringRecovery"),
                       "an inter frame behind the pending IRAP is the episode's own chain")

        rig.renderer.completeRecoveryFlush()
        rig.renderer.ready = true
        rig.renderer.becomeReady()
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [6, 7])
    }

    /// The recovery IRAP's own chain overflows while the renderer is still
    /// blocked: the IRAP goes with it, so the sink asks for another one at
    /// once instead of leaving the stream to the requester's retry.
    func testOverflowDiscardingThePendingIrapAsksAgain() throws {
        let rig = Rig()
        rig.renderer.ready = false
        rig.renderer.holdRecoveryFlush = true
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        for frame in 2...5 {
            try rig.submit(frame: UInt32(frame), idr: false, bytes: corpus[frame - 1])
        }
        try rig.submit(frame: 6, idr: true, bytes: corpus[0])
        for frame in 7...10 {
            try rig.submit(frame: UInt32(frame), idr: false, bytes: corpus[frame - 6])
        }
        rig.barrier()
        XCTAssertEqual(rig.peer.recoveryRequests.map(\.frame), [5, 10])

        try rig.submit(frame: 11, idr: true, bytes: corpus[0])
        rig.renderer.completeRecoveryFlush()
        rig.renderer.ready = true
        rig.renderer.becomeReady()
        rig.barrier()
        XCTAssertEqual(rig.renderer.enqueuedFrames(), [11])
        XCTAssertTrue(rig.renderer.lastEnqueueResetDecoder)
        XCTAssertEqual(rig.peer.irapsEnqueued, [11])
        XCTAssertEqual(rig.peer.recoveryRequests.count, 2)
    }

    func testAStaleQueuedEntryExpiresIntoRecovery() throws {
        let rig = Rig(deadlineMicroseconds: 50_000)
        rig.renderer.ready = false
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        rig.barrier()
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)

        // One re-armed timer fires the 50 ms deadline.
        let deadline = Date().addingTimeInterval(2)
        while rig.peer.recoveryRequests.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(rig.peer.recoveryRequests.map(\.cause), [.rendererBackpressure])
        XCTAssertEqual(rig.renderer.recoveryFlushes, 1)
    }

    func testUpstreamDamageVoidsTheEpisodeWithoutAskingTwice() throws {
        let rig = Rig()
        rig.renderer.ready = false
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        try rig.submit(frame: 2, idr: false, bytes: corpus[1])
        rig.handoff.beginRecovery(cause: .fecAssemblerDamage, after: FrameNumber(rawValue: 2))
        rig.barrier()

        XCTAssertEqual(rig.renderer.recoveryFlushes, 1)
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0,
                       "the session already asked; the sink only flushes")
    }

    // MARK: - Stop

    func testStopIsInertAndFlushesBehindTheLastEnqueue() throws {
        let rig = Rig()
        rig.renderer.ready = false
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        rig.barrier()

        rig.handoff.stop(flushingRenderer: true)
        try rig.submit(frame: 2, idr: true, bytes: corpus[0])
        rig.renderer.ready = true
        rig.renderer.becomeReady()
        rig.handoff.beginRecovery(cause: .rendererFailure, after: FrameNumber(rawValue: 2))
        rig.barrier()

        XCTAssertEqual(rig.renderer.enqueuedCount, 0)
        XCTAssertEqual(rig.renderer.plainFlushes, 1)
        XCTAssertEqual(rig.renderer.recoveryFlushes, 0)
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)
        XCTAssertFalse(rig.recorder.frames(after: 0).contains { $0.rendererDropped },
                       "a teardown discard is not a renderer verdict")
    }

    func testStopDoesNotWaitForTheDeliveryQueue() throws {
        let rig = Rig()
        let gate = DispatchSemaphore(value: 0)
        rig.queue.async { gate.wait() }   // an enqueue stalled on main's CA transaction
        let started = Date()
        rig.handoff.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        gate.signal()
        rig.barrier()
    }

    func testDimensionsAnnouncedOncePerSize() throws {
        let rig = Rig()
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        try rig.submit(frame: 2, idr: false, bytes: corpus[1])
        rig.barrier()
        XCTAssertEqual(rig.dimensions.value.count, 1)
    }
}

// MARK: - Rig

private final class Rig {
    let queue = DispatchQueue(label: "test.video.delivery")
    let renderer = ScriptedRenderer()
    let peer = RecordingPeer()
    let recorder = VideoFlightRecorder(nowMicroseconds: {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
    })
    let dimensions = Locked<[String]>([])
    let handoff: VideoRendererHandoff
    private let factory = VideoRenderFactory()

    /// The default queued-frame deadline is 50 ms; the rig waits far longer
    /// so a loaded test machine never expires entries mid-script.
    init(deadlineMicroseconds: UInt64 = 10_000_000) {
        let dimensions = dimensions
        handoff = VideoRendererHandoff(
            renderer: renderer,
            queue: queue,
            clockModel: HostClockModel(),
            books: VideoDeliveryBooks(),
            recorder: recorder,
            onDimensionsChanged: { width, height in
                dimensions.mutate { $0.append("\(width)x\(height)") }
            },
            queuedFrameDeadlineMicroseconds: deadlineMicroseconds)
        handoff.bind(peer)
    }

    static let coreNow = ClientTimestamp(microseconds: 40_000_000)

    /// A real session core as the handoff's recovery peer, wired the way
    /// the app wires them: core demands hop onto the handoff's queue.
    /// `peer` keeps recording what the core is told.
    func bindCore() -> LyteUdpSessionCore {
        let crypto = PassthroughTransportCrypto()
        let core = LyteUdpSessionCore(
            demux: ReceiveDemux(crypto: crypto),
            sender: TransportSender(crypto: crypto, transmit: { _ in true }),
            now: { Rig.coreNow },
            onVideoRecoveryDemand: { [weak handoff = self.handoff] cause, frame in
                handoff?.beginRecovery(cause: cause, after: frame)
            },
            videoSink: HeadlessVideoSink(),
            onEvent: { _ in })
        peer.forward = core
        return core
    }

    func submit(frame: UInt32, idr: Bool, bytes: [UInt8]) throws {
        let unit = DecodeUnit(
            frameNumber: FrameNumber(rawValue: frame),
            timestamp: HostTimestamp(microseconds: UInt64(frame) * 16_667),
            isIDR: idr,
            annexB: bytes)
        let sample = try XCTUnwrap(try factory.makeSampleBuffer(from: unit))
        renderer.register(sample, frame: frame)
        handoff.submit(sample: sample, unit: unit)
    }

    /// Lets every queued hop (including chained ones) run.
    func barrier() {
        for _ in 0..<4 { queue.sync {} }
    }
}

private final class RecordingPeer: VideoRecoveryPeer, @unchecked Sendable {
    struct Request { var frame: UInt32; var cause: VideoRecoveryCause }
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _iraps: [UInt32] = []
    private var _closing: [UInt32] = []
    private var _ensures: [UInt32] = []
    /// When set, every call is also delivered to this peer.
    var forward: (any VideoRecoveryPeer)? {
        get { lock.withLock { _forward } }
        set { lock.withLock { _forward = newValue } }
    }
    private var _forward: (any VideoRecoveryPeer)?

    var recoveryRequests: [Request] { lock.withLock { _requests } }
    var irapsEnqueued: [UInt32] { lock.withLock { _iraps } }
    /// The enqueued IRAPs that closed the handoff's gate.
    var gateClosingIraps: [UInt32] { lock.withLock { _closing } }
    var ensuredOpen: [UInt32] { lock.withLock { _ensures } }

    func requestVideoRecovery(after frame: FrameNumber, cause: VideoRecoveryCause) {
        lock.withLock { _requests.append(Request(frame: frame.rawValue, cause: cause)) }
        forward?.requestVideoRecovery(after: frame, cause: cause)
    }

    func noteVideoIrapEnqueued(frame: FrameNumber, closesRecovery: Bool) {
        lock.withLock {
            _iraps.append(frame.rawValue)
            if closesRecovery { _closing.append(frame.rawValue) }
        }
        forward?.noteVideoIrapEnqueued(frame: frame, closesRecovery: closesRecovery)
    }

    func ensureVideoRecoveryOpen(after frame: FrameNumber, cause: VideoRecoveryCause) {
        lock.withLock { _ensures.append(frame.rawValue) }
        forward?.ensureVideoRecoveryOpen(after: frame, cause: cause)
    }
}

/// A renderer whose readiness, recovery flushes, and media-data requests
/// the test scripts. Samples are identified by the frame they were built for.
private final class ScriptedRenderer: VideoRendererPort, @unchecked Sendable {
    private let lock = NSLock()
    private var framesByData: [ObjectIdentifier: UInt32] = [:]
    private var enqueued: [CMSampleBuffer] = []
    private var request: (DispatchQueue, @Sendable () -> Void)?
    private var heldFlush: (@Sendable () -> Void)?
    private var _ready = true
    private var _recoveryFlushes = 0
    private var _plainFlushes = 0
    private var _failed = false
    var holdRecoveryFlush = false

    /// Reports `.failed` until the next recovery flush, as AVFoundation does.
    var failed: Bool {
        get { lock.withLock { _failed } }
        set { lock.withLock { _failed = newValue } }
    }

    var ready: Bool {
        get { lock.withLock { _ready } }
        set { lock.withLock { _ready = newValue } }
    }
    var enqueuedCount: Int { lock.withLock { enqueued.count } }
    var recoveryFlushes: Int { lock.withLock { _recoveryFlushes } }
    var plainFlushes: Int { lock.withLock { _plainFlushes } }
    var lastEnqueueResetDecoder: Bool {
        guard let last = lock.withLock({ enqueued.last }) else { return false }
        return CMGetAttachment(
            last, key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil) != nil
    }

    func register(_ sample: CMSampleBuffer, frame: UInt32) {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { return }
        lock.withLock { framesByData[ObjectIdentifier(buffer)] = frame }
    }

    /// Frames of the enqueued samples, in order. A retimed copy shares its
    /// source's data buffer, which identifies it.
    func enqueuedFrames() -> [UInt32] {
        lock.withLock {
            enqueued.compactMap { sample in
                CMSampleBufferGetDataBuffer(sample).flatMap {
                    framesByData[ObjectIdentifier($0)]
                }
            }
        }
    }

    func becomeReady() {
        let pending = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            _ready = true
            return request
        }
        if let (queue, block) = pending { queue.async(execute: block) }
    }

    func completeRecoveryFlush() {
        let held = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { heldFlush = nil }
            return heldFlush
        }
        held?()
    }

    // MARK: VideoRendererPort

    var isReadyForMoreMediaData: Bool { ready }
    var status: AVQueuedSampleBufferRenderingStatus { failed ? .failed : .rendering }
    var error: (any Error)? { nil }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock { enqueued.append(sampleBuffer) }
    }

    func flush() {
        lock.withLock { _plainFlushes += 1 }
    }

    func flush(removingDisplayedImage: Bool, completionHandler: (@Sendable () -> Void)?) {
        let hold = lock.withLock { () -> Bool in
            _recoveryFlushes += 1
            _failed = false
            if holdRecoveryFlush { heldFlush = completionHandler }
            return holdRecoveryFlush
        }
        if !hold { completionHandler?() }
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue, using block: @escaping @Sendable () -> Void
    ) {
        let fire = lock.withLock { () -> Bool in
            request = (queue, block)
            return _ready
        }
        if fire { queue.async(execute: block) }
    }

    func stopRequestingMediaData() {
        lock.withLock { request = nil }
    }

    func loadVideoPerformanceMetrics(
        completionHandler: @escaping @Sendable (AVVideoPerformanceMetrics?) -> Void
    ) {
        completionHandler(nil)
    }
}
