import Foundation
import AudioToolbox

/// Opus → interleaved Float32 PCM via the system AudioConverter (no vendored
/// libopus). Stereo/mono only: a single coupled Opus stream is a standard
/// Opus packet. Surround (multistream) needs libopus and is deferred to M7.
///
/// Loss concealment: on a missing packet we emit silence for one frame —
/// libopus PLC would interpolate, but the system decoder has no such API.
final class OpusDecoder {
    private var converter: AudioConverterRef?
    private let channels: UInt32
    private let samplesPerFrame: UInt32     // 48 * packetDurationMs

    private var currentPacket: Data?
    private var packetConsumed = false
    private var packetDescription = AudioStreamPacketDescription()

    init?(channels: Int, samplesPerFrame: Int) {
        self.channels = UInt32(channels)
        self.samplesPerFrame = UInt32(samplesPerFrame)

        var inFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(samplesPerFrame),
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)

        var ref: AudioConverterRef?
        guard AudioConverterNew(&inFormat, &outFormat, &ref) == noErr, let ref else { return nil }
        converter = ref
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    /// Decode one Opus packet (nil = lost → silence) into interleaved floats.
    func decode(_ packet: Data?) -> [Float] {
        let frameCount = Int(samplesPerFrame)
        guard let packet, let converter else {
            return [Float](repeating: 0, count: frameCount * Int(channels))
        }

        currentPacket = packet
        packetConsumed = false

        var output = [Float](repeating: 0, count: frameCount * Int(channels))
        var ioPackets = UInt32(frameCount)
        let status = output.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels,
                                      mDataByteSize: UInt32(buf.count * 4),
                                      mData: UnsafeMutableRawPointer(buf.baseAddress)))
            return AudioConverterFillComplexBuffer(
                converter, Self.inputProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &ioPackets, &bufferList, nil)
        }
        currentPacket = nil

        // kNoMorePackets (1) from our supplier just ends the pull — fine.
        if status != noErr && status != Self.noMorePackets {
            return [Float](repeating: 0, count: frameCount * Int(channels))
        }
        return output
    }

    private static let noMorePackets: OSStatus = 1

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        let decoder = Unmanaged<OpusDecoder>.fromOpaque(inUserData!).takeUnretainedValue()

        guard !decoder.packetConsumed, let packet = decoder.currentPacket else {
            ioNumberDataPackets.pointee = 0
            return noMorePackets
        }
        decoder.packetConsumed = true

        // Hand the converter our single Opus packet
        packet.withUnsafeBytes { bytes in
            decoder.scratch.removeAll(keepingCapacity: true)
            decoder.scratch.append(contentsOf: bytes)
        }
        decoder.scratch.withUnsafeMutableBufferPointer { buf in
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = decoder.channels
            ioData.pointee.mBuffers.mDataByteSize = UInt32(buf.count)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(buf.baseAddress)
        }
        decoder.packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(decoder.scratch.count))
        outDataPacketDescription?.pointee = withUnsafeMutablePointer(to: &decoder.packetDescription) { $0 }
        ioNumberDataPackets.pointee = 1
        return noErr
    }

    private var scratch: [UInt8] = []
}
