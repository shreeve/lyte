import XCTest
import LyteWire
import LyteWireTestKit

// Seeded property coverage for the video interior — the W-G3 integrity
// property as a sweep: packetize → scripted network damage (loss ≤ m,
// reorder, duplication, interleave, wrap-crossing seqs) → assemble, and
// the output is byte-identical input in frame order, or honestly
// nothing — never corrupt bytes. Same reproduce-from-seed discipline as
// the rest of the suite.

final class VideoPropertyTests: XCTestCase {

    /// A random frame-shaped Annex-B blob: start code, a VCL NAL header
    /// (IDR or TRAIL_R), random body with any accidental start codes
    /// scrubbed (00 00 00/01 runs broken up).
    private func randomFrame(
        byteCount: Int, isIDR: Bool, using rng: inout SplitMix64
    ) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 1, isIDR ? 0x26 : 0x02, 0x01]
        var body = rng.bytes(byteCount - out.count)
        for i in 2..<body.count where body[i] <= 1 && body[i - 1] == 0 && body[i - 2] == 0 {
            body[i] = 0x80
        }
        out += body
        return out
    }

    /// Frame sizes that walk every geometry bucket: k=1 through the
    /// 9…32 bucket, biased small the way live traffic is.
    private func randomFrameByteCount(using rng: inout SplitMix64) -> Int {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<4: return Int.random(in: 8...1112, using: &rng)          // k=1
        case 4..<7: return Int.random(in: 1113...(8 * 1112), using: &rng) // k=2…8
        default: return Int.random(in: (8 * 1112 + 1)...(20 * 1112), using: &rng)
        }
    }

    func testDamageSweepRoundTripsByteExact() throws {
        var rng = SplitMix64(seed: 0x57_1D_71_D0)
        for trial in 0..<40 {
            // A fresh channel per trial, with a random starting seq so
            // wrap crossings happen in a good fraction of trials.
            var packetizer = VideoPacketizer(
                firstSeq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng))
            )
            var assembler = VideoAssembler(config: VideoAssemblerConfig(
                holdbackFrameCount: 8,
                staleAfterMicroseconds: 10_000_000,
                maxTrackedGroups: 64,
                reorderThresholdPackets: 3
            ))
            let frameCount = Int.random(in: 2...6, using: &rng)
            let regime: FecRegime = Bool.random(using: &rng) ? .clean : .lossy

            // Delivery model: within each frame, shards shuffle freely and
            // lose up to the parity budget; up to half a frame's survivors
            // straggle into the next frame's batch (so adjacent frames
            // interleave and complete out of order), and one in ten shards
            // duplicates. Frame i always opens before frame i+1 completes —
            // beyond that lies the whole-frame-early startup case, where
            // emitting the completed frame immediately is the policy.
            var frames: [[UInt8]] = []
            var deliveries: [VideoShard] = []
            var stragglers: [VideoShard] = []
            for number in 0..<frameCount {
                let frame = randomFrame(
                    byteCount: randomFrameByteCount(using: &rng),
                    isIDR: number == 0,
                    using: &rng
                )
                frames.append(frame)
                var shards = try packetizer.packetize(
                    frame: frame,
                    frameNumber: FrameNumber(rawValue: UInt32(number)),
                    captureTimestamp: HostTimestamp(microseconds: UInt64(number)),
                    isIDR: number == 0,
                    regime: regime
                )
                // Loss up to the parity budget.
                let geometry = try FecGeometryTable.geometry(
                    forGroupByteCount: frame.count, regime: regime
                )
                shards.shuffle(using: &rng)
                shards.removeLast(
                    Int.random(in: 0...geometry.parityShards, using: &rng)
                )
                let carryCount = Int.random(in: 0...(shards.count / 2), using: &rng)
                var batch = stragglers + shards.dropLast(carryCount)
                stragglers = Array(shards.suffix(carryCount))
                batch.shuffle(using: &rng)
                for shard in batch {
                    deliveries.append(shard)
                    if Int.random(in: 0..<10, using: &rng) == 0 {
                        deliveries.append(shard)
                    }
                }
            }
            deliveries += stragglers

            var units: [DecodeUnit] = []
            var now = ClientTimestamp(microseconds: 0)
            for shard in deliveries {
                now = now.advanced(byMicroseconds: 10)
                for event in assembler.ingest(
                    envelope: shard.envelope,
                    payload: shard.payload,
                    now: now
                ) {
                    if case .decoded(let unit) = event { units.append(unit) }
                }
            }
            // Flush the ordering tail.
            for event in assembler.evictStale(
                now: now.advanced(byMicroseconds: 20_000_000)
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }

            XCTAssertEqual(units.count, frameCount, "trial \(trial)")
            for (number, unit) in units.enumerated() {
                XCTAssertEqual(unit.frameNumber.rawValue, UInt32(number), "trial \(trial)")
                XCTAssertEqual(unit.annexB, frames[number], "trial \(trial) frame \(number)")
                XCTAssertEqual(unit.isIDR, number == 0, "trial \(trial)")
                XCTAssertEqual(unit.timestamp.microseconds, UInt64(number), "trial \(trial)")
            }
        }
    }

    func testLossBeyondParityNeverEmitsCorruptBytes() throws {
        var rng = SplitMix64(seed: 0x57_1D_71_D1)
        for trial in 0..<40 {
            var packetizer = VideoPacketizer()
            // Write-off at distance 4: one follow-on frame (≥ 3 shards)
            // suffices to render the verdict inside the trial window.
            var assembler = VideoAssembler(config: VideoAssemblerConfig(
                holdbackFrameCount: 3,
                staleAfterMicroseconds: 100_000,
                maxTrackedGroups: 64,
                reorderThresholdPackets: 3,
                fecImpossibleThresholdPackets: 4
            ))
            let frameCount = Int.random(in: 3...6, using: &rng)
            // One doomed frame loses more data shards than parity; never
            // the last frame, so follow-on traffic exists to presume its
            // shards lost against.
            let doomed = Int.random(in: 0..<(frameCount - 1), using: &rng)

            var frames: [[UInt8]] = []
            var units: [DecodeUnit] = []
            var sawImpossible = false
            var now = ClientTimestamp(microseconds: 0)
            for number in 0..<frameCount {
                // ≥ 2 data shards so a beyond-parity pattern exists.
                let frame = randomFrame(
                    byteCount: Int.random(in: 1113...(6 * 1112), using: &rng),
                    isIDR: false, using: &rng
                )
                frames.append(frame)
                var shards = try packetizer.packetize(
                    frame: frame,
                    frameNumber: FrameNumber(rawValue: UInt32(number)),
                    captureTimestamp: HostTimestamp(microseconds: 0),
                    isIDR: false,
                    regime: .clean
                )
                if number == doomed {
                    let geometry = try FecGeometryTable.geometry(
                        forGroupByteCount: frame.count, regime: .clean
                    )
                    // Drop parity+1 shards from the front — all data.
                    shards.removeFirst(geometry.parityShards + 1)
                }
                // Reorder within the presumption threshold's calibration
                // (resiliency G4 models 2–4-packet displacement): the
                // fec-impossible verdict must then be precise — reported
                // for the doomed frame and no other.
                for shard in Reorder.bounded(shards, maxDisplacement: 3, using: &rng) {
                    now = now.advanced(byMicroseconds: 10)
                    for event in assembler.ingest(
                        envelope: shard.envelope, payload: shard.payload, now: now
                    ) {
                        switch event {
                        case .decoded(let unit): units.append(unit)
                        case .fecImpossible(let frame, _, _):
                            XCTAssertEqual(frame.rawValue, UInt32(doomed), "trial \(trial)")
                            sawImpossible = true
                        default: break
                        }
                    }
                }
            }
            for event in assembler.evictStale(
                now: now.advanced(byMicroseconds: 20_000_000)
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }

            // Every healthy frame emitted byte-exact; the doomed frame
            // never emitted at all — and was called impossible.
            XCTAssertEqual(units.count, frameCount - 1, "trial \(trial)")
            XCTAssertTrue(sawImpossible, "trial \(trial): fec-impossible never reported")
            for unit in units {
                let number = Int(unit.frameNumber.rawValue)
                XCTAssertNotEqual(number, doomed, "trial \(trial)")
                XCTAssertEqual(unit.annexB, frames[number], "trial \(trial)")
            }
        }
    }

    func testHostileDatagramsNeverTrapTheAssembler() throws {
        // Random envelopes and payloads straight into ingest: any mix of
        // events is fine, a crash is not, and nothing may emit (random
        // 8-byte groups can pass FEC but never the frame-shape check).
        var rng = SplitMix64(seed: 0x57_1D_71_D2)
        var assembler = VideoAssembler()
        for trial in 0..<20_000 {
            let envelope = Envelope(
                channel: Bool.random(using: &rng)
                    ? .videoActive : ChannelId(rawValue: UInt8.random(in: 0...255, using: &rng)),
                seq: ChannelSeq(rawValue: UInt16.random(in: .min ... .max, using: &rng)),
                frame: FrameNumber(rawValue: UInt32.random(in: 0...40, using: &rng)),
                timestamp: rng.next(),
                fec: Bool.random(using: &rng)
                    ? rng.next()
                    // Bias into decodable fields so the group machinery runs.
                    : (try? FecField.reedSolomonShard(
                        Int.random(in: 0..<3, using: &rng),
                        of: FecGeometry(dataShards: 2, parityShards: 1, groupByteCount: 8)
                    ).encoded) ?? 0
            )
            let payload = rng.bytes(Int.random(in: 0...16, using: &rng))
            let events = assembler.ingest(
                envelope: envelope, payload: payload,
                now: ClientTimestamp(microseconds: UInt64(trial))
            )
            for event in events {
                if case .decoded = event {
                    XCTFail("trial \(trial): random bytes emitted a DecodeUnit")
                }
            }
        }
    }
}
