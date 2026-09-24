import HostSession
import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import XCTest

/// The engine lyte-control-peer serves to Chrome — a shipping
/// HostWire.Session plus PairingResponderService — in process, with UDP
/// replaced by arrays and time by one virtual clock shared with the browser
/// session. Tests decide which datagrams cross, so loss, duplication,
/// reordering and forgery are explicit.
final class BrowserHostPeer {
    static let tuple = FourTuple(
        localAddress: "127.0.0.1", localPort: 41_234,
        remoteAddress: "127.0.0.1", remotePort: 50_000
    )
    static let pin = "246810"

    let hostStatic = NoiseKeyPair.generate()
    let pairing: PairingResponderService
    private let lifecycle: SessionMachineConfig
    private(set) var session: Session?
    private(set) var events: [SessionEvent] = []
    private var outbox: [[UInt8]] = []
    /// Virtual time in microseconds, shared by both ends.
    private(set) var nowMicros: UInt64 = 1_000_000

    init(lifecycle: SessionMachineConfig = SessionMachineConfig(
        blackoutSilenceMicroseconds: 30_000_000,
        recoveryBlackoutSilenceMicroseconds: 30_000_000
    )) {
        self.lifecycle = lifecycle
        self.pairing = PairingResponderService(
            pin: Array(Self.pin.utf8),
            hostStaticPublicKey: hostStatic.publicKey
        )
    }

    var hostStaticHex: String { Hex.string(hostStatic.publicKey) }
    private var nowNS: UInt64 { nowMicros * 1_000 }

    func makeClient(
        retry: BrowserControlSession.HandshakeRetry = .init()
    ) throws -> BrowserControlSession {
        try BrowserControlSession(
            hostStaticPublicKeyHex: hostStaticHex, pin: Self.pin,
            handshakeRetry: retry
        )
    }

    /// Moves virtual time and runs the host's timers (beacons, echo
    /// flush, ARQ retransmit, lifecycle), as the peer's run loop does.
    func advance(microseconds: UInt64) {
        nowMicros += microseconds
        guard let session else { return }
        handle(session.advance(now: nowNS, hostMicroseconds: nowMicros), session)
        session.pump(now: nowNS)
    }

    /// One client datagram arrives at the host.
    func receive(_ datagram: [UInt8]) {
        if session == nil {
            session = Session(
                config: SessionConfig(
                    crypto: .noise(hostStatic: hostStatic),
                    rateBitsPerSecond: 50_000_000,
                    capabilities: .wireDefault.declaringClipboardText(),
                    lifecycle: lifecycle
                ),
                clientTuple: Self.tuple,
                now: nowNS,
                rng: SystemRandomNumberGenerator()
            ) { [unowned self] datagram in
                outbox.append(datagram.bytes)
            }
        }
        guard let session else { return }
        handle(
            session.receive(
                datagram[...], from: Self.tuple, now: nowNS, hostMicroseconds: nowMicros
            ),
            session
        )
        session.pump(now: nowNS)
    }

    private func handle(_ produced: [SessionEvent], _ session: Session) {
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
                if let output = pairing.handleReliableCtrl(message, now: nowNS) {
                    for reply in output.replies {
                        try? session.sendReliable(
                            reply, now: nowNS, hostMicroseconds: nowMicros
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

    /// Everything the host has sent since the last drain.
    func drain() -> [[UInt8]] {
        session?.pump(now: nowNS)
        defer { outbox.removeAll() }
        return outbox
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

    /// Shuttles datagrams both ways in 5 ms beats until `done` or `limit`.
    func run(
        _ client: BrowserControlSession,
        notes: inout [String],
        beats limit: Int = 400,
        until done: (BrowserControlSession) -> Bool
    ) {
        for _ in 0..<limit {
            if done(client) { return }
            for datagram in drain() {
                deliver(client.ingest(datagram: datagram, nowMicros: nowMicros), notes: &notes)
            }
            deliver(client.tick(nowMicros: nowMicros), notes: &notes)
            advance(microseconds: 5_000)
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
}
