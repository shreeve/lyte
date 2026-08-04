// HandshakeGate (HS-9, cookie escalation HS-21): the pre-handshake flood
// throttle. A Noise message 1 costs the responder real work (X25519 +
// AEAD before anything is authenticated), and the decision record makes
// that flood surface ours with no RFC 9000 lineage — the host must
// "rate-limit unauthenticated first datagrams, no allocation before
// handshake progress" (host plan §7).
//
// Two postures, low to high:
//
//   • THE TOKEN BUCKET (HS-9, the H1-era posture): a bucket consulted
//     BEFORE any handshake state is allocated; a message 1 beyond the
//     budget is dropped for free. Covers an honest client's retry burst
//     (0443beb's lesson: one msg1 retransmitted on a timer) with room
//     over, and blunts a small flood outright.
//
//   • REQUIRE-COOKIE MODE (HS-21, the W8 dial the host never drove
//     live): a sustained flood exhausts the bucket, so dropping is the
//     only H1 answer — but a genuine client caught in the same second is
//     dropped too. The stateless HMAC retry cookie (W8's 0x13/0x14,
//     LyteWire's RetryCookie owns the crypto) fixes exactly that: once
//     the msg1 arrival rate crosses `cookieEnterThreshold` in a
//     `floodWindowNS` window, the gate flips to require-cookie. An
//     un-cookied msg1 is then answered with a stateless RetryChallenge
//     (mint = one HMAC, reply SMALLER than the request — no amplification,
//     no per-client state, no Noise) instead of being dropped; a client
//     that echoes a VERIFYING cookie in a RetryHandshake1 is admitted
//     (one extra round trip, but it connects). The flip clears with
//     hysteresis once arrivals fall to `cookieExitThreshold`. Cookie mode
//     is OFF unless `cookieSecret` is set — a nil secret keeps the exact
//     H1 posture, so every pre-HS-21 caller and test is unchanged.
//
// Sans-IO: `now` is injected monotonic ns; the cookie secret is injected
// bytes; the client tuple is opaque bytes the caller serializes (only the
// crypto binds them). RetryCookie's window handles a harvested cookie's
// lifetime.

import LyteWire

public struct HandshakeGate: Sendable {
    public struct Config: Sendable {
        /// Sustained admissions per second once the burst is spent.
        public var ratePerSecond: Int
        /// Bucket depth — how many back-to-back attempts are admitted
        /// cold. Covers an honest client's retry burst (0443beb's
        /// lesson: one msg1 retransmitted on a timer) with room over.
        public var burst: Int
        /// The host's cookie secret (RetryCookie.secretByteCount = 32).
        /// Nil disables require-cookie mode entirely — the pure H1
        /// token-bucket posture (every pre-HS-21 test relies on this).
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

        public init(
            ratePerSecond: Int = 10,
            burst: Int = 10,
            cookieSecret: [UInt8]? = nil,
            cookieEnterThreshold: Int = 20,
            cookieExitThreshold: Int = 5,
            floodWindowNS: UInt64 = 1_000_000_000,
            cookieLifetimeNS: UInt64 = RetryCookie.defaultLifetimeNanoseconds
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
            /// Bucket empty and cookie mode off (the H1 posture).
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

    private let config: Config
    /// Nanosecond credit: refill accrues 1 ns per elapsed ns, one
    /// admission costs `costNS`.
    private var creditNS: UInt64
    private var lastRefillNS: UInt64?
    /// Recent message-1 arrival instants inside `floodWindowNS` — the
    /// flood detector's evidence. Capped so a pathological flood cannot
    /// grow it without bound (the exact count past the threshold is
    /// irrelevant to the dial).
    private var recentArrivals: [UInt64] = []

    public private(set) var admitted = 0
    public private(set) var refused = 0
    /// RetryChallenges minted (require-cookie mode, HS-21).
    public private(set) var challengesMinted = 0
    /// Cookies presented that verified — the extra-round-trip admits.
    public private(set) var cookiesVerified = 0
    /// Cookies presented that did not verify — spoof/replay evidence.
    public private(set) var cookiesRejected = 0
    /// Whether the gate is currently demanding a cookie (the observable
    /// dial; the caller surfaces its transitions).
    public private(set) var cookieMode = false

    public init(config: Config = Config()) {
        self.config = config
        // Start full: the first `burst` attempts are free.
        self.creditNS = UInt64(config.burst) * Self.costNS(config)
    }

    /// ns of credit one admission costs (refill accrues 1 ns of credit
    /// per elapsed ns, scaled by the rate).
    private static func costNS(_ config: Config) -> UInt64 {
        1_000_000_000 / UInt64(max(config.ratePerSecond, 1))
    }

    /// Legacy HS-9 entry point: a bare token-bucket verdict with no
    /// cookie machinery. True = process this message 1; false = drop it
    /// unread. Kept for callers that never opt into cookie mode.
    public mutating func admit(now: UInt64) -> Bool {
        refill(now: now)
        return spendToken()
    }

    /// The HS-21 entry point: the full flood decision for one message 1.
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
        refill(now: now)
        noteArrival(now: now)
        updateCookieMode()
        let cookieModeChangedTo = cookieMode == previousCookieMode ? nil : cookieMode
        func decided(_ admission: Admission) -> Decision {
            Decision(admission: admission, cookieModeChangedTo: cookieModeChangedTo)
        }

        // A presented cookie is judged first, in EITHER posture: a
        // client that already holds a verifying cookie has proven its
        // address and is admitted without spending a token (it is not a
        // flood). Cookie mode being off does not make a valid cookie
        // suspect — but with no secret we cannot verify one, so it is
        // refused as unverifiable.
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

        // Normal posture (or cookie mode desired but the mint refused a
        // malformed tuple): the H1 token bucket.
        if spendToken() { return decided(.admit) }
        return decided(.drop(.throttled))
    }

    // MARK: - Internals

    private mutating func refill(now: UInt64) {
        let cost = Self.costNS(config)
        let cap = UInt64(config.burst) * cost
        if let last = lastRefillNS, now > last {
            creditNS = min(cap, creditNS &+ (now - last))
        }
        lastRefillNS = now
    }

    private mutating func spendToken() -> Bool {
        let cost = Self.costNS(config)
        guard creditNS >= cost else {
            refused += 1
            return false
        }
        creditNS -= cost
        admitted += 1
        return true
    }

    private mutating func noteArrival(now: UInt64) {
        recentArrivals.append(now)
        recentArrivals.removeAll { now &- $0 > config.floodWindowNS }
        // The dial only compares against thresholds, so a few extra
        // entries past the cap can be dropped without changing any
        // verdict — keep the newest.
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
