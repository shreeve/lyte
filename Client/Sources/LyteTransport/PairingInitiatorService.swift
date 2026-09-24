// The thread-safe shell over LyteClientSession's ClientPairing: the
// pairing flow drives `start()` from its own thread and
// `handleReliableCtrl` from the receive thread.

import Foundation
import LyteClientSession
import LyteWire

public final class PairingInitiatorService: @unchecked Sendable {
    public typealias Event = ClientPairing.Event
    public typealias Output = ClientPairing.Output

    private let lock = NSLock()
    private var pairing: ClientPairing

    /// See `ClientPairing.init`: the statics and handshake hash must be the
    /// carrying Noise session's, or confirmation fails by design.
    public init(
        pin: [UInt8],
        clientStaticPublicKey: [UInt8],
        hostStaticPublicKey: [UInt8],
        noiseHandshakeHash: [UInt8]
    ) throws {
        pairing = try ClientPairing(
            pin: pin,
            clientStaticPublicKey: clientStaticPublicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: noiseHandshakeHash)
    }

    /// Set once, on success — the static the shell pins.
    public var pairedHostStaticPublicKey: [UInt8]? {
        lock.withLock { pairing.pairedHostStaticPublicKey }
    }

    public var isTerminal: Bool { lock.withLock { pairing.isTerminal } }

    public func start() throws -> [UInt8] {
        try lock.withLock { try pairing.start() }
    }

    public func handleReliableCtrl(_ message: [UInt8]) -> Output? {
        lock.withLock { pairing.handleReliableCtrl(message) }
    }
}
