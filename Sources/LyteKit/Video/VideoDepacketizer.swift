import Foundation

/// A fully reassembled frame ready for the decoder.
public struct DecodeUnit: Sendable {
    public enum FrameType: Sendable { case idr, pframe }
    public enum BufferType: Sendable { case vps, sps, pps, picdata }
    public struct Buffer: Sendable {
        public let type: BufferType
        public let data: Data          // Annex-B, start code included
    }

    public let frameNumber: UInt32
    public let frameType: FrameType
    public let buffers: [Buffer]
    public let fullLength: Int
    public let rtpTimestamp: UInt32              // 90 kHz clock
    public let receiveTimeUs: UInt64
    public let presentationTimeUs: UInt64
    public let frameHostProcessingLatency: UInt16   // 1/10 ms units (Sunshine)
}

/// Reassembles depacketized RTP payloads into Annex-B decode units.
/// Port of VideoDepacketizer.c trimmed to Sunshine ≥ 7.1.415 (8/24-byte frame
/// headers) and strict-IDR recovery (no reference frame invalidation yet):
/// any loss ⇒ wait for an IDR frame, requesting one via the control channel.
final class VideoDepacketizer {
    enum Codec { case h264, hevc }

    private let codec: Codec
    /// Deliver a completed decode unit downstream.
    var onDecodeUnit: (DecodeUnit) -> Void = { _ in }
    /// Ask the host for an IDR frame (control message 0x0302).
    var onRequestIdr: () -> Void = {}

    private var nalChain: [DecodeUnit.Buffer] = []
    private var nalChainDataLength = 0

    private var nextFrameNumber: UInt32 = 1
    private var waitingForNextSuccessfulFrame = false
    private var waitingForIdrFrame = true
    private var lastPacketInStream: UInt32 = 0xFFFF_FFFF
    private var decodingFrame = false
    private var frameType: DecodeUnit.FrameType = .pframe
    private var syntheticPtsBaseUs: UInt64 = 0
    private var frameHostProcessingLatency: UInt16 = 0
    private var firstPacketReceiveTimeUs: UInt64 = 0
    private var firstPacketPresentationTime: UInt64 = 0
    private var firstPacketRtpTimestamp: UInt32 = 0
    private var idrFrameProcessed = false

    private static let consecutiveDropLimit = 120
    private var consecutiveFrameDrops = 0

    init(codec: Codec) {
        self.codec = codec
    }

    // MARK: - NAL type helpers

    @inline(__always) private func nalType(_ byte: UInt8) -> UInt8 {
        codec == .h264 ? byte & 0x1F : (byte & 0x7E) >> 1
    }

    private enum Nal {
        static let h264Sps: UInt8 = 7, h264Pps: UInt8 = 8, h264Aud: UInt8 = 9
        static let h264Sei: UInt8 = 6, h264Idr: UInt8 = 5, h264Filler: UInt8 = 12
        static let hevcVps: UInt8 = 32, hevcSps: UInt8 = 33, hevcPps: UInt8 = 34
        static let hevcAud: UInt8 = 35, hevcFiller: UInt8 = 38, hevcSei: UInt8 = 39
    }

    private func isReferenceFrameSliceType(_ t: UInt8) -> Bool {
        codec == .h264 ? t == Nal.h264Idr : (16...21).contains(t)   // HEVC BLA/IDR/CRA
    }

    /// Buffer window over the payload of one packet.
    private struct Cursor {
        let bytes: [UInt8]
        var offset: Int
        var length: Int

        /// Annex-B start sequence at the cursor (with at least 1 byte after it
        /// for the NAL header). Returns its length (3 or 4), or nil.
        func startSequence() -> Int? {
            guard length > 3 else { return nil }
            guard bytes[offset] == 0, bytes[offset + 1] == 0 else { return nil }
            if bytes[offset + 2] == 1 { return 3 }
            if bytes[offset + 2] == 0, length > 4, bytes[offset + 3] == 1 { return 4 }
            return nil
        }

        /// NAL header byte just after the start sequence (nil when not at one).
        func nalHeader() -> UInt8? {
            guard let sl = startSequence() else { return nil }
            return bytes[offset + sl]
        }

        /// Advance past the current start sequence (if any), then to the next
        /// start sequence or end of buffer.
        mutating func skipToNextNalOrEnd() {
            if let sl = startSequence() {
                offset += sl
                length -= sl
            }
            while startSequence() == nil {
                if length == 0 { return }
                offset += 1
                length -= 1
            }
        }
    }

    // MARK: - Frame state

    private func cleanupFrameState() {
        nalChain.removeAll()
        nalChainDataLength = 0
    }

