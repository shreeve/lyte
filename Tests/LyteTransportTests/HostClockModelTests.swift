import XCTest
import Foundation
import LyteTransport
import LyteWire

// THE CL-10 GATE (client plan: "min-filtered offset + regression skew over
// 30 s window from beacon echoes; residual < 1 ms after 30 s"). Synthetic
// traces built from the LIVE-RUN facts: min RTT 5–10 ms with offsets
// stable to ~±1 µs at the min edge; Wi-Fi power-save RTT spikes of
// 55–100 ms whose offsets are polluted by tens of ms of one-sided
// queuing; CLOCK_MONOTONIC epochs differing by boot time, so offsets are
// ~10¹¹ µs and the fit must stay exact anyway.

final class HostClockModelTests: XCTestCase {

    /// The live-soak epoch gap: offset ≈ 83,907,658,000,000 µs.
    private static let bootEpochOffset: Int64 = 83_907_658_000_000

    private func sample(
        seq: UInt32, atSeconds: Double, offset: Int64, rtt: Int64
    ) -> ClockSample {
        ClockSample(
            beaconSeq: seq,
            offsetMicroseconds: offset,
            rttMicroseconds: rtt,
            measuredAt: ClientTimestamp(
                microseconds: UInt64(atSeconds * 1_000_000)))
    }

    // MARK: - Basics

    func testEmptyModelHasNoEstimate() throws {
        let model = HostClockModel()
        XCTAssertNil(model.estimate())
        XCTAssertNil(model.map(HostTimestamp(microseconds: 1)))
    }

    func testSingleSampleIsUsableImmediately() throws {
        // Frame 1 after idle must be mappable: no warm-up window.
        let model = HostClockModel()
        model.ingest(sample(seq: 0, atSeconds: 10, offset: 250_000, rtt: 8_000))

        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.offsetMicroseconds, 250_000)
        XCTAssertEqual(fit.skewPartsPerMillion, 0, "one sample fits no slope")
        XCTAssertEqual(fit.acceptedSamples, 1)
        XCTAssertEqual(fit.residualRmsMicroseconds, 0)

