// PairingResponderService (HS-9): the host's half of PIN pairing —
// drives LyteWire's PairingPakeResponder (W6 CPace) over the HS-8
// reliable-CTRL seam, and owns the flood posture the plan assigns the
// shell: an online-guess budget and an attempt throttle.
//
// Why guesses are counted at share-B issuance, not at a failed confirm:
// the 0x0C message carries the responder's confirmation tag Tb (the W6
// layout — the client learns wrong-PIN one message early). A client
// holding a PIN guess can therefore verify it against Tb and abandon
// the run without ever sending a wrong 0x0D. Every share B issued IS
// one online PIN test, so that is what spends an attempt. A low-order
// share (0x0E invalid-share) spends none — it aborts before any tag
// math and teaches the sender nothing about the PIN — but it still
// arms the throttle.
//
// When the budget is spent the PIN BURNS: the service goes silent on
// further pairing traffic (no oracle, no reply) and the shell exits
// pairing mode loudly. A burned PIN is never resurrected — the
// operator mints a fresh one by restarting pairing mode. With 6-digit
// PINs and a 3-guess budget an online attacker's odds are 3 in 10⁶
// per displayed PIN, and the CPace transcript yields nothing
// offline-testable (the draft's quantum-annoying property).
//
// Sans-IO in the house style: no clock (entry points take `now`,
// monotonic ns), no sockets, no persistence. Replies come back as
// encoded CTRL bodies for Session.sendReliable; pinning the paired
// static (the keystore write) is the shell's move on `.paired`.

import LyteWire

public final class PairingResponderService {
    public struct Config: Sendable {
        /// Share-B issuances (online PIN guesses) before the PIN burns.
        public var maxAttempts: Int
        /// Minimum ns between accepted share-A openings — one guess per
        /// second by default, so even the in-session peer cannot
        /// machine-gun the budget.
        public var minAttemptIntervalNS: UInt64

        public init(
            maxAttempts: Int = 3,
            minAttemptIntervalNS: UInt64 = 1_000_000_000
        ) {
            self.maxAttempts = maxAttempts
            self.minAttemptIntervalNS = minAttemptIntervalNS
        }
    }

    /// What the shell must react to. Values in delivery order, loud on
    /// purpose — the gate's "wrong PIN fails loudly" is these lines.
    public enum Event: Equatable, Sendable {
        /// A share B left: one online guess spent.
        case attemptOpened(attempt: Int, of: Int)
        /// The client's confirmation verified — pin this static now.
        case paired(clientStaticPublicKey: [UInt8])
        /// A typed 0x0E reject left (wrong PIN / tampered binding, or a
        /// low-order share). One reason per wire rule — no oracle.
        case rejected(PairingRejectReason, attemptsRemaining: Int)
        /// The client sent 0x0E — it saw Tb mismatch its own PIN entry
        /// and aborted. The attempt was already spent at share B.
        case clientAborted(PairingRejectReason)
        /// A share A arrived inside the throttle window: dropped, no
        /// reply, no attempt spent.
        case throttled
        /// The guess budget is spent. Emitted exactly once; everything
        /// after is wire silence.
        case pinBurned
        /// Undecodable or out-of-order pairing bytes: dropped silently.
        case malformed
    }

    public struct Output: Equatable, Sendable {
        /// Encoded CTRL bodies for `Session.sendReliable`, in order.
        public var replies: [[UInt8]] = []
        public var events: [Event] = []

        public init(replies: [[UInt8]] = [], events: [Event] = []) {
            self.replies = replies
            self.events = events
        }
    }

    private let pin: [UInt8]
    private let hostStaticPublicKey: [UInt8]
    private let config: Config

    /// The carrying session's identity — set at establishment, the
    /// PairingPake binding inputs (§8.2). A re-handshake replaces it
    /// and aborts any in-flight run: the sid changed under it.
    private var binding: (clientStatic: [UInt8], handshakeHash: [UInt8])?
    /// The in-flight CPace run, between share B and the confirm.
    private var responder: PairingPakeResponder?
    private var attemptsUsed = 0
    private var lastOpenNS: UInt64?
    private var burned = false

    /// Set once, on success. The shell pins exactly this.
    public private(set) var pairedClientStaticPublicKey: [UInt8]?

    public var isPaired: Bool { pairedClientStaticPublicKey != nil }
    public var isBurned: Bool { burned }

    /// - Parameters:
    ///   - pin: the displayed PIN's ASCII bytes (digits only — trivially
    ///     its own RFC 8265 profile; both ends must feed CPace the same
    ///     bytes).
    ///   - hostStaticPublicKey: our Noise static public key — the CI's
    ///     second identity, the key the client pins on success.
    public init(
        pin: [UInt8],
        hostStaticPublicKey: [UInt8],
        config: Config = Config()
    ) {
        self.pin = pin
        self.hostStaticPublicKey = hostStaticPublicKey
        self.config = config
    }

