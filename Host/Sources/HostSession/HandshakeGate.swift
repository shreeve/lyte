// HandshakeGate: the pre-handshake flood throttle. A Noise message 1
// costs the responder real work (X25519 + AEAD before anything is
// authenticated), so unauthenticated first datagrams are rate-limited
// with no allocation before handshake progress.
//
// Two postures, low to high:
//
//   • TOKEN BUCKET: consulted BEFORE any handshake state is allocated; a
//     message 1 beyond the budget is dropped for free. The burst covers an
//     honest client's msg1 retransmits with room over.
//
//   • REQUIRE-COOKIE MODE: under a sustained flood the bucket would drop
//     genuine clients too. Once msg1 arrivals in `floodWindowNS` reach
//     `cookieEnterThreshold`, an un-cookied msg1 is answered with a
//     stateless RetryChallenge (0x13: one HMAC, reply SMALLER than the
//     request, no per-client state, no Noise); a client echoing a
//     VERIFYING cookie in a RetryHandshake1 (0x14) is admitted. The mode
//     clears with hysteresis at `cookieExitThreshold`. It is OFF unless
//     `cookieSecret` is set. LyteWire's RetryCookie owns the crypto.
//
// A verified cookie proves an address, not good intent: one real client
// can replay the same RetryHandshake1 at line rate for the cookie's whole
// lifetime, and every admission costs the Noise DH. Cookie admissions
// therefore spend from their own (larger) bucket, and an exact replay of
// a cookie already admitted is dropped before it spends anything.
//
// Sans-IO: `now` is injected monotonic ns; the cookie secret is injected
// bytes; the client tuple is opaque bytes the caller serializes (only the
// crypto binds them). RetryCookie's window handles a harvested cookie's
// lifetime.

import LyteCore
import LyteWire

public struct HandshakeGate: Sendable {
    public struct Config: Sendable {
        /// Sustained admissions per second once the burst is spent.
        public var ratePerSecond: Int
        /// Bucket depth — back-to-back attempts admitted cold. Covers an
        /// honest client's msg1 retransmits with room over.
        public var burst: Int
        /// The host's cookie secret (RetryCookie.secretByteCount = 32).
        /// Nil disables require-cookie mode (token bucket only).
        public var cookieSecret: [UInt8]?
        /// Message-1 arrivals within `floodWindowNS` at or above which
        /// the gate flips INTO require-cookie mode.
        public var cookieEnterThreshold: Int
        /// Arrivals within `floodWindowNS` at or below which it flips
        /// back OUT (hysteresis; must be < the enter threshold so a
        /// flood on the edge cannot flap the dial).
        public var cookieExitThreshold: Int
        /// The sliding window the flood detector counts arrivals over.
        public var floodWindowNS: UInt64
        /// How long a minted cookie verifies (RetryCookie's own default
        /// is generous against Wi-Fi power-save latencies).
        public var cookieLifetimeNS: UInt64
        /// Sustained verified-cookie admissions per second. Each honest
        /// client needs one; the budget caps the Noise work a cookie
        /// holder can buy.
        public var cookieAdmissionsPerSecond: Int
        /// Verified-cookie admissions allowed back to back.
        public var cookieAdmissionBurst: Int

        public init(
            ratePerSecond: Int = 10,
            burst: Int = 10,
            cookieSecret: [UInt8]? = nil,
            cookieEnterThreshold: Int = 20,
            cookieExitThreshold: Int = 5,
            floodWindowNS: UInt64 = 1_000_000_000,
            cookieLifetimeNS: UInt64 = RetryCookie.defaultLifetimeNanoseconds,
            cookieAdmissionsPerSecond: Int = 50,
            cookieAdmissionBurst: Int = 50
        ) {
            self.ratePerSecond = ratePerSecond
            self.burst = burst
            self.cookieSecret = cookieSecret
            self.cookieEnterThreshold = max(cookieEnterThreshold, 1)
            self.cookieExitThreshold = min(
                max(cookieExitThreshold, 0), max(cookieEnterThreshold, 1) - 1
            )
            self.floodWindowNS = floodWindowNS
            self.cookieLifetimeNS = cookieLifetimeNS
            self.cookieAdmissionsPerSecond = cookieAdmissionsPerSecond
            self.cookieAdmissionBurst = cookieAdmissionBurst
        }
    }

    /// What to do with one message 1 (the caller owns the wire I/O).
    public enum Admission: Equatable, Sendable {
        /// Process it — spend the Noise crypto (the burst admitted it,
        /// or a presented cookie verified).
        case admit
        /// Under flood and no valid cookie: answer with a RetryChallenge
        /// carrying this freshly-minted cookie. Allocate nothing else.
        case challenge(cookie: [UInt8])
        /// Refuse before any allocation.
        case drop(Reason)

        public enum Reason: Equatable, Sendable {
            /// Bucket empty and cookie mode off, or a
            /// verified cookie that is a replay or over the cookie budget.
            case throttled
            /// A cookie was presented but did not verify (wrong tuple,
            /// wrong msg1, expired, or forged) — dropped quietly.
            case cookieInvalid
        }
    }

    public struct Decision: Equatable, Sendable {
        public var admission: Admission
        public var cookieModeChangedTo: Bool?
    }

    /// A nanosecond-credit token bucket: refill accrues 1 ns of credit per
    /// elapsed ns, one admission costs `costNS`, credit caps at the burst.
    private struct TokenBucket: Sendable {
        let costNS: UInt64
        let capNS: UInt64
        var creditNS: UInt64
        var lastRefillNS: UInt64?

