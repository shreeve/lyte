import HostCore
import LyteClientCore
import LyteWire
import XCTest

// The host's wake burst against the client's jitter buffer, both at
// their shipping defaults: the burst the tripwire ships on wake must fit
// under the buffer's hard cap, so the onset plays from its first packet
// and nothing is re-centered away.

final class AudioWakeGateTests: XCTestCase {
    private static let packetMicros: UInt64 = 5_000

    func testTheDefaultWakeBurstPlaysWholeWithoutARecenter() {
        var tripwire = AudioTripwire()
        let buffer = AudioJitterBuffer()
        var number: UInt32 = 0
        var tick: UInt64 = 0
        var burst: [AudioTripwirePacket] = []

        func capture(rms: Float) -> AudioTripwireAction {
            tick += 1
            return tripwire.ingest(
                rms: rms, packet: [UInt8(truncatingIfNeeded: tick)],
                captureMicroseconds: tick * Self.packetMicros)
        }
        func deliver(_ packet: AudioTripwirePacket, at now: UInt64) {
            buffer.insert(
                AudioPacket(number: number,
                            captureMicroseconds: packet.captureMicroseconds,
                            bytes: packet.bytes, recovered: false),
                arrivalMicroseconds: now)
            number += 1
        }

        // Silence transmits until the hold closes the gate; the client
        // plays it at the wire's cadence.
        while true {
            let now = tick * Self.packetMicros
            let bytes = [UInt8(truncatingIfNeeded: tick + 1)]
            let action = capture(rms: 0)
            guard action == .transmit else {
                XCTAssertEqual(action, .beginQuiet(checkIn: true))
                break
            }
            deliver(AudioTripwirePacket(bytes: bytes,
                                        captureMicroseconds: now),
                    at: now)
            _ = buffer.pull(nowMicroseconds: now, urgent: true)
        }
        buffer.noteAnnouncedQuiet()
        for _ in 0..<200 {
            XCTAssertNotEqual(capture(rms: 0), .transmit)
            _ = buffer.pull(nowMicroseconds: tick * Self.packetMicros,
                            urgent: true)
        }

        // Sound until the tripwire fires; its burst lands at once.
        while burst.isEmpty {
            if case .wake(let preRoll) = capture(rms: 0.5) {
                burst = preRoll
            }
        }
        let before = buffer.snapshotStats()
        let now = tick * Self.packetMicros
        for packet in burst { deliver(packet, at: now) }

        guard case .packet(let first) = buffer.pull(nowMicroseconds: now,
                                                    urgent: true)
        else { return XCTFail("the wake burst must play at once") }
        XCTAssertEqual(first.bytes, burst[0].bytes,
                       "the onset plays from the burst's first packet")
        let after = buffer.snapshotStats()
        XCTAssertEqual(after.recenterEvents, before.recenterEvents)
        XCTAssertEqual(after.packetsDroppedInRecenter,
                       before.packetsDroppedInRecenter)
    }
}
