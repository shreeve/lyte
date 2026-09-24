import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import XCTest

/// What the host receives from browser input: finite, ordered, coalesced
/// motion, and every key and button edge.
final class BrowserInputTests: XCTestCase {
    /// The host drops a non-finite coordinate; the browser never sends
    /// one, and a refused event spends no seq.
    func testNonFiniteMotionIsRefusedBeforeItSpendsASeq() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        for body: InputEvent.Body in [
            .pointerMotionAbsolute(x: .nan, y: 1),
            .pointerMotionRelative(dx: .infinity, dy: 0),
            .pointerAxis(dx: 0, dy: -.infinity, finish: true),
        ] {
            host.deliver(client.sendInput(body: body, nowMicros: host.nowMicros), notes: &notes)
        }
        host.deliver(
            client.sendInput(body: .keyKeycode(keycode: 30, pressed: true), nowMicros: host.nowMicros),
            notes: &notes)
        host.run(client, notes: &notes, beats: 20) { _ in false }

        XCTAssertEqual(client.counters.inputsRefused, 3)
        XCTAssertEqual(received(host).map(\.seq), [0])
        XCTAssertEqual(received(host).map(\.body), [.keyKeycode(keycode: 30, pressed: true)])
    }

    /// Motion captured within one beat crosses as its newest position, and
    /// a button edge after it still lands after it.
    func testMotionCoalescesAndStaysOrderedWithButtons() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        for x in 1...10 {
            host.deliver(
                client.sendInput(
                    body: .pointerMotionAbsolute(x: Double(x), y: 5),
                    nowMicros: host.nowMicros),
                notes: &notes)
        }
        host.deliver(
            client.sendInput(body: .pointerButton(button: 272, pressed: true), nowMicros: host.nowMicros),
            notes: &notes)
        for dy in [3.0, 4.0] {
            host.deliver(
                client.sendInput(
                    body: .pointerAxis(dx: 0, dy: dy, finish: false), nowMicros: host.nowMicros),
                notes: &notes)
        }
        host.run(client, notes: &notes, beats: 20) { _ in false }

        XCTAssertEqual(received(host).map(\.body), [
            .pointerMotionAbsolute(x: 10, y: 5),
            .pointerButton(button: 272, pressed: true),
            .pointerAxis(dx: 0, dy: 7, finish: false),
        ])
    }

    /// A host that stops acknowledging fills the reliable queue; the key
    /// edges behind it wait instead of being dropped, so the final release
    /// still reaches the host once the path recovers.
    func testFullReliableQueueDefersKeyEdgesInsteadOfDroppingThem() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        let edges = ArqBounds.maxQueuedSegmentsPerGroup + 10
        var stalled: [[UInt8]] = []
        for index in 0..<edges {
            stalled += client.sendInput(
                body: .keyKeycode(keycode: 30, pressed: index % 2 == 0),
                nowMicros: host.nowMicros
            ).outbound
        }
        XCTAssertGreaterThan(client.counters.inputsDeferred, 0)
        XCTAssertGreaterThan(client.inputsPending, 0)
        XCTAssertEqual(client.counters.inputsRefused, 0)
        XCTAssertEqual(client.currentStatus, .ready)

        for datagram in stalled { host.receive(datagram) }
        host.run(client, notes: &notes, beats: 4_000) {
            $0.inputsPending == 0 && $0.isReliableQuiescent
        }
        let keys = received(host)
        XCTAssertEqual(keys.count, edges)
        XCTAssertEqual(keys.last?.body, .keyKeycode(keycode: 30, pressed: false))
        XCTAssertEqual(keys.map(\.seq), (0..<UInt32(edges)).map { $0 })
    }

    private func received(_ host: BrowserHostPeer) -> [InputEvent] {
        host.events.compactMap {
            if case .inputReceived(let input, _) = $0 { return input }
            return nil
        }
    }
}
