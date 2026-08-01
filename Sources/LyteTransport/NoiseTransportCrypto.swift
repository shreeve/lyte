// The client's Noise leg (CL-1's noisePending slice, closed): the
// initiator side of W5's Noise IK over LyteWire.NoiseSession, plugged
// into the TransportCrypto seam so ReceiveDemux/TransportSender need no
// changes — the exact mirror of the host's HS-7 Session discipline:
//
//   • config carries the host's pinned static public key (hex-argued for
//     now; pairing UX — W6 PIN-PAKE — is H1's slice) and the host's
//     address, because the initiator speaks first.
//   • the handshake rides the promoted CTRL carriage: message 1 leaves as
//     one CTRL datagram whose payload is 0x05 ‖ raw IK message 1,
//     UNSEALED (self-protecting; version byte inside per W5); message 2
//     comes back as 0x06 ‖ raw message 2. The client owns the retry
//     timer — a fresh NoiseSession per attempt, so a stale message 2
//     can never complete a newer attempt.
//   • after Split, every payload both ways seals under the transport
//     with the exact envelope header bytes as AAD and the (chan, seq)
//     extended-counter ROC discipline — all inside
//     LyteWire.NoiseTransport; this file only holds the state and lock.
//
// The socket is the endpoint's; the handshake needs it before the
// receive thread exists, so `HandshakingTransportCrypto` is the seam
// UdpReceiveEndpoint drives between bind and thread start, handing this
// object blocking datagram IO aimed at the configured host.

