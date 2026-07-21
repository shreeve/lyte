import XCTest
import LyteWire
import LyteWireTestKit

// Seeded, deterministic property coverage: every trial reproduces from the
// fixed seed on both platforms. W-G1's full 10^7-iteration fuzz is a CI
// budget decision for later; these counts keep `swift test` under a few
// seconds while still walking the interesting boundaries every run.

final class RoundTripPropertyTests: XCTestCase {

    func testEncodeDecodeIsIdentity() throws {
        var rng = SplitMix64(seed: 0x57_1D_E0_01)
        for trial in 0..<20_000 {
            let envelope = Envelope(
                channel: ChannelId(rawValue: UInt8.random(in: 0...255, using: &rng)),
                seq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng)),
                frame: FrameNumber(rawValue: UInt32.random(in: .min ... .max, using: &rng)),
                timestamp: UInt64.random(in: .min ... .max, using: &rng),
                fec: UInt64.random(in: .min ... .max, using: &rng),
                extensions: try randomExtensions(using: &rng)
            )
            // Keep header + payload within budget so encode succeeds.
            let headroom = WireBudget.maxDatagramByteCount - envelope.headerByteCount
            let payloadLength = Int.random(
                in: 0...min(WireBudget.maxWirePayloadByteCount, headroom),
                using: &rng
            )
            let payload = rng.bytes(payloadLength)

            let datagram = try envelope.encode(payload: payload)
            let (decoded, decodedPayload) = try Envelope.decode(datagram)
            XCTAssertEqual(decoded, envelope, "trial \(trial)")
            XCTAssertEqual(Array(decodedPayload), payload, "trial \(trial)")
            // And re-encoding the decode is byte-identical.
            XCTAssertEqual(
                try decoded.encode(payload: Array(decodedPayload)),
                datagram,
                "trial \(trial)"
            )
        }
    }

    func testDecodeNeverTrapsOnArbitraryBytes() {
        var rng = SplitMix64(seed: 0x57_1D_E0_02)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...1300, using: &rng)
            var bytes = rng.bytes(length)
            // Bias toward the parser's own edges: valid-looking headers
            // with hostile TLV blocks.
            if length >= 25, Bool.random(using: &rng) {
                bytes[1] = 0x01
            }
            // Throws or succeeds; must never crash.
            _ = try? Envelope.decode(bytes)
        }
    }

    func testDecodeOfTruncatedValidDatagramsNeverTraps() throws {
        var rng = SplitMix64(seed: 0x57_1D_E0_03)
        for _ in 0..<2_000 {
            var envelope = Envelope(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng)),
                frame: FrameNumber(rawValue: 1),
                timestamp: 2,
                fec: 3,
                extensions: try randomExtensions(using: &rng)
            )
            if envelope.headerByteCount > 200 {
                envelope.extensions = []
            }
            let datagram = try envelope.encode(payload: rng.bytes(64))
            let cut = Int.random(in: 0..<datagram.count, using: &rng)
            _ = try? Envelope.decode(Array(datagram.prefix(cut)))
        }
    }

    private func randomExtensions(
        using rng: inout SplitMix64
    ) throws -> [WireExtension] {
        let count = Int.random(in: 0...4, using: &rng)
        return try (0..<count).map { _ in
            try WireExtension(
                type: UInt8.random(in: 0...255, using: &rng),
                value: rng.bytes(Int.random(in: 0...32, using: &rng))
            )
        }
    }
}
