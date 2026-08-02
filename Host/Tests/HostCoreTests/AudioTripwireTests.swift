import XCTest
@testable import HostCore

// The tripwire's gate laws (postures design, 2026-08-02): capture
// never stops — only transmission gates; ~5 s of unbroken silence
// closes the gate; ~100 ms of sound fires it; the wake burst carries
// the onset AND its leading context; check-ins bound staleness while
// gated. All in packet time — the wire's 5 ms cadence is the clock.

final class AudioTripwireTests: XCTestCase {

    /// Small numbers so the laws read at a glance: gate after 10
    /// silent packets, trip after 3 sound packets, ring of 6,
    /// check-in every 8.
    private func makeTripwire() -> AudioTripwire {
        AudioTripwire(config: AudioTripwireConfig(
            soundRmsFloor: 0.01,
            tripPackets: 3,
            quietHoldPackets: 10,
            preRollPackets: 6,
            checkInPackets: 8
        ))
    }

    private func offer(
        _ tripwire: inout AudioTripwire, rms: Float, tag: UInt8
    ) -> AudioTripwireAction {
        tripwire.ingest(
            rms: rms, packet: [tag],
            captureMicroseconds: UInt64(tag) * 5_000)
    }

    func testGateClosesOnlyAfterTheFullSilentHold() {
        var tripwire = makeTripwire()
        // 9 silent packets: still transmitting (silence is content
        // until the hold expires — the wire stays always-on).
        for i in 0..<9 {
            XCTAssertEqual(
                offer(&tripwire, rms: 0, tag: UInt8(i)), .transmit,
                "packet \(i) must transmit before the hold expires")
        }
        // The 10th closes the gate exactly once, with the first
        // check-in riding the announcement.
        XCTAssertEqual(
            offer(&tripwire, rms: 0, tag: 9), .beginQuiet(checkIn: true))
        XCTAssertTrue(tripwire.isGated)
        XCTAssertEqual(tripwire.counters.quietEntries, 1)
    }

    func testSentenceGapsNeverFlapTheGate() {
        var tripwire = makeTripwire()
        // 9 silent, one sound, 9 silent, forever: the run resets and
        // the gate never closes (hysteresis — the asymmetry law's
        // "leak down" half).
        for cycle in 0..<5 {
            for i in 0..<9 {
                XCTAssertEqual(
                    offer(&tripwire, rms: 0, tag: UInt8(cycle * 10 + i)),
                    .transmit)
            }
            XCTAssertEqual(
                offer(&tripwire, rms: 0.5, tag: UInt8(cycle * 10 + 9)),
                .transmit)
        }
        XCTAssertFalse(tripwire.isGated)
        XCTAssertEqual(tripwire.counters.quietEntries, 0)
    }

    func testWakeShipsTheOnsetAndItsLeadingContextInOrder() {
        var tripwire = makeTripwire()
        for i in 0..<10 { _ = offer(&tripwire, rms: 0, tag: UInt8(i)) }
        XCTAssertTrue(tripwire.isGated)

        // A long silence streams through the ring (evicting oldest)...
        for i in 10..<30 {
            let action = offer(&tripwire, rms: 0, tag: UInt8(i))
            if case .wake = action { XCTFail("silence must not wake") }
        }
        // ...then sound: two packets of onset keep it gated (trip
        // needs 3), the third fires.
        XCTAssertEqual(
            offer(&tripwire, rms: 0.5, tag: 30), .stayQuiet(checkIn: false))
        XCTAssertEqual(
            offer(&tripwire, rms: 0.5, tag: 31), .stayQuiet(checkIn: false))
        guard case .wake(let preRoll) = offer(&tripwire, rms: 0.5, tag: 32)
        else { return XCTFail("the third sound packet must fire the trip") }

        // The burst is the ring's last 6 packets in capture order:
        // 3 packets of leading silence context + the WHOLE onset,
        // ending with the packet that fired the trip.
        XCTAssertEqual(preRoll.map(\.bytes), [[27], [28], [29], [30], [31], [32]])
        XCTAssertEqual(
            preRoll.map(\.captureMicroseconds),
            [27, 28, 29, 30, 31, 32].map { UInt64($0) * 5_000 })
        XCTAssertFalse(tripwire.isGated)
        XCTAssertEqual(tripwire.counters.wakes, 1)
        XCTAssertEqual(tripwire.counters.preRollShipped, 6)

        // Awake again: the next packet transmits normally.
        XCTAssertEqual(offer(&tripwire, rms: 0.5, tag: 33), .transmit)
    }

    func testSoundBlipsShorterThanTheTripNeverWake() {
        var tripwire = makeTripwire()
        for i in 0..<10 { _ = offer(&tripwire, rms: 0, tag: UInt8(i)) }
        // 2-packet blips (below the 3-packet trip) separated by
        // silence: gated throughout — a click is not a conversation.
        for cycle in 0..<4 {
            _ = offer(&tripwire, rms: 0.5, tag: UInt8(40 + cycle * 3))
            _ = offer(&tripwire, rms: 0.5, tag: UInt8(41 + cycle * 3))
            let action = offer(&tripwire, rms: 0, tag: UInt8(42 + cycle * 3))
            if case .wake = action { XCTFail("a blip must not wake") }
        }
        XCTAssertTrue(tripwire.isGated)
        XCTAssertEqual(tripwire.counters.wakes, 0)
    }

    func testCheckInsFireOnCadenceWhileGated() {
        var tripwire = makeTripwire()
        for i in 0..<9 { _ = offer(&tripwire, rms: 0, tag: UInt8(i)) }
        XCTAssertEqual(
            offer(&tripwire, rms: 0, tag: 9), .beginQuiet(checkIn: true))

        // Every 8th gated packet thereafter carries a check-in.
        var checkIns = 0
        for i in 10..<34 {
            if offer(&tripwire, rms: 0, tag: UInt8(i))
                == .stayQuiet(checkIn: true) {
                checkIns += 1
            }
        }
        XCTAssertEqual(checkIns, 3, "24 gated packets at cadence 8")
    }

    func testRingNeverExceedsCapacityAndCountersAddUp() {
        var tripwire = makeTripwire()
        for i in 0..<10 { _ = offer(&tripwire, rms: 0, tag: UInt8(i)) }
        for i in 10..<100 { _ = offer(&tripwire, rms: 0, tag: UInt8(i)) }
        for tag in [100, 101] {
            _ = offer(&tripwire, rms: 0.5, tag: UInt8(tag))
        }
        guard case .wake(let preRoll) = offer(&tripwire, rms: 0.5, tag: 102)
        else { return XCTFail("must wake") }
        XCTAssertEqual(preRoll.count, 6, "the burst is bounded by the ring")
        // Every gated packet was counted: 10th closer + 90 silent +
        // 3 onset.
        XCTAssertEqual(tripwire.counters.packetsGated, 94)
        XCTAssertEqual(tripwire.counters.preRollShipped, 6)
    }
}