        // map: host 900,000 µs + offset 250,000 = client 1,150,000 µs.
        XCTAssertEqual(
            model.map(HostTimestamp(microseconds: 900_000))?.microseconds,
            1_150_000)
    }

    func testConstantOffsetCleanRttsFitExactly() throws {
        let model = HostClockModel()
        for i in 0..<20 {
            model.ingest(sample(
                seq: UInt32(i), atSeconds: Double(i),
                offset: Self.bootEpochOffset, rtt: 6_000))
        }
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.offsetMicroseconds, Self.bootEpochOffset,
                       "a ~10¹¹ µs offset survives the fit exactly (centering)")
        XCTAssertEqual(fit.skewPartsPerMillion, 0, accuracy: 0.001)
        XCTAssertEqual(fit.residualRmsMicroseconds, 0, accuracy: 0.001)
        XCTAssertEqual(fit.acceptedSamples, 20)
        XCTAssertEqual(fit.minRttMicroseconds, 6_000)
    }

    func testNegativeOffsetSurvives() throws {
        // The other live shape: offset settles near −129,894 s.
        let offset: Int64 = -129_894_000_000
        let model = HostClockModel()
        for i in 0..<10 {
            model.ingest(sample(seq: UInt32(i), atSeconds: Double(i),
                                offset: offset, rtt: 5_500))
        }
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.offsetMicroseconds, offset)

        // map inverts it: client = host + offset (host µs here is large
        // enough that the sum stays positive).
        let host = HostTimestamp(microseconds: 130_000_000_000)
        XCTAssertEqual(model.map(host)?.microseconds,
                       UInt64(130_000_000_000 + offset))
    }

    // MARK: - Min-RTT gating (the Wi-Fi power-save spikes)

    func testRttSpikesAreGatedOutOfTheFit() throws {
        let model = HostClockModel()
        let trueOffset: Int64 = 500_000
        for i in 0..<30 {
            if i % 5 == 4 {
                // A power-save spike: 55–100 ms RTT, offset polluted by
                // ~half the extra one-way queuing (tens of ms).
                model.ingest(sample(
                    seq: UInt32(i), atSeconds: Double(i),
                    offset: trueOffset + 40_000, rtt: 80_000))
            } else {
                model.ingest(sample(
                    seq: UInt32(i), atSeconds: Double(i),
                    offset: trueOffset + Int64(i % 3) - 1,   // ±1 µs jitter
                    rtt: 6_000 + Int64(i % 7) * 100))        // 6.0–6.6 ms
            }
        }
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.windowSamples, 30)
        XCTAssertEqual(fit.acceptedSamples, 24, "the 6 spikes are gated out")
        XCTAssertEqual(fit.minRttMicroseconds, 6_000)
        XCTAssertEqual(Double(fit.offsetMicroseconds), Double(trueOffset),
                       accuracy: 5, "spike-polluted offsets never touch the fit")
        XCTAssertLessThan(fit.residualRmsMicroseconds, 10)
    }

    func testAllSpikesStillYieldAnEstimate() throws {
        // A window that is ALL bad samples still answers — with honest
        // residuals — rather than going dark (min-gating is relative).
        let model = HostClockModel()
        for i in 0..<5 {
            model.ingest(sample(seq: UInt32(i), atSeconds: Double(i),
                                offset: 100_000 + Int64(i) * 3_000,
                                rtt: 60_000 + Int64(i) * 9_000))
        }
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.acceptedSamples, 1,
                       "only the min-RTT sample passes a tight gate")
        XCTAssertEqual(fit.offsetMicroseconds, 100_000)
    }

    // MARK: - Skew regression

    func testFiftyPpmSkewIsRecovered() throws {
        // The audio doc's consumer-clock figure: ~50 ppm ≈ 3 ms/min.
        // offset(t) = base + 50e-6 · t, sampled at 1 Hz for 30 s. Base is
        // the live "host booted long before the client" shape (negative:
        // host µs = client µs − offset stays positive for small client t).
        let model = HostClockModel()
        let base: Int64 = -129_894_000_000
        for i in 0..<31 {
            let t = Double(i)
            model.ingest(sample(
                seq: UInt32(i), atSeconds: t,
                offset: base + Int64((50e-6 * t * 1_000_000).rounded()),
                rtt: 6_000))
        }
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.skewPartsPerMillion, 50, accuracy: 0.5)
        // Anchor is the newest sample (t = 30 s): offset there is base + 1500.
        XCTAssertEqual(Double(fit.offsetMicroseconds),
                       Double(base + 1_500), accuracy: 2)
        XCTAssertLessThan(fit.residualRmsMicroseconds, 2,
                          "rounding noise only — the line is real")

        // Extrapolate 1 s past the window: a skew-blind model would be
        // 50 µs wrong per second; the fit tracks it. The host instant
        // consistent with client t=31 s is client − offset(31 s).
        let offsetAt31 = base + Int64((50e-6 * 31 * 1_000_000).rounded())
        let hostAt31 = HostTimestamp(
            microseconds: UInt64(31_000_000 - offsetAt31))
        let mapped = try XCTUnwrap(model.map(hostAt31))
        XCTAssertEqual(Double(mapped.microseconds), 31_000_000, accuracy: 5)
    }

    func testTooFewSamplesDegradeToOffsetOnly() throws {
        let model = HostClockModel(config: .init(minimumSamplesForSkew: 3))
        // Two skewed samples: a naive 2-point fit would chase them.
        model.ingest(sample(seq: 0, atSeconds: 0, offset: 1_000, rtt: 5_000))
        model.ingest(sample(seq: 1, atSeconds: 1, offset: 1_400, rtt: 5_000))
        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.skewPartsPerMillion, 0,
                       "below the sample floor, skew stays 0 (offset-only)")
        XCTAssertEqual(fit.offsetMicroseconds, 1_200, "mean of the two")
    }

    // MARK: - Window eviction

    func testWindowSlidesAndEvicts() throws {
        let model = HostClockModel(
            config: .init(windowMicroseconds: 30_000_000))
        for i in 0..<61 {
            model.ingest(sample(seq: UInt32(i), atSeconds: Double(i),
                                offset: 0, rtt: 5_000))
        }
        let fit = try XCTUnwrap(model.estimate())
        // Newest at t=60 s; horizon at 30 s; t ∈ [30, 60] survives.
        XCTAssertEqual(fit.windowSamples, 31)
        XCTAssertEqual(fit.anchor.microseconds, 60_000_000)
    }

    func testEvictionDropsAStaleMinRttHostage() throws {
        // A pathological min RTT early on must not gate out every later
        // (honest) sample forever: once it slides out, the gate re-bases.
        let model = HostClockModel(
            config: .init(windowMicroseconds: 10_000_000))
        model.ingest(sample(seq: 0, atSeconds: 0, offset: 0, rtt: 1_000))
        for i in 1..<8 {
            model.ingest(sample(seq: UInt32(i), atSeconds: Double(i),
                                offset: 77, rtt: 9_000))
        }
        var fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.acceptedSamples, 1, "the 1 ms floor gates the rest")

        // Slide past t=0: the 9 ms samples become the new floor.
        for i in 8..<15 {
            model.ingest(sample(seq: UInt32(i), atSeconds: Double(i),
                                offset: 77, rtt: 9_000))
        }
        fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.minRttMicroseconds, 9_000)
        XCTAssertEqual(fit.acceptedSamples, fit.windowSamples)
        XCTAssertEqual(fit.offsetMicroseconds, 77)
    }

    // MARK: - THE T GATE: residual < 1 ms after 30 s, realistic trace

    func testThirtySecondRealisticTraceHoldsTheResidualGate() throws {
        // The live soak, synthesized: 1 Hz beacons for 30 s; true offset
        // = boot-epoch gap (the negative live shape, so synthetic host µs
        // stay positive) + 50 ppm client skew; min-RTT samples carry
        // ±1 µs offset noise on a 5.5–7.4 ms RTT floor; every 6th beacon
        // is a Wi-Fi power-save casualty (55–100 ms RTT, offset shoved
        // tens of ms). Deterministic "noise" via fixed tables — the test
        // must never flake.
        let base: Int64 = -129_894_000_000
        let offsetNoise: [Int64] = [0, 1, -1, 1, 0, -1]
        let rttFloor: [Int64] = [5_500, 6_100, 5_800, 7_400, 6_200, 6_600]
        let spikeRtt: [Int64] = [55_000, 72_000, 100_000, 61_000, 88_000]
        let model = HostClockModel()

        var spikes = 0
        for i in 0...30 {
            let t = Double(i)
            let trueOffset = base + Int64((50e-6 * t * 1_000_000).rounded())
            if i % 6 == 5 {
                let rtt = spikeRtt[spikes % spikeRtt.count]
                spikes += 1
                model.ingest(sample(
                    seq: UInt32(i), atSeconds: t,
                    offset: trueOffset + (rtt - 6_000) / 2,   // one-sided queue
                    rtt: rtt))
            } else {
                model.ingest(sample(
                    seq: UInt32(i), atSeconds: t,
                    offset: trueOffset + offsetNoise[i % offsetNoise.count],
                    rtt: rttFloor[i % rttFloor.count]))
            }
        }

        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.windowSamples, 31)
        XCTAssertEqual(fit.acceptedSamples, 31 - spikes,
                       "every spike gated, every floor sample kept")

        // THE GATE: mapping residual < 1 ms after 30 s. We hold the fit
        // to its own accepted samples (rms and worst-case) AND to the
        // true line across the window and 1 s beyond it — three ways to
        // fail, all ≪ 1 ms.
        XCTAssertLessThan(fit.residualRmsMicroseconds, 1_000, "THE T GATE")
        XCTAssertLessThan(fit.residualMaxMicroseconds, 1_000)
        for t in [0.0, 15.0, 30.0, 31.0] {
            let trueOffset = base + Int64((50e-6 * t * 1_000_000).rounded())
            let client = Int64(t * 1_000_000)
            let host = HostTimestamp(microseconds: UInt64(client - trueOffset))
            let mapped = try XCTUnwrap(model.map(host))
            let error = abs(Int64(mapped.microseconds) - client)
            XCTAssertLessThan(error, 1_000,
                              "mapping error at t=\(t)s is \(error) µs — gate is 1 ms")
        }

        // And the achieved numbers match the live observation (~±1 µs at
        // the min edge): the fit is microsecond-class, not just sub-ms.
        XCTAssertLessThan(fit.residualRmsMicroseconds, 5)
        XCTAssertEqual(fit.skewPartsPerMillion, 50, accuracy: 1)
    }

    // MARK: - The live feed seam

    func testResponderFeedsTheModelPerClosedSample() throws {
        // BeaconEchoResponder → onClockSample → model, end to end: the
        // worked example's exchange closes one sample carrying its own
        // t2 as the regression coordinate.
        let model = HostClockModel()
        let clock = TickingClock(start: 1_253_500)
        let responder = BeaconEchoResponder(
            now: { clock.next() },
            onClockSample: { model.ingest($0) },
            emit: { _ in })

        let first = ClockBeacon(
            beaconSeq: 0, hostSend: HostTimestamp(microseconds: 1_000_000))
        responder.handleCtrlPayload(first.encode(), arrivalMicroseconds: 1_253_000)
        XCTAssertNil(model.estimate(), "no mirror yet, nothing fed")

        let second = ClockBeacon(
            beaconSeq: 1,
            hostSend: HostTimestamp(microseconds: 2_000_000),
            lastEcho: ClockBeacon.LastEcho(
                beaconSeq: 0,
                clientSend: ClientTimestamp(microseconds: 1_253_500),
                hostReceive: HostTimestamp(microseconds: 1_008_500)))
        responder.handleCtrlPayload(second.encode(), arrivalMicroseconds: 2_253_000)

        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.offsetMicroseconds, 249_000,
                       "the worked example's offset, straight through the seam")
        XCTAssertEqual(fit.minRttMicroseconds, 8_000)
        XCTAssertEqual(fit.anchor.microseconds, 1_253_000,
                       "the coordinate is the exchange's t2, not the mirror's arrival")
    }

    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64
        init(start: UInt64) { value = start }
        func next() -> ClientTimestamp {
            lock.lock()
            defer { lock.unlock() }
            let v = value
            value += 1_000_000
            return ClientTimestamp(microseconds: v)
        }
    }
}
