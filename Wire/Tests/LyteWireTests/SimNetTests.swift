import XCTest
import LyteWireTestKit

final class SimNetTests: XCTestCase {
    private func replay(seed: UInt64) -> ([UInt64], [[UInt8]], Int, Int) {
        let healthy = SimNetConfig(baseDelayMicroseconds: 500)
        let fifty = SimNetConfig(
            baseDelayMicroseconds: 500,
            bandwidthBitsPerSecond: 50_000_000,
            maxQueueByteCount: 20_000
        )
        let five = SimNetConfig(
            baseDelayMicroseconds: 500,
            bandwidthBitsPerSecond: 5_000_000,
            maxQueueByteCount: 8_000
        )
        let jitter = SimNetConfig(
            baseDelayMicroseconds: 500, jitterMicroseconds: 8_000
        )
        let lossy = SimNetConfig(lossRate: 0.35, baseDelayMicroseconds: 500)
        let blackout = SimNetConfig(lossRate: 1)
        let schedule = [
            SimNetPhase(startMicroseconds: 10_000, config: fifty),
            SimNetPhase(startMicroseconds: 20_000, config: five),
            SimNetPhase(startMicroseconds: 30_000, config: fifty),
            SimNetPhase(startMicroseconds: 40_000, config: jitter),
            SimNetPhase(startMicroseconds: 50_000, config: lossy),
            SimNetPhase(startMicroseconds: 60_000, config: blackout),
            SimNetPhase(startMicroseconds: 70_000, config: healthy),
        ]
        var net = SimNet(config: healthy, seed: seed, schedule: schedule)
        for index in 0..<80 {
            var bytes = [UInt8](repeating: 0xA5, count: 1_000)
            bytes[0] = UInt8(index)
            net.send(
                from: index & 1,
                bytes: bytes,
                now: UInt64(index) * 1_000
            )
        }
        let deliveries = net.deliveries(upTo: 1_000_000)
        return (
            deliveries.map(\.arrivalMicroseconds),
            deliveries.map(\.bytes),
            net.lostCount,
            net.queueDroppedCount
        )
    }

    func testPhasedScheduleReplayIsByteAndTimeExact() {
        let first = replay(seed: 0xB077_E2)
        let second = replay(seed: 0xB077_E2)
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(first.2, second.2)
        XCTAssertEqual(first.3, second.3)
        XCTAssertGreaterThan(first.2, 0)
        XCTAssertFalse(first.0.isEmpty)
    }

    func testBandwidthSerializesEachDirectionIndependently() {
        var net = SimNet(
            config: SimNetConfig(bandwidthBitsPerSecond: 8_000_000),
            seed: 1
        )
        net.send(from: 0, bytes: [UInt8](repeating: 1, count: 100), now: 0)
        net.send(from: 0, bytes: [UInt8](repeating: 2, count: 100), now: 0)
        net.send(from: 1, bytes: [UInt8](repeating: 3, count: 100), now: 0)

        let deliveries = net.deliveries(upTo: 1_000)
        XCTAssertEqual(
            deliveries.map(\.arrivalMicroseconds), [100, 100, 200]
        )
        XCTAssertEqual(deliveries.map { $0.bytes[0] }, [1, 3, 2])
    }

    func testStandingQueueDropsAtBoundAndRecoversCapacity() {
        var net = SimNet(
            config: SimNetConfig(
                bandwidthBitsPerSecond: 8_000_000,
                maxQueueByteCount: 150
            ),
            seed: 2
        )
        net.send(from: 0, bytes: [UInt8](repeating: 1, count: 100), now: 0)
        net.send(from: 0, bytes: [UInt8](repeating: 2, count: 100), now: 0)
        XCTAssertEqual(net.queuedByteCount(from: 0, at: 0), 100)
        XCTAssertEqual(net.queueDroppedCount, 1)
        XCTAssertEqual(net.peakQueuedByteCount, 100)

        net.send(from: 0, bytes: [UInt8](repeating: 3, count: 100), now: 100)
        XCTAssertEqual(net.queueDroppedCount, 1)
        XCTAssertEqual(
            net.deliveries(upTo: 1_000).map { $0.bytes[0] }, [1, 3]
        )
    }

