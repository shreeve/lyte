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
// With a secret, a message 1 the bucket cannot admit is challenged, never
// dropped, in either posture: a spoofed flood fast enough to drain the
// bucket but below the dial's threshold would otherwise starve every
// honest dial.
//
// A verified cookie proves an address, not good intent: one real client
// can replay the same RetryHandshake1 at line rate for the cookie's whole
// lifetime, or mint fresh ones with fresh ephemerals, and every admission
// costs the Noise DH. Cookie admissions therefore spend from their own
// (larger) bucket, each proven address (IP only; an IPv6 /64) from a small
// share of it, an admission spends both or neither, and an exact replay of
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
        /// One proven address's share of the cookie budget, per second and
        /// back to back: a holder minting fresh cookies at line rate
        /// cannot spend every other client's admissions.
        public var cookieAdmissionsPerAddressPerSecond: Int

        public init(
            ratePerSecond: Int = 10,
            burst: Int = 10,
            cookieSecret: [UInt8]? = nil,
            cookieEnterThreshold: Int = 20,
            cookieExitThreshold: Int = 5,
            floodWindowNS: UInt64 = 1_000_000_000,
            cookieLifetimeNS: UInt64 = RetryCookie.defaultLifetimeNanoseconds,
            cookieAdmissionsPerSecond: Int = 50,
            cookieAdmissionBurst: Int = 50,
            cookieAdmissionsPerAddressPerSecond: Int = 2
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
            self.cookieAdmissionsPerAddressPerSecond =
                cookieAdmissionsPerAddressPerSecond
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
            /// Bucket empty and no secret to challenge with, or a verified
            /// cookie that is a replay or over its address's or the
            /// host's cookie budget.
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

        var canSpend: Bool { creditNS >= costNS }

        mutating func spend() -> Bool {
            guard canSpend else { return false }
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
    private var admittedCookies = BoundedFifoMap<[UInt8], Void>(capacity: 256)
    /// Each proven address's share of the cookie budget, keyed by
    /// `addressShareKey` (never the port: one host on many ports is one
    /// share). The oldest address is forgotten first; re-proving it costs
    /// a round trip.
    private var addressBuckets = BoundedFifoMap<[UInt8], TokenBucket>(
        capacity: 256)

    public private(set) var admitted = 0
    public private(set) var refused = 0
    /// RetryChallenges minted in require-cookie mode.
    public private(set) var challengesMinted = 0
    /// Cookies presented that verified — the extra-round-trip admits.
    public private(set) var cookiesVerified = 0
    /// Cookies presented that did not verify — spoof evidence.
    public private(set) var cookiesRejected = 0
    /// Verified cookies dropped as exact replays or over a cookie budget.
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
    /// address and port (the cookie binds ownership of exactly it);
    /// `clientAddress` keys the source's share of the cookie budget
    /// (`addressShareKey` of the address alone); `message1` is the raw
    /// Noise message 1 the cookie must match verbatim.
    public mutating func admitMessage1(
        presentedCookie: ArraySlice<UInt8>?,
        clientTuple: [UInt8],
        clientAddress: [UInt8],
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
            var share = addressBuckets[clientAddress] ?? TokenBucket(
                ratePerSecond: config.cookieAdmissionsPerAddressPerSecond,
                burst: config.cookieAdmissionsPerAddressPerSecond)
            share.refill(now: now)
            // Both budgets must have credit before either is spent: a
            // host-wide refusal never burns an honest address's share,
            // and an address over its share never drains the host's.
            let spent = admittedCookies[cookie] == nil
                && share.canSpend && cookieBucket.canSpend
            if spent {
                _ = cookieBucket.spend()
                _ = share.spend()
            }
            addressBuckets.set(share, for: clientAddress)
            guard spent else {
                cookiesThrottled += 1
                refused += 1
                return decided(.drop(.throttled))
            }
            admittedCookies.set((), for: cookie)
            admitted += 1
            return decided(.admit)
        }

        // No cookie: the token bucket, unless the dial is engaged. What
        // the bucket does not admit is answered, with a secret, by a
        // stateless challenge (one HMAC, no Noise, no state); the honest
        // client resubmits with the cookie echoed.
        if !cookieMode, bucket.spend() {
            admitted += 1
            return decided(.admit)
        }
        if let secret = config.cookieSecret,
           let cookie = try? RetryCookie.mint(
                clientTuple: clientTuple, message1: message1,
                now: now, secret: secret
           ) {
            challengesMinted += 1
            refused += 1
            return decided(.challenge(cookie: cookie))
        }
        // The mint refused a malformed tuple: the bucket still applies.
        if cookieMode, bucket.spend() {
            admitted += 1
            return decided(.admit)
        }
        refused += 1
        return decided(.drop(.throttled))
    }

    /// The cookie-budget share key for a source address: an IPv4 address
    /// as written, an IPv6 address by its /64 (one subscriber's prefix;
    /// the interface half is free for it to rotate), an IPv4-mapped IPv6
    /// address as its IPv4. Never the port. Text that parses as neither
    /// keys as written.
    public static func addressShareKey(_ address: String) -> [UInt8] {
        let unscoped = address.split(
            separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard unscoped.contains(":") else { return Array(unscoped.utf8) }
        if let v4 = unscoped.split(separator: ":").last, v4.contains(".") {
            return Array(v4.utf8)
        }
        guard let groups = ipv6Groups(unscoped) else {
            return Array(address.utf8)
        }
        var key: [UInt8] = Array("v6/64:".utf8)
        for group in groups.prefix(4) {
            key.append(UInt8(group >> 8))
            key.append(UInt8(group & 0xFF))
        }
        return key
    }

    /// The eight 16-bit groups of textual IPv6, "::" expanded; nil when
    /// it is not IPv6.
    private static func ipv6Groups(_ text: Substring) -> [UInt16]? {
        let colon = UInt8(ascii: ":")
        let bytes = Array(text.utf8)
        var gap: Int?
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == colon, bytes[index + 1] == colon {
                guard gap == nil else { return nil }
                gap = index
                index += 2
            } else {
                index += 1
            }
        }
        func parse(_ part: ArraySlice<UInt8>) -> [UInt16]? {
            if part.isEmpty { return [] }
            var groups: [UInt16] = []
            for field in part.split(
                separator: colon, omittingEmptySubsequences: false) {
                guard (1...4).contains(field.count),
                      let value = UInt16(
                        String(decoding: field, as: UTF8.self), radix: 16)
                else { return nil }
                groups.append(value)
            }
            return groups
        }
        guard let gap else {
            guard let groups = parse(bytes[...]), groups.count == 8
            else { return nil }
            return groups
        }
        guard let front = parse(bytes[..<gap]),
              let back = parse(bytes[(gap + 2)...]),
              front.count + back.count <= 7 else { return nil }
        return front
            + [UInt16](repeating: 0, count: 8 - front.count - back.count)
            + back
    }

    // MARK: - Internals

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