    private func dropFrameState() {
        // Strict IDR mode: every loss requires an IDR frame to recover
        waitingForIdrFrame = true

        consecutiveFrameDrops += 1
        if consecutiveFrameDrops == Self.consecutiveDropLimit {
            consecutiveFrameDrops = 0
            onRequestIdr()
        }

        cleanupFrameState()
    }

    /// Called by the RTP queue when it knows a frame can't be recovered.
    func notifyFrameLost(_ frameNumber: UInt32, speculative: Bool) {
        dropFrameState()
        // RFI would go here; in strict IDR mode the request is sent when the
        // next fully received frame arrives (network recovery approximation).
    }

    private func queueFragment(_ type: DecodeUnit.BufferType, _ bytes: [UInt8], _ offset: Int, _ length: Int) {
        guard length > 0 else { return }
        nalChain.append(.init(type: type, data: Data(bytes[offset..<offset + length])))
        nalChainDataLength += length
    }

    private func bufferType(for header: UInt8) -> DecodeUnit.BufferType {
        switch (codec, nalType(header)) {
        case (.h264, Nal.h264Sps): return .sps
        case (.h264, Nal.h264Pps): return .pps
        case (.hevc, Nal.hevcVps): return .vps
        case (.hevc, Nal.hevcSps): return .sps
        case (.hevc, Nal.hevcPps): return .pps
        default: return .picdata
        }
    }

    // MARK: - Payload processing

    /// Process one data packet from a completed frame, in sequence order.
    func processEntry(_ entry: VideoQueueEntry) {
        let packet = entry.packet
        let payloadStart = packet.payloadOffset
        let payloadLength = entry.length - payloadStart
        guard payloadLength > 0 else { return }

        var cursor = Cursor(bytes: packet.raw, offset: payloadStart, length: payloadLength)

        let fecCurrentBlock = packet.fecCurrentBlock
        let flagsNoPic = packet.flags & ~VideoFlags.containsPicData
        let firstPacket = (flagsNoPic == (VideoFlags.sof | VideoFlags.eof) || flagsNoPic == VideoFlags.sof)
            && fecCurrentBlock == 0
        let lastPacket = (packet.flags & VideoFlags.eof != 0) && fecCurrentBlock == packet.fecLastBlock
        let frameIndex = packet.frameIndex

        // Drop packets from a previously corrupt frame
        if isBefore32(frameIndex, nextFrameNumber) { return }

        // Detect corrupt frames the FEC queue let through via SPI discontinuity
        if isBefore24(packet.streamPacketIndex, u24(lastPacketInStream &+ 1)) ||
            (packet.flags & VideoFlags.sof == 0 && packet.streamPacketIndex != u24(lastPacketInStream &+ 1)) {
            decodingFrame = false
            nextFrameNumber = frameIndex + 1
            dropFrameState()
            onRequestIdr()
            return
        }

        if firstPacket {
            if isBefore32(nextFrameNumber, frameIndex) {
                // Network dropped whole frame(s) — wait for the next complete
                // frame before requesting recovery.
                nextFrameNumber = frameIndex
                waitingForNextSuccessfulFrame = true
                dropFrameState()
            }

            decodingFrame = true
            frameType = .pframe
            firstPacketReceiveTimeUs = entry.receiveTimeUs

            // Some Sunshine versions don't send a valid PTS; synthesize one
            // from receive time.
            if syntheticPtsBaseUs == 0 { syntheticPtsBaseUs = entry.receiveTimeUs }
            if entry.presentationTimeUs == 0 && frameIndex > 0 {
                firstPacketPresentationTime = entry.receiveTimeUs - syntheticPtsBaseUs
            } else {
                firstPacketPresentationTime = entry.presentationTimeUs
            }
            firstPacketRtpTimestamp = packet.rtpTimestamp
        }

        lastPacketInStream = packet.streamPacketIndex

        if firstPacket {
            // Sunshine ≥ 7.1.415 frame header: first byte 0x01 ⇒ 8 bytes,
            // 0x81 ⇒ 24 bytes ([7.1.415, 7.1.446) table in the reference).
            guard cursor.length >= 8 else { return }

            // Byte 3 is the frame type; 2 = IDR (trusted for non-parsed codecs),
            // {1,4,5,104} = P/intra-refresh/RFI/Sunshine-hardcoded.
            // We parse H.264/HEVC bitstreams, so only non-parsed codecs would
            // trust it — nothing to do here for now.

            // Sunshine sends host processing latency as LE16 at bytes 1-2
            frameHostProcessingLatency = UInt16(cursor.bytes[cursor.offset + 1])
                | UInt16(cursor.bytes[cursor.offset + 2]) << 8

            let frameHeaderSize = cursor.bytes[cursor.offset] == 0x01 ? 8 : 24
            guard cursor.length >= frameHeaderSize else { return }
            cursor.offset += frameHeaderSize
            cursor.length -= frameHeaderSize

            // The Annex-B start prefix must be next; recover by scanning if not
            if cursor.startSequence() == nil {
                cursor.skipToNextNalOrEnd()
                guard cursor.length > 0 else { return }
            }

            // Strip a prepended AUD and any SEI NALs
            if let h = cursor.nalHeader(),
               nalType(h) == (codec == .h264 ? Nal.h264Aud : Nal.hevcAud) {
                cursor.skipToNextNalOrEnd()
            }
            while let h = cursor.nalHeader(),
                  nalType(h) == (codec == .h264 ? Nal.h264Sei : Nal.hevcSei) {
                cursor.skipToNextNalOrEnd()
            }
            guard cursor.length > 0 else { return }
        }

        let isIdrStart = firstPacket && cursor.nalHeader().map {
            nalType($0) == (codec == .h264 ? Nal.h264Sps : Nal.hevcVps)
        } ?? false

        if isIdrStart {
            // Parameter sets are padded between NALs — split them out (slow path)
            processIdrFirstPacket(&cursor)
        } else {
            // Intel's encoder prepends a PPS to P-frames; skip it
            if firstPacket, let h = cursor.nalHeader(),
               nalType(h) == (codec == .h264 ? Nal.h264Pps : Nal.hevcPps) {
                cursor.skipToNextNalOrEnd()
            }
            queueFragment(.picdata, cursor.bytes, cursor.offset, cursor.length)
        }

        if lastPacket {
            decodingFrame = false
            nextFrameNumber = frameIndex + 1

            if waitingForIdrFrame {
                if waitingForNextSuccessfulFrame {
                    // First complete frame after loss: network has recovered
                    // enough to ask for an IDR frame.
                    onRequestIdr()
                }
                waitingForNextSuccessfulFrame = false
                dropFrameState()
                return
            }
            waitingForNextSuccessfulFrame = false

            reassembleFrame(frameIndex)
        }
    }

