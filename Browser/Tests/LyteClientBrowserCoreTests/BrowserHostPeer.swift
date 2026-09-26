import HostSession
import HostWire
import HostWireTestKit
import LyteClientBrowserCore
import LyteCore
import LyteWire
import Foundation
import XCTest

/// The engine lyte-control-peer serves to Chrome — HostWireTestKit's
/// shipping `Session` on an outbox, plus PairingResponderService — in
/// process. Host time is the harness's virtual µs; the browser reads the
/// same instant through its own clock (`nowMicros`), which may run skewed.
/// Tests decide which datagrams cross, so loss, duplication, reordering
/// and forgery are explicit.
final class BrowserHostPeer {
    static let pin = "246810"
    static let startMicros: UInt64 = 1_000_000

    let hostStatic = NoiseKeyPair.generate()
    let pairing: PairingResponderService
    let harness: HostSessionHarness
    /// Client clock rate against the host's, parts per million.
    private let clientSkewPartsPerMillion: Int64
    private(set) var events: [SessionEvent] = []
    /// Host virtual time in microseconds.
    private(set) var hostMicros: UInt64 = BrowserHostPeer.startMicros
    /// The source tuple client datagrams arrive from; changing it roams.
    var clientTuple: FourTuple {
        get { harness.tuple }
        set { harness.tuple = newValue }
    }

    init(
        lifecycle: SessionMachineConfig = SessionMachineConfig(
            blackoutSilenceMicroseconds: 30_000_000,
            recoveryBlackoutSilenceMicroseconds: 30_000_000
        ),
        capabilities: Capabilities = .wireDefault.declaringClipboardText(),
        clientSkewPartsPerMillion: Int64 = 0
    ) {
        self.clientSkewPartsPerMillion = clientSkewPartsPerMillion
        self.pairing = PairingResponderService(
            pin: Array(Self.pin.utf8),
            hostStaticPublicKey: hostStatic.publicKey
        )
        self.harness = HostSessionHarness(
            config: SessionConfig(
                rateBitsPerSecond: 50_000_000,
                capabilities: capabilities,
                lifecycle: lifecycle
            ),
            acceptor: HandshakeAcceptor.Config(hostStatic: hostStatic),
            tuple: FourTuple(
                localAddress: "127.0.0.1", localPort: 41_234,
                remoteAddress: "127.0.0.1", remotePort: 50_000
            ),
            rng: SystemRandomNumberGenerator()
        )
    }

    var session: Session { harness.session }
    var hostStaticHex: String { Hex.string(hostStatic.publicKey) }

    /// The browser's clock at this host instant.
    var nowMicros: UInt64 {
        let elapsed = Int64(hostMicros - Self.startMicros)
        return UInt64(Int64(hostMicros) + elapsed * clientSkewPartsPerMillion / 1_000_000)
    }

    func makeClient(
        pin: String = BrowserHostPeer.pin,
        retry: BrowserControlSession.HandshakeRetry = .firstDial
    ) throws -> BrowserControlSession {
        try BrowserControlSession(
            hostStaticPublicKeyHex: hostStaticHex, pin: pin,
            handshakeRetry: retry
        )
    }

    /// Moves virtual time and runs the host's timers (beacons, echo
    /// flush, ARQ retransmit, lifecycle), as the peer's run loop does.
    func advance(microseconds: UInt64) {
        hostMicros += microseconds
        handle(harness.advance(to: hostMicros))
    }

    /// One client datagram arrives at the host.
    func receive(_ datagram: [UInt8]) {
        handle(harness.receive(datagram, at: hostMicros))
    }

