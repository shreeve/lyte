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
        let directory = ClientTestPaths.videoCorpus
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".annexb") }
            .sorted()
        corpus = try names.prefix(8).map {
            [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory + "/" + $0)))
        }
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
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)
    }

    func testIrapCloseEndsTheIdrRequesterEpisode() throws {
        let emitted = Locked<[IdrRequest]>([])
        let requester = IdrRequester(retryIntervalMilliseconds: 500) { request in
            emitted.mutate { $0.append(request) }
        }
        let base = ClientTimestamp(microseconds: 40_000_000)
        requester.recordRecoveryDemand(frame: FrameNumber(rawValue: 1), now: base)
        XCTAssertTrue(requester.snapshotStats().recoveryOutstanding)

        let rig = Rig()
        rig.peer.onIrap = { _ in requester.noteUsableIrapAccepted() }
        try rig.submit(frame: 12, idr: true, bytes: corpus[0])
        rig.barrier()

        requester.flushIfDue(now: base.advanced(byMicroseconds: 500_000))
        XCTAssertEqual(emitted.value.count, 1,
                       "IRAP enqueue must end the episode; no 500 ms retry storm")
        XCTAssertFalse(requester.snapshotStats().recoveryOutstanding)
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
        XCTAssertEqual(rig.peer.recoveryRequests.count, 1, "one episode, one ask")
    }

    func testAStaleQueuedEntryExpiresIntoRecovery() throws {
        let rig = Rig()
        rig.renderer.ready = false
        try rig.submit(frame: 1, idr: true, bytes: corpus[0])
        rig.barrier()
        XCTAssertEqual(rig.peer.recoveryRequests.count, 0)

        // The deadline is 50 ms; one re-armed timer fires it.
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
        XCTAssertFalse(rig.recorder.recentFrames().contains { $0.rendererDropped },
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

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

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

    init() {
        let dimensions = dimensions
        handoff = VideoRendererHandoff(
            renderer: renderer,
            queue: queue,
            clockModel: HostClockModel(),
            books: VideoDeliveryBooks(),
            recorder: recorder,
            onDimensionsChanged: { width, height in
                dimensions.mutate { $0.append("\(width)x\(height)") }
            })
        handoff.bind(peer)
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
    var onIrap: (@Sendable (FrameNumber) -> Void)?

    var recoveryRequests: [Request] { lock.withLock { _requests } }
    var irapsEnqueued: [UInt32] { lock.withLock { _iraps } }

    func requestVideoRecovery(after frame: FrameNumber, cause: VideoRecoveryCause) {
        lock.withLock { _requests.append(Request(frame: frame.rawValue, cause: cause)) }
    }

    func noteVideoIrapEnqueued(frame: FrameNumber) {
        lock.withLock { _iraps.append(frame.rawValue) }
        onIrap?(frame)
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
    var holdRecoveryFlush = false

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
    var status: AVQueuedSampleBufferRenderingStatus { .rendering }
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
