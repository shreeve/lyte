// The client's Noise IK initiator over LyteWire.NoiseSession, plugged into
// the TransportCrypto seam so ReceiveDemux and TransportSender need no
// changes:
//
//   • config carries the host's pinned static public key (from pairing or
//     an operator-supplied key) and the host's address, because the
//     initiator speaks first.
//   • the handshake is LyteClientSession's ClientHandshakeInitiator (bare
//     CTRL carriage, verbatim message-1 retransmit, retry-challenge
//     answers) driven here over blocking datagram IO and the monotonic
//     clock — the same machine the browser drives.
//   • after Split, every payload both ways seals under the transport with
//     the exact envelope header bytes as AAD and the (chan, seq)
//     extended-counter discipline — all inside LyteWire.NoiseTransport;
//     this file only holds the state and locks.
//
// The socket is the endpoint's; the handshake needs it before the receive
// thread exists, so `HandshakingTransportCrypto` is the seam
// UdpReceiveEndpoint drives between bind and thread start, handing this
// object blocking datagram IO aimed at the configured host.

import LyteIO
import Foundation
import LyteCore
import LyteClientSession
import LyteWire

/// Blocking datagram IO for the pre-thread handshake window. The endpoint
/// implements it over the bound socket; tests implement it in-process.
public protocol NoiseHandshakeIO {
    /// Sends one datagram to the configured host tuple.
    func sendToHost(_ datagram: [UInt8]) throws
    /// Receives one datagram, nil on timeout.
    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]?
}

/// A TransportCrypto whose open step needs the socket (handshake over the
/// wire). The endpoint binds first, then calls `performHandshake`, then
/// starts the receive thread — `open()` becomes the post-hoc assertion
/// that the transport really exists before any payload is accepted.
public protocol HandshakingTransportCrypto: TransportCrypto {
    var hostAddress: String { get }
    var hostPort: UInt16 { get }
    func performHandshake(io: any NoiseHandshakeIO) throws
}

/// Test-only operation instrumentation. It runs inside the directional
/// critical sections so tests can prove opposite directions overlap and
/// same-direction mutations do not. Production instances have no probe.
final class NoiseTransportOperationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let rendezvousDirections: Bool
    private let holdUntil: TimeInterval
    private var activeSeals = 0
    private var activeUnseals = 0
    private(set) var maximumConcurrentSeals = 0
    private(set) var maximumConcurrentUnseals = 0
    private(set) var observedDirectionalOverlap = false

    init(rendezvousDirections: Bool = false, holdMilliseconds: Int = 0) {
        self.rendezvousDirections = rendezvousDirections
        self.holdUntil = TimeInterval(holdMilliseconds) / 1_000
    }

    func enteredSeal() {
        entered(isSeal: true)
    }

    func exitedSeal() {
        exited(isSeal: true)
    }

    func enteredUnseal() {
        entered(isSeal: false)
    }

    func exitedUnseal() {
        exited(isSeal: false)
    }

    private func entered(isSeal: Bool) {
        condition.lock()
        if isSeal {
            activeSeals += 1
            maximumConcurrentSeals = max(maximumConcurrentSeals, activeSeals)
        } else {
            activeUnseals += 1
            maximumConcurrentUnseals = max(maximumConcurrentUnseals, activeUnseals)
        }
        if activeSeals > 0, activeUnseals > 0 {
            observedDirectionalOverlap = true
            condition.broadcast()
        }
        if rendezvousDirections {
            let deadline = Date(timeIntervalSinceNow: 1)
            while !observedDirectionalOverlap, condition.wait(until: deadline) {}
        } else if holdUntil > 0 {
            _ = condition.wait(until: Date(timeIntervalSinceNow: holdUntil))
        }
        condition.unlock()
    }

    private func exited(isSeal: Bool) {
        condition.lock()
        if isSeal {
            activeSeals -= 1
        } else {
            activeUnseals -= 1
        }
        condition.unlock()
    }

    var snapshot: (
        directionalOverlap: Bool,
        maximumConcurrentSeals: Int,
        maximumConcurrentUnseals: Int
    ) {
        condition.lock()
        defer { condition.unlock() }
        return (
            observedDirectionalOverlap,
            maximumConcurrentSeals,
            maximumConcurrentUnseals)
    }
}

public final class NoiseTransportCrypto: HandshakingTransportCrypto, @unchecked Sendable {
    public let hostAddress: String
    public let hostPort: UInt16
    private let hostStaticPublicKey: [UInt8]
    private let staticKeys: NoiseKeyPair
    private let attempts: Int
    private let attemptTimeoutMilliseconds: Int