    private func handle(_ produced: [SessionEvent]) {
        events += produced
        for event in produced {
            switch event {
            case .handshakeCompleted(let remote):
                if let hash = session.handshakeHash {
                    pairing.sessionEstablished(
                        clientStaticPublicKey: remote, noiseHandshakeHash: hash
                    )
                }
            case .reliableCtrl(_, let message):
                if let output = pairing.handleReliableCtrl(
                    message, now: hostMicros * 1_000
                ) {
                    for reply in output.replies {
                        try? session.sendReliable(
                            reply, now: hostMicros * 1_000,
                            hostMicroseconds: hostMicros
                        )
                    }
                }
            case .inputReceived(let input, let receivedAt):
                session.noteInputInjected(
                    seq: input.seq,
                    receivedAtMicroseconds: receivedAt,
                    injectedAtMicroseconds: receivedAt
                )
            default:
                break
            }
        }
    }

    /// Everything the host has released since the last drain, with the
    /// pacer's metadata (frame number, class).
    func drainReleased() -> [VideoChannelDatagram] {
        harness.currentSession?.pump(now: hostMicros * 1_000)
        let released = Array(harness.sent[harness.forwarded...])
        harness.forwarded = harness.sent.count
        return released
    }

    /// Everything the host has sent since the last drain.
    func drain() -> [[UInt8]] {
        drainReleased().map(\.bytes)
    }

    // MARK: Driving a client

    /// Delivers the client's step to the host and records its notes.
    @discardableResult
    func deliver(
        _ step: BrowserControlSession.Step, notes: inout [String]
    ) -> BrowserControlSession.Step {
        notes += step.events
        for datagram in step.outbound { receive(datagram) }
        return step
    }

    /// Hands host datagrams to the client and its replies back to the host;
    /// returns the frames the client's Conductor scheduled.
    @discardableResult
    func deliver(
        _ datagrams: [[UInt8]], to client: BrowserControlSession,
        notes: inout [String]
    ) -> [BrowserVideoPlayout.ScheduledFrame] {
        datagrams.flatMap { datagram in
            deliver(client.ingest(datagram: datagram, nowMicros: nowMicros), notes: &notes)
                .scheduled
        }
    }

    /// Shuttles datagrams both ways in `beat` steps until `done` or `limit`.
    func run(
        _ client: BrowserControlSession,
        notes: inout [String],
        beats limit: Int = 400,
        beat: UInt64 = 5_000,
        until done: (BrowserControlSession) -> Bool
    ) {
        for _ in 0..<limit {
            if done(client) { return }
            deliver(drain(), to: client, notes: &notes)
            deliver(client.tick(nowMicros: nowMicros), notes: &notes)
            advance(microseconds: beat)
        }
    }

    /// A fresh client driven to READY.
    func readyClient(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (BrowserControlSession, [String]) {
        let client = try makeClient()
        var notes: [String] = []
        deliver(try client.begin(nowMicros: nowMicros), notes: &notes)
        run(client, notes: &notes) { $0.currentStatus == .ready }
        XCTAssertEqual(
            client.currentStatus, .ready,
            "notes: \(notes.joined(separator: " | "))", file: file, line: line
        )
        return (client, notes)
    }

    // MARK: Media

    /// The host ingests one frame captured at `capture` (default: now on
    /// its clock); every shard crosses in 1 ms beats until the client's
    /// Conductor schedules it.
    func sendFrame(
        _ annexB: [UInt8], keyframe: Bool, capture: UInt64? = nil,
        to client: BrowserControlSession
    ) throws -> [BrowserVideoPlayout.ScheduledFrame] {
        try session.ingestVideoFrame(
            annexB, captureTimestampMicroseconds: capture ?? hostMicros,
            isKeyframe: keyframe, now: hostMicros * 1_000
        )
        var scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
        var notes: [String] = []
        for _ in 0..<200 where scheduled.isEmpty {
            advance(microseconds: 1_000)
            scheduled = deliver(drain(), to: client, notes: &notes)
        }
        return scheduled
    }
}

/// `Wire/Vectors/video-corpus-v1`: frame 000 is an IDR, the rest its chain.
enum VideoCorpus {
    static func frames() throws -> [[UInt8]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../Wire/Vectors/video-corpus-v1")
            .standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("frame-00") && $0.hasSuffix(".annexb") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 2)
        return try names.map {
            [UInt8](try Data(contentsOf: root.appendingPathComponent($0)))
        }
    }
}
