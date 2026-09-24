import LyteTransport
import LyteWire
import XCTest

// Loss with FEC healing through the real depacketizer and jitter
// buffer, pumped the way LyteAudioPlayer pumps them: a simulated PCM
// ring consumed at the hardware rate, refilled to the adaptive target,
// `urgent` when the ring nears dry. PLC fires only when FEC is honestly
// impossible.

final class AudioReceiverFecGateTests: XCTestCase {

    private static let packetMicros: UInt64 = 5_000
    private static let packetFrames = 240
    private static let framesPerMs = 48

    /// Capture stamps are the host's: one stamped 2^63 µs away pins the
    /// latency floor at Int64's edge, and the next honest packet's span
    /// above it no longer fits. The books skip it instead of trapping.
    func testHostileCaptureStampsNeverTrapTheLatencyBooks() throws {
        let receiver = AudioReceiver()
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320)
        let now: UInt64 = 1_000_000
        let stamps = [now &+ (1 << 63), now &- 10_000]
        for (group, stamp) in stamps.enumerated() {
            let shards = try FecEncoder.encode(
                group: [UInt8](repeating: 7, count: 320), geometry: geometry)
            for index in 0..<4 {
                receiver.ingest(
                    envelope: Envelope(
                        channel: .audio,
                        seq: ChannelSeq(rawValue: UInt16(group * 6 + index)),
                        frame: FrameNumber(rawValue: UInt32(group * 4)),
                        timestamp: stamp &+ UInt64(index) * Self.packetMicros,
                        fec: try FecField.reedSolomonShard(
                            index, of: geometry).encoded),
                    payload: shards[index],
                    now: ClientTimestamp(microseconds: now))
            }
        }
        var played = 0
        for _ in 0..<16 {
            let decision = receiver.pullDecision(
                now: ClientTimestamp(microseconds: now), urgent: true)
            if case .packet = decision.verdict { played += 1 }
        }
        XCTAssertEqual(played, 8)
        let recorded = receiver.snapshotStats().captureToFeed.count
        XCTAssertGreaterThan(recorded, 0)
        XCTAssertLessThan(recorded, 8,
                          "a span past Int64 records nothing")
    }

    func testFecHealedLossPlaysByteExactWithZeroPlc() throws {
        let receiver = AudioReceiver()
        // 100 groups; drop exactly one data shard of every third group
        // — always inside RS 4+2's budget, healed when parity lands.
        var arrivals: [(at: UInt64, envelope: Envelope, payload: [UInt8])] = []
        var originals: [UInt32: [UInt8]] = [:]
        for group in 0..<100 {
            let packets = (0..<4).map { i -> [UInt8] in
                let n = group * 4 + i
                originals[UInt32(n)] =
                    (0..<80).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
                return originals[UInt32(n)]!
            }
            let geometry = try FecGeometry(
                dataShards: 4, parityShards: 2, groupByteCount: 320)
            let shards = try FecEncoder.encode(
                group: packets.flatMap { $0 }, geometry: geometry)
            let base = 10_000 + UInt64(group) * 20_000
            let dropped = group % 3 == 0 ? (group / 3) % 4 : -1
            for index in 0..<6 {
                if index == dropped { continue }
                let at = index < 4
                    ? base + UInt64(index) * Self.packetMicros
                    : base + 3 * Self.packetMicros + UInt64(index - 3)
                let envelope = Envelope(
                    channel: .audio,
                    seq: ChannelSeq(rawValue: UInt16((group * 6 + index) & 0xFFFF)),
                    frame: FrameNumber(rawValue: UInt32(group * 4)),
                    timestamp: index < 4
                        ? base + UInt64(index) * Self.packetMicros
                        : base,
                    fec: try FecField.reedSolomonShard(index, of: geometry).encoded)
                arrivals.append((at, envelope, shards[index]))
            }
        }
        arrivals.sort { $0.at < $1.at }

        // The pump loop over the receiver (ring model as in simulate).
        var ringFrames = 0
        var flowing = false
        var underrun = 0
        var played: [AudioPacket] = []
        var plc = 0
        var cursor = 0
        var t: UInt64 = 0
        let horizon = arrivals.map(\.at).max()! + 1_000
        while t <= horizon {
            while cursor < arrivals.count, arrivals[cursor].at <= t {
                receiver.ingest(
                    envelope: arrivals[cursor].envelope,
                    payload: arrivals[cursor].payload,
                    now: ClientTimestamp(microseconds: arrivals[cursor].at))
                cursor += 1
            }
            if flowing {
                if ringFrames >= Self.framesPerMs {
                    ringFrames -= Self.framesPerMs
                } else {
                    underrun += Self.framesPerMs - ringFrames
                    ringFrames = 0
                }
            }
            var pulling = true
            while pulling,
                  ringFrames < receiver.targetDepthPackets * Self.packetFrames {
                let urgent = ringFrames < Self.packetFrames
                switch receiver.pullDecision(
                    now: ClientTimestamp(microseconds: t), urgent: urgent
                ).verdict {
                case .packet(let packet):
                    played.append(packet)
                    ringFrames += Self.packetFrames
                    flowing = true
                case .conceal:
                    plc += 1
                    ringFrames += Self.packetFrames
                    flowing = true
                case .starved:
                    pulling = false
                }
            }
            t += 1_000
        }

        let stats = receiver.snapshotStats()
        XCTAssertEqual(plc, 0,
            "every dropped shard was FEC-healable — PLC must stay zero")
        XCTAssertEqual(stats.depacketizer.packetsRebuilt, 34,
                       "one rebuilt packet per every third group")
        XCTAssertEqual(played.count, 400, "all 400 packets played")
        XCTAssertEqual(underrun, 0)
        for packet in played {
            XCTAssertEqual(packet.bytes, originals[packet.number],
                           "packet \(packet.number) byte-exact")
        }
        XCTAssertEqual(played.map(\.number),
                       played.map(\.number).sorted(), "ordered playout")
    }
}