    func testG3JitterShapeIsBoundedAndActuallyReorders() {
        let config = SimNetConfig(
            baseDelayMicroseconds: 2_000,
            jitterMicroseconds: 20_000
        )
        var net = SimNet(config: config, seed: 0x63_33)
        for index in 0..<100 {
            net.send(
                from: 0, bytes: [UInt8(index)], now: UInt64(index) * 1_000
            )
        }
        let deliveries = net.deliveries(upTo: 1_000_000)
        for delivery in deliveries {
            let sentAt = UInt64(delivery.bytes[0]) * 1_000
            XCTAssertGreaterThanOrEqual(
                delivery.arrivalMicroseconds, sentAt + 2_000
            )
            XCTAssertLessThanOrEqual(
                delivery.arrivalMicroseconds, sentAt + 22_000
            )
        }
        XCTAssertNotEqual(
            deliveries.map { $0.bytes[0] }, (0..<100).map(UInt8.init)
        )
        let gaps = CadenceSLO.interArrivalGaps(
            deliveries.map(\.arrivalMicroseconds)
        )
        XCTAssertLessThanOrEqual(
            CadenceSLO.percentile(gaps, p: 0.99)!, 6_000
        )
    }

    func testBurstLossDropsConsecutiveDatagramsThenPhaseRecovers() {
        let burst = SimNetConfig(
            burstLoss: SimNetBurstLoss(
                startRate: 1, minimumDatagrams: 3, maximumDatagrams: 3
            )
        )
        var net = SimNet(
            config: burst,
            seed: 3,
            schedule: [
                SimNetPhase(startMicroseconds: 3, config: SimNetConfig())
            ]
        )
        for index in 0..<6 {
            net.send(from: 0, bytes: [UInt8(index)], now: UInt64(index))
        }
        XCTAssertEqual(net.lostCount, 3)
        XCTAssertEqual(
            net.deliveries(upTo: 100).map { $0.bytes[0] }, [3, 4, 5]
        )
    }

    func testSeededRandomLossReplaysTheSameSparseSet() {
        func delivered(seed: UInt64) -> [UInt8] {
            var net = SimNet(
                config: SimNetConfig(lossRate: 0.30), seed: seed
            )
            for index in 0..<100 {
                net.send(from: 0, bytes: [UInt8(index)], now: UInt64(index))
            }
            return net.deliveries(upTo: 1_000).map { $0.bytes[0] }
        }
        let first = delivered(seed: 0x1055)
        XCTAssertEqual(first, delivered(seed: 0x1055))
        XCTAssertGreaterThan(first.count, 50)
        XCTAssertLessThan(first.count, 100)
    }

    func testCapacityCliffAndRecoveryHaveExpectedSerialization() {
        let fifty = SimNetConfig(bandwidthBitsPerSecond: 50_000_000)
        let five = SimNetConfig(bandwidthBitsPerSecond: 5_000_000)
        var net = SimNet(
            config: fifty,
            seed: 4,
            schedule: [
                SimNetPhase(startMicroseconds: 20_000, config: five),
                SimNetPhase(startMicroseconds: 80_000, config: fifty),
            ]
        )
        let bytes = [UInt8](repeating: 0, count: 6_250)
        net.send(from: 0, bytes: bytes, now: 0)
        net.send(from: 0, bytes: bytes, now: 20_000)
        net.send(from: 0, bytes: bytes, now: 80_000)
        let arrivals = net.deliveries(upTo: 200_000).map(\.arrivalMicroseconds)
        XCTAssertEqual(arrivals, [1_000, 30_000, 81_000])
        XCTAssertEqual(
            CadenceSLO.recoveryDelay(
                after: 80_000, observations: arrivals
            ),
            1_000
        )
    }

    func testBlackoutAndRecoverySchedule() {
        var net = SimNet(
            config: SimNetConfig(),
            seed: 5,
            schedule: [
                SimNetPhase(
                    startMicroseconds: 10,
                    config: SimNetConfig(lossRate: 1)
                ),
                SimNetPhase(startMicroseconds: 20, config: SimNetConfig()),
            ]
        )
        net.send(from: 0, bytes: [0], now: 0)
        net.send(from: 0, bytes: [1], now: 10)
        net.send(from: 0, bytes: [2], now: 20)
        XCTAssertEqual(net.lostCount, 1)
        XCTAssertEqual(
            net.deliveries(upTo: 100).map { $0.bytes[0] }, [0, 2]
        )
    }

    func testCadenceSLOHelpers() {
        let arrivals: [UInt64] = [10, 20, 35, 100]
        XCTAssertEqual(CadenceSLO.interArrivalGaps(arrivals), [10, 15, 65])
        XCTAssertEqual(
            CadenceSLO.stalls(arrivals, exceeding: 20), [65]
        )
        XCTAssertEqual(
            CadenceSLO.percentile([10, 15, 65], p: 0.50), 15
        )
        XCTAssertTrue(CadenceSLO.queueStayedBounded([0, 5, 10], limit: 10))
        XCTAssertFalse(CadenceSLO.queueStayedBounded([11], limit: 10))
    }
}
