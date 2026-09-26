import XCTest
import LyteWire
import LyteWireTestKit

// Seeded envelope round trips: every trial reproduces from the fixed seed
// on both platforms. The never-trap sweep lives in CtrlDecoderFuzzTests.

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

    private func randomExtensions(
        using rng: inout SplitMix64
    ) throws -> [WireExtension] {
        let count = rng.int(in: 0...4)
        return try (0..<count).map { _ in
            try WireExtension(
                type: UInt8.random(in: 0...255, using: &rng),
                value: rng.bytes(rng.int(in: 0...32))
            )
        }
    }
}
