// The client's half of PIN pairing, IO-free: drives LyteWire's
// PairingPakeInitiator (CPace) over the reliable CTRL stream. The mirror
// of the host's PairingResponderService, with the client's smaller duties
// — no guess budget or throttle (those defend the PIN's owner, the host),
// just the run's lifecycle and the wire's no-oracle rules:
//
//   • share A (0x0B) opens the run; share B (0x0C) carries the host's
//     confirmation tag Tb, so a wrong PIN is learned here, one message
//     early — the client aborts with a typed 0x0E and never sends a
//     confirm the host would have to refuse.
//   • wrong PIN and tampered binding are deliberately one event
//     (`pinMismatch` = PairingPakeError.confirmationFailed): the CPace
//     binding makes them indistinguishable by design, and surfacing a
//     difference would invent an oracle the wire refuses to be.
//   • the machine is dead after any terminal event — a retry is a new
//     machine on a new Noise session (fresh sid), matching the host's
//     fresh-responder-per-share-A discipline.
//
// Replies come back as encoded CTRL bodies for the shell's reliable
// stream; pinning the host static is the shell's move on `.paired`.

import LyteWire

public struct ClientPairing: Sendable {
    /// What the shell must react to, in delivery order.
    public enum Event: Equatable, Sendable {
        /// The host's tag verified — pin this static now. The key is the
        /// same one this session dialed; pairing's confirmation is what
        /// promotes it from trust-on-first-use to trusted.
        case paired(hostStaticPublicKey: [UInt8])
        /// Share B's tag failed against OUR pin entry: wrong PIN (or a
        /// tampered session — indistinguishable on purpose). A typed
        /// 0x0E reject went back; the run is dead.
        case pinMismatch
        /// Share B carried a low-order point (G.I abort, draft §7.2).
        /// A typed 0x0E went back; the run is dead.
        case invalidShare
        /// The host sent 0x0E: our guess was spent host-side (wrong
        /// PIN), the PIN burned, or our share was refused. The run is
        /// dead.
        case hostRejected(PairingRejectReason)
        /// Undecodable or out-of-order pairing bytes: dropped silently.
        case malformed
    }

    public struct Output: Equatable, Sendable {
        /// Encoded CTRL bodies for the reliable ordered stream, in order.
        public var replies: [[UInt8]] = []
        public var events: [Event] = []

        public init(replies: [[UInt8]] = [], events: [Event] = []) {
            self.replies = replies
            self.events = events
        }
    }

    private enum State {
        case idle
        case awaitingShareB
        case complete
        case failed
    }

    private var pake: PairingPakeInitiator
    private var state: State = .idle

    /// Set once, on success — the static the shell pins.
    public var pairedHostStaticPublicKey: [UInt8]? {
        pake.result?.peerStaticPublicKeyToPin
    }

    public var isPaired: Bool { pairedHostStaticPublicKey != nil }

    /// Terminal (success or failure) — the shell can stop waiting once
    /// this is true AND its reliable endpoint is quiescent (the confirm
    /// must be acknowledged before "paired" is honest end to end).
    public var isTerminal: Bool {
        state == .complete || state == .failed
    }

    /// - Parameters:
    ///   - pin: the PIN the operator read off the host's console, as
    ///     entered — digits' ASCII bytes (both ends feed CPace the same
    ///     trivial RFC 8265 profile).
    ///   - clientStaticPublicKey / hostStaticPublicKey: the two statics
    ///     this run decides to pin — MUST be the same keys the carrying
    ///     Noise session used, or confirmation fails (that is the
    ///     binding working, not a bug).
    ///   - noiseHandshakeHash: the carrying session's transcript hash
    ///     (sid — the §8.2 binding).
    public init(
        pin: [UInt8],
        clientStaticPublicKey: [UInt8],
        hostStaticPublicKey: [UInt8],
        noiseHandshakeHash: [UInt8]
    ) throws {
        pake = try PairingPakeInitiator(
            pin: pin,
            clientStaticPublicKey: clientStaticPublicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: noiseHandshakeHash
        )
    }

    /// Opens the run: the encoded 0x0B share A for the reliable ordered
    /// stream. Callable exactly once.
    public mutating func start() throws -> [UInt8] {
        guard state == .idle else {
            throw PairingPakeError.invalidState
        }
        let shareA = try pake.makeShareA().encode()
        state = .awaitingShareB
        return shareA
    }

    /// Feeds one ARQ-delivered CTRL message. Returns nil when the type
    /// byte is not pairing's (0x0B–0x0E) — the shell dispatches those
    /// elsewhere. Never throws: hostile bytes become events.
    public mutating func handleReliableCtrl(_ message: [UInt8]) -> Output? {
        switch message.first {
        case CtrlMessageType.pairingShareB:
            return shareBArrived(message)
        case CtrlMessageType.pairingReject:
            return hostReject(message)
        case CtrlMessageType.pairingShareA, CtrlMessageType.pairingConfirm:
            // Client-role messages arriving at the client: hostile or
            // confused. Silence either way.
            return Output(events: [.malformed])
        default:
            return nil
        }
    }

    // MARK: The two message handlers

    private mutating func shareBArrived(_ message: [UInt8]) -> Output {
        guard state == .awaitingShareB else {
            // Late duplicate after completion/failure: the run already
            // spoke its verdict; stay silent.
            return Output()
        }
        guard let shareB = try? PairingShareB.decode(message) else {
            return Output(events: [.malformed])
        }
        do {
            let confirm = try pake.receiveShareB(shareB)
            let host = pake.result!.peerStaticPublicKeyToPin
            state = .complete
            return Output(
                replies: [try confirm.encode()],
                events: [.paired(hostStaticPublicKey: host)]
            )
        } catch PairingPakeError.invalidPeerShare {
            state = .failed
            return Output(
                replies: [PairingReject(reason: .invalidShare).encode()],
                events: [.invalidShare]
            )
        } catch {
            // confirmationFailed: our PIN entry disagreed (or the
            // binding was tampered with). One wire reason for both.
            state = .failed
            return Output(
                replies: [
                    PairingReject(reason: .confirmationFailed).encode()
                ],
                events: [.pinMismatch]
            )
        }
    }

    private mutating func hostReject(_ message: [UInt8]) -> Output {
        guard state == .awaitingShareB else { return Output() }
        guard let reject = try? PairingReject.decode(message) else {
            return Output(events: [.malformed])
        }
        state = .failed
        return Output(events: [.hostRejected(reject.reason)])
    }
}
