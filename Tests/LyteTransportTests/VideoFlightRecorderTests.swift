import XCTest
@testable import LyteTransport

final class VideoFlightRecorderTests: XCTestCase {
    func testHealthyFramesReportNoMeasuredStall() {
        let recorder = VideoFlightRecorder(capacity: 10)
        for i: UInt32 in 0..<10 {
            let ready = UInt64(i) * 16_667_000
            let token = recorder.frameReady(
                frame: i,
                hostMicroseconds: UInt64(i) * 16_667,
                nowNanoseconds: ready)
            recorder.frameEnqueued(
                token,
                enqueueStartedNanoseconds: ready + 100_000,
                enqueueFinishedNanoseconds: ready + 200_000,
                rendererReady: true,
                rendererFailed: false)
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.frames, 10)
        XCTAssertEqual(snapshot.pending, 0)
        XCTAssertEqual(snapshot.maximumPending, 1)
        XCTAssertEqual(snapshot.bottleneck, "no measured stall")
        XCTAssertEqual(snapshot.sourceGapP99Milliseconds ?? 0, 16.667,
                       accuracy: 0.001)
    }

    func testEachBoundaryProducesItsOwnVerdict() {
        let source = VideoFlightRecorder()
        recordPair(source, hostGapMS: 40, readyGapMS: 40)
        XCTAssertEqual(source.snapshot().bottleneck, "host capture/encode")

        let transit = VideoFlightRecorder()
        recordPair(transit, hostGapMS: 16, readyGapMS: 40)
        XCTAssertEqual(transit.snapshot().bottleneck, "network/assembly")

        let queue = VideoFlightRecorder()
        let token = queue.frameReady(
            frame: 1, hostMicroseconds: 1_000, nowNanoseconds: 1_000_000)
        queue.frameEnqueued(
            token,
            enqueueStartedNanoseconds: 12_000_000,
            enqueueFinishedNanoseconds: 12_100_000,
            rendererReady: true,
            rendererFailed: false)
        XCTAssertEqual(queue.snapshot().bottleneck, "app delivery queue")

        let renderer = VideoFlightRecorder()
        let rendererToken = renderer.frameReady(
            frame: 1, hostMicroseconds: 1_000, nowNanoseconds: 1_000_000)
        renderer.frameEnqueued(
            rendererToken,
            enqueueStartedNanoseconds: 1_100_000,
            enqueueFinishedNanoseconds: 1_200_000,
            rendererReady: false,
            rendererFailed: false)
        XCTAssertEqual(
            renderer.snapshot().bottleneck, "renderer backpressure")
    }

    func testRendererMetricsOverrideUpstreamTiming() {
        let recorder = VideoFlightRecorder()
        recorder.recordRendererMetrics(.init(
            totalFrames: 120,
            droppedFrames: 7,
            corruptedFrames: 0,
            accumulatedDelayMilliseconds: 42))
        XCTAssertEqual(
            recorder.snapshot().bottleneck, "renderer dropped frames")
    }

    func testRingIsBoundedAndRendererSamplingCadenceIsPinned() {
        let recorder = VideoFlightRecorder(capacity: 3)
        var sampled: [UInt32] = []
        for i: UInt32 in 1...120 {
            let now = UInt64(i) * 1_000_000
            let token = recorder.frameReady(
                frame: i, hostMicroseconds: UInt64(i) * 1_000,
                nowNanoseconds: now)
            if recorder.shouldSampleRenderer(after: token) {
                sampled.append(i)
            }
            recorder.frameEnqueued(
                token,
                enqueueStartedNanoseconds: now,
                enqueueFinishedNanoseconds: now,
                rendererReady: true,
                rendererFailed: false)
        }
        XCTAssertEqual(sampled, [1, 60, 120])
        XCTAssertEqual(recorder.snapshot().frames, 120)
    }

    private func recordPair(
        _ recorder: VideoFlightRecorder,
        hostGapMS: UInt64,
        readyGapMS: UInt64
    ) {
        let first = recorder.frameReady(
            frame: 1, hostMicroseconds: 0, nowNanoseconds: 0)
        recorder.frameEnqueued(
            first,
            enqueueStartedNanoseconds: 100_000,
            enqueueFinishedNanoseconds: 200_000,
            rendererReady: true,
            rendererFailed: false)
        let second = recorder.frameReady(
            frame: 2,
            hostMicroseconds: hostGapMS * 1_000,
            nowNanoseconds: readyGapMS * 1_000_000)
        recorder.frameEnqueued(
            second,
            enqueueStartedNanoseconds: readyGapMS * 1_000_000 + 100_000,
            enqueueFinishedNanoseconds: readyGapMS * 1_000_000 + 200_000,
            rendererReady: true,
            rendererFailed: false)
    }
}
