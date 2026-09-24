import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import XCTest

final class BrowserControlSessionTests: XCTestCase {
    func testReachesReadyAgainstHostWireSession() throws {
        let host = BrowserHostPeer()
        let (client, notes) = try host.readyClient()
        XCTAssertTrue(client.handshakeCompleted)
        XCTAssertTrue(client.paired)
        XCTAssertTrue(client.capabilitiesAgreed)
        XCTAssertTrue(client.clipboardNegotiated)
        XCTAssertTrue(notes.contains { $0.contains("clipboardText=true") })
        XCTAssertEqual(client.counters.message1Transmissions, 1)
    }

    // MARK: Per-datagram faults are dropped, not fatal

    func testReplayedSealedDatagramIsDroppedAndSessionStaysReady() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        var sealed: [UInt8]?
        for _ in 0..<400 where sealed == nil {
            host.advance(microseconds: 5_000)
            sealed = host.drain().first
        }
        let datagram = try XCTUnwrap(sealed, "host sent nothing sealed")

        let first = client.ingest(datagram: datagram, nowMicros: host.nowMicros)
        let replay = client.ingest(datagram: datagram, nowMicros: host.nowMicros)

        XCTAssertNotEqual(first.status, .failed)
        XCTAssertEqual(replay.status, .ready)
        XCTAssertFalse(replay.events.contains { $0.hasPrefix("FAIL") })
        XCTAssertEqual(client.counters.unsealFailures, 1)
    }

    func testJunkAndForgedDatagramsAreDroppedAndSessionStaysReady() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()

        let junk = client.ingest(datagram: [0xFF, 0x00, 0x13], nowMicros: host.nowMicros)
        let forged = client.ingest(
            datagram: try forgedCtrlDatagram(), nowMicros: host.nowMicros
        )

        XCTAssertEqual(junk.status, .ready)
        XCTAssertEqual(forged.status, .ready)
        XCTAssertEqual(client.counters.undecodableDatagrams, 1)
        XCTAssertEqual(client.counters.unsealFailures, 1)

        // Still a working session: an input event round-trips to an echo.
        var notes: [String] = []
        host.deliver(
            client.sendInput(body: .keyKeycode(keycode: 30, pressed: true),
                             nowMicros: host.nowMicros),
            notes: &notes
        )
        host.run(client, notes: &notes) { $0.inputEchoes >= 1 }
        XCTAssertEqual(client.inputEchoes, 1)
    }

    // MARK: Handshake

    func testLostMessage1IsRetransmittedVerbatim() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient()
        var notes: [String] = []
        let lost = try client.begin(nowMicros: host.nowMicros)

        host.advance(microseconds: 999_000)
        XCTAssertTrue(client.tick(nowMicros: host.nowMicros).outbound.isEmpty)
        host.advance(microseconds: 1_000)
        let resent = host.deliver(client.tick(nowMicros: host.nowMicros), notes: &notes)

        XCTAssertEqual(resent.outbound.count, 1)
        XCTAssertEqual(
            try carriagePayload(try XCTUnwrap(resent.outbound.first)),
            try carriagePayload(try XCTUnwrap(lost.outbound.first)),
            "the retransmit must carry the same message 1"
        )
        host.run(client, notes: &notes) { $0.currentStatus == .ready }
        XCTAssertEqual(client.currentStatus, .ready)
        XCTAssertEqual(client.counters.message1Transmissions, 2)
    }

    func testUnansweredHandshakeFailsAfterItsAttempts() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient(
            retry: .init(attempts: 3, intervalMicroseconds: 100_000)
        )
        _ = try client.begin(nowMicros: 0)
        var last: BrowserControlSession.Step?
        for beat in 1...10 {
            last = client.tick(nowMicros: UInt64(beat) * 100_000)
            if last?.status == .failed { break }
        }
        XCTAssertEqual(last?.status, .failed)
        XCTAssertEqual(client.counters.message1Transmissions, 3)
    }

    func testRejectedMessage2IsSkippedAndTheGenuineOneCompletes() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient()
        var notes: [String] = []
        host.deliver(try client.begin(nowMicros: host.nowMicros), notes: &notes)

        let garbage = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [CtrlMessageType.noiseHandshake2] + Array(repeating: 0xA5, count: 48))
        let rejected = client.ingest(datagram: garbage, nowMicros: host.nowMicros)
        XCTAssertEqual(rejected.status, .handshaking)
        XCTAssertEqual(client.counters.rejectedMessage2, 1)

        host.run(client, notes: &notes) { $0.currentStatus == .ready }
        XCTAssertEqual(client.currentStatus, .ready, notes.joined(separator: " | "))
    }

    /// A forged first datagram carrying a conn-id must not pick the conn-id
    /// every later client send carries; the host would drop those sends.
    func testConnectionIdIsLearnedOnlyFromAuthenticatedDatagrams() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient()
        var notes: [String] = []
        host.deliver(try client.begin(nowMicros: host.nowMicros), notes: &notes)
        // Deliver only message 2 (bare), then the forgery, then the rest.
        var pending = host.drain()
        let message2 = pending.removeFirst()
        host.deliver(client.ingest(datagram: message2, nowMicros: host.nowMicros), notes: &notes)
        XCTAssertEqual(client.currentStatus, .established)
        _ = client.ingest(datagram: try forgedCtrlDatagram(), nowMicros: host.nowMicros)
        for datagram in pending {
            host.deliver(client.ingest(datagram: datagram, nowMicros: host.nowMicros), notes: &notes)
        }

        host.run(client, notes: &notes) { $0.currentStatus == .ready }
        XCTAssertEqual(client.currentStatus, .ready, notes.joined(separator: " | "))
        let hostConnectionId = try XCTUnwrap(host.session?.connectionId)
        let send = client.sendInput(
            body: .pointerMotionAbsolute(x: 1, y: 2), nowMicros: host.nowMicros
        )
        let (envelope, _) = try Envelope.decode(try XCTUnwrap(send.outbound.first))
        XCTAssertEqual(
            try ConnectionId.decode(extensions: envelope.extensions), hostConnectionId
        )
    }

    // MARK: Lifecycle

    func testLivenessTimeoutClosesTheSessionAndSendsTeardown() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        _ = host.drain()

        // The host goes silent; the browser's lifecycle must notice.
        var closing: BrowserControlSession.Step?
        for second in 1...40 {
            let step = client.tick(nowMicros: host.nowMicros + UInt64(second) * 1_000_000)
            if step.status == .closed {
                closing = step
                break
            }
        }
        let step = try XCTUnwrap(closing, "liveness timeout never closed the session")
        XCTAssertEqual(client.closeReason, .livenessTimeout)
        XCTAssertTrue(step.events.contains { $0.contains("session: closed") })
        XCTAssertFalse(step.outbound.isEmpty, "the teardown must reach the wire")
    }

    func testLocalTeardownIsRetransmittedUntilAcknowledged() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        let teardown = client.teardown(nowMicros: host.nowMicros)
        XCTAssertEqual(teardown.status, .closed)
        XCTAssertFalse(teardown.outbound.isEmpty)
        XCTAssertFalse(client.isReliableQuiescent)

        // First copy lost; a PTO retransmit must still leave while closed.
        var retransmitted = false
        for _ in 0..<400 where !retransmitted {
            host.advance(microseconds: 5_000)
            retransmitted = !client.tick(nowMicros: host.nowMicros).outbound.isEmpty
        }
        XCTAssertTrue(retransmitted)
    }

    // MARK: Notes

    func testFailureIsReportedOnce() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient()
        _ = try client.begin(nowMicros: 0)
        let failed = try client.begin(nowMicros: 1)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.events.filter { $0.hasPrefix("FAIL") }.count, 1)

        let after = client.tick(nowMicros: 2)
        XCTAssertTrue(after.events.isEmpty, "the failure note was replayed: \(after.events)")
    }

    func testDeclinedClipboardShareIsNotASessionFailure() throws {
        let host = BrowserHostPeer()
        let (client, _) = try host.readyClient()
        var notes: [String] = []
        host.deliver(client.shareClipboard(text: "same", nowMicros: host.nowMicros), notes: &notes)
        let repeatShare = client.shareClipboard(text: "same", nowMicros: host.nowMicros)
        XCTAssertEqual(repeatShare.status, .ready)
        XCTAssertTrue(repeatShare.outbound.isEmpty)
        XCTAssertTrue(repeatShare.events.contains { $0.hasPrefix("clipboard: not shared") })
    }

    // MARK: Helpers

    private func carriagePayload(_ datagram: [UInt8]) throws -> [UInt8] {
        Array(try Envelope.decode(datagram).1)
    }

    /// A CTRL datagram claiming a random conn-id with a payload no key seals.
    private func forgedCtrlDatagram() throws -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        let forged = ConnectionId.random(using: &rng)
        return try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 7),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0,
            extensions: [forged.wireExtension]
        ).encode(payload: Array(repeating: 0x5A, count: 40))
    }
}
