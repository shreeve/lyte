import Foundation
import HostAudio
import XCTest

final class HostOpusCodecTests: XCTestCase {
    func testHardCBRRoundTripsFiveMillisecondPackets() throws {
        let encoder = try HostOpusEncoder(bitrate: 128_000)
        let decoder = try HostOpusDecoder()
        var packet = [UInt8](repeating: 0, count: HostOpus.maxPacketBytes)

        let silence = [Float](repeating: 0, count: HostOpus.samplesPerPacket)
        let silenceBytes = try silence.withUnsafeBufferPointer {
            try encoder.encode($0, into: &packet)
        }

        let tone = (0..<HostOpus.samplesPerPacket).map { sample -> Float in
            let frame = Double(sample / HostOpus.channels)
            return Float(0.2 * sin(2 * .pi * 440 * frame / 48_000))
        }
        let toneBytes = try tone.withUnsafeBufferPointer {
            try encoder.encode($0, into: &packet)
        }

        XCTAssertEqual(silenceBytes, toneBytes)
        XCTAssertGreaterThan(silenceBytes, 2, "DTX must remain disabled")

        var decoded = [Float](
            repeating: 0, count: HostOpus.samplesPerPacket)
        XCTAssertEqual(
            try decoder.decode(packet, byteCount: toneBytes, into: &decoded),
            HostOpus.framesPerPacket
        )
        XCTAssertGreaterThan(decoded.map { abs($0) }.max() ?? 0, 0.001)
    }

    func testEncoderRejectsAnythingButOneWireQuantum() throws {
        let encoder = try HostOpusEncoder(bitrate: 128_000)
        var packet = [UInt8](repeating: 0, count: HostOpus.maxPacketBytes)
        let short = [Float](repeating: 0, count: HostOpus.samplesPerPacket - 1)

        XCTAssertThrowsError(try short.withUnsafeBufferPointer {
            try encoder.encode($0, into: &packet)
        }) { error in
            XCTAssertEqual(
                error as? HostOpusCodecError,
                .invalidPCMCount(
                    expected: HostOpus.samplesPerPacket,
                    actual: HostOpus.samplesPerPacket - 1
                )
            )
        }
    }
}
