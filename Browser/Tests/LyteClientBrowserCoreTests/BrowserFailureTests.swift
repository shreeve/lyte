import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import LyteWireTestKit
import XCTest

/// How the browser session ends when the far end refuses it: every
/// failure is reported in the step that saw it, a failure that composed a
/// teardown still sends it, and hostile bytes never end the session.
final class BrowserFailureTests: XCTestCase {
    func testWrongPinFailsTheSessionAndSaysSo() throws {
        let host = BrowserHostPeer()
        let client = try host.makeClient(pin: "135790")
        var notes: [String] = []
        host.deliver(try client.begin(nowMicros: host.nowMicros), notes: &notes)
        host.run(client, notes: &notes) { $0.currentStatus == .failed }

        XCTAssertEqual(client.currentStatus, .failed)
        XCTAssertFalse(client.paired)
        XCTAssertTrue(
            notes.contains("FAIL  pairing: PIN mismatch"), notes.joined(separator: " | "))
    }

    func testHostPairingRejectFailsTheSessionAndSaysSo() throws {
        var host = ScriptedHost()
        let client = try host.establish()
        try host.peer.send(
            PairingReject(reason: .confirmationFailed).encode(),
            nowMicros: host.nowMicros)
        let steps = try host.flush(to: client)

        XCTAssertEqual(client.currentStatus, .failed)
        XCTAssertTrue(
            steps.flatMap(\.events).contains { $0.hasPrefix("FAIL  pairing: host rejected") },
            "\(steps.flatMap(\.events))")
    }

    /// An unworkable capability intersection composes a typed teardown;
    /// it must reach the host even when its first copy is lost.
    func testCapabilityFailureStillSendsItsTeardown() throws {
        var host = ScriptedHost()
        let client = try host.establish()
        var unworkable = Capabilities.wireDefault
        unworkable.chromaModes = [CapabilityChroma.yuv444]
        try host.peer.declare(unworkable, as: .host, nowMicros: host.nowMicros)

        let failing = try host.flush(to: client, deliveringReplies: false)
        XCTAssertEqual(client.currentStatus, .failed)
        XCTAssertTrue(
            failing.flatMap(\.events).contains { $0.hasPrefix("FAIL  capabilities failed") },
            "\(failing.flatMap(\.events))")

        host.nowMicros += 2_000_000
        try host.absorb(client.tick(nowMicros: host.nowMicros))
        XCTAssertEqual(
            host.peer.take(type: CtrlMessageType.sessionTeardown).count, 1,
            "the composed teardown never reached the host")
    }

    func testMalformedInputEchoIsCountedAndDropped() throws {
        var host = ScriptedHost()
        let client = try host.establish()
        try host.peer.send([CtrlMessageType.inputEcho, 0xFF], nowMicros: host.nowMicros)
        let steps = try host.flush(to: client)

        XCTAssertEqual(client.currentStatus, .established)
        XCTAssertEqual(client.counters.malformedControl, 1)
        XCTAssertFalse(steps.flatMap(\.events).contains { $0.hasPrefix("FAIL") })
    }

    func testTeardownAfterTheHostClosedIsANoOp() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        _ = host.session.beginTeardown(
            reason: .shuttingDown, now: host.hostMicros * 1_000,
            hostMicroseconds: host.hostMicros)
        host.run(client, notes: &notes) { $0.currentStatus == .closed }
        XCTAssertEqual(client.closeReason, .peerTeardown(.shuttingDown))

        let late = client.teardown(nowMicros: host.nowMicros)
        XCTAssertEqual(late.status, .closed)
        XCTAssertTrue(late.passed)
        XCTAssertFalse(late.events.contains { $0.hasPrefix("FAIL") })
    }
}

/// A scripted far end for the paths the shipping host never takes: a
/// `SealedCtrlPeer` in the responder role that answers message 1 and then
/// says exactly what a test tells it to.
struct ScriptedHost {
    let staticKeys = NoiseKeyPair.generate()
    var peer: SealedCtrlPeer<HostClock>
    var nowMicros: UInt64 = 1_000_000

    init() {
        peer = SealedCtrlPeer(responderWith: staticKeys)
    }

    /// A browser session dialed at this host and established.
    mutating func establish() throws -> BrowserControlSession {
        let client = try BrowserControlSession(
            hostStaticPublicKeyHex: Hex.string(staticKeys.publicKey),
            pin: BrowserHostPeer.pin)
        let begin = try client.begin(nowMicros: nowMicros)
        let message2 = try XCTUnwrap(try peer.answerMessage1(try XCTUnwrap(begin.outbound.first)))
        try absorb(client.ingest(datagram: message2, nowMicros: nowMicros))
        XCTAssertEqual(client.currentStatus, .established)
        return client
    }

    mutating func absorb(_ step: BrowserControlSession.Step) throws {
        for datagram in step.outbound {
            try peer.absorb(datagram, nowMicros: nowMicros)
        }
    }

    /// The peer's due output into the client; replies go back unless told
    /// otherwise. Returns the client's steps.
    mutating func flush(
        to client: BrowserControlSession, deliveringReplies: Bool = true
    ) throws -> [BrowserControlSession.Step] {
        var steps: [BrowserControlSession.Step] = []
        for datagram in try peer.pollOut(nowMicros: nowMicros) {
            let step = client.ingest(datagram: datagram, nowMicros: nowMicros)
            if deliveringReplies { try absorb(step) }
            steps.append(step)
        }
        return steps
    }
}
