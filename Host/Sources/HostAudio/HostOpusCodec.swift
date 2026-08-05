import COpus

/// Lyte's host-side Opus wire posture. The pinned C leaf supplies codec
/// mechanism; this Swift role layer owns the session's audio policy.
public enum HostOpus {
    public static let sampleRate: Int = 48_000
    public static let channels: Int = 2
    public static let framesPerPacket: Int = 240
    public static let samplesPerPacket = framesPerPacket * channels
    public static let maxPacketBytes: Int = 1_500
}

public enum HostOpusCodecError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case createEncoder(Int32)
    case configureEncoder(request: Int32, status: Int32)
    case createDecoder(Int32)
    case invalidPCMCount(expected: Int, actual: Int)
    case invalidPacketCapacity(Int)
    case invalidPacketByteCount(Int)
    case invalidDecodeCapacity(expected: Int, actual: Int)
    case encode(Int32)
    case decode(Int32)

    public var description: String {
        switch self {
        case .createEncoder(let status):
            "opus_encoder_create: \(opusDescription(status))"
        case .configureEncoder(let request, let status):
            "opus_encoder_ctl request \(request): \(opusDescription(status))"
        case .createDecoder(let status):
            "opus_decoder_create: \(opusDescription(status))"
        case .invalidPCMCount(let expected, let actual):
            "opus input has \(actual) samples; expected \(expected)"
        case .invalidPacketCapacity(let capacity):
            "opus packet capacity must be positive; got \(capacity)"
        case .invalidPacketByteCount(let count):
            "opus packet byte count is invalid: \(count)"
        case .invalidDecodeCapacity(let expected, let actual):
            "opus decode output has \(actual) samples; expected \(expected)"
        case .encode(let status):
            "opus_encode_float: \(opusDescription(status))"
        case .decode(let status):
            "opus_decode_float: \(opusDescription(status))"
        }
    }
}

/// Continuous 48 kHz stereo encoder. One call consumes exactly one 5 ms
/// packet. Silence remains on the wire because DTX is deliberately disabled.
public final class HostOpusEncoder {
    private let encoder: OpaquePointer

    public init(bitrate: Int32, useVBR: Bool = false) throws {
        var status: Int32 = OPUS_OK
        guard let created = opus_encoder_create(
            Int32(HostOpus.sampleRate),
            Int32(HostOpus.channels),
            OPUS_APPLICATION_RESTRICTED_LOWDELAY,
            &status
        ), status == OPUS_OK else {
            throw HostOpusCodecError.createEncoder(status)
        }

        do {
            try Self.configure(
                created,
                request: OPUS_SET_BITRATE_REQUEST,
                value: bitrate
            )
            try Self.configure(
                created,
                request: OPUS_SET_VBR_REQUEST,
                value: useVBR ? 1 : 0
            )
            // Cadence is load-bearing for the receiver's audio clock.
            try Self.configure(
                created, request: OPUS_SET_DTX_REQUEST, value: 0)
            try Self.configure(
                created, request: OPUS_SET_PACKET_LOSS_PERC_REQUEST, value: 0)
            try Self.configure(
                created, request: OPUS_SET_INBAND_FEC_REQUEST, value: 0)
        } catch {
            opus_encoder_destroy(created)
            throw error
        }
        encoder = created
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    public func encode(
        _ pcm: UnsafeBufferPointer<Float>,
        into packet: inout [UInt8]
    ) throws -> Int {
        guard pcm.count == HostOpus.samplesPerPacket else {
            throw HostOpusCodecError.invalidPCMCount(
                expected: HostOpus.samplesPerPacket,
                actual: pcm.count
            )
        }
        guard !packet.isEmpty else {
            throw HostOpusCodecError.invalidPacketCapacity(packet.count)
        }

        let count = packet.withUnsafeMutableBufferPointer { output in
            opus_encode_float(
                encoder,
                pcm.baseAddress!,
                Int32(HostOpus.framesPerPacket),
                output.baseAddress!,
                Int32(output.count)
            )
        }
        guard count > 0 else {
            throw HostOpusCodecError.encode(
                count < 0 ? count : OPUS_INTERNAL_ERROR)
        }
        return Int(count)
    }

    private static func configure(
        _ encoder: OpaquePointer,
        request: Int32,
        value: Int32
    ) throws {
        let status = lyte_opus_encoder_ctl_int(encoder, request, value)
        guard status == OPUS_OK else {
            throw HostOpusCodecError.configureEncoder(
                request: request, status: status)
        }
    }
}

/// Matching decoder used by the on-host loop-verification harness.
public final class HostOpusDecoder {
    private let decoder: OpaquePointer

    public init() throws {
        var status: Int32 = OPUS_OK
        guard let created = opus_decoder_create(
            Int32(HostOpus.sampleRate),
            Int32(HostOpus.channels),
            &status
        ), status == OPUS_OK else {
            throw HostOpusCodecError.createDecoder(status)
        }
        decoder = created
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    public func decode(
        _ packet: [UInt8],
        byteCount: Int,
        into pcm: inout [Float]
    ) throws -> Int {
        guard byteCount > 0, byteCount <= packet.count else {
            throw HostOpusCodecError.invalidPacketByteCount(byteCount)
        }
        guard pcm.count == HostOpus.samplesPerPacket else {
            throw HostOpusCodecError.invalidDecodeCapacity(
                expected: HostOpus.samplesPerPacket,
                actual: pcm.count
            )
        }

        let frames = packet.withUnsafeBufferPointer { input in
            pcm.withUnsafeMutableBufferPointer { output in
                opus_decode_float(
                    decoder,
                    input.baseAddress!,
                    Int32(byteCount),
                    output.baseAddress!,
                    Int32(HostOpus.framesPerPacket),
                    0
                )
            }
        }
        guard frames > 0 else {
            throw HostOpusCodecError.decode(
                frames < 0 ? frames : OPUS_INTERNAL_ERROR)
        }
        return Int(frames)
    }
}

private func opusDescription(_ status: Int32) -> String {
    String(cString: opus_strerror(status))
}
