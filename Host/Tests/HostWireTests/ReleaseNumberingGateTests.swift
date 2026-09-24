import XCTest
import HostCore
import HostWire
import LyteWire

// Chan-2 seqs are numbered and sealed at pacer release. Judged by a real
// NoiseTransport receiver (the client's 64-deep replay window) plus the
// client's seq-ledger rule: a repair queued behind a large fresh frame
// still opens, host-side drops never read as missing, a started frame
// keeps contiguous seqs even when an urgent keyframe arrives mid-flight,
// and committing a frame seals nothing.
final class ReleaseNumberingGateTests: XCTestCase {

    /// The client end: the real transport, and the demux's seq ledger (a
    /// seq a higher arrival skipped is missing until it arrives late).
    private struct Receiver {
        var transport: NoiseTransport
        var highest: UInt16?
        var missing: Set<UInt16> = []
        var refused: [(VideoChannelDatagram, Error)] = []
        var opened: [VideoChannelDatagram] = []

        mutating func receive(_ datagram: VideoChannelDatagram) {
            do {
                _ = try transport.openDatagram(datagram.bytes[...])
            } catch {
                refused.append((datagram, error))
                return
            }
            opened.append(datagram)
            let seq = datagram.seq.rawValue
            guard let highest else {
                self.highest = seq
                return
            }
            let ahead = Int16(bitPattern: seq &- highest)
            if ahead > 0 {
                for gap in 1..<Int(ahead) {
                    missing.insert(highest &+ UInt16(gap))
                }
                self.highest = seq
            } else {
                missing.remove(seq)
            }
        }
    }

    private final class Box {
        var host: NoiseTransport
        var sent: [VideoChannelDatagram] = []
        var sealCalls = 0
        init(_ host: NoiseTransport) { self.host = host }
    }

