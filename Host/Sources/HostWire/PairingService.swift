// PairingResponderService: the host's half of PIN pairing. It drives
// LyteWire's PairingPakeResponder (CPace) over reliable CTRL and owns the
// flood posture: an online-guess budget and an attempt throttle.
//
// Guesses are counted at share-B issuance, not at a failed confirm: 0x0C
// carries the responder's confirmation tag Tb, so a client can test a PIN
// guess against Tb and abandon the run without sending a wrong 0x0D.
// Every share B issued IS one online PIN test. A low-order share
// (0x0E invalid-share) spends no attempt — it aborts before any tag math
// and teaches nothing about the PIN — but still arms the throttle.
//
// When the budget is spent the PIN BURNS: the service goes silent on
// further pairing traffic (no oracle) and is never resurrected; the
// operator restarts pairing mode for a fresh PIN. It burns the moment no
// run that could still succeed remains: the last guess's run fails, or is
// abandoned (a newer share A, a re-handshake, or the session's end). With 6-digit PINs and
// 3 guesses an online attacker's odds are 3 in 10⁶ per displayed PIN, and
// the CPace transcript yields nothing offline-testable.
//
// Sans-IO: entry points take `now` (monotonic ns). Replies are encoded
// CTRL bodies for Session.sendReliable; pinning the paired static is the
// shell's move on `.paired`.

import LyteWire

public final class PairingResponderService {
    /// A fresh zero-padded 6-digit pairing PIN. Pass a CSPRNG in
    /// production.
    public static func mintPin(
        using rng: inout some RandomNumberGenerator
    ) -> String {
        let digits = String(rng.next(upperBound: UInt32(1_000_000)))
        let padding = PairingPin.digitCount - digits.count
        return String(repeating: "0", count: padding) + digits
    }

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

    /// What the shell must react to, in delivery order.
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

    /// The carrying session's PairingPake binding inputs. A re-handshake
    /// replaces them and aborts any in-flight run.
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
    ///   - pin: the displayed PIN's ASCII digits (both ends must feed
    ///     CPace the same bytes).
    ///   - hostStaticPublicKey: our Noise static public key — the key
    ///     the client pins on success.
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
    @discardableResult
    public func sessionEstablished(
        clientStaticPublicKey: [UInt8], noiseHandshakeHash: [UInt8]
    ) -> Output {
        binding = (clientStaticPublicKey, noiseHandshakeHash)
        return abandonRun()
    }

    /// Call when the carrying session ends: its in-flight run can never
    /// confirm. If that was the budget's last guess the PIN burns now,
    /// not at the next client's share A.
    @discardableResult
    public func sessionEnded() -> Output {
        binding = nil
        return abandonRun()
    }

    private func abandonRun() -> Output {
        responder = nil
        return Output(events: burnIfSpent())
    }

    /// Burns (once) when the budget is spent and no run is in flight.
    private func burnIfSpent() -> [Event] {
        guard !burned, !isPaired, responder == nil,
              attemptsUsed >= config.maxAttempts else { return [] }
        burned = true
        return [.pinBurned]
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
            // ARQ deliveries only exist post-establishment: a missing
            // binding is a shell wiring bug — silent on the wire.
            return Output(events: [.malformed])
        }
        if attemptsUsed >= config.maxAttempts {
            // A newer share A abandons the last guess's run.
            return abandonRun()
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
            // Aborted before any tag math: no PIN information left, so
            // no guess is spent, but the typed reject is owed and the
            // throttle stays armed.
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
            let events: [Event] = [.rejected(
                .confirmationFailed,
                attemptsRemaining: config.maxAttempts - attemptsUsed
            )] + burnIfSpent()
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
        return Output(events: [.clientAborted(reject.reason)] + burnIfSpent())
    }
}