    // Handshake publication and diagnostics are brief state operations.
    // Transport mutation is direction-disjoint: each copy owns exactly
    // the direction used under its lock. This preserves Noise's nonce /
    // replay serialization without making send wait for receive.
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var sendTransport: NoiseTransport?
    private var receiveTransport: NoiseTransport?
    private var handshakeInProgress = false
    private var handshakeHash: [UInt8]?
    private var handshakeMilliseconds: Double?
    private var retryChallengesAnswered = 0
    private var operationProbe: NoiseTransportOperationProbe?

    /// - Parameters:
    ///   - hostStaticPublicKey: the host's pinned 32-byte X25519 static
    ///     (from the pinned-host store, or printed by lyte-host at start).
    ///   - staticKeys: the client's Noise static identity. nil mints a
    ///     throwaway pair for this connection — fine for debug harnesses,
    ///     but pairing and `--require-paired` reconnects need the
    ///     PERSISTENT identity here: the host pins/authenticates exactly
    ///     the static message 1 delivers.
    ///   - attempts/attemptTimeoutMilliseconds: the client-owned retry
    ///     timer — a lost message 1 or 2 meets a fresh attempt, and the
    ///     host answers each message 1 from fresh responder state.
    public init(
        hostAddress: String,
        hostPort: UInt16,
        hostStaticPublicKey: [UInt8],
        staticKeys: NoiseKeyPair? = nil,
        attempts: Int = 5,
        attemptTimeoutMilliseconds: Int = 1_000
    ) throws {
        guard hostStaticPublicKey.count == 32 else {
            throw TransportCryptoError.invalidHostKey(
                "host static public key must be 32 bytes, got \(hostStaticPublicKey.count)")
        }
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.hostStaticPublicKey = hostStaticPublicKey
        self.staticKeys = staticKeys ?? NoiseKeyPair.generate()
        self.attempts = attempts
        self.attemptTimeoutMilliseconds = attemptTimeoutMilliseconds
    }

    convenience init(
        hostAddress: String,
        hostPort: UInt16,
        hostStaticPublicKey: [UInt8],
        staticKeys: NoiseKeyPair? = nil,
        attempts: Int = 5,
        attemptTimeoutMilliseconds: Int = 1_000,
        operationProbe: NoiseTransportOperationProbe
    ) throws {
        try self.init(
            hostAddress: hostAddress,
            hostPort: hostPort,
            hostStaticPublicKey: hostStaticPublicKey,
            staticKeys: staticKeys,
            attempts: attempts,
            attemptTimeoutMilliseconds: attemptTimeoutMilliseconds)
        self.operationProbe = operationProbe
    }

    /// The static public key message 1 will present to the host.
    public var clientStaticPublicKey: [UInt8] { staticKeys.publicKey }

