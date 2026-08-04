import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (HS-25): one oversized frame must never kill the session.
//
// The live wound (2026-07-28, 50 Mbps/p4 recipe): a ~307 KB first-IDR
// packetized to 279 data shards, past the GF(2⁸) 255-shard RS block, and
// `unprotectableDataShardCount(279)` thrown out of the send path exited
// the host. The fec field binds ONE group per frame number and carries
// no group index, so a frame above the protectable ceiling is
// unshippable on this wire — the fix is a ceiling, not a split. Pinned
// behaviors, each a leg below:
//
//   • THE CEILING IS THE BLOCK MATH, EXACTLY: maxDataShards(regime) ×
//     the config's real shard budget — 231/204 (clean/lossy) × 1101 B
//     with the conn-id TLV, 1095 B with the lastInputSeq stamp riding;
//   • A CEILING-SIZED FRAME SHIPS PROTECTED: exactly 255 shards
//     (231 + 24 clean), every fec field decoding to the advertised
//     geometry, parity ≥ 1 — full protection at the block's brim;
//   • ONE BYTE PAST IT NEVER THROWS OUT OF THE SESSION: the live-repro
//     307 KB IDR ingests to zero shards, zero datagrams, one counted
//     drop, the coalesced keyframe latch armed (once), and the frame
//     number UNCONSUMED — the client sees no numbering gap, just the
//     re-encoded IDR riding the number the oversized frame would have
//     taken;
//   • THE CHANNEL SEAM STAYS LOUD (W2): VideoChannel.ingest past the
//     ceiling still throws `unprotectableDataShardCount` — the session
//     guard is policy, the channel invariant is the backstop;
//   • A REGIME FLIP SHRINKS THE CEILING, the guard follows: a frame
//     legal under clean drops under lossy instead of throwing.

final class UnprotectableFrameGateTests: XCTestCase {

    /// The HS-23 session rate — the recipe that exposed the bug live.
    private static let rate = 50_000_000

    private static let tuple = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_181,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    private final class Box {
        var sent: [VideoChannelDatagram] = []
        func fresh() -> [VideoChannelDatagram] {
            sent.filter { $0.pacerClass == .freshVideo }
        }
    }

