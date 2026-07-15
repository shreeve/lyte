import Foundation
import CNanors

/// Reorders video RTP packets and recovers losses with Reed-Solomon FEC.
/// Faithful port of RtpVideoQueue.c (Sunshine ≥ 7.1.431 only: multi-FEC
/// capable, no Gen < 5 fallbacks). Single-threaded: everything runs on the
/// video receive thread.
///
/// FEC layout per frame: data shards are the frame's RTP packets, parity
/// shards follow at sequence numbers right after the data. Shard content is
/// the full wire packet zero-padded to `receiveSize` — except that the host
/// rewrites each parity packet's RTP header and a few NV fields before
/// sending, so those byte positions recover as garbage and are patched from
/// queue state afterwards (same as the reference).
final class RtpVideoQueue {
    static let queued = 0
    static let rejected = 1

    private let packetSize: Int          // StreamConfig.packetSize (payload budget)
    private var receiveSize: Int { packetSize + 16 }   // + MAX_RTP_HEADER_SIZE

    /// Called when a frame is known to be unrecoverable (speculative = predicted
    /// from missing-packet count before the frame window ended).
    var onFrameLost: (_ frameNumber: UInt32, _ speculative: Bool) -> Void = { _, _ in }
    /// Called once per new frame observed (connectionSawFrame).
    var onSawFrame: (_ frameNumber: UInt32) -> Void = { _ in }

    private var pending: [VideoQueueEntry] = []
    private var completed: [VideoQueueEntry] = []

    private var bufferFirstRecvTimeUs: UInt64 = 0
    private var bufferLowestSequenceNumber: UInt16 = 0
    private var bufferHighestSequenceNumber: UInt16 = 0
    private var bufferFirstParitySequenceNumber: UInt16 = 0
    private var bufferDataPackets: UInt32 = 0
    private var bufferParityPackets: UInt32 = 0
    private var receivedDataPackets: UInt32 = 0
    private var receivedParityPackets: UInt32 = 0
    private var receivedHighestSequenceNumber: UInt16 = 0
    private var fecPercentage: UInt32 = 0
    private var nextContiguousSequenceNumber: UInt16 = 0
    private var missingPackets: UInt32 = 0
    private var useFastQueuePath = false
    private var reportedLostFrame = false

    private(set) var currentFrameNumber: UInt32 = 1

    private var multiFecCurrentBlockNumber: UInt8 = 0
    private var multiFecLastBlockNumber: UInt8 = 0

    // Speculative loss prediction is disabled for 5 minutes after OOS data
    private static let oosCooldownUs: UInt64 = 300_000_000
    private var lastOosFramePresentationTimestamp: UInt64 = 0
    private var receivedOosData = false

    // Lifetime stats
    private(set) var statsPacketCountVideo: UInt64 = 0
    private(set) var statsPacketCountFec: UInt64 = 0
    private(set) var statsRecoveredPackets: UInt64 = 0
    private(set) var statsLostFrames: UInt64 = 0

    init(packetSize: Int) {
        self.packetSize = packetSize
        reed_solomon_init()
    }

