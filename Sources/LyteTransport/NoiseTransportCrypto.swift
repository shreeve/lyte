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

public final class NoiseTransportCrypto: HandshakingTransportCrypto, @unchecked Sendable {
    public let hostAddress: String
    public let hostPort: UInt16
    private let hostStaticPublicKey: [UInt8]
    private let attempts: Int
    private let attemptTimeoutMilliseconds: Int

    private let lock = NSLock()
    private var transport: NoiseTransport?
    private var handshakeMilliseconds: Double?

    /// - Parameters:
    ///   - hostStaticPublicKey: the host's pinned 32-byte X25519 static
    ///     (printed by lyte-host at start; hand-carried until W6 pairing).
    ///   - attempts/attemptTimeoutMilliseconds: the client-owned retry
    ///     timer — a lost message 1 or 2 meets a fresh attempt, and the
    ///     host answers each message 1 from fresh responder state.
    public init(
        hostAddress: String,
        hostPort: UInt16,
        hostStaticPublicKey: [UInt8],
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
        self.attempts = attempts
        self.attemptTimeoutMilliseconds = attemptTimeoutMilliseconds
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
        lock.lock()
        defer { lock.unlock() }
        return handshakeMilliseconds
    }

    /// The seam's contract: no payload before the transport exists. The
    /// endpoint calls `performHandshake` between bind and thread start;
    /// this only asserts it happened.
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }
        guard transport != nil else {
            throw TransportCryptoError.handshakeFailed(
                "transport-open before the Noise handshake completed")
        }
    }

    // MARK: The IK handshake (initiator)

    public func performHandshake(io: any NoiseHandshakeIO) throws {
        let started = DispatchTime.now()
        var lastFailure = "no response from \(hostAddress):\(hostPort) "
            + "after \(attempts) attempts"
        for _ in 0..<attempts {
            // Fresh session per attempt: a stale message 2 (from a lost
            // earlier exchange) fails authentication against the new
            // ephemeral instead of completing the wrong transcript.
            var session = try NoiseSession(
                role: .initiator,
                staticKeys: NoiseKeyPair.generate(),
                remoteStaticPublicKey: hostStaticPublicKey
            )
            let message1 = try session.writeMessage1()
            try io.sendToHost(encodeCarriage(
                type: CtrlMessageType.noiseHandshake1, message: message1))

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
                guard let message2 = decodeCarriage(datagram) else {
                    // Not message 2 (a reordered sealed datagram, noise
                    // on the port) — FEC absorbs early shard loss;
                    // message 2 precedes them in the host's control FIFO.
                    continue
                }
                do {
                    _ = try session.readMessage2(message2[...])
                } catch {
                    lastFailure = "message 2 rejected: \(error)"
                    continue
                }
                let made = try session.makeTransport()
                lock.lock()
                transport = made
                handshakeMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds
                        &- started.uptimeNanoseconds) / 1e6
                lock.unlock()
                return
            }
        }
        throw TransportCryptoError.handshakeFailed(lastFailure)
    }

    /// One CTRL carriage datagram: bare envelope (chan 0, seq 0, client
    /// monotonic µs), payload = type byte ‖ raw Noise message, unsealed.
    private func encodeCarriage(type: UInt8, message: [UInt8]) -> [UInt8] {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: DispatchTime.now().uptimeNanoseconds / 1_000,
            fec: 0
        )
        // A 66 B payload under a bare envelope cannot breach any budget.
        return try! envelope.encode(payload: [type] + message)
    }

    /// The raw Noise message 2 when `datagram` is its carriage, else nil.
    private func decodeCarriage(_ datagram: [UInt8]) -> [UInt8]? {
        guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
              envelope.channel == .ctrl,
              payload.first == CtrlMessageType.noiseHandshake2
        else { return nil }
        return Array(payload.dropFirst())
    }

    // MARK: The transport seam

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> ArraySlice<UInt8> {
        lock.lock()
        defer { lock.unlock() }
        guard transport != nil else {
            throw TransportCryptoError.handshakeFailed("unseal before handshake")
        }
        do {
            let plaintext = try transport!.unseal(
                wirePayload: wirePayload, aad: aad, envelope: envelope)
            return plaintext[...]
        } catch {
            throw TransportCryptoError.unsealFailed(String(describing: error))
        }
    }

    public func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard transport != nil else {
            throw TransportCryptoError.handshakeFailed("seal before handshake")
        }
        return try transport!.seal(
            plaintext: plaintext, aad: aad, envelope: envelope)
    }
}
