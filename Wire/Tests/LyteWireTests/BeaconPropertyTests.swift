import XCTest
import LyteWire
import LyteWireTestKit

// Gate W-G5a's round-trip fuzz for the W4a codecs, in the house style of
// RoundTripPropertyTests: seeded and deterministic, every trial reproduces
// from its seed on both platforms. Random valid structs must survive
// encode → decode → equality; random and truncated bytes must decode to a
// clean throw or a value — never a trap.

final class BeaconPropertyTests: XCTestCase {

    // MARK: Round trips

    func testBeaconEncodeDecodeIsIdentity() throws {
        var rng = SplitMix64(seed: 0x57_4A_B0_01)
        for trial in 0..<20_000 {
            let beacon = randomBeacon(using: &rng)
            let bytes = beacon.encode()
            XCTAssertEqual(bytes.count, ClockBeacon.encodedByteCount)
            XCTAssertEqual(try ClockBeacon.decode(bytes), beacon, "trial \(trial)")
        }
    }

    func testEchoEncodeDecodeIsIdentity() throws {
        var rng = SplitMix64(seed: 0x57_4A_B0_02)
        for trial in 0..<20_000 {
            let echo = BeaconEcho(
                beaconSeq: UInt32.random(in: .min ... .max, using: &rng),
                hostSend: HostTimestamp(
                    microseconds: UInt64.random(in: .min ... .max, using: &rng)),
                clientReceive: ClientTimestamp(
                    microseconds: UInt64.random(in: .min ... .max, using: &rng)),
                clientSend: ClientTimestamp(
                    microseconds: UInt64.random(in: .min ... .max, using: &rng))
            )
            let bytes = echo.encode()
            XCTAssertEqual(bytes.count, BeaconEcho.encodedByteCount)
            XCTAssertEqual(try BeaconEcho.decode(bytes), echo, "trial \(trial)")
        }
    }

    func testFeedbackEncodeDecodeIsIdentity() throws {
        var rng = SplitMix64(seed: 0x57_4A_B0_03)
        for trial in 0..<5_000 {
            let report = try randomReport(using: &rng)
            let bytes = try report.encode()
            XCTAssertLessThanOrEqual(
                bytes.count, WireBudget.maxPlaintextShardByteCount,
                "trial \(trial): every in-bounds report fits the shard budget"
            )
            XCTAssertEqual(
                try FeedbackReport.decode(bytes), report, "trial \(trial)"
            )
        }
    }

    // MARK: Hostile bytes never trap

    func testDecodersNeverTrapOnArbitraryBytes() {
        var rng = SplitMix64(seed: 0x57_4A_B0_04)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...1300, using: &rng)
            var bytes = rng.bytes(length)
            // Bias toward the parsers' own edges: plausible type bytes,
            // section counts near the bounds, TLV flags.
            if !bytes.isEmpty, Bool.random(using: &rng) {
                bytes[0] = UInt8.random(in: 0...3, using: &rng)
            }
            if bytes.count > 20, Bool.random(using: &rng) {
                bytes[1] = UInt8.random(in: 0...1, using: &rng)
                bytes[18] = UInt8.random(in: 0...9, using: &rng)
                bytes[19] = UInt8.random(in: 0...113, using: &rng)
                bytes[20] = UInt8.random(in: 0...7, using: &rng)
            }
            // Throws or succeeds; must never crash.
            _ = try? ClockBeacon.decode(bytes)
            _ = try? BeaconEcho.decode(bytes)
            _ = try? FeedbackReport.decode(bytes)
        }
    }

    func testFeedbackDecodeOfTruncatedValidReportsNeverTraps() throws {
        var rng = SplitMix64(seed: 0x57_4A_B0_05)
        for _ in 0..<2_000 {
            let bytes = try randomReport(using: &rng).encode()
            let cut = Int.random(in: 0..<bytes.count, using: &rng)
            _ = try? FeedbackReport.decode(Array(bytes.prefix(cut)))
        }
    }

    // MARK: Generators

    private func randomBeacon(using rng: inout SplitMix64) -> ClockBeacon {
        ClockBeacon(
            beaconSeq: UInt32.random(in: .min ... .max, using: &rng),
            hostSend: HostTimestamp(
                microseconds: UInt64.random(in: .min ... .max, using: &rng)),
            lastEcho: Bool.random(using: &rng)
                ? ClockBeacon.LastEcho(
                    beaconSeq: UInt32.random(in: .min ... .max, using: &rng),
                    clientSend: ClientTimestamp(
                        microseconds: UInt64.random(in: .min ... .max, using: &rng)),
                    hostReceive: HostTimestamp(
                        microseconds: UInt64.random(in: .min ... .max, using: &rng)))
                : nil
        )
    }

    /// A random report inside every FeedbackBounds limit. TLV values are
    /// kept ≤ 16 B so bounds-maxed sections plus extensions always fit
    /// the shard budget — the identity test asserts that, which is the
    /// "comfortably" in the budget requirement.
    private func randomReport(
        using rng: inout SplitMix64
    ) throws -> FeedbackReport {
        let channels = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
            FeedbackReport.ChannelStats(
                channel: ChannelId(rawValue: UInt8.random(in: 0...255, using: &rng)),
                highestSeq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng)),
                received: UInt32.random(in: .min ... .max, using: &rng),
                missing: UInt32.random(in: .min ... .max, using: &rng),
                duplicates: UInt32.random(in: .min ... .max, using: &rng)
            )
        }
        let sampleCount = Int.random(in: 0...112, using: &rng)
        let dispersion: FeedbackReport.Dispersion? = sampleCount == 0
            ? nil
            : FeedbackReport.Dispersion(
                base: ClientTimestamp(
                    microseconds: UInt64.random(in: .min ... .max, using: &rng)),
                samples: (0..<sampleCount).map { _ in
                    .init(
                        channel: ChannelId(rawValue: UInt8.random(in: 0...255, using: &rng)),
                        seq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng)),
                        arrivalDeltaMicroseconds: UInt32.random(
                            in: 0...FeedbackBounds.maxArrivalDeltaMicroseconds,
                            using: &rng)
                    )
                }
            )
        let nacks = try (0..<Int.random(in: 0...6, using: &rng)).map { _ in
            try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: UInt32.random(in: .min ... .max, using: &rng)),
                missingShards: (0..<Int.random(in: 1...12, using: &rng)).map { _ in
                    UInt8.random(in: 0...254, using: &rng)
                }
            )
        }
        let extensions = try (0..<Int.random(in: 0...3, using: &rng)).map { _ in
            try WireExtension(
                type: UInt8.random(in: 1...255, using: &rng),
                value: rng.bytes(Int.random(in: 0...16, using: &rng))
            )
        }
        return FeedbackReport(
            pathId: UInt8.random(in: 0...255, using: &rng),
            clientTimestamp: ClientTimestamp(
                microseconds: UInt64.random(in: .min ... .max, using: &rng)),
            channels: channels,
            dispersion: dispersion,
            nacks: nacks,
            extensions: extensions
        )
    }
}
