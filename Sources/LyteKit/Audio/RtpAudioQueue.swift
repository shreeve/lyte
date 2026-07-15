import Foundation
import CNanors

/// Reordering + FEC queue for RTP audio (port of RtpAudioQueue.c, Sunshine
/// era only — data/FEC shards are constant-size within a block).
///
/// Every 4 data packets (payload type 97) are protected by 2 Reed-Solomon
/// parity packets (type 127). The parity matrix is patched to the one Nvidia
/// generates (OpenFEC), which nanors' generator does not reproduce.
///
/// Not thread-safe; confine to the audio receive thread.
final class RtpAudioQueue {
    static let dataShards = 4
    static let fecShards = 2
    static let totalShards = 6
    static let rtpHeaderSize = 12
    static let fecHeaderSize = 12
    private static let oosWaitTimeMs: UInt64 = 30

    enum AddResult {
        case handleNow      // in-order data packet: caller consumes it directly
        case packetReady    // queued packets available via getQueuedPacket()
        case consumed       // stored or dropped; nothing to do
    }

    private final class FecBlock {
        let baseSequenceNumber: UInt16
        let baseTimestamp: UInt32
        let ssrc: UInt32
        let payloadType: UInt8
        let blockSize: Int
        var dataPackets: [Data?]         // full RTP packet (header + payload)
        var fecPayloads: [Data?]         // parity payload only
        var dataShardsReceived = 0
        var fecShardsReceived = 0
        var nextDataPacketIndex = 0
        var allowDiscontinuity = false
        var fullyReassembled = false
        let queueTimeUs: UInt64

        init(baseSequenceNumber: UInt16, baseTimestamp: UInt32, ssrc: UInt32,
             payloadType: UInt8, blockSize: Int) {
            self.baseSequenceNumber = baseSequenceNumber
            self.baseTimestamp = baseTimestamp
            self.ssrc = ssrc
            self.payloadType = payloadType
            self.blockSize = blockSize
            self.dataPackets = Array(repeating: nil, count: RtpAudioQueue.dataShards)
            self.fecPayloads = Array(repeating: nil, count: RtpAudioQueue.fecShards)
            self.queueTimeUs = DispatchTime.now().uptimeNanoseconds / 1000
        }
    }

    private var blocks: [FecBlock] = []      // sorted by baseSequenceNumber
    private var nextRtpSequenceNumber: UInt16 = 0
    private var oldestRtpBaseSequenceNumber: UInt16 = 0
    private var synchronizing = true
    private var startedSync = false
    private var receivedOosData = false
    private var lastOosSequenceNumber: UInt16 = 0
    private let packetDurationMs: UInt32
    private let rs: UnsafeMutablePointer<reed_solomon>

    // Stats
    private(set) var packetsRecovered: UInt64 = 0
    private(set) var packetsLost: UInt64 = 0
    private(set) var packetsOOS: UInt64 = 0

    init(packetDurationMs: Int) {
        self.packetDurationMs = UInt32(packetDurationMs)
        reed_solomon_init()
        rs = reed_solomon_new(Int32(Self.dataShards), Int32(Self.fecShards))!
        // Nvidia's parity matrix (from OpenFEC) differs from the one nanors
        // generates for 4+2; patch it in (RtpAudioQueue.c does the same).
        let parity: [UInt8] = [0x77, 0x40, 0x38, 0x0e, 0xc7, 0xa7, 0x0d, 0x6c]
        let pOffset = MemoryLayout<reed_solomon>.size
        UnsafeMutableRawPointer(rs).advanced(by: pOffset)
            .copyMemory(from: parity, byteCount: parity.count)
    }

    deinit {
        reed_solomon_release(rs)
    }

    // MARK: - Ingest

