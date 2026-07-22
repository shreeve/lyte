import XCTest
import COpus
import LyteTransport

// THE GATE (CL-11, decode leaf): the client's libopus wrapper decodes
// real Opus packets — generated here with libopus' own encoder in the
// host's mode (48 kHz stereo RESTRICTED_LOWDELAY, 5 ms frames; the
// loop-decode discipline Host/'s COpusEncode harness established) —
// and its PLC entry point conceals without crashing or going hard
// silent mid-stream. This is the capability LyteKit's AudioConverter
// path never had (documented there), which is why the leaf exists.

final class OpusLeafGateTests: XCTestCase {

    /// One 5 ms block of a 440 Hz sine at −24 dBFS (amplitude ≈ 0.0631),
    /// interleaved stereo — HS-15's tone-verification pattern.
    private func toneBlock(startFrame: Int) -> [Float] {
        let amplitude: Float = 0.0631
        var pcm = [Float]()
        pcm.reserveCapacity(AudioWire.samplesPerPacket * 2)
        for frame in 0..<AudioWire.samplesPerPacket {
            let phase = 2 * Float.pi * 440
                * Float(startFrame + frame) / Float(AudioWire.sampleRate)
            let sample = amplitude * sin(phase)
            pcm.append(sample)
            pcm.append(sample)
        }
        return pcm
    }

    func testToneRoundTripsThroughDecoderAtExpectedLevelAndPitch() throws {
        let encoder = makeEncoderOrFail()
        defer { opus_encoder_destroy(encoder) }
        let decoder = try OpusStreamDecoder()

        var decoded: [Float] = []
        for n in 0..<200 {
            let pcm = toneBlock(startFrame: n * AudioWire.samplesPerPacket)
            var packet = [UInt8](repeating: 0, count: 1_500)
            let bytes = pcm.withUnsafeBufferPointer { input in
                packet.withUnsafeMutableBufferPointer { output in
                    opus_encode_float(
                        encoder, input.baseAddress!,
                        Int32(AudioWire.samplesPerPacket),
                        output.baseAddress!, 1_500)
                }
            }
            XCTAssertGreaterThan(bytes, 0)
            decoded += decoder.decode(Array(packet.prefix(Int(bytes))))
        }
        XCTAssertEqual(decoded.count, 200 * AudioWire.samplesPerPacket * 2)

        // Skip the codec's convergence, then measure the back half:
        // RMS near −24 dBFS and a zero-crossing rate near 440 Hz on
        // the left channel — the same objective checks the live gate
        // runs against pup's generated tone.
        let tail = Array(decoded.suffix(decoded.count / 2))
        var sumSquares = 0.0
        var crossings = 0
        var last: Float = 0
        var frames = 0
        var index = 0
        while index < tail.count {
            let sample = tail[index]
            sumSquares += Double(sample) * Double(sample)
            if (sample > 0 && last <= 0) || (sample < 0 && last >= 0) {
                crossings += 1
            }
            if sample != 0 { last = sample }
            frames += 1
            index += 2
        }
        let rmsDbfs = 20 * log10((sumSquares / Double(frames)).squareRoot())
        let seconds = Double(frames) / 48_000
        let estimatedHz = Double(crossings) / 2 / seconds
        // A sine's RMS sits 3 dB under its peak: −24 dBFS peak ≈
        // −27 dBFS RMS. CELT at defaults holds this within ~1.5 dB.
        XCTAssertEqual(rmsDbfs, -27.0, accuracy: 1.5,
                       "decoded tone level drifted: \(rmsDbfs) dBFS")
        XCTAssertEqual(estimatedHz, 440, accuracy: 15,
                       "decoded tone pitch drifted: \(estimatedHz) Hz")
    }

    func testPlcConcealsAndRecoversWithoutHardSilence() throws {
        let encoder = makeEncoderOrFail()
        defer { opus_encoder_destroy(encoder) }
        let decoder = try OpusStreamDecoder()

        // Warm the decoder with real tone…
        for n in 0..<40 {
            let pcm = toneBlock(startFrame: n * AudioWire.samplesPerPacket)
            var packet = [UInt8](repeating: 0, count: 1_500)
            let bytes = pcm.withUnsafeBufferPointer { input in
                packet.withUnsafeMutableBufferPointer { output in
                    opus_encode_float(
                        encoder, input.baseAddress!,
                        Int32(AudioWire.samplesPerPacket),
                        output.baseAddress!, 1_500)
                }
            }
            _ = decoder.decode(Array(packet.prefix(Int(bytes))))
        }
        // …then conceal one lost packet: right sample count, and the
        // interpolation carries energy (no hard mute at the seam).
        let concealed = decoder.decode(nil)
        XCTAssertEqual(concealed.count, AudioWire.samplesPerPacket * 2)
        let energy = concealed.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertGreaterThan(
            energy, 0, "PLC after a steady tone must interpolate, not mute")
        XCTAssertEqual(decoder.decodeFailures, 0)
    }

    func testGarbagePacketYieldsSilenceAndCountsNeverThrows() throws {
        let decoder = try OpusStreamDecoder()
        let garbage = decoder.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(garbage.count, AudioWire.samplesPerPacket * 2)
        XCTAssertTrue(garbage.allSatisfy { $0 == 0 })
        XCTAssertEqual(decoder.decodeFailures, 1)
    }

    private func makeEncoderOrFail() -> OpaquePointer {
        var status: Int32 = 0
        let encoder = opus_encoder_create(
            48_000, 2, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &status)
        precondition(encoder != nil && status == OPUS_OK,
                     "libopus encoder unavailable (\(status))")
        return encoder!
    }
}