        init(ratePerSecond: Int, burst: Int) {
            costNS = 1_000_000_000 / UInt64(max(ratePerSecond, 1))
            capNS = UInt64(max(burst, 0)) * costNS
            // Start full: the first `burst` attempts are free.
            creditNS = capNS
        }

        mutating func refill(now: UInt64) {
            if let last = lastRefillNS, now > last {
                creditNS = min(capNS, creditNS &+ (now - last))
            }
            lastRefillNS = now
        }

        mutating func spend() -> Bool {
            guard creditNS >= costNS else { return false }
            creditNS -= costNS
            return true
        }
    }

    private let config: Config
    private var bucket: TokenBucket
    private var cookieBucket: TokenBucket
    /// Recent message-1 arrival instants inside `floodWindowNS`, oldest
    /// first. Capped: the count past the threshold is irrelevant.
    private var recentArrivals = Deque<UInt64>()
    /// Cookies already admitted. A cookie binds (tuple, msg1), so an exact
    /// repeat is a replay of a handshake the host already answered.
    private var admittedCookies = BoundedRing<[UInt8]>(capacity: 256)

    public private(set) var admitted = 0
    public private(set) var refused = 0
    /// RetryChallenges minted in require-cookie mode.
    public private(set) var challengesMinted = 0
    /// Cookies presented that verified — the extra-round-trip admits.
    public private(set) var cookiesVerified = 0
    /// Cookies presented that did not verify — spoof evidence.
    public private(set) var cookiesRejected = 0
    /// Verified cookies dropped as exact replays or over the cookie budget.
    public private(set) var cookiesThrottled = 0
    /// Whether the gate is currently demanding a cookie (the observable
    /// dial; the caller surfaces its transitions).
    public private(set) var cookieMode = false

    public init(config: Config = Config()) {
        self.config = config
        bucket = TokenBucket(
            ratePerSecond: config.ratePerSecond, burst: config.burst)
        cookieBucket = TokenBucket(
            ratePerSecond: config.cookieAdmissionsPerSecond,
            burst: config.cookieAdmissionBurst)
    }

    /// The full flood decision for one message 1.
    /// `presentedCookie` is non-nil only for a RetryHandshake1 (0x14);
    /// `clientTuple` is the caller's opaque serialization of the source
    /// address (the cookie binds ownership of exactly it); `message1` is
    /// the raw Noise message 1 the cookie must match verbatim.
    public mutating func admitMessage1(
        presentedCookie: ArraySlice<UInt8>?,
        clientTuple: [UInt8],
        message1: ArraySlice<UInt8>,
        now: UInt64
    ) -> Decision {
        let previousCookieMode = cookieMode
        bucket.refill(now: now)
        cookieBucket.refill(now: now)
        noteArrival(now: now)
        updateCookieMode()
        let cookieModeChangedTo = cookieMode == previousCookieMode ? nil : cookieMode
        func decided(_ admission: Admission) -> Decision {
            Decision(admission: admission, cookieModeChangedTo: cookieModeChangedTo)
        }

        // A presented cookie is judged first, in EITHER posture: a
        // verifying cookie proves the address, so it spends the cookie
        // bucket (once — an exact replay is dropped), not the msg1 bucket.
        // With no secret it cannot be verified and is refused.
        if let presentedCookie {
            guard let secret = config.cookieSecret,
                  RetryCookie.verify(
                    cookie: presentedCookie,
                    clientTuple: clientTuple,
                    message1: message1,
                    now: now,
                    secrets: [secret],
                    lifetimeNanoseconds: config.cookieLifetimeNS
                  )
            else {
                cookiesRejected += 1
                refused += 1
                return decided(.drop(.cookieInvalid))
            }
            cookiesVerified += 1
            let cookie = Array(presentedCookie)
            guard !admittedCookies.contains(cookie), cookieBucket.spend()
            else {
                cookiesThrottled += 1
                refused += 1
                return decided(.drop(.throttled))
            }
            admittedCookies.append(cookie)
            admitted += 1
            return decided(.admit)
        }

        // No cookie. In require-cookie mode, answer with a stateless
        // challenge (one HMAC, no Noise, no state); the honest client
        // resubmits with the cookie echoed.
        if cookieMode, let secret = config.cookieSecret,
           let cookie = try? RetryCookie.mint(
                clientTuple: clientTuple, message1: message1,
                now: now, secret: secret
           ) {
            challengesMinted += 1
            refused += 1
            return decided(.challenge(cookie: cookie))
        }

        // Normal posture (or the mint refused a malformed tuple): the
        // token bucket.
        if spendToken() { return decided(.admit) }
        return decided(.drop(.throttled))
    }

    // MARK: - Internals

    private mutating func spendToken() -> Bool {
        guard bucket.spend() else {
            refused += 1
            return false
        }
        admitted += 1
        return true
    }

    private mutating func noteArrival(now: UInt64) {
        recentArrivals.append(now)
        while let oldest = recentArrivals.first,
              now &- oldest > config.floodWindowNS {
            recentArrivals.removeFirst()
        }
        // The dial only compares against thresholds; keep the newest.
        let cap = max(config.cookieEnterThreshold * 2, 1_024)
        if recentArrivals.count > cap {
            recentArrivals.removeFirst(recentArrivals.count - cap)
        }
    }

    private mutating func updateCookieMode() {
        guard config.cookieSecret != nil else { return }
        let count = recentArrivals.count
        if !cookieMode, count >= config.cookieEnterThreshold {
            cookieMode = true
        } else if cookieMode, count <= config.cookieExitThreshold {
            cookieMode = false
        }
    }
}