    func addPacket(_ packet: Data) -> AddResult {
        guard packet.count >= Self.rtpHeaderSize else { return .consumed }
        let payloadType = packet[packet.startIndex + 1]
        let seq = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])

        let baseSeq: UInt16
        let baseTs: UInt32
        let blockSize: Int
        let blockPayloadType: UInt8
        let ssrc = be32(packet, at: 8)

        if payloadType == 97 {
            if !synchronizing, isBefore16(seq, oldestRtpBaseSequenceNumber) {
                lastOosSequenceNumber = seq
                packetsOOS += 1
                receivedOosData = true
            } else if receivedOosData, isBefore16(oldestRtpBaseSequenceNumber, lastOosSequenceNumber) {
                receivedOosData = false
            }
            blockPayloadType = payloadType
            baseSeq = (seq / UInt16(Self.dataShards)) * UInt16(Self.dataShards)
            baseTs = be32(packet, at: 4) &- UInt32(seq &- baseSeq) * packetDurationMs
            blockSize = packet.count - Self.rtpHeaderSize
        } else if payloadType == 127 {
            guard packet.count >= Self.rtpHeaderSize + Self.fecHeaderSize else { return .consumed }
            let fec = packet.subdata(in: (packet.startIndex + 12)..<(packet.startIndex + 24))
            let shardIndex = Int(fec[fec.startIndex])
            guard shardIndex < Self.fecShards else { return .consumed }
            blockPayloadType = fec[fec.startIndex + 1]
            baseSeq = UInt16(fec[fec.startIndex + 2]) << 8 | UInt16(fec[fec.startIndex + 3])
            baseTs = be32(fec, at: 4)
            guard baseSeq % UInt16(Self.dataShards) == 0 else { return .consumed }
            blockSize = packet.count - Self.rtpHeaderSize - Self.fecHeaderSize
        } else {
            return .consumed
        }

        // Synchronize on the first packet: start clean at the next block boundary
        if synchronizing && !startedSync {
            startedSync = true
            nextRtpSequenceNumber = baseSeq &+ UInt16(Self.dataShards)
            oldestRtpBaseSequenceNumber = nextRtpSequenceNumber
            return .consumed
        }

        // Drop packets from FEC blocks that have already completed
        if isBefore16(baseSeq, oldestRtpBaseSequenceNumber) { return .consumed }

        guard let block = findOrCreateBlock(baseSeq: baseSeq, baseTs: baseTs, ssrc: ssrc,
                                            payloadType: blockPayloadType, blockSize: blockSize) else {
            return .consumed
        }

        if payloadType == 97 {
            let pos = Int(seq &- block.baseSequenceNumber)
            guard pos < Self.dataShards, block.dataPackets[pos] == nil else { return .consumed }
            block.dataPackets[pos] = packet
            block.dataShardsReceived += 1

            // Fast path: in-order receive of the next expected data packet
            if seq == nextRtpSequenceNumber {
                nextRtpSequenceNumber = seq &+ 1
                block.nextDataPacketIndex += 1
                if nextRtpSequenceNumber == block.baseSequenceNumber &+ UInt16(Self.dataShards) {
                    freeBlockHead()
                }
                return .handleNow
            }
        } else {
            let fec = packet.subdata(in: (packet.startIndex + 12)..<(packet.startIndex + 24))
            let shardIndex = Int(fec[fec.startIndex])
            guard block.fecPayloads[shardIndex] == nil else { return .consumed }
            block.fecPayloads[shardIndex] = packet.subdata(in: (packet.startIndex + 24)..<packet.endIndex)
            block.fecShardsReceived += 1
        }

        if completeFecBlock(block) {
            block.fullyReassembled = true
        }
        if !queueHasPacketReady() {
            handleMissingPackets()
        }
        return queueHasPacketReady() ? .packetReady : .consumed
    }

    /// Next in-order packet, `nil` when none ready. `.placeholder` means the
    /// packet is unrecoverable — the decoder should run loss concealment.
    func getQueuedPacket() -> (packet: Data?, isPlaceholder: Bool)? {
        if let head = blocks.first, head.allowDiscontinuity {
            if head.dataPackets[head.nextDataPacketIndex] == nil {
                head.nextDataPacketIndex += 1
                nextRtpSequenceNumber &+= 1
                packetsLost += 1
                if head.nextDataPacketIndex == Self.dataShards { freeBlockHead() }
                return (nil, true)
            }
        }
        guard queueHasPacketReady(), let head = blocks.first else { return nil }
        let packet = head.dataPackets[head.nextDataPacketIndex]
        head.nextDataPacketIndex += 1
        nextRtpSequenceNumber &+= 1
        if head.nextDataPacketIndex == Self.dataShards { freeBlockHead() }
        return (packet, false)
    }

    // MARK: - Internals

    private func findOrCreateBlock(baseSeq: UInt16, baseTs: UInt32, ssrc: UInt32,
                                   payloadType: UInt8, blockSize: Int) -> FecBlock? {
        var insertAt = blocks.count
        for (i, b) in blocks.enumerated() {
            if b.baseSequenceNumber == baseSeq {
                // Sunshine can vary packet sizes across a block boundary; a
                // mismatch within one block means we can't FEC it safely.
                guard b.blockSize == blockSize else { return nil }
                return b.fullyReassembled ? nil : b
            }
            if isBefore16(baseSeq, b.baseSequenceNumber) { insertAt = i; break }
        }
        let block = FecBlock(baseSequenceNumber: baseSeq, baseTimestamp: baseTs, ssrc: ssrc,
                             payloadType: payloadType, blockSize: blockSize)
        blocks.insert(block, at: insertAt)
        return block
    }

    private func freeBlockHead() {
        guard let head = blocks.first else { return }
        oldestRtpBaseSequenceNumber = head.baseSequenceNumber &+ UInt16(Self.dataShards)
        synchronizing = false
        blocks.removeFirst()
    }

    private func queueHasPacketReady() -> Bool {
        guard let head = blocks.first else { return false }
        return (head.dataPackets[head.nextDataPacketIndex] != nil &&
                head.baseSequenceNumber &+ UInt16(head.nextDataPacketIndex) == nextRtpSequenceNumber)
            || head.allowDiscontinuity
    }

    private func handleMissingPackets() {
        guard let head = blocks.first else { return }

        // The packet we want precedes the earliest block: that block was
        // entirely lost. Resynchronize at the head block.
        if isBefore16(nextRtpSequenceNumber, head.baseSequenceNumber) {
            nextRtpSequenceNumber = head.baseSequenceNumber
            oldestRtpBaseSequenceNumber = head.baseSequenceNumber
            return
        }

        // Wait for a second block before giving up on the first; if the host
        // has ever sent OOS data, wait a bit longer for stragglers.
        guard blocks.count > 1 else { return }
        let ageUs = DispatchTime.now().uptimeNanoseconds / 1000 - head.queueTimeUs
        let waitUs = UInt64(packetDurationMs) * UInt64(Self.dataShards) * 1000 + Self.oosWaitTimeMs * 1000
        if !receivedOosData || ageUs > waitUs {
            head.allowDiscontinuity = true
        }
    }

    private func completeFecBlock(_ block: FecBlock) -> Bool {
        guard block.dataShardsReceived + block.fecShardsReceived >= Self.dataShards else { return false }
        if block.dataShardsReceived == Self.dataShards { return true }

        // Contiguous slab of 6 equal shards; marks[i]=1 flags a missing shard
        let bs = block.blockSize
        var slab = [UInt8](repeating: 0, count: Self.totalShards * bs)
        var marks = [UInt8](repeating: 1, count: Self.totalShards)
        for i in 0..<Self.dataShards {
            if let p = block.dataPackets[i], p.count - Self.rtpHeaderSize == bs {
                slab.replaceSubrange(i*bs..<(i+1)*bs, with: p.dropFirst(Self.rtpHeaderSize))
                marks[i] = 0
            }
        }
        for i in 0..<Self.fecShards {
            if let f = block.fecPayloads[i], f.count == bs {
                let base = (Self.dataShards + i) * bs
                slab.replaceSubrange(base..<base+bs, with: f)
                marks[Self.dataShards + i] = 0
            }
        }

        let result: Int32 = slab.withUnsafeMutableBufferPointer { buf in
            var ptrs: [UnsafeMutablePointer<UInt8>?] = (0..<Self.totalShards).map {
                buf.baseAddress! + $0 * bs
            }
            return marks.withUnsafeMutableBufferPointer { m in
                ptrs.withUnsafeMutableBufferPointer { pp in
                    reed_solomon_decode(rs, pp.baseAddress, m.baseAddress, Int32(Self.totalShards), Int32(bs))
                }
            }
        }
        guard result == 0 else { return false }

        // Rebuild the missing RTP packets from recovered shards
        for i in 0..<Self.dataShards where block.dataPackets[i] == nil {
            var pkt = Data(capacity: Self.rtpHeaderSize + bs)
            pkt.append(0x80)
            pkt.append(block.payloadType)
            let seq = block.baseSequenceNumber &+ UInt16(i)
            pkt.append(contentsOf: [UInt8(seq >> 8), UInt8(seq & 0xff)])
            let ts = block.baseTimestamp &+ UInt32(i) * packetDurationMs
            pkt.append(contentsOf: [UInt8(ts >> 24), UInt8((ts >> 16) & 0xff), UInt8((ts >> 8) & 0xff), UInt8(ts & 0xff)])
            pkt.append(contentsOf: [UInt8(block.ssrc >> 24), UInt8((block.ssrc >> 16) & 0xff),
                                    UInt8((block.ssrc >> 8) & 0xff), UInt8(block.ssrc & 0xff)])
            pkt.append(contentsOf: slab[i*bs..<(i+1)*bs])
            block.dataPackets[i] = pkt
            packetsRecovered += 1
        }
        return true
    }

    // MARK: - Byte helpers

    private func be32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i+1]) << 16 | UInt32(data[i+2]) << 8 | UInt32(data[i+3])
    }

    private func isBefore16(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) < 0
    }
}