    /// IDR first packet: VPS/SPS/PPS with zero padding between NALs, then
    /// picture data extending to the end of the packet.
    private func processIdrFirstPacket(_ cursor: inout Cursor) {
        while cursor.length != 0 {
            // Skip padding to the next NAL
            if cursor.startSequence() == nil {
                cursor.skipToNextNalOrEnd()
                if cursor.length == 0 { return }
            }

            // Skip AUD/SEI NALs (padding may separate them from what follows)
            while let h = cursor.nalHeader(),
                  nalType(h) == (codec == .h264 ? Nal.h264Aud : Nal.hevcAud) ||
                  nalType(h) == (codec == .h264 ? Nal.h264Sei : Nal.hevcSei) {
                cursor.skipToNextNalOrEnd()
            }
            guard let header = cursor.nalHeader() else { return }

            let start = cursor.offset
            var containsPicData = false

            if isReferenceFrameSliceType(nalType(header)) {
                // Reference frame slice: IDR arrival satisfies all waits
                waitingForIdrFrame = false
                waitingForNextSuccessfulFrame = false
                containsPicData = true
                frameType = .idr
            }

            cursor.skipToNextNalOrEnd()

            // Picture data extends to the end of the packet
            if containsPicData {
                while cursor.length != 0 {
                    cursor.skipToNextNalOrEnd()
                }
            }

            queueFragment(containsPicData ? .picdata : bufferType(for: header),
                          cursor.bytes, start, cursor.offset - start)
        }
    }

    private func reassembleFrame(_ frameNumber: UInt32) {
        guard !nalChain.isEmpty else { return }

        var type = frameType
        if nalChain[0].type != .picdata || frameType == .idr {
            type = .idr
        }

        let du = DecodeUnit(frameNumber: frameNumber,
                            frameType: type,
                            buffers: nalChain,
                            fullLength: nalChainDataLength,
                            rtpTimestamp: firstPacketRtpTimestamp,
                            receiveTimeUs: firstPacketReceiveTimeUs,
                            presentationTimeUs: firstPacketPresentationTime,
                            frameHostProcessingLatency: frameHostProcessingLatency)
        nalChain = []
        nalChainDataLength = 0

        if type == .idr { idrFrameProcessed = true }
        consecutiveFrameDrops = 0

        onDecodeUnit(du)
    }
}