    /// A sealed channel and the receiver holding the matching keys.
    private func pair(
        rate: Int, usefulnessNS: UInt64 = 100_000_000
    ) throws -> (VideoChannel, Box, Receiver) {
        let hostKeys = NoiseKeyPair.generate()
        var initiator = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostKeys.publicKey)
        var responder = try NoiseSession(
            role: .responder, staticKeys: hostKeys)
        _ = try responder.readMessage1(try initiator.writeMessage1()[...])
        _ = try initiator.readMessage2(try responder.writeMessage2()[...])
        let box = Box(try responder.makeTransport())
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: rate,
                repairQueueUsefulnessNS: usefulnessNS),
            now: 0,
            seal: { plaintext, aad, envelope in
                box.sealCalls += 1
                return try box.host.seal(
                    plaintext: plaintext, aad: aad, envelope: envelope)
            },
            send: { box.sent.append($0) })
        return (channel, box, Receiver(
            transport: try initiator.makeTransport()))
    }

    private func frame(_ byteCount: Int, keyframe: Bool = false) -> [UInt8] {
        [0, 0, 0, 1, keyframe ? 0x26 : 0x02, 0x01]
            + [UInt8](repeating: 0x42, count: byteCount)
    }

    private func drain(_ channel: VideoChannel, from now: inout UInt64) {
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
    }

    func testRepairQueuedBehindAnEightyKilobyteFrameStillOpens() throws {
        let (channel, box, receiver) = try pair(rate: 1_000_000_000)
        var client = receiver
        var now: UInt64 = 1_000_000
        try channel.ingest(
            frame: frame(5_000), frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0, isKeyframe: false, now: now)
        drain(channel, from: &now)
        // Shard 0 is NACKed, and the next frame lands before the pacer
        // releases the repair: 70+ fresh shards now outrank it.
        XCTAssertEqual(channel.enqueueRepair(
            frame: FrameNumber(rawValue: 0), shardIndices: [0], now: now), 1)
        try channel.ingest(
            frame: frame(80_000), frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 16_000, isKeyframe: false, now: now)
        drain(channel, from: &now)

        box.sent.forEach { client.receive($0) }
        XCTAssertTrue(client.refused.isEmpty,
                      "refused: \(client.refused.map { ($0.0.seq, $0.1) })")
        XCTAssertEqual(
            client.opened.filter { $0.pacerClass == .videoTail }.count, 1,
            "the repair must reach the client's decoder, not its replay drop")
        XCTAssertTrue(client.missing.isEmpty)
    }

    func testHostDropsNeverReadAsClientMissing() throws {
        // 2 Mbps: a 40 KB frame takes ~160 ms, so it is mid-release when
        // the fall purge lands.
        let (channel, box, receiver) = try pair(
            rate: 2_000_000, usefulnessNS: 50_000_000)
        var client = receiver
        var now: UInt64 = 1_000_000
        try channel.ingest(
            frame: frame(4_000), frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0, isKeyframe: false, now: now)
        drain(channel, from: &now)
        try channel.ingest(
            frame: frame(40_000), frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 16_000, isKeyframe: false, now: now)
        for _ in 0..<5 {
            now += 1_000_000
            channel.pump(now: now)
        }
        XCTAssertGreaterThan(box.sent.count, 4, "frame 1 has started")
        XCTAssertGreaterThan(channel.purgeQueuedVideo().datagrams, 20)

        // A repair that expires in the queue behind fresh video.
        try channel.ingest(
            frame: frame(4_000), frameNumber: FrameNumber(rawValue: 2),
            captureTimestampMicroseconds: 32_000, isKeyframe: false, now: now)
        XCTAssertEqual(channel.enqueueRepair(
            frame: FrameNumber(rawValue: 0), shardIndices: [1], now: now), 1)
        now += 60_000_000
        drain(channel, from: &now)
        XCTAssertEqual(channel.counters.repairShardsExpiredQueued, 1)

        try channel.ingest(
            frame: frame(4_000), frameNumber: FrameNumber(rawValue: 3),
            captureTimestampMicroseconds: 48_000, isKeyframe: false, now: now)
        drain(channel, from: &now)

        box.sent.forEach { client.receive($0) }
        XCTAssertTrue(client.refused.isEmpty)
        XCTAssertEqual(
            client.missing, [],
            "purged and expired datagrams consumed no seq, so the client "
                + "ledger sees no loss the path never caused")
    }

    func testUrgentKeyframeWaitsForAStartedFrameAndSeqsStayContiguous() throws {
        let (channel, box, receiver) = try pair(rate: 5_000_000)
        var client = receiver
        var now: UInt64 = 1_000_000
        try channel.ingest(
            frame: frame(20_000), frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0, isKeyframe: false, now: now)
        channel.pump(now: now)
        let started = box.sent.count
        XCTAssertGreaterThan(started, 0)
        try channel.ingest(
            frame: frame(20_000, keyframe: true),
            frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 16_000, isKeyframe: true, now: now)
        drain(channel, from: &now)

        let frames = box.sent.map(\.frameNumber.rawValue)
        let firstKeyframe = try XCTUnwrap(frames.firstIndex(of: 1))
        XCTAssertTrue(frames[..<firstKeyframe].allSatisfy { $0 == 0 },
                      "the started frame finishes before the keyframe")
        XCTAssertTrue(frames[firstKeyframe...].allSatisfy { $0 == 1 })
        for frameNumber: UInt32 in [0, 1] {
            let shards = try box.sent
                .filter { $0.frameNumber.rawValue == frameNumber }
                .map { datagram -> (index: Int, seq: UInt16) in
                    let (envelope, _) = try Envelope.decode(datagram.bytes)
                    guard case .reedSolomon(let index, _) =
                        try FecField.decode(envelope.fec)
                    else { throw FecFieldMismatch() }
                    return (Int(index), envelope.seq.rawValue)
                }
            let base = shards[0].seq &- UInt16(shards[0].index)
            for shard in shards {
                XCTAssertEqual(shard.seq, base &+ UInt16(shard.index),
                               "frame \(frameNumber): seq off its block")
            }
        }
        box.sent.forEach { client.receive($0) }
        XCTAssertTrue(client.refused.isEmpty)
        XCTAssertTrue(client.missing.isEmpty)
    }

    func testCommitSealsNothingAndEachReleaseSealsOnce() throws {
        let (channel, box, _) = try pair(rate: 100_000_000)
        let shards = try channel.ingest(
            frame: frame(240_000, keyframe: true),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0, isKeyframe: true, now: 0)
        XCTAssertGreaterThan(shards, 200)
        XCTAssertEqual(box.sealCalls, 0, "commit is FEC plus enqueue")

        channel.pump(now: 0)
        XCTAssertGreaterThan(box.sent.count, 0)
        XCTAssertLessThan(box.sent.count, shards,
                          "one quantum leaves, not the frame")
        XCTAssertEqual(box.sealCalls, box.sent.count)

        var now: UInt64 = 0
        drain(channel, from: &now)
        XCTAssertEqual(box.sent.count, shards)
        XCTAssertEqual(box.sealCalls, shards)
        XCTAssertEqual(channel.pacerTelemetry.bytesSent,
                       box.sent.reduce(0) { $0 + $1.bytes.count },
                       "each token priced its datagram's exact wire image")
    }

    /// A shard the seal refuses leaves its frame undecodable: the rest of
    /// that frame is dropped unsealed and unsent, without spending seqs,
    /// no repair of it is offered, and the next frame flows normally.
    func testASealRefusalDropsTheRestOfItsFrame() throws {
        struct Refused: Error {}
        let hostKeys = NoiseKeyPair.generate()
        var initiator = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostKeys.publicKey)
        var responder = try NoiseSession(role: .responder, staticKeys: hostKeys)
        _ = try responder.readMessage1(try initiator.writeMessage1()[...])
        _ = try initiator.readMessage2(try responder.writeMessage2()[...])
        let box = Box(try responder.makeTransport())
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: 1_000_000_000),
            now: 0,
            seal: { plaintext, aad, envelope in
                box.sealCalls += 1
                if box.sealCalls == 3 { throw Refused() }
                return try box.host.seal(
                    plaintext: plaintext, aad: aad, envelope: envelope)
            },
            send: { box.sent.append($0) })
        var client = Receiver(transport: try initiator.makeTransport())

        var now: UInt64 = 1_000_000
        let broken = try channel.ingest(
            frame: frame(20_000), frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0, isKeyframe: false, now: now)
        XCTAssertGreaterThan(broken, 5)
        drain(channel, from: &now)
        XCTAssertEqual(box.sent.count, 2, "only the shards before the refusal")
        XCTAssertEqual(box.sealCalls, 3, "nothing after it is sealed")
        XCTAssertEqual(channel.counters.releaseSealFailures, 1)
        XCTAssertTrue(channel.framesWithQueuedShards().isEmpty)
        XCTAssertEqual(channel.enqueueRepair(
            frame: FrameNumber(rawValue: 0), shardIndices: [5], now: now), 0,
            "no repair of a frame that cannot decode")

        let next = try channel.ingest(
            frame: frame(20_000), frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 16_000, isKeyframe: false, now: now)
        drain(channel, from: &now)
        XCTAssertEqual(box.sent.count, 2 + next)
        box.sent.forEach { client.receive($0) }
        XCTAssertTrue(client.refused.isEmpty)
        XCTAssertTrue(client.missing.isEmpty, "no seq was spent on a drop")
    }

    private struct FecFieldMismatch: Error {}
}
