// OpusStreamDecoder (CL-11): the client's libopus decode leaf — 48 kHz
// stereo, one 5 ms packet per call, PLC on nil (the concealment tool
// the audio-continuity decision pins: "lost packets interpolate
// instead of going silent", §5.4). Host/'s COpusEncode decoder half is
// the loop-decode reference this mirrors; the system AudioConverter
// is NOT used (no PLC entry point — the gap that pinned libopus).
//
// Real-time posture: opus_decode_float neither allocates nor blocks,
// but this wrapper still runs on the pump thread, never the render
// callback — the SPSC ring is the only thing the render thread touches.

import COpus

public enum OpusStreamDecoderError: Error, Sendable {
    case createFailed(Int32)
}

public final class OpusStreamDecoder {
    private let decoder: OpaquePointer
    public private(set) var decodeFailures: UInt64 = 0

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
            decodeFailures += 1
            return [Float](repeating: 0, count: frames * AudioWire.channels)
        }
        return pcm
    }
}