    /// The completed session's Noise handshake hash — the W6 pairing
    /// binding (sid). Nil until `performHandshake` succeeds.
    public var handshakeHashSnapshot: [UInt8]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handshakeHash
    }

    /// Parses the CLI's `--host-key` hex argument (64 hex digits,
    /// whitespace/0x tolerated).
    public static func parseKeyHex(_ hex: String) throws -> [UInt8] {
        var trimmed = hex.filter { !$0.isWhitespace }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            trimmed = String(trimmed.dropFirst(2))
        }
        guard trimmed.count == 64 else {
            throw TransportCryptoError.invalidHostKey(
                "expected 64 hex digits, got \(trimmed.count)")
        }
        guard let bytes = Hex.bytes(trimmed) else {
            throw TransportCryptoError.invalidHostKey("non-hex digit in key")
        }
        return bytes
    }

    public var modeDescription: String {
        let key = Hex.string(hostStaticPublicKey.prefix(4))
        let time = handshakeMillisecondsSnapshot.map {
            String(format: ", handshake %.1f ms", $0)
        } ?? ""
        return "Noise IK (host \(hostAddress):\(hostPort), pinned static \(key)…\(time))"
    }

    public var handshakeMillisecondsSnapshot: Double? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handshakeMilliseconds
    }

    /// Retry challenges (0x13) this dial answered with a 0x14
    /// resubmission — the W8 client leg's evidence counter.
    public var retryChallengesAnsweredSnapshot: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retryChallengesAnswered
    }

    /// The seam's contract: no payload before the transport exists. The
    /// endpoint calls `performHandshake` between bind and thread start;
    /// this only asserts it happened.
    public func open() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard handshakeHash != nil else {
            throw TransportCryptoError.handshakeFailed(
                "transport-open before the Noise handshake completed")
        }
    }

    // MARK: The IK handshake (initiator)

    public func performHandshake(io: any NoiseHandshakeIO) throws {
        stateLock.lock()
        let alreadyEstablished = handshakeHash != nil
        guard !alreadyEstablished, !handshakeInProgress else {
            stateLock.unlock()
            throw TransportCryptoError.handshakeFailed(
                alreadyEstablished ? "Noise handshake already completed"
                    : "Noise handshake already in progress")
        }
        handshakeInProgress = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            handshakeInProgress = false
            stateLock.unlock()
        }

        let started = SystemMonotonicClock.nowNanoseconds
        var initiator = try ClientHandshakeInitiator(
            hostStaticPublicKey: hostStaticPublicKey,
            clientStatic: staticKeys,
            retry: .init(
                attempts: attempts,
                intervalMicroseconds: UInt64(max(1, attemptTimeoutMilliseconds))
                    * 1_000))
        var lastFailure = "no response from \(hostAddress):\(hostPort) "
            + "after \(attempts) attempts"
        var datagramsReceived = 0
        try io.sendToHost(initiator.begin(
            nowMicros: SystemMonotonicClock.nowMicroseconds))
        while true {
            let now = SystemMonotonicClock.nowMicroseconds
            switch initiator.tick(nowMicros: now) {
            case .wait:
                break
            case .retransmit(let carriage):
                try io.sendToHost(carriage)
                continue
            case .exhausted:
                let counters = initiator.counters
                throw TransportCryptoError.handshakeFailed(
                    lastFailure + " [kernel accepted "
                        + "\(counters.message1Transmissions + counters.retryChallengesAnswered) sends; "
                        + "received \(datagramsReceived) datagrams: "
                        + "\(counters.retryChallengesAnswered) retry challenges answered, "
                        + "\(counters.otherDatagrams + counters.undecodableDatagrams) non-message-2, "
                        + "\(counters.rejectedMessage2) rejected message-2]")
            }
            let remainingMs = Int(
                (initiator.attemptDeadlineMicros &- now) / 1_000)
            guard let datagram = try io.receiveDatagram(
                timeoutMilliseconds: max(1, min(remainingMs, 100))
            ) else { continue }
            datagramsReceived += 1
            switch initiator.ingest(
                datagram[...], nowMicros: SystemMonotonicClock.nowMicroseconds
            ) {
            case .ignored:
                continue
            case .reply(let carriage):
                try io.sendToHost(carriage)
                stateLock.lock()
                retryChallengesAnswered += 1
                stateLock.unlock()
            case .rejectedMessage2(let error):
                lastFailure = "message 2 rejected: \(error)"
            case .established(let made):
                // Lock order is state → send → receive everywhere a
                // transition touches more than one domain. The state lock
                // publishes both directional copies and the handshake hash
                // as one atomic post-handshake state to every operation.
                stateLock.lock()
                sendLock.lock()
                receiveLock.lock()
                sendTransport = made
                receiveTransport = made
                handshakeHash = made.handshakeHash
                handshakeMilliseconds = Double(
                    SystemMonotonicClock.nowNanoseconds &- started) / 1e6
                receiveLock.unlock()
                sendLock.unlock()
                stateLock.unlock()
                return
            }
        }
    }

    // MARK: The transport seam

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        // The directional transport is published under every lock at
        // once, so its presence alone proves the handshake completed.
        receiveLock.lock()
        defer { receiveLock.unlock() }
        guard receiveTransport != nil else {
            throw TransportCryptoError.handshakeFailed("unseal before handshake")
        }
        operationProbe?.enteredUnseal()
        defer { operationProbe?.exitedUnseal() }
        // The AEAD's fresh buffer IS the result — no re-slice, no second
        // copy at the demux. Failures surface as the Wire transport's own
        // typed error (replay, stale, authentication): a flood of junk
        // datagrams costs no per-failure string.
        return try receiveTransport!.unseal(
            wirePayload: wirePayload, aad: aad, envelope: envelope)
    }

    public func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard sendTransport != nil else {
            throw TransportCryptoError.handshakeFailed("seal before handshake")
        }
        operationProbe?.enteredSeal()
        defer { operationProbe?.exitedSeal() }
        return try sendTransport!.seal(
            plaintext: plaintext, aad: aad, envelope: envelope)
    }
}
