import Foundation
import XCTest
@testable import LyteTransport

final class VideoFlightRecorderTests: XCTestCase {
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var next: UInt64
        private let step: UInt64

        init(start: UInt64, step: UInt64) {
            next = start
            self.step = step
        }

        func now() -> UInt64 {
            lock.lock()
            defer {
                next &+= step
                lock.unlock()
            }
            return next
        }
    }

    func testHealthyFramesReportNoMeasuredStall() {
        let recorder = makeRecorder(capacity: 10)
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
        let source = makeRecorder()
        recordPair(source, hostGapMS: 40, readyGapMS: 40)
        XCTAssertEqual(source.snapshot().bottleneck, "host capture/encode")

        let transit = makeRecorder()
        recordPair(transit, hostGapMS: 16, readyGapMS: 40)
        XCTAssertEqual(
            transit.snapshot().bottleneck, "pre-render delivery")

        let queue = makeRecorder()
        let token = queue.frameReady(
            frame: 1, hostMicroseconds: 1_000, nowNanoseconds: 1_000_000)
        queue.frameEnqueued(
            token,
            enqueueStartedNanoseconds: 12_000_000,
            enqueueFinishedNanoseconds: 12_100_000,
            rendererReady: true,
            rendererFailed: false)
        XCTAssertEqual(queue.snapshot().bottleneck, "app delivery queue")

        let renderer = makeRecorder()
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

    func testRendererMetricsUseRecentDeltaNotHistoricalTotal() {
        let recorder = makeRecorder()
        let first = recorder.frameReady(
            frame: 1, hostMicroseconds: 1_000, nowNanoseconds: 1_000_000)
        recorder.frameEnqueued(
            first,
            enqueueStartedNanoseconds: 1_100_000,
            enqueueFinishedNanoseconds: 1_200_000,
            rendererReady: true,
            rendererFailed: false)
        recorder.recordRendererMetrics(.init(
            totalFrames: 120,
            droppedFrames: 7,
            corruptedFrames: 0,
            accumulatedDelayMilliseconds: 42))

        let second = recorder.frameReady(
            frame: 2, hostMicroseconds: 17_667,
            nowNanoseconds: 17_667_000)
        recorder.frameEnqueued(
            second,
            enqueueStartedNanoseconds: 17_767_000,
            enqueueFinishedNanoseconds: 17_867_000,
            rendererReady: true,
            rendererFailed: false)
        recorder.recordRendererMetrics(.init(
            totalFrames: 180,
            droppedFrames: 7,
            corruptedFrames: 0,
            accumulatedDelayMilliseconds: 42))

        XCTAssertEqual(
            recorder.snapshot().bottleneck, "no measured stall")
        XCTAssertEqual(
            recorder.snapshot().recentRendererMetrics?.droppedFrames, 0)

        recorder.recordRendererMetrics(.init(
            totalFrames: 181,
            droppedFrames: 8,
            corruptedFrames: 0,
            accumulatedDelayMilliseconds: 43))
        XCTAssertEqual(
            recorder.snapshot().bottleneck, "renderer dropped frames")
    }

    func testHistoricalHandoffFailureAgesOutOfCurrentVerdict() {
        let recorder = makeRecorder(capacity: 2)
        for i: UInt32 in 1...3 {
            let now = UInt64(i) * 16_667_000
            let token = recorder.frameReady(
                frame: i,
                hostMicroseconds: UInt64(i) * 16_667,
                nowNanoseconds: now)
            recorder.frameEnqueued(
                token,
                enqueueStartedNanoseconds: now + 100_000,
                enqueueFinishedNanoseconds: now + 200_000,
                rendererReady: i != 1,
                rendererFailed: i == 1,
                rendererDropped: i == 1)
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.rendererFailures, 1)
        XCTAssertEqual(snapshot.rendererDrops, 1)
        XCTAssertEqual(snapshot.recentRendererFailures, 0)
        XCTAssertEqual(snapshot.recentRendererDrops, 0)
        XCTAssertEqual(snapshot.bottleneck, "no measured stall")
    }

    func testRecoveryCausesAreCountedSeparately() {
        let recorder = makeRecorder()
        recorder.recordRecoveryCause(.fecAssemblerDamage)
        recorder.recordRecoveryCause(.fecAssemblerDamage)
        recorder.recordRecoveryCause(.hostPurgeInferredDamage)
        XCTAssertEqual(recorder.snapshot().recoveryCauses, [
            "fecAssemblerDamage": 2,
            "hostPurgeInferredDamage": 1,
        ])
        recorder.reset()
        XCTAssertTrue(recorder.snapshot().recoveryCauses.isEmpty)
    }

    func testRecoveryLifecycleCorrelatesResetAndCorruptionDelta() {
        let clock = StepClock(start: 1_000_000, step: 250_000)
        let recorder = makeRecorder(nowMicroseconds: clock.now)
        let token = recorder.frameReady(
            frame: 42, hostMicroseconds: 1_000,
            nowNanoseconds: 1_000_000)
        recorder.recordRecoveryLifecycle(
            kind: "rendererEnqueueIrap",
            frame: 42,
            cause: .fecAssemblerDamage,
            episode: 3,
            isRandomAccess: true,
            resetDecoderBeforeDecoding: true,
            awaitingRandomAccess: true,
            randomAccessPending: true,
            pendingCount: 0)
        recorder.recordRendererMetrics(
            .init(
                totalFrames: 100,
                droppedFrames: 2,
                corruptedFrames: 7,
                accumulatedDelayMilliseconds: 0),
            sampledAfter: token,
            sampledAfterFrame: 42,
            sampledAfterIsRandomAccess: true)

        let events = recorder.snapshot().recoveryLifecycle
        XCTAssertEqual(events.map(\.kind), [
            "rendererEnqueueIrap", "rendererMetrics",
        ])
        XCTAssertEqual(events[0].frame, 42)
        XCTAssertEqual(events[0].resetDecoderBeforeDecoding, true)
        XCTAssertEqual(events[0].uptimeMicroseconds, 1_000_000)
        XCTAssertEqual(events[1].frame, 42)
        XCTAssertEqual(events[1].corruptedDelta, 7)
        XCTAssertEqual(events[1].uptimeMicroseconds, 1_250_000)
    }

    func testRingIsBoundedAndRendererSamplingCadenceIsPinned() {
        let recorder = makeRecorder(capacity: 3)
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

    func testStructuredFrameTelemetryJSONAndSessionReset() throws {
        let recorder = makeRecorder(capacity: 2)
        let token = recorder.frameReady(
            frame: 7, hostMicroseconds: 10_000,
            nowNanoseconds: 20_000_000)
        recorder.frameEnqueued(
            token,
            enqueueStartedNanoseconds: 21_000_000,
            enqueueFinishedNanoseconds: 21_100_000,
            rendererReady: false,
            rendererFailed: false,
            rendererDropped: true,
            sampleBuildMicroseconds: 900,
            assemblyLockHoldMicroseconds: 40,
            scheduledPresentationMicroseconds: 45_000,
            cueMicroseconds: 25_000,
            pathDelayMicroseconds: 9_000,
            reserveMicroseconds: 16_000,
            presentationLatenessMicroseconds: 2_000,
            rendererRecovery: true)

        let frame = try XCTUnwrap(recorder.recentFrames().first)
        XCTAssertEqual(frame.frame, 7)
        XCTAssertEqual(frame.queueDepth, 1)
        XCTAssertEqual(frame.sampleBuildMilliseconds ?? 0, 0.9)
        XCTAssertEqual(frame.cueMilliseconds, 25)
        XCTAssertEqual(frame.pathDelayMilliseconds, 9)
        XCTAssertEqual(frame.reserveMilliseconds, 16)
        XCTAssertTrue(frame.rendererDropped)
        XCTAssertTrue(
            try recorder.summaryJSONLine().contains("\"rendererDrops\":1"))

        recorder.reset()
        XCTAssertEqual(recorder.snapshot().frames, 0)
        XCTAssertTrue(recorder.recentFrames().isEmpty)
    }

    func testWrappedRingReportsNewestCue() {
        let recorder = makeRecorder(capacity: 2)
        for i: UInt32 in 1...3 {
            let now = UInt64(i) * 10_000_000
            let token = recorder.frameReady(
                frame: i,
                hostMicroseconds: UInt64(i) * 10_000,
                nowNanoseconds: now)
            recorder.frameEnqueued(
                token,
                enqueueStartedNanoseconds: now,
                enqueueFinishedNanoseconds: now,
                rendererReady: true,
                rendererFailed: false,
                cueMicroseconds: UInt64(i) * 10_000)
        }

        XCTAssertEqual(recorder.snapshot().cueMilliseconds, 30)
    }

    func testRepeatedCaptureTimestampIsRetainedProvenanceNotTransitStall() {
        let recorder = makeRecorder(capacity: 10)
        for i: UInt32 in 0..<3 {
            let ready = UInt64(i) * 16_000_000
            let token = recorder.frameReady(
                frame: i,
                hostMicroseconds: 42_000,
                nowNanoseconds: ready)
            recorder.frameEnqueued(
                token,
                enqueueStartedNanoseconds: ready + UInt64(i + 1) * 100_000,
                enqueueFinishedNanoseconds: ready + UInt64(i + 1) * 200_000,
                rendererReady: true,
                rendererFailed: false)
        }

        let observations = recorder.recentFrames()
        XCTAssertEqual(
            observations.map(\.provenance),
            [.freshCapture, .retainedRefinement, .retainedRefinement])
        XCTAssertNil(observations[1].transitStretchMilliseconds)
        XCTAssertEqual(recorder.snapshot().freshCaptureFrames, 1)
        XCTAssertEqual(recorder.snapshot().retainedRefinementFrames, 2)
        XCTAssertEqual(
            recorder.snapshot().queueWaitP50Milliseconds ?? 0,
            0.2, accuracy: 0.001)
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

    private func makeRecorder(
        capacity: Int = 360,
        nowMicroseconds: @escaping @Sendable () -> UInt64 = { 0 }
    ) -> VideoFlightRecorder {
        VideoFlightRecorder(
            capacity: capacity,
            nowMicroseconds: nowMicroseconds)
    }
}
