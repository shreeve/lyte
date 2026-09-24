// OpusStreamDecoder: the client's libopus decode leaf — 48 kHz stereo, one
// 5 ms packet per call, PLC on nil (AudioConverter has no PLC entry point).
// Runs on the pump thread, never the render callback.

import COpus
import LyteWire
import Synchronization

public enum OpusStreamDecoderError: Error, Sendable {
    case createFailed(Int32)
}

public final class OpusStreamDecoder {
    private let decoder: OpaquePointer
    private let failures = Atomic<UInt64>(0)
    /// Read from any thread (the stats rows); counted on the pump.
    public var decodeFailures: UInt64 { failures.load(ordering: .relaxed) }

    public init() throws {
        var status: Int32 = 0
        guard let created = opus_decoder_create(
            opus_int32(AudioWire.sampleRate),
            Int32(AudioWire.channels),
            &status
        ), status == OPUS_OK else {
            throw OpusStreamDecoderError.createFailed(status)
        }
        decoder = created
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Decodes one packet to interleaved Float32 stereo (240 frames =
    /// 480 floats). `nil` invokes packet-loss concealment for one
    /// packet duration. A refusing decoder yields silence, counted.
    public func decode(_ packet: [UInt8]?) -> [Float] {
        let frames = AudioWire.samplesPerPacket
        var pcm = [Float](repeating: 0, count: frames * AudioWire.channels)
        let decoded = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
            guard let outBase = out.baseAddress else { return -1 }
            if let packet {
                return packet.withUnsafeBufferPointer { bytes in
                    opus_decode_float(
                        decoder, bytes.baseAddress,
                        opus_int32(packet.count),
                        outBase, Int32(frames), 0)
                }
            }
            return opus_decode_float(
                decoder, nil, 0, outBase, Int32(frames), 0)
        }
        if decoded != Int32(frames) {
            failures.add(1, ordering: .relaxed)
            return [Float](repeating: 0, count: frames * AudioWire.channels)
        }
        return pcm
    }
}
