import XCTest
@testable import HostCore

final class KernelPressureGovernorTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func sample(
        now: UInt64,
        userspace: Int = 0,
        videoKernel: Int = 0,
        latencyKernel: Int = 0,
        eagain: Int = 0,
        enobufs: Int = 0
    ) -> KernelPressureSample {
        KernelPressureSample(
            nowNS: now,
            userspaceVideoBytes: userspace,
            videoKernelBytes: videoKernel,
            latencyKernelBytes: latencyKernel,
            videoSendBufferBytes: 212_992,
            latencySendBufferBytes: 212_992,
            videoWouldBlockCount: eagain,
            latencyWouldBlockCount: 0,
            videoENOBUFSCount: enobufs,
            latencyENOBUFSCount: 0,
            pacerRateBitsPerSecond: 50_000_000,
            videoQueueBudgetNS: 100 * ms,
            frameBudgetBytes: 150_000)
    }

    func testAdmissionDebtIncludesKernelAcceptedVideo() {
        var governor = KernelPressureGovernor()
        _ = governor.observe(sample(now: 0))
        let decision = governor.observe(sample(
            now: ms, userspace: 100_000, videoKernel: 110_000))
        XCTAssertEqual(decision.totalVideoBytes, 210_000)
        XCTAssertEqual(decision.totalVideoServiceDebtNS, 33_600_000)
        XCTAssertEqual(decision.state, .constrained,
            "kernel high water tightens admission before SO_SNDBUF fills")
        XCTAssertLessThan(
            decision.admissionBudgetNS,
            decision.totalVideoServiceDebtNS)
    }

    func testSustainedPressureStopsVideoPumpThenRecoversHysteretically() {
        var governor = KernelPressureGovernor()
        _ = governor.observe(sample(now: 0))
        XCTAssertEqual(governor.observe(sample(
            now: ms, videoKernel: 120_000)).state, .constrained)
        let stopped = governor.observe(sample(
            now: 30 * ms, videoKernel: 120_000))
        XCTAssertEqual(stopped.state, .latencyOnly)
        XCTAssertFalse(stopped.allowVideoPump)

        XCTAssertEqual(governor.observe(sample(
            now: 60 * ms, videoKernel: 0)).state, .latencyOnly)
        XCTAssertEqual(governor.observe(sample(
            now: 90 * ms, videoKernel: 0)).state, .constrained)
        XCTAssertEqual(governor.observe(sample(
            now: 120 * ms, videoKernel: 0)).state, .calm)
    }

    func testUserspaceDebtCannotDeadlockLatencyOnlyPump() {
        var governor = KernelPressureGovernor()
        _ = governor.observe(sample(now: 0))
        _ = governor.observe(sample(now: ms, videoKernel: 120_000))
        XCTAssertEqual(governor.observe(sample(
            now: 30 * ms, videoKernel: 120_000)).state, .latencyOnly)

        let draining = governor.observe(sample(
            now: 31 * ms, userspace: 700_000, videoKernel: 0))
        XCTAssertEqual(draining.state, .constrained)
        XCTAssertTrue(draining.allowVideoPump,
            "kernel-clear userspace debt must be pumped down")
        XCTAssertLessThan(
            draining.admissionBudgetNS,
            draining.totalVideoServiceDebtNS,
            "the same debt must keep pre-encode admission closed")
    }

    func testENOBUFSEscalatesAndSheddingIsFreshOnlyAndStaleOnly() {
        var governor = KernelPressureGovernor()
        _ = governor.observe(sample(now: 0))
        let decision = governor.observe(sample(now: ms, enobufs: 1))
        XCTAssertEqual(decision.enobufsDelta, 1)
        XCTAssertEqual(decision.state, .latencyOnly)

        let now = 200 * ms
        XCTAssertTrue(KernelPressureGovernor.shouldShedAtSocket(
            priorityClass: .freshVideo,
            releasedAtNS: 50 * ms,
            nowNS: now,
            videoQueueBudgetNS: 100 * ms))
        XCTAssertFalse(KernelPressureGovernor.shouldShedAtSocket(
            priorityClass: .freshVideo,
            releasedAtNS: 150 * ms,
            nowNS: now,
            videoQueueBudgetNS: 100 * ms))
        for protectedClass in [
            PacerClass.control, .audio, .videoTail, .refinement,
            .telemetry, .bulk
        ] {
            XCTAssertFalse(KernelPressureGovernor.shouldShedAtSocket(
                priorityClass: protectedClass,
                releasedAtNS: 0,
                nowNS: now,
                videoQueueBudgetNS: 100 * ms))
        }
    }
}