    /// Feed one wire packet. Returns (status, completedFrame) — the frame is
    /// non-nil when this packet completed the last FEC block of a frame; the
    /// entries are the frame's data packets in sequence order.
    func addPacket(_ raw: [UInt8], receiveTimeUs: UInt64) -> (status: Int, frame: [VideoQueueEntry]?) {
        guard let packet = VideoPacket(raw: raw) else { return (Self.rejected, nil) }

        // Reject packets behind our current buffer window
        if isBefore16(packet.sequenceNumber, nextContiguousSequenceNumber) {
            return (Self.rejected, nil)
        }
        // Reject frames behind our current frame number (16-bit wrap compare, as reference)
        if isBefore16(u16(packet.frameIndex), u16(currentFrameNumber)) {
            return (Self.rejected, nil)
        }

        let fecIndex = packet.fecShardIndex
        let fecCurrentBlockNumber = packet.fecCurrentBlock

        if packet.frameIndex == currentFrameNumber && fecCurrentBlockNumber < multiFecCurrentBlockNumber {
            // Reject FEC blocks behind our current block number
            return (Self.rejected, nil)
        }

        // Reinitialize the queue if it's empty after a frame delivery or
        // if we can't finish a frame before receiving the next one.
        if pending.isEmpty || currentFrameNumber != packet.frameIndex ||
            multiFecCurrentBlockNumber != fecCurrentBlockNumber {
            if !pending.isEmpty {
                if multiFecLastBlockNumber != 0 {
                    // We missed a block of a multi-block frame: advance manually.
                    if currentFrameNumber == packet.frameIndex {
                        pending.removeAll()
                        completed.removeAll()
                        if !reportedLostFrame {
                            statsLostFrames += 1
                            onFrameLost(currentFrameNumber, false)
                            reportedLostFrame = true
                        }
                        currentFrameNumber += 1
                        multiFecCurrentBlockNumber = 0
                        return (Self.rejected, nil)
                    }
                }
            }

            // We must either start on the current FEC block number for the current
            // frame, or block 0 of a new frame.
            let expectedFecBlockNumber: UInt8 = (currentFrameNumber == packet.frameIndex) ? multiFecCurrentBlockNumber : 0
            if fecCurrentBlockNumber != expectedFecBlockNumber {
                pending.removeAll()
                completed.removeAll()
                if !reportedLostFrame {
                    statsLostFrames += 1
                    onFrameLost(currentFrameNumber, false)
                    reportedLostFrame = true
                }
                currentFrameNumber = packet.frameIndex + 1
                multiFecCurrentBlockNumber = 0
                return (Self.rejected, nil)
            }

            // Discard any pending buffers from the previous FEC block
            pending.removeAll()

            // Discard any completed FEC blocks from the previous frame
            if currentFrameNumber != packet.frameIndex {
                completed.removeAll()

                // If frame numbers aren't contiguous, the network dropped whole frame(s).
                if currentFrameNumber + 1 != packet.frameIndex || !reportedLostFrame {
                    statsLostFrames += 1
                    onFrameLost(packet.frameIndex - 1, false)
                }
            }

            currentFrameNumber = packet.frameIndex
            onSawFrame(currentFrameNumber)

            bufferFirstRecvTimeUs = receiveTimeUs
            bufferLowestSequenceNumber = packet.sequenceNumber &- u16(fecIndex)
            nextContiguousSequenceNumber = bufferLowestSequenceNumber
            receivedDataPackets = 0
            receivedParityPackets = 0
            receivedHighestSequenceNumber = 0
            missingPackets = 0
            useFastQueuePath = true
            reportedLostFrame = false
            bufferDataPackets = packet.fecDataPackets
            fecPercentage = packet.fecPercentage
            bufferParityPackets = (bufferDataPackets * fecPercentage + 99) / 100
            bufferFirstParitySequenceNumber = bufferLowestSequenceNumber &+ u16(bufferDataPackets)
            bufferHighestSequenceNumber = bufferFirstParitySequenceNumber &+ u16(bufferParityPackets) &- 1
            multiFecCurrentBlockNumber = fecCurrentBlockNumber
            multiFecLastBlockNumber = packet.fecLastBlock

            statsPacketCountVideo += UInt64(bufferDataPackets)
            statsPacketCountFec += UInt64(bufferParityPackets)
        }

        // Reject packets above our FEC queue valid sequence number range
        if isBefore16(bufferHighestSequenceNumber, packet.sequenceNumber) {
            return (Self.rejected, nil)
        }

        let isParity = !isBefore16(packet.sequenceNumber, bufferFirstParitySequenceNumber)
        let entry = VideoQueueEntry(packet: packet, length: raw.count,
                                    isParity: isParity, receiveTimeUs: receiveTimeUs)
        guard queuePacket(entry, isFecRecovery: false) else {
            return (Self.rejected, nil)
        }

        // Update missing-packet accounting
        if pending.count == 1 {
            missingPackets &+= UInt32(packet.sequenceNumber &- bufferLowestSequenceNumber)
            receivedHighestSequenceNumber = packet.sequenceNumber
        } else if isBefore16(receivedHighestSequenceNumber, packet.sequenceNumber) {
            missingPackets &+= UInt32(packet.sequenceNumber &- receivedHighestSequenceNumber &- 1)
            receivedHighestSequenceNumber = packet.sequenceNumber
        } else if missingPackets > 0 {
            missingPackets -= 1
        }

        if isParity {
            receivedParityPackets += 1
        } else {
            receivedDataPackets += 1
        }

        // Try to complete this FEC block. If we haven't received enough
        // packets, this fails and we keep waiting.
        if reconstructFrame() == 0 {
            stageCompleteFecBlock()

            if multiFecCurrentBlockNumber < multiFecLastBlockNumber {
                multiFecCurrentBlockNumber += 1
            } else {
                let frame = completed
                completed = []
                currentFrameNumber += 1
                multiFecCurrentBlockNumber = 0
                return (Self.queued, frame)
            }
        }

        return (Self.queued, nil)
    }

    // MARK: - Internals

    private func queuePacket(_ newEntry: VideoQueueEntry, isFecRecovery: Bool) -> Bool {
        let packet = newEntry.packet
        var outOfSequence = false

        if useFastQueuePath && packet.sequenceNumber == nextContiguousSequenceNumber {
            nextContiguousSequenceNumber = packet.sequenceNumber &+ 1
        } else {
            // Check for duplicates; note whether this packet is out of order
            for entry in pending {
                if packet.sequenceNumber == entry.packet.sequenceNumber {
                    return false
                } else if isBefore16(packet.sequenceNumber, entry.packet.sequenceNumber) {
                    outOfSequence = true
                }
            }
            // Queuing a non-duplicate packet out of order: the fast path's
            // nextContiguousSequenceNumber invariant is broken for this frame.
            useFastQueuePath = false
        }

        // FEC recovery packets are synthesized by us, so don't use them for OOS detection
        if !isFecRecovery {
            if outOfSequence {
                lastOosFramePresentationTimestamp = newEntry.presentationTimeUs
                receivedOosData = true
            } else if receivedOosData &&
                        newEntry.presentationTimeUs > lastOosFramePresentationTimestamp + Self.oosCooldownUs {
                receivedOosData = false
            }
        }

        pending.append(newEntry)
        return true
    }

