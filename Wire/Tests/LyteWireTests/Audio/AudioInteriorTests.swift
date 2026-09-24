import XCTest
import LyteWire

// The promoted audio interior (HS-15's AudioFramer + CL-11's
// AudioDepacketizer, canonical here since the second codec-promotion
// slice). The layout is FROZEN DATA pinned as hand-built envelope
// bytes — the same arrays the Host gate pinned host-side and the root
// gate cross-pinned client-side — and the pair must survive ANY two
// losses of a 4+2 group byte-exact through the frozen FEC machinery.
// No vector file of its own: the interior COMPOSES the envelope/fec
// formats those files already freeze (the Noise-carriage precedent).

final class AudioInteriorTests: XCTestCase {

    /// A hard-CBR-shaped Opus packet stand-in: `byteCount` deterministic
    /// bytes seeded by the packet number (the AudioGateTests generator).
    private func opusPacket(_ n: Int, byteCount: Int = 80) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
    }

    // MARK: Leg 1 — the layout, pinned as hand-built bytes

    func testFramerLayoutPinnedAgainstHandBuiltBytes() throws {
        var framer = AudioFramer(config: AudioFramerConfig())
        let packets = (0..<4).map { opusPacket($0, byteCount: 12) }

        var emitted: [(envelope: Envelope, payload: [UInt8])] = []
        for (n, packet) in packets.enumerated() {
            emitted += try framer.ingest(
                packet: packet,
                captureTimestampMicroseconds: 1_000 + UInt64(n) * 5_000
            )
        }
        XCTAssertEqual(emitted.count, 6, "4 data + 2 parity")

        // Hand-assembled wire image of data shard `i`: the layout IS
        // the contract. All fields little-endian (envelope rule).
        func handBuilt(shardIndex i: UInt8, timestamp: UInt64,
                       payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.append(1)                    // chan 1 = audio
            out.append(0)                    // flags: no TLV block
            out += [UInt8(i), 0]             // seq u16 LE (emit order)
            out += [0, 0, 0, 0]              // frame u32 LE = group id 0
            for shift in stride(from: 0, to: 64, by: 8) {
                out.append(UInt8(truncatingIfNeeded: timestamp >> shift))
            }
            // fec u64 LE: shardIndex ‖ k=4 ‖ m=2 ‖ scheme=RS(0x01) ‖
            // groupByteCount u24 = 48 ‖ reserved 0.
            out += [i, 4, 2, 0x01, 48, 0, 0, 0]
            out += payload
            return out
        }

        for i in 0..<4 {
            let wire = try emitted[i].envelope.encode(
                plaintextShard: emitted[i].payload
            )
            XCTAssertEqual(
                wire,
                handBuilt(shardIndex: UInt8(i),
                          timestamp: 1_000 + UInt64(i) * 5_000,
                          payload: packets[i]),
                "data shard \(i) layout drifted"
            )
        }

        // Parity shards: envelope hand-built (group-FIRST capture µs —
        // they correspond to no single packet); payload pinned against
        // the frozen FEC machinery (fec-v1.json owns the matrix math).
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 48
        )
        let reference = try FecEncoder.encode(
            group: packets.flatMap { $0 }, geometry: geometry
        )
        for (offset, i) in [4, 5].enumerated() {
            let wire = try emitted[i].envelope.encode(
                plaintextShard: emitted[i].payload
            )
            let expected = handBuilt(
                shardIndex: UInt8(i), timestamp: 1_000,
                payload: reference[4 + offset]
            )
            XCTAssertEqual(wire, expected, "parity shard \(i) layout drifted")
        }
    }

    // MARK: Leg 2 — any two losses heal byte-exact (15/15 patterns)

    func testAnyTwoLossesRecoverByteExactAndThreeRefuse() throws {
        let packets = (0..<4).map { opusPacket($0) }

        // Every 2-of-6 loss pattern.
        var patterns: [[Int]] = []
        for a in 0..<6 {
            for b in (a + 1)..<6 { patterns.append([a, b]) }
        }
        XCTAssertEqual(patterns.count, 15)

        for lost in patterns {
            var framer = AudioFramer(config: AudioFramerConfig())
            var datagrams: [(envelope: Envelope, payload: [UInt8])] = []
            for (n, packet) in packets.enumerated() {
                datagrams += try framer.ingest(
                    packet: packet,
                    captureTimestampMicroseconds: UInt64(n) * 5_000
                )
            }
            var depacketizer = AudioDepacketizer()
            var received: [UInt32: AudioPacket] = [:]
            for (index, datagram) in datagrams.enumerated()
            where !lost.contains(index) {
                for packet in depacketizer.ingest(
                    envelope: datagram.envelope, payload: datagram.payload
                ) {
                    received[packet.number] = packet
                }
            }
            for n in 0..<4 {
                guard let out = received[UInt32(n)] else {
                    return XCTFail("pattern \(lost): packet \(n) missing")
                }
                XCTAssertEqual(out.bytes, packets[n],
                               "pattern \(lost): packet \(n) not byte-exact")
                XCTAssertEqual(out.captureMicroseconds, UInt64(n) * 5_000,
                               "pattern \(lost): packet \(n) stamp drifted")
            }
        }

        // Three losses refuse honestly: only the arrived packet emits.
        var framer = AudioFramer(config: AudioFramerConfig())
        var datagrams: [(envelope: Envelope, payload: [UInt8])] = []
        for (n, packet) in packets.enumerated() {
            datagrams += try framer.ingest(
                packet: packet, captureTimestampMicroseconds: UInt64(n) * 5_000
            )
        }
        var depacketizer = AudioDepacketizer()
        var emitted = 0
        for index in [0, 4, 5] {
            emitted += depacketizer.ingest(
                envelope: datagrams[index].envelope,
                payload: datagrams[index].payload
            ).count
        }
        XCTAssertEqual(emitted, 1, "3 data losses must not fabricate audio")
    }

    // MARK: Leg 3 — the CBR contract and hostile-shard discipline

    func testHostileShardsCountNeverTrap() throws {
        // The depacketizer counts hostility, never traps, never emits.
        var depacketizer = AudioDepacketizer()
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320
        )
        let field = try FecField.reedSolomonShard(1, of: geometry)
        let goodEnvelope = Envelope(
            channel: .audio, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 5_000,
            fec: field.encoded
        )
        // Wrong-size payload.
        XCTAssertTrue(depacketizer.ingest(
            envelope: goodEnvelope, payload: [1, 2, 3]
        ).isEmpty)
        // A non-RS fec field.
        var bare = goodEnvelope
        bare.fec = 0
        XCTAssertTrue(depacketizer.ingest(
            envelope: bare, payload: opusPacket(1)
        ).isEmpty)
        XCTAssertEqual(depacketizer.stats.malformedDatagrams, 2)

        // A duplicate data shard is counted, not re-emitted.
        XCTAssertEqual(depacketizer.ingest(
            envelope: goodEnvelope, payload: opusPacket(1)
        ).count, 1)
        XCTAssertTrue(depacketizer.ingest(
            envelope: goodEnvelope, payload: opusPacket(1)
        ).isEmpty)
        XCTAssertEqual(depacketizer.stats.duplicateShards, 1)

        // A geometry-disagreeing shard for the same group is hostile.
        let foreignGeometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 316
        )
        let foreignField = try FecField.reedSolomonShard(2, of: foreignGeometry)
        var disagreeing = goodEnvelope
        disagreeing.fec = foreignField.encoded
        XCTAssertTrue(depacketizer.ingest(
            envelope: disagreeing, payload: opusPacket(2, byteCount: 79)
        ).isEmpty)
        XCTAssertEqual(depacketizer.stats.malformedDatagrams, 3)
    }

    /// A mid-group size change closes the open group without parity and
    /// the new size starts a fresh group: the receiver still gets every
    /// packet, the new groups FEC-protected.
    func testSizeChangeAbandonsTheOpenGroup() throws {
        var framer = AudioFramer(config: AudioFramerConfig())
        var depacketizer = AudioDepacketizer()
        var delivered: [UInt32] = []
        func feed(_ n: Int, byteCount: Int, dropping dropped: Set<Int> = []) throws {
            let datagrams = try framer.ingest(
                packet: opusPacket(n, byteCount: byteCount),
                captureTimestampMicroseconds: UInt64(n) * 5_000
            )
            for (index, datagram) in datagrams.enumerated()
            where !dropped.contains(index) {
                delivered += depacketizer.ingest(
                    envelope: datagram.envelope, payload: datagram.payload
                ).map(\.number)
            }
        }
        for n in 0..<6 { try feed(n, byteCount: 80) }
        XCTAssertEqual(framer.counters.groupsAbandoned, 0)
        // Packet 6 changes size with packets 4 and 5 in the open group.
        try feed(6, byteCount: 96)
        XCTAssertEqual(framer.counters.groupsAbandoned, 1)
        XCTAssertEqual(framer.counters.groupsCompleted, 1)
        // Packet 7's own data shard is lost; parity of the new group
        // rebuilds it.
        for n in 7..<14 {
            try feed(n, byteCount: 96, dropping: n == 7 ? [0] : [])
        }
        XCTAssertEqual(delivered.sorted(), (0..<14).map { UInt32($0) })
        XCTAssertEqual(depacketizer.stats.packetsRebuilt, 1)
        XCTAssertEqual(framer.counters.groupsCompleted, 3)
        // Nothing is open right after a completed group.
        XCTAssertFalse(framer.abandonOpenGroup())
        try feed(14, byteCount: 96)
        XCTAssertTrue(framer.abandonOpenGroup())
        XCTAssertEqual(framer.counters.groupsAbandoned, 2)
    }

    // MARK: The retention horizon is local policy

    /// A shard's DECLARED geometry must not move the horizon: a legal k=1
    /// shard must not shrink retention to 8 packets (flushing groups
    /// still awaiting parity), nor a k=254 shard widen admission to ~2000
    /// packets. Both bounce off the pinned 32-packet (160 ms) policy
    /// while honest 4+2 traffic is untouched.
    func testDeclaredGeometryCannotMoveTheRetentionHorizon() throws {
        // Group 0 via the real framer: 3 of 4 data shards arrive, so the
        // group waits on parity for its recovery.
        let packets = (0..<4).map { opusPacket($0) }
        var framer = AudioFramer(config: AudioFramerConfig())
        var datagrams: [(envelope: Envelope, payload: [UInt8])] = []
        for (n, packet) in packets.enumerated() {
            datagrams += try framer.ingest(
                packet: packet, captureTimestampMicroseconds: UInt64(n) * 5_000
            )
        }
        var depacketizer = AudioDepacketizer()
        for i in [0, 1, 2] {
            _ = depacketizer.ingest(
                envelope: datagrams[i].envelope, payload: datagrams[i].payload
            )
        }

        let nominal = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320
        )
        func shard(
            group: UInt32, index: Int, of geometry: FecGeometry
        ) throws -> Envelope {
            let field = try FecField.reedSolomonShard(index, of: geometry)
            return Envelope(
                channel: .audio, seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: group),
                timestamp: UInt64(group) * 5_000, fec: field.encoded
            )
        }

        // Benign traffic advances the newest group to 24 — group 0 sits
        // 24 packets back, inside the 32-packet horizon.
        _ = depacketizer.ingest(
            envelope: try shard(group: 24, index: 0, of: nominal),
            payload: opusPacket(24)
        )

        // The shrink attack: a legal k=1 shard at a fresher id. Its
        // declared geometry must not flush group 0 (age 28 > 8·1).
        let tiny = try FecGeometry(
            dataShards: 1, parityShards: 1, groupByteCount: 80
        )
        _ = depacketizer.ingest(
            envelope: try shard(group: 28, index: 0, of: tiny),
            payload: opusPacket(28)
        )
        XCTAssertEqual(depacketizer.stats.groupsUnrecoverable, 0,
                       "a declared k=1 must not flush groups awaiting parity")

        // Group 0's parity arrives late (age 28, inside policy) and the
        // missing packet still heals byte-exact.
        let healed = depacketizer.ingest(
            envelope: datagrams[4].envelope, payload: datagrams[4].payload
        )
        XCTAssertEqual(healed.map(\.number), [3],
                       "the waiting group must still recover")
        XCTAssertEqual(healed[0].bytes, packets[3])
        XCTAssertTrue(healed[0].recovered)

        // The widen attack: advance to 48, then replay a 40-packet-stale
        // id under a declared k=254. Admission must follow the pinned
        // policy (40 > 32 → stale), not the declared 8·254.
        _ = depacketizer.ingest(
            envelope: try shard(group: 48, index: 0, of: nominal),
            payload: opusPacket(48)
        )
        let wide = try FecGeometry(
            dataShards: 254, parityShards: 1, groupByteCount: 254 * 80
        )
        XCTAssertTrue(depacketizer.ingest(
            envelope: try shard(group: 8, index: 0, of: wide),
            payload: opusPacket(8)
        ).isEmpty)
        XCTAssertEqual(depacketizer.stats.staleShards, 1,
                       "a declared k=254 must not widen admission")
    }

    // MARK: Retention is bounded against hostile group ids

    private func audioShard(
        group: UInt32, index: Int, of geometry: FecGeometry
    ) throws -> Envelope {
        let field = try FecField.reedSolomonShard(index, of: geometry)
        return Envelope(
            channel: .audio, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: group),
            timestamp: UInt64(group) * 5_000, fec: field.encoded
        )
    }

    /// An id exactly 2³¹ from the newest is neither behind nor ahead in
    /// serial arithmetic. It must be stale: admitted, it could never be
    /// evicted, and one such ghost per step grew retention without bound.
    func testAntipodalGroupIdIsStaleAndNeverRetained() throws {
        let nominal = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320
        )
        var depacketizer = AudioDepacketizer()
        for step in 0..<1_000 {
            let real = UInt32(step * 4)
            _ = depacketizer.ingest(
                envelope: try audioShard(group: real, index: 1, of: nominal),
                payload: opusPacket(step)
            )
            XCTAssertTrue(depacketizer.ingest(
                envelope: try audioShard(
                    group: real &+ 0x8000_0000, index: 1, of: nominal
                ),
                payload: opusPacket(step)
            ).isEmpty, "the antipode yields no packet")
        }
        XCTAssertEqual(depacketizer.stats.staleShards, 1_000)
        XCTAssertLessThanOrEqual(
            depacketizer.trackedGroupCount, depacketizer.horizonGroups + 1
        )
    }

    /// A peer declaring small groups at every packet number inside the
    /// horizon cannot hold more than the group cap; the oldest makes
    /// room, and its missing data counts as honest loss.
    func testGroupCountIsCappedAgainstDenseSmallGroups() throws {
        let tiny = try FecGeometry(
            dataShards: 2, parityShards: 1, groupByteCount: 160
        )
        var depacketizer = AudioDepacketizer()
        // Parity only: one shard of k = 2 recovers nothing, so every
        // group stays missing both data packets.
        for id in UInt32(0)...32 {
            _ = depacketizer.ingest(
                envelope: try audioShard(group: id, index: 2, of: tiny),
                payload: opusPacket(Int(id))
            )
        }
        XCTAssertEqual(
            depacketizer.trackedGroupCount, 2 * depacketizer.horizonGroups
        )
        XCTAssertEqual(
            depacketizer.stats.groupsUnrecoverable,
            UInt64(33 - 2 * depacketizer.horizonGroups)
        )
        XCTAssertEqual(
            depacketizer.stats.packetsUnrecoverable,
            2 * depacketizer.stats.groupsUnrecoverable
        )
        // The newest group survived the squeeze: its data shard is
        // delivered and completes a recovery.
        let healed = depacketizer.ingest(
            envelope: try audioShard(group: 32, index: 0, of: tiny),
            payload: opusPacket(32)
        )
        XCTAssertEqual(healed.map(\.number), [32, 33])
    }
}