    private func makeSession(box: Box) -> Session {
        Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.rate
            ),
            clientTuple: Self.tuple,
            now: 0,
            rng: SplitMix64(seed: 0x2501)
        ) { [box] datagram in
            box.sent.append(datagram)
        }
    }

    private func drain(
        _ session: Session, until horizon: UInt64, now: inout UInt64
    ) {
        while let wake = session.nextWake(now: now), wake <= horizon {
            now = max(now &+ 1, wake)
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }
    }

    /// A frame-shaped Annex-B blob with position-dependent bytes (the
    /// house pattern — a shard swap can never pass byte equality).
    private func syntheticFrame(
        byteCount: Int, irap: Bool = false
    ) -> [UInt8] {
        [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
            + (0..<(byteCount - 6)).map {
                UInt8(truncatingIfNeeded: $0 &* 131 &+ 7)
            }
    }

    // MARK: Leg 1 — the ceiling is the block math, exactly

    func testCeilingIsTheBlockMathExactly() {
        let box = Box()
        let session = makeSession(box: box)

        // Every session datagram carries the 11 B conn-id TLV block:
        // shard budget 1128 − 16 (tag) − 11 = 1101 B; the lastInputSeq
        // stamp (6 B more, once input flows) leaves 1095 B. The §5.2
        // ladder protects at most 231 data shards clean, 204 lossy.
        XCTAssertEqual(session.protectableFrameByteCeiling, 231 * 1_101,
                       "clean regime, no input stamp: 254,331 B")
        XCTAssertEqual(session.worstCaseProtectableFrameByteCeiling,
                       204 * 1_095,
                       "lossy regime with the input stamp: 223,380 B")
        // The live-repro frame sits above even the clean ceiling — the
        // 279-shard IDR was never shippable, only fatal.
        XCTAssertGreaterThan(307_000, session.protectableFrameByteCeiling)
    }

    // MARK: Leg 2 — a ceiling-sized frame ships fully protected

    func testCeilingSizedFrameShipsProtected() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        _ = session.advance(now: now, hostMicroseconds: 0)
        session.pump(now: now)
        box.sent.removeAll()

        let ceiling = session.protectableFrameByteCeiling
        let shards = try session.ingestVideoFrame(
            syntheticFrame(byteCount: ceiling, irap: true),
            captureTimestampMicroseconds: 1_000,
            isKeyframe: true,
            now: now
        )
        XCTAssertEqual(shards, 255,
                       "the brim of the block: 231 data + 24 parity")
        drain(session, until: 200_000_000, now: &now)

        let fresh = box.fresh()
        XCTAssertEqual(fresh.count, 255)
        for datagram in fresh {
            let (envelope, _) = try Envelope.decode(datagram.bytes)
            guard case .reedSolomon(_, let geometry) =
                try FecField.decode(envelope.fec) else {
                return XCTFail("video shard without an RS fec field")
            }
            XCTAssertEqual(geometry.dataShards, 231)
            XCTAssertEqual(geometry.parityShards, 24)
            XCTAssertEqual(geometry.groupByteCount, ceiling)
            XCTAssertLessThanOrEqual(geometry.totalShards, 255)
        }
        XCTAssertEqual(session.counters.videoFramesUnprotectable, 0)
    }

    // MARK: Leg 3 — the live repro never throws out of the session

    func testOversizedFrameDropsArmsIdrAndKeepsTheNumber() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        _ = session.advance(now: now, hostMicroseconds: 0)
        session.pump(now: now)
        box.sent.removeAll()
        // Consume establishment latches so the leg sees ONLY the
        // guard's arm below.
        _ = session.takeFreshKeyframeRequest()

        // The 2026-07-28 live frame: ~307 KB, the session's first IDR.
        let oversized = syntheticFrame(byteCount: 307_000, irap: true)
        var shards = 0
        XCTAssertNoThrow(
            shards = try session.ingestVideoFrame(
                oversized,
                captureTimestampMicroseconds: 1_000,
                isKeyframe: true,
                now: now
            ),
            "the unprotectable frame class must drop, never throw"
        )
        XCTAssertEqual(shards, 0)
        XCTAssertNil(session.lastAdmittedVideoFrameNumber)
        drain(session, until: 100_000_000, now: &now)
        XCTAssertTrue(box.fresh().isEmpty,
                      "nothing of the dropped frame reaches the wire")
        XCTAssertEqual(session.counters.videoFramesUnprotectable, 1)

        // The coalesced keyframe latch is armed — once.
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
                      "the dropped frame owes a fresh IDR")
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "the latch fires once per demand")

        // The frame number was NOT consumed: the re-encoded IDR rides
        // frame 0 and the client sees no numbering gap.
        now += 16_666_667
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 30_000, irap: true),
            captureTimestampMicroseconds: 17_667,
            isKeyframe: true,
            now: now
        )
        drain(session, until: now + 100_000_000, now: &now)
        let fresh = box.fresh()
        XCTAssertFalse(fresh.isEmpty)
        for datagram in fresh {
            XCTAssertEqual(datagram.frameNumber.rawValue, 0)
        }
        XCTAssertEqual(
            session.lastAdmittedVideoFrameNumber,
            FrameNumber(rawValue: 0))
    }

    func testSessionBorrowedIngressOwnsBytesBeforeReturn() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        _ = session.advance(now: now, hostMicroseconds: 0)
        session.pump(now: now)
        box.sent.removeAll()

        let original = syntheticFrame(byteCount: 7_003, irap: true)
        let pointer = UnsafeMutableBufferPointer<UInt8>.allocate(
            capacity: original.count
        )
        _ = pointer.initialize(from: original)
        _ = try session.ingestVideoFrame(
            UnsafeBufferPointer(pointer),
            captureTimestampMicroseconds: 7_777,
            isKeyframe: true,
            now: now
        )
        pointer.update(repeating: 0xE1)
        pointer.deallocate()

        drain(session, until: 100_000_000, now: &now)
        var assembler = VideoAssembler()
        var decoded: [DecodeUnit] = []
        for datagram in box.fresh() {
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            for event in assembler.ingest(
                envelope: envelope, payload: payload,
                now: ClientTimestamp(microseconds: now / 1_000)
            ) {
                if case .decoded(let unit) = event { decoded.append(unit) }
            }
        }
        XCTAssertEqual(decoded.map(\.annexB), [original])
        XCTAssertEqual(session.videoCounters.borrowedFramesIngested, 1)
        XCTAssertEqual(
            session.videoCounters.borrowedFrameBytesIngested, original.count
        )
    }

    // MARK: Leg 4 — the channel seam stays loud (the W2 backstop)

    func testChannelSeamStillThrowsPastTheCeiling() throws {
        var emitted: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: Self.rate,
                connectionId: try ConnectionId(
                    bytes: [1, 2, 3, 4, 5, 6, 7, 8]
                )
            ),
            now: 0
        ) { emitted.append($0) }

        let ceiling = channel.maxProtectableFrameByteCount(
            hasLastInputSeq: false
        )
        XCTAssertEqual(ceiling, 231 * 1_101)
        XCTAssertThrowsError(try channel.ingest(
            frame: syntheticFrame(byteCount: ceiling + 1, irap: true),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0,
            isKeyframe: true,
            now: 0
        )) { error in
            guard case .unprotectableDataShardCount(232)? =
                error as? FecError else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(emitted.isEmpty)
    }

    // MARK: Leg 5 — a regime flip shrinks the ceiling, the guard follows

    func testLossyRegimeShrinksTheCeilingAndTheGuardFollows() throws {
        var emitted: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                regime: .lossy,
                rateBitsPerSecond: Self.rate,
                connectionId: try ConnectionId(
                    bytes: [1, 2, 3, 4, 5, 6, 7, 8]
                )
            ),
            now: 0
        ) { emitted.append($0) }

        let lossyCeiling = channel.maxProtectableFrameByteCount(
            hasLastInputSeq: false
        )
        XCTAssertEqual(lossyCeiling, 204 * 1_101,
                       "lossy protects 204 data shards, not 231")

        // Legal under clean (230 KB < 254,331), unshippable under
        // lossy — the channel throws, which is exactly what the
        // session guard's live ceiling read prevents from ever being
        // reached.
        XCTAssertThrowsError(try channel.ingest(
            frame: syntheticFrame(byteCount: 230_000, irap: true),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0,
            isKeyframe: true,
            now: 0
        ))
        // At its own brim the lossy column ships 204 + 51 = 255.
        let shards = try channel.ingest(
            frame: syntheticFrame(byteCount: lossyCeiling, irap: true),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 0,
            isKeyframe: true,
            now: 0
        )
        XCTAssertEqual(shards, 255)
    }
}
