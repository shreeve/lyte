import XCTest
import LyteTransport
import LyteWire

// THE GATE (CL-11, layout half): the client's audio depacketizer is a
// BYTE MIRROR of HS-15's HOST-PINNED AudioFramer layout — pinned here
// against hand-built wire bytes (the identical hand-built arrays
// Host/Tests/HostWireTests/AudioGateTests.swift leg 1 pins the framer
// against — the cross-pin), and against the frozen FEC machinery for
// recovery. Both copies promote into Wire/ together; neither may move
// a byte.

final class AudioDepacketizerGateTests: XCTestCase {

    /// The host test's hard-CBR Opus stand-in, verbatim: byteCount
    /// deterministic bytes seeded by the packet number.
    private func opusPacket(_ n: Int, byteCount: Int = 80) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
    }

    /// Hand-assembled wire image of one audio shard — copied from the
    /// host gate's leg 1 (the layout IS the contract; all fields
    /// little-endian per the envelope rule).
    private func handBuilt(
        shardIndex i: UInt8, seq: UInt8, groupId: UInt32,
        timestamp: UInt64, groupByteCount: UInt8, payload: [UInt8]
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(1)                    // chan 1 = audio
        out.append(0)                    // flags: no TLV block
        out += [seq, 0]                  // seq u16 LE (emit order)
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8(truncatingIfNeeded: groupId >> shift))
        }                                // frame u32 LE = group id
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8(truncatingIfNeeded: timestamp >> shift))
        }
        // fec u64 LE: shardIndex ‖ k=4 ‖ m=2 ‖ scheme=RS(0x01) ‖
        // groupByteCount u24 ‖ reserved 0.
        out += [i, 4, 2, 0x01, groupByteCount, 0, 0, 0]
        out += payload
        return out
    }

    /// The mirror framer: builds one group's six wire images exactly
    /// as the host's AudioFramer emits them (data shards stamped with
    /// their own capture µs, parity with the group's first, seqs
    /// contiguous in emit order).
    private func buildGroup(
        packets: [[UInt8]], groupId: UInt32, firstSeq: UInt16,
        firstCaptureMicros: UInt64
    ) throws -> [(envelope: Envelope, payload: [UInt8])] {
        let k = packets.count
        let geometry = try FecGeometry(
            dataShards: k, parityShards: 2,
            groupByteCount: packets[0].count * k)
        let shards = try FecEncoder.encode(
            group: packets.flatMap { $0 }, geometry: geometry)
        var out: [(envelope: Envelope, payload: [UInt8])] = []
        for index in 0..<geometry.totalShards {
            let timestamp = geometry.isParityShard(index)
                ? firstCaptureMicros
                : firstCaptureMicros + UInt64(index) * 5_000
            let envelope = Envelope(
                channel: .audio,
                seq: ChannelSeq(rawValue: firstSeq &+ UInt16(index)),
                frame: FrameNumber(rawValue: groupId),
                timestamp: timestamp,
                fec: try FecField.reedSolomonShard(index, of: geometry).encoded)
            out.append((envelope, shards[index]))
        }
        return out
    }

    // MARK: Leg 1 — the layout, cross-pinned as hand-built bytes

    func testMirrorLayoutMatchesHostPinnedBytesAndDepacketizes() throws {
        // The host gate's exact leg-1 shape: 12 B packets, stamps
        // 1000 + 5000n, group id 0, seqs 0…5.
        let packets = (0..<4).map { opusPacket($0, byteCount: 12) }
        let group = try buildGroup(
            packets: packets, groupId: 0, firstSeq: 0,
            firstCaptureMicros: 1_000)

        // Our mirror-built wire images equal the hand-built layout —
        // the same arrays the host test pins its framer against.
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 48)
        let reference = try FecEncoder.encode(
            group: packets.flatMap { $0 }, geometry: geometry)
        for i in 0..<6 {
            let wire = try group[i].envelope.encode(
                plaintextShard: group[i].payload)
            let expected = handBuilt(
                shardIndex: UInt8(i), seq: UInt8(i), groupId: 0,
                timestamp: i < 4 ? 1_000 + UInt64(i) * 5_000 : 1_000,
                groupByteCount: 48,
                payload: i < 4 ? packets[i] : reference[i])
            XCTAssertEqual(wire, expected, "shard \(i) layout drifted")
        }

        // Decoding the hand-built bytes and depacketizing yields the
        // packets with the pinned number/stamp semantics: packet n =
        // frame + shardIndex, data shards carry their own capture µs.
        let depacketizer = AudioDepacketizer()
        var emitted: [AudioPacket] = []
        for i in 0..<6 {
            let wire = handBuilt(
                shardIndex: UInt8(i), seq: UInt8(i), groupId: 0,
                timestamp: i < 4 ? 1_000 + UInt64(i) * 5_000 : 1_000,
                groupByteCount: 48,
                payload: i < 4 ? packets[i] : reference[i])
            let (envelope, payload) = try Envelope.decode(wire[...])
            emitted += depacketizer.ingest(
                envelope: envelope, payload: Array(payload))
        }
        XCTAssertEqual(emitted.count, 4, "parity must not emit packets")
        for (n, packet) in emitted.enumerated() {
            XCTAssertEqual(packet.number, UInt32(n))
            XCTAssertEqual(packet.captureMicroseconds,
                           1_000 + UInt64(n) * 5_000)
            XCTAssertEqual(packet.bytes, packets[n])
            XCTAssertFalse(packet.recovered)
        }
        let stats = depacketizer.snapshotStats()
        XCTAssertEqual(stats.packetsEmitted, 4)
        XCTAssertEqual(stats.packetsRebuilt, 0)
        XCTAssertEqual(stats.malformedDatagrams, 0)
    }

    func testSecondGroupIdIsItsFirstPacketNumber() throws {
        let depacketizer = AudioDepacketizer()
        var numbers: [UInt32] = []
        for groupIndex in 0..<2 {
            let packets = (0..<4).map {
                opusPacket(groupIndex * 4 + $0, byteCount: 12)
            }
            let group = try buildGroup(
                packets: packets, groupId: UInt32(groupIndex * 4),
                firstSeq: UInt16(groupIndex * 6),
                firstCaptureMicros: 1_000 + UInt64(groupIndex) * 20_000)
            for (envelope, payload) in group {
                numbers += depacketizer.ingest(
                    envelope: envelope, payload: payload
                ).map(\.number)
            }
        }
        XCTAssertEqual(numbers, [0, 1, 2, 3, 4, 5, 6, 7],
                       "packet number = frame + shardIndex, both groups")
    }

    // MARK: Leg 2 — FEC recovery from ANY 2-of-6, client side

    func testAnyTwoLossesRecoverByteExactWithDerivedStamps() throws {
        let packets = (0..<4).map { opusPacket($0) }
        for a in 0..<6 {
            for b in (a + 1)..<6 {
                let depacketizer = AudioDepacketizer()
                let group = try buildGroup(
                    packets: packets, groupId: 100, firstSeq: 0,
                    firstCaptureMicros: 7_000_000)
                var emitted: [AudioPacket] = []
                for (index, entry) in group.enumerated()
                where index != a && index != b {
                    emitted += depacketizer.ingest(
                        envelope: entry.envelope, payload: entry.payload)
                }
                XCTAssertEqual(
                    emitted.count, 4,
                    "losing shards \(a),\(b) must still yield 4 packets")
                let byNumber = Dictionary(
                    uniqueKeysWithValues: emitted.map { ($0.number, $0) })
                for n in 0..<4 {
                    let packet = byNumber[UInt32(100 + n)]!
                    XCTAssertEqual(packet.bytes, packets[n],
                                   "packet \(n) after losing \(a),\(b)")
                    XCTAssertEqual(
                        packet.captureMicroseconds,
                        7_000_000 + UInt64(n) * 5_000,
                        "stamp of packet \(n) after losing \(a),\(b) — "
                        + "recovered stamps derive from the group-first µs")
                    XCTAssertEqual(packet.recovered, n == a || n == b,
                                   "recovered flag for \(n)")
                }
                let stats = depacketizer.snapshotStats()
                let lostData = [a, b].filter { $0 < 4 }.count
                XCTAssertEqual(stats.packetsRebuilt, UInt64(lostData))
                XCTAssertEqual(stats.groupsRecovered, lostData > 0 ? 1 : 0)
            }
        }
    }

    func testLateOriginalAfterRecoveryCountsAsDuplicate() throws {
        let packets = (0..<4).map { opusPacket($0) }
        let depacketizer = AudioDepacketizer()
        let group = try buildGroup(
            packets: packets, groupId: 0, firstSeq: 0,
            firstCaptureMicros: 1_000)
        // Lose data shard 1 on the "wire"; recovery completes at the
        // 4th arriving shard; the straggler then shows up anyway.
        var emitted: [AudioPacket] = []
        for index in [0, 2, 3, 4] {
            emitted += depacketizer.ingest(
                envelope: group[index].envelope,
                payload: group[index].payload)
        }
        XCTAssertEqual(emitted.count, 4)
        XCTAssertTrue(emitted.contains {
            $0.number == 1 && $0.recovered && $0.bytes == packets[1]
        })
        let straggler = depacketizer.ingest(
            envelope: group[1].envelope, payload: group[1].payload)
        XCTAssertTrue(straggler.isEmpty)
        XCTAssertEqual(depacketizer.snapshotStats().duplicateShards, 1)
    }

    // MARK: Leg 3 — honest refusals

    func testThreeLossesAreHonestlyUnrecoverableAndCountedAtEviction() throws {
        let depacketizer = AudioDepacketizer(horizonGroups: 2)
        let packets = (0..<4).map { opusPacket($0) }
        let group = try buildGroup(
            packets: packets, groupId: 0, firstSeq: 0,
            firstCaptureMicros: 1_000)
        // Only 3 of 6 arrive (2 data + 1 parity): 2 data packets are gone.
        var emitted: [AudioPacket] = []
        for index in [0, 3, 4] {
            emitted += depacketizer.ingest(
                envelope: group[index].envelope,
                payload: group[index].payload)
        }
        XCTAssertEqual(emitted.count, 2, "recovery must not run on 3 shards")

        // Push the horizon (2 groups × 4 packets) past group 0 with a
        // COMPLETE later group (an incomplete one would honestly count
        // its own losses too).
        let laterGroup = try buildGroup(
            packets: packets, groupId: 12,
            firstSeq: 0, firstCaptureMicros: 1_000)
        for (envelope, payload) in laterGroup {
            _ = depacketizer.ingest(envelope: envelope, payload: payload)
        }
        let stats = depacketizer.snapshotStats()
        XCTAssertEqual(stats.groupsUnrecoverable, 1)
        XCTAssertEqual(stats.packetsUnrecoverable, 2)
    }

    func testHostileShardsAreCountedNeverFatal() throws {
        let depacketizer = AudioDepacketizer()
        let packets = (0..<4).map { opusPacket($0) }
        let group = try buildGroup(
            packets: packets, groupId: 0, firstSeq: 0,
            firstCaptureMicros: 1_000)

        // Wrong-size payload for its declared geometry.
        XCTAssertTrue(depacketizer.ingest(
            envelope: group[0].envelope,
            payload: Array(group[0].payload.dropLast())
        ).isEmpty)
        // A non-RS fec field on the audio channel.
        var bareEnvelope = group[0].envelope
        bareEnvelope.fec = 0
        XCTAssertTrue(depacketizer.ingest(
            envelope: bareEnvelope, payload: group[0].payload
        ).isEmpty)
        // A shard whose geometry disagrees with the group's.
        _ = depacketizer.ingest(
            envelope: group[0].envelope, payload: group[0].payload)
        let foreignGeometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 4 * 40)
        var disagreeing = group[1].envelope
        disagreeing.fec = try FecField
            .reedSolomonShard(1, of: foreignGeometry).encoded
        XCTAssertTrue(depacketizer.ingest(
            envelope: disagreeing,
            payload: [UInt8](repeating: 0, count: 40)
        ).isEmpty)

        XCTAssertEqual(depacketizer.snapshotStats().malformedDatagrams, 3)
        XCTAssertEqual(depacketizer.snapshotStats().packetsEmitted, 1)
    }
}
