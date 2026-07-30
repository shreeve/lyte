// The adaptive pump cadence pins (item 18): the schedule is a pure
// function of ring depth — microseconds until the ring, draining at
// exactly the DAC rate, could reach the urgent threshold (one packet),
// clamped to the [2 ms, 10 ms] band. The floor is the dry-ring reflex
// the fixed 2 ms timer used to provide everywhere; the ceiling bounds
// any wrong guess to two packets. These pins hold the safety law: the
// pump never sleeps past the moment the ring could go urgent.

import LyteWire
import XCTest

@testable import LyteTransport

final class AudioPumpCadenceTests: XCTestCase {
    private let packet = AudioWire.samplesPerPacket   // 240 frames, 5 ms
    private let floor = LyteAudioPlayer.pumpFloorMicros
    private let ceiling = LyteAudioPlayer.pumpCeilingMicros

    func testDryAndShallowRingsWalkTheFloor() {
        // No headroom above the urgent threshold — the reflex cadence.
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: 0), floor)
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: packet),
            floor)
        // Under 2 ms of headroom still floors: one packet plus 1 ms
        // (48 frames) is 1 ms from urgent — the floor is the shortest
        // sleep the pump ever takes.
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: packet + 48),
            floor)
    }

    func testMidRingSleepsExactlyItsHeadroom() {
        // Between the clamps the sleep IS the headroom: 1.5 packets
        // deep is 2.5 ms from urgent, two packets deep is 5 ms.
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(
                ringDepthFrames: packet + packet / 2), 2_500)
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: 2 * packet),
            5_000)
    }

    func testDeepRingRidesTheCeiling() {
        // Three packets deep lands exactly on the ceiling; anything
        // deeper clamps to it — a healthy ring wakes 100×/s, not 500.
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: 3 * packet),
            ceiling)
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(ringDepthFrames: 10 * packet),
            ceiling)
        XCTAssertEqual(
            LyteAudioPlayer.nextPumpDelayMicros(
                ringDepthFrames: AudioPcmRing.capacityFrames), ceiling)
    }

    func testSleepNeverPassesTheUrgentInstant() {
        // The safety law across every depth the ring can hold: the
        // chosen sleep never exceeds the time the ring takes to drain
        // to the urgent threshold, except where the floor IS the
        // minimum sleep (and the floor sits inside one packet, so the
        // urgent flag still fires with the ring merely nearly-dry).
        for depth in stride(
            from: 0, through: AudioPcmRing.capacityFrames, by: 60) {
            let delay = LyteAudioPlayer.nextPumpDelayMicros(
                ringDepthFrames: depth)
            let urgentMicros =
                (depth - packet) * 1_000_000 / AudioWire.sampleRate
            XCTAssertLessThanOrEqual(delay, max(floor, urgentMicros))
            XCTAssertGreaterThanOrEqual(delay, floor)
            XCTAssertLessThanOrEqual(delay, ceiling)
        }
    }
}