    /// Call on every `.handshakeCompleted`: the pairing run binds to
    /// THIS session's transcript and statics. Guess accounting and the
    /// throttle survive reconnects on purpose — a client cannot refill
    /// its budget by re-handshaking.
    public func sessionEstablished(
        clientStaticPublicKey: [UInt8], noiseHandshakeHash: [UInt8]
    ) {
        binding = (clientStaticPublicKey, noiseHandshakeHash)
        responder = nil
    }

    /// Feeds one ARQ-delivered CTRL message. Returns nil when the type
    /// byte is not pairing's (0x0B–0x0E) — the shell dispatches those
    /// elsewhere. Never throws: hostile bytes become events.
    public func handleReliableCtrl(
        _ message: [UInt8], now: UInt64
    ) -> Output? {
        switch message.first {
        case CtrlMessageType.pairingShareA:
            return openAttempt(message, now: now)
        case CtrlMessageType.pairingConfirm:
            return confirmAttempt(message)
        case CtrlMessageType.pairingReject:
            return clientReject(message)
        case CtrlMessageType.pairingShareB:
            // Host-role message arriving at the host: hostile or
            // confused. Silence either way.
            return Output(events: [.malformed])
        default:
            return nil
        }
    }

    // MARK: The three message handlers

    private func openAttempt(_ message: [UInt8], now: UInt64) -> Output {
        guard !isPaired else { return Output() }
        if burned { return Output() } // announced once; silence after
        guard let binding else {
            // ARQ deliveries only exist post-establishment, so a
            // missing binding is a shell wiring bug — stay silent on
            // the wire, loud in the event.
            return Output(events: [.malformed])
        }
        if attemptsUsed >= config.maxAttempts {
            burned = true
            return Output(events: [.pinBurned])
        }
        if let last = lastOpenNS,
           now &- last < config.minAttemptIntervalNS {
            return Output(events: [.throttled])
        }
        guard let shareA = try? PairingShareA.decode(message) else {
            return Output(events: [.malformed])
        }
        // A fresh share A abandons any run awaiting its confirm; that
        // run's guess was spent when its share B left.
        lastOpenNS = now
        do {
            var fresh = try PairingPakeResponder(
                pin: pin,
                clientStaticPublicKey: binding.clientStatic,
                hostStaticPublicKey: hostStaticPublicKey,
                noiseHandshakeHash: binding.handshakeHash
            )
            let shareB = try fresh.receiveShareA(shareA)
            responder = fresh
            attemptsUsed += 1
            return Output(
                replies: [try shareB.encode()],
                events: [.attemptOpened(
                    attempt: attemptsUsed, of: config.maxAttempts
                )]
            )
        } catch PairingPakeError.invalidPeerShare {
            // Aborted before any tag math: no PIN information left this
            // host, so no guess is spent — but the typed reject is owed
            // (the wire's loud-without-oracle rule) and the throttle
            // stays armed.
            responder = nil
            return Output(
                replies: [PairingReject(reason: .invalidShare).encode()],
                events: [.rejected(
                    .invalidShare,
                    attemptsRemaining: config.maxAttempts - attemptsUsed
                )]
            )
        } catch {
            responder = nil
            return Output(events: [.malformed])
        }
    }

    private func confirmAttempt(_ message: [UInt8]) -> Output {
        guard !isPaired, !burned else { return Output() }
        guard var run = responder,
              let confirm = try? PairingConfirm.decode(message)
        else {
            return Output(events: [.malformed])
        }
        responder = nil
        do {
            try run.receiveConfirm(confirm)
            let client = run.result!.peerStaticPublicKeyToPin
            pairedClientStaticPublicKey = client
            return Output(events: [.paired(clientStaticPublicKey: client)])
        } catch {
            // Wrong PIN or tampered binding — one wire reason for both.
            var events: [Event] = [.rejected(
                .confirmationFailed,
                attemptsRemaining: config.maxAttempts - attemptsUsed
            )]
            if attemptsUsed >= config.maxAttempts {
                burned = true
                events.append(.pinBurned)
            }
            return Output(
                replies: [
                    PairingReject(reason: .confirmationFailed).encode()
                ],
                events: events
            )
        }
    }

    private func clientReject(_ message: [UInt8]) -> Output {
        guard !isPaired, !burned else { return Output() }
        guard let reject = try? PairingReject.decode(message) else {
            return Output(events: [.malformed])
        }
        responder = nil
        var events: [Event] = [.clientAborted(reject.reason)]
        if attemptsUsed >= config.maxAttempts {
            burned = true
            events.append(.pinBurned)
        }
        return Output(events: events)
    }
}
