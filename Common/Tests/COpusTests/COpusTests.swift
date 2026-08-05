import COpus
import XCTest

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class COpusTests: XCTestCase {
    func testPinnedVersionAndFiveMillisecondFloatPath() throws {
        let versionBytes = UnsafeRawPointer(opus_get_version_string())
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(
            String(decodingCString: versionBytes, as: UTF8.self),
            "libopus 1.6.1"
        )

        var encoderStatus: Int32 = 0
        guard let encoder = opus_encoder_create(
            48_000, 2, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &encoderStatus
        ) else {
            return XCTFail("cannot create encoder: \(encoderStatus)")
        }
        defer { opus_encoder_destroy(encoder) }

        var decoderStatus: Int32 = 0
        guard let decoder = opus_decoder_create(48_000, 2, &decoderStatus) else {
            return XCTFail("cannot create decoder: \(decoderStatus)")
        }
        defer { opus_decoder_destroy(decoder) }

        let pcm = (0..<(240 * 2)).map { sample -> Float in
            let frame = Double(sample / 2)
            return Float(0.2 * sin(2 * .pi * 440 * frame / 48_000))
        }
        var packet = [UInt8](repeating: 0, count: 1_500)
        let byteCount = pcm.withUnsafeBufferPointer { input in
            packet.withUnsafeMutableBufferPointer { output in
                opus_encode_float(
                    encoder, input.baseAddress!, 240,
                    output.baseAddress!, Int32(output.count)
                )
            }
        }
        XCTAssertGreaterThan(byteCount, 0)

        var decoded = [Float](repeating: 0, count: 240 * 2)
        let frameCount = packet.withUnsafeBufferPointer { input in
            decoded.withUnsafeMutableBufferPointer { output in
                opus_decode_float(
                    decoder, input.baseAddress!, byteCount,
                    output.baseAddress!, 240, 0
                )
            }
        }
        XCTAssertEqual(frameCount, 240)
        XCTAssertGreaterThan(decoded.map { abs($0) }.max() ?? 0, 0.001)

        let concealedFrameCount = decoded.withUnsafeMutableBufferPointer {
            output in
            opus_decode_float(decoder, nil, 0, output.baseAddress!, 240, 0)
        }
        XCTAssertEqual(concealedFrameCount, 240)
    }
}