import Foundation
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
    private var established = false
    private var handshakeInProgress = false
    private var handshakeHash: [UInt8]?
    private var handshakeMilliseconds: Double?
    private var retryChallengesAnswered = 0
    private var operationProbe: NoiseTransportOperationProbe?

    /// - Parameters:
    ///   - hostStaticPublicKey: the host's pinned 32-byte X25519 static
    ///     (printed by lyte-host at start; hand-carried until W6 pairing).
    ///   - staticKeys: the client's Noise static identity. nil mints a
    ///     throwaway pair for this connection — fine for debug harnesses,
    ///     but pairing (CL-6) and `--require-paired` reconnects need the
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
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else {
                throw TransportCryptoError.invalidHostKey("non-hex digit in key")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public var modeDescription: String {
        let key = hostStaticPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
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
        guard established else {
            throw TransportCryptoError.handshakeFailed(
                "transport-open before the Noise handshake completed")
        }
    }

    // MARK: The IK handshake (initiator)

    public func performHandshake(io: any NoiseHandshakeIO) throws {
        stateLock.lock()
        guard !established, !handshakeInProgress else {
            stateLock.unlock()
            throw TransportCryptoError.handshakeFailed(
                established ? "Noise handshake already completed"
                    : "Noise handshake already in progress")
        }
        handshakeInProgress = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            handshakeInProgress = false
            stateLock.unlock()
        }

        let started = DispatchTime.now()
        var lastFailure = "no response from \(hostAddress):\(hostPort) "
            + "after \(attempts) attempts"
        var sendsAccepted = 0
        var datagramsReceived = 0
        var retryChallengesReceived = 0
        var nonMessage2Datagrams = 0
        var rejectedMessage2Datagrams = 0
        // ONE session, ONE message 1, retransmitted verbatim across the
        // retry window (classic handshake-retransmit semantics). The
        // first live run proved why: a Wi-Fi host waking from power save
        // can deliver message 1 seconds late — the host completes and
        // starts streaming against THAT message, and a client that
        // already rolled to a fresh ephemeral can never read the answer
        // (the host, established, drops all later message 1s). Resending
        // the same bytes keeps every host answer valid for this
        // transcript, however late it lands.
        var session = try NoiseSession(
            role: .initiator,
            staticKeys: staticKeys,
            remoteStaticPublicKey: hostStaticPublicKey
        )
        let message1 = try session.writeMessage1()
        for _ in 0..<attempts {
            try io.sendToHost(encodeCarriage(
                type: CtrlMessageType.noiseHandshake1, message: message1))
            sendsAccepted += 1

            let deadline = DispatchTime.now()
                + .milliseconds(attemptTimeoutMilliseconds)
            while true {
                let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                guard nowNanoseconds < deadline.uptimeNanoseconds else { break }
                let remaining = Int(
                    (deadline.uptimeNanoseconds - nowNanoseconds) / 1_000_000)
                guard let datagram = try io.receiveDatagram(
                    timeoutMilliseconds: max(1, min(remaining, 100))
                ) else { continue }
                datagramsReceived += 1
                // W8, the client leg: a flooded host answers message 1
                // with a stateless RetryChallenge (0x13) instead of
                // spending crypto. The answer is the SAME message 1,
                // byte-verbatim, wrapped with the cookie echoed in a
                // RetryHandshake1 (0x14) — the retransmit rule (0443beb)
                // makes the verbatim echo free, and the cookie's MAC
                // over exactly those bytes makes it mandatory. Answering
                // does not consume an attempt: the challenge IS the
                // host's liveness, and the resubmission stays inside
                // this attempt's window.
                if let challenge = decodeRetryChallenge(datagram) {
                    retryChallengesReceived += 1
                    let resubmission: [UInt8]
                    do {
                        resubmission = try RetryHandshake1(
                            echoing: challenge, message1: message1
                        ).encode()
                    } catch {
                        lastFailure = "retry challenge unanswerable: \(error)"
                        continue
                    }
                    try io.sendToHost(encodeCarriage(payload: resubmission))
                    stateLock.lock()
                    retryChallengesAnswered += 1
                    stateLock.unlock()
                    continue
                }
                guard let message2 = decodeCarriage(datagram) else {
                    nonMessage2Datagrams += 1
                    // Not message 2 (a reordered sealed datagram, noise
                    // on the port) — FEC absorbs early shard loss;
                    // message 2 precedes them in the host's control FIFO.
                    continue
                }
                do {
                    _ = try session.readMessage2(message2[...])
                } catch {
                    rejectedMessage2Datagrams += 1
                    lastFailure = "message 2 rejected: \(error)"
                    continue
                }
                let made = try session.makeTransport()
                // Lock order is state → send → receive everywhere a
                // transition touches more than one domain. Publishing
                // `established` last makes the two directional copies an
                // atomic post-handshake state to every operation.
                stateLock.lock()
                sendLock.lock()
                receiveLock.lock()
                sendTransport = made
                receiveTransport = made
                handshakeHash = made.handshakeHash
                handshakeMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds
                        &- started.uptimeNanoseconds) / 1e6
                established = true
                receiveLock.unlock()
                sendLock.unlock()
                stateLock.unlock()
                return
            }
        }
        throw TransportCryptoError.handshakeFailed(
            lastFailure + " [kernel accepted \(sendsAccepted) sends; "
                + "received \(datagramsReceived) datagrams: "
                + "\(retryChallengesReceived) retry challenges, "
                + "\(nonMessage2Datagrams) non-message-2, "
                + "\(rejectedMessage2Datagrams) rejected message-2]")
    }

    /// One CTRL carriage datagram: bare envelope (chan 0, seq 0, client
    /// monotonic µs), payload = type byte ‖ raw Noise message, unsealed.
    private func encodeCarriage(type: UInt8, message: [UInt8]) -> [UInt8] {
        encodeCarriage(payload: [type] + message)
    }

    /// The same bare pre-transport carriage for an already-typed payload
    /// (the 0x14 retry resubmission carries its own type byte).
    private func encodeCarriage(payload: [UInt8]) -> [UInt8] {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: DispatchTime.now().uptimeNanoseconds / 1_000,
            fec: 0
        )
        // Handshake payloads (≤ 26 + 122 B with the cookie) cannot
        // breach any budget under a bare envelope.
        return try! envelope.encode(payload: payload)
    }

    /// The raw Noise message 2 when `datagram` is its carriage, else nil.
    private func decodeCarriage(_ datagram: [UInt8]) -> [UInt8]? {
        guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
              envelope.channel == .ctrl,
              payload.first == CtrlMessageType.noiseHandshake2
        else { return nil }
        return Array(payload.dropFirst())
    }

    /// The typed RetryChallenge when `datagram` carries one (bare CTRL,
    /// 0x13), else nil. Malformed challenges are ignored, not fatal —
    /// the attempt window's retransmit draws a fresh one.
    private func decodeRetryChallenge(_ datagram: [UInt8]) -> RetryChallenge? {
        guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
              envelope.channel == .ctrl,
              payload.first == CtrlMessageType.retryChallenge
        else { return nil }
        return try? RetryChallenge.decode(payload)
    }

    // MARK: The transport seam

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        stateLock.lock()
        let ready = established
        stateLock.unlock()
        guard ready else {
            throw TransportCryptoError.handshakeFailed("unseal before handshake")
        }
        receiveLock.lock()
        defer { receiveLock.unlock() }
        guard receiveTransport != nil else {
            throw TransportCryptoError.handshakeFailed("unseal before handshake")
        }
        operationProbe?.enteredUnseal()
        defer { operationProbe?.exitedUnseal() }
        do {
            // The AEAD's fresh buffer IS the result — no re-slice, no
            // second copy at the demux.
            return try receiveTransport!.unseal(
                wirePayload: wirePayload, aad: aad, envelope: envelope)
        } catch {
            throw TransportCryptoError.unsealFailed(String(describing: error))
        }
    }

    public func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        stateLock.lock()
        let ready = established
        stateLock.unlock()
        guard ready else {
            throw TransportCryptoError.handshakeFailed("seal before handshake")
        }
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
