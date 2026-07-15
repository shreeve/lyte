import Foundation

/// Wrap-safe sequence comparisons (Misc.c isBeforeSigned equivalents).
@inline(__always) func isBefore16(_ a: UInt16, _ b: UInt16) -> Bool { (a &- b) > 0x7FFF }
@inline(__always) func isBefore24(_ a: UInt32, _ b: UInt32) -> Bool { ((a &- b) & 0xFFFFFF) > 0x7FFFFF }
@inline(__always) func isBefore32(_ a: UInt32, _ b: UInt32) -> Bool { (a &- b) > 0x7FFF_FFFF }
@inline(__always) func u16(_ v: UInt32) -> UInt16 { UInt16(truncatingIfNeeded: v) }
@inline(__always) func u24(_ v: UInt32) -> UInt32 { v & 0xFFFFFF }

/// NV_VIDEO_PACKET flag bits.
enum VideoFlags {
    static let containsPicData: UInt8 = 0x1
    static let eof: UInt8 = 0x2
    static let sof: UInt8 = 0x4
}

/// A video RTP packet as received off the wire (unencrypted for SS_ENC_VIDEO
/// off; the raw bytes are kept wire-exact because FEC parity is computed over
/// them on the host).
///
/// Layout: RTP header (12 bytes, +4 with the extension flag that all supported
/// hosts set) followed by NV_VIDEO_PACKET (16 bytes, little-endian fields),
/// then payload.
struct VideoPacket {
    let raw: [UInt8]                 // full wire packet, possibly EOF-short
    let sequenceNumber: UInt16       // RTP, host order
    let rtpTimestamp: UInt32
    let dataOffset: Int              // RTP header size (12 or 16)

    // NV_VIDEO_PACKET fields (host order)
    let streamPacketIndex: UInt32    // 24-bit SPI (upper 8 bits already masked off)
    let frameIndex: UInt32
    let flags: UInt8
    let extraFlags: UInt8
    let multiFecFlags: UInt8
    let multiFecBlocks: UInt8
    let fecInfo: UInt32

    static let rtpExtensionFlag: UInt8 = 0x10
    static let nvHeaderSize = 16

    var fecShardIndex: UInt32 { (fecInfo & 0x3FF000) >> 12 }
    var fecDataPackets: UInt32 { (fecInfo & 0xFFC0_0000) >> 22 }
    var fecPercentage: UInt32 { (fecInfo & 0xFF0) >> 4 }
    var fecCurrentBlock: UInt8 { (multiFecBlocks >> 4) & 0x3 }
    var fecLastBlock: UInt8 { (multiFecBlocks >> 6) & 0x3 }

    /// Payload (NV header included) starts here.
    var nvOffset: Int { dataOffset }
    var payloadOffset: Int { dataOffset + Self.nvHeaderSize }

    init?(raw: [UInt8]) {
        guard raw.count >= 12 else { return nil }
        let header = raw[0]
        let dataOffset = 12 + ((header & Self.rtpExtensionFlag) != 0 ? 4 : 0)
        guard raw.count >= dataOffset + Self.nvHeaderSize else { return nil }

        self.raw = raw
        self.dataOffset = dataOffset
        self.sequenceNumber = UInt16(raw[2]) << 8 | UInt16(raw[3])
        self.rtpTimestamp = UInt32(raw[4]) << 24 | UInt32(raw[5]) << 16 | UInt32(raw[6]) << 8 | UInt32(raw[7])

        @inline(__always) func le32(_ o: Int) -> UInt32 {
            UInt32(raw[o]) | UInt32(raw[o+1]) << 8 | UInt32(raw[o+2]) << 16 | UInt32(raw[o+3]) << 24
        }
        // Mask the top 8 bits from the SPI (VideoDepacketizer.c does this later;
        // we do it at parse time since we never need the raw value)
        self.streamPacketIndex = (le32(dataOffset + 0) >> 8) & 0xFFFFFF
        self.frameIndex = le32(dataOffset + 4)
        self.flags = raw[dataOffset + 8]
        self.extraFlags = raw[dataOffset + 9]
        self.multiFecFlags = raw[dataOffset + 10]
        self.multiFecBlocks = raw[dataOffset + 11]
        self.fecInfo = le32(dataOffset + 12)
    }

    /// Synthesize a parsed packet for FEC-recovered shard bytes. Header
    /// positions were overwritten in the parity shards by the host, so the
    /// recovered bytes there are garbage — the caller supplies the corrected
    /// values just like RtpVideoQueue.c does after reed_solomon_decode().
    init(recovered raw: [UInt8], dataOffset: Int, sequenceNumber: UInt16,
         rtpTimestamp: UInt32, frameIndex: UInt32, multiFecBlocks: UInt8) {
        self.raw = raw
        self.dataOffset = dataOffset
        self.sequenceNumber = sequenceNumber
        self.rtpTimestamp = rtpTimestamp
        @inline(__always) func le32(_ o: Int) -> UInt32 {
            UInt32(raw[o]) | UInt32(raw[o+1]) << 8 | UInt32(raw[o+2]) << 16 | UInt32(raw[o+3]) << 24
        }
        self.streamPacketIndex = (le32(dataOffset + 0) >> 8) & 0xFFFFFF
        self.frameIndex = frameIndex
        self.flags = raw[dataOffset + 8]
        self.extraFlags = raw[dataOffset + 9]
        self.multiFecFlags = raw[dataOffset + 10]
        self.multiFecBlocks = multiFecBlocks
        self.fecInfo = le32(dataOffset + 12)
    }
}

/// A queued packet plus receive-side timing (RTPV_QUEUE_ENTRY).
final class VideoQueueEntry {
    var packet: VideoPacket
    var length: Int                  // valid byte count in packet.raw
    let isParity: Bool
    var receiveTimeUs: UInt64
    let presentationTimeUs: UInt64   // 90 kHz RTP timestamp → microseconds

    init(packet: VideoPacket, length: Int, isParity: Bool, receiveTimeUs: UInt64) {
        self.packet = packet
        self.length = length
        self.isParity = isParity
        self.receiveTimeUs = receiveTimeUs
        self.presentationTimeUs = UInt64(packet.rtpTimestamp) * 1000 / 90
    }
}
