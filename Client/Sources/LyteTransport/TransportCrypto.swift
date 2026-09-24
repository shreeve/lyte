// The transport crypto seam: the exact envelope header bytes are the AAD,
// and the envelope's (chan, seq) feed the nonce.

import LyteClientSession
import LyteWire

public enum TransportCryptoError: Error, Equatable, Sendable {
    /// Not a 32-byte hex X25519 public key.
    case invalidHostKey(String)
    /// The Noise IK handshake could not run or was misused (a second
    /// handshake, transport used before open). An unanswered handshake is
    /// `HandshakeExhausted`.
    case handshakeFailed(String)
    /// A payload was refused by a crypto seam without a typed error of
    /// its own. The Noise seam rethrows the Wire transport's typed error.
    case unsealFailed(String)
}

/// Every message-1 attempt's window passed without a session: the host
/// stayed silent, or everything that came back from its address failed to
/// read (stale or forged). A restarting host looks exactly like this, so a
/// dial loop may retry it; the counters say what came back.
public struct HandshakeExhausted: Error, Equatable, Sendable,
    CustomStringConvertible
{
    public var host: String
    public var port: UInt16
    public var counters: ClientHandshakeInitiator.Counters
    /// Why the last message 2 that came back failed to read, if one did.
    public var lastRejection: String?

    public init(
        host: String, port: UInt16,
        counters: ClientHandshakeInitiator.Counters,
        lastRejection: String? = nil
    ) {
        self.host = host
        self.port = port
        self.counters = counters
        self.lastRejection = lastRejection
    }

    /// Datagrams that came back from the host's address, of every kind.
    public var datagramsReceived: UInt64 {
        counters.retryChallengesAnswered + counters.malformedRetryChallenges
            + counters.retryChallengesIgnored + counters.rejectedMessage2 + counters.undecodableDatagrams
            + counters.otherDatagrams
    }

    public var description: String {
        let lead = lastRejection.map { "message 2 rejected: \($0)" }
            ?? "no response from \(host):\(port) after "
                + "\(counters.message1Transmissions) attempts"
        return lead + " [kernel accepted "
            + "\(counters.message1Transmissions + counters.retryChallengesAnswered) sends; "
            + "received \(datagramsReceived) datagrams: "
            + "\(counters.retryChallengesAnswered) retry challenges answered, "
            + "\(counters.otherDatagrams + counters.undecodableDatagrams) non-message-2, "
            + "\(counters.rejectedMessage2) rejected message-2]"
    }
}

/// Both directions of one transport session's crypto. `open()` must
/// complete before any payload is accepted.
public protocol TransportCrypto: Sendable {
    /// Human-readable mode label for logs and the CLI banner.
    var modeDescription: String { get }

    /// Transport-open. Throws if the session cannot be established.
    func open() throws

    /// Unseals one received payload. `aad` is the exact header bytes as
    /// received; `envelope` carries the nonce material.
    func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8]

    /// Seals one outbound shard; `aad` is the exact header bytes that will
    /// precede it. Returns ciphertext + authentication tag.
    func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8]
}