    /// Returns 0 when the current FEC block is completely constructed.
    private func reconstructFrame() -> Int {
        let totalPackets = bufferDataPackets + bufferParityPackets
        let neededPackets = bufferDataPackets

        if pending.count < Int(neededPackets) {
            // Predict unrecoverable frames early so the host can resend sooner.
            // Only safe when this host never delivers out-of-order data.
            if !reportedLostFrame && !receivedOosData {
                if missingPackets > totalPackets - neededPackets {
                    statsLostFrames += 1
                    onFrameLost(currentFrameNumber, true)
                    reportedLostFrame = true
                }
            }
            return -1   // not enough data yet
        }

        if receivedDataPackets == bufferDataPackets {
            // Full frame, no recovery needed
            return 0
        }

        // Reed-Solomon recovery
        guard let rs = reed_solomon_new(Int32(bufferDataPackets), Int32(bufferParityPackets)) else {
            return -3
        }
        defer { reed_solomon_release(rs) }

        let total = Int(totalPackets)
        let shardSize = receiveSize
        // One contiguous zeroed allocation for all shards
        let backing = UnsafeMutablePointer<UInt8>.allocate(capacity: total * shardSize)
        backing.initialize(repeating: 0, count: total * shardSize)
        defer { backing.deallocate() }

        var shards = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: total)
        var marks = [UInt8](repeating: 1, count: total)
        for i in 0..<total { shards[i] = backing + i * shardSize }

        for entry in pending {
            let index = Int(entry.packet.sequenceNumber &- bufferLowestSequenceNumber)
            guard index < total, marks[index] != 0 else { continue }
            entry.packet.raw.withUnsafeBufferPointer { src in
                shards[index]!.update(from: src.baseAddress!, count: min(entry.length, shardSize))
            }
            marks[index] = 0
        }

        let ret = shards.withUnsafeMutableBufferPointer { shardPtrs in
            marks.withUnsafeMutableBufferPointer { markPtrs in
                reed_solomon_decode(rs, shardPtrs.baseAddress, markPtrs.baseAddress,
                                    Int32(total), Int32(shardSize))
            }
        }
        guard ret == 0 else { return Int(ret) }

        // Ingest recovered data shards (parity shards are never needed again)
        guard let head = pending.first else { return -1 }
        let dataOffset = head.packet.dataOffset
        for i in 0..<Int(bufferDataPackets) where marks[i] != 0 {
            var recovered = [UInt8](repeating: 0, count: shardSize)
            recovered.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: shards[i]!, count: shardSize)
            }

            let seq = bufferLowestSequenceNumber &+ UInt16(i)
            let multiFecBlocks = ((multiFecLastBlockNumber << 2) | multiFecCurrentBlockNumber) << 4
            let packet = VideoPacket(recovered: recovered, dataOffset: dataOffset,
                                     sequenceNumber: seq,
                                     rtpTimestamp: head.packet.rtpTimestamp,
                                     frameIndex: currentFrameNumber,
                                     multiFecBlocks: multiFecBlocks)

            // Sanity-check the recovered packet before it reaches the
            // depacketizer (rare corrupt recoveries observed upstream).
            let sane: Bool
            if i == 0 {
                sane = packet.flags & VideoFlags.sof != 0
            } else if i == Int(bufferDataPackets) - 1 {
                sane = packet.flags & VideoFlags.eof != 0
            } else {
                sane = packet.flags & VideoFlags.containsPicData != 0
            }
            guard sane, packet.flags & ~(VideoFlags.sof | VideoFlags.eof | VideoFlags.containsPicData) == 0 else {
                return -1
            }

            let entry = VideoQueueEntry(packet: packet, length: dataOffset + packetSize,
                                        isParity: false, receiveTimeUs: bufferFirstRecvTimeUs)
            _ = queuePacket(entry, isFecRecovery: true)
            statsRecoveredPackets += 1
        }

        return 0
    }

    /// Move the block's data packets (in sequence order) to the completed list.
    private func stageCompleteFecBlock() {
        let dataEntries = pending.filter { !$0.isParity }
        pending.removeAll()

        for entry in dataEntries {
            // Use the first packet's receive time for all packets — better for
            // downstream latency measurement with out-of-order arrival.
            entry.receiveTimeUs = bufferFirstRecvTimeUs
        }
        completed.append(contentsOf: dataEntries.sorted {
            ($0.packet.sequenceNumber &- bufferLowestSequenceNumber) <
            ($1.packet.sequenceNumber &- bufferLowestSequenceNumber)
        })
    }
}
