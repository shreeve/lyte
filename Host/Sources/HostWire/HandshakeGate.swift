// HandshakeGate (HS-9): the pre-handshake flood throttle. A Noise
// message 1 costs the responder real work (X25519 + AEAD before
// anything is authenticated), and the decision record makes that flood
// surface ours with no RFC 9000 lineage — the host must "rate-limit
// unauthenticated first datagrams, no allocation before handshake
// progress" (host plan §7). This is the cheapest honest form: a token
// bucket consulted BEFORE any handshake state is allocated; a datagram
// refused here is dropped for free.
//
// The core plans also sketch a stateless HMAC retry cookie for the
// first handshake datagram. That codec does not exist in LyteWire yet
// (W6 shipped the PAKE only), and minting one host-side would fork a
// wire format Wire/ owns — so cookie *enforcement* stays deferred until
// the core codec lands, and this bucket is the H1-era posture. Sans-IO:
// `now` is injected monotonic ns.

public struct HandshakeGate: Sendable {
    public struct Config: Sendable {
        /// Sustained admissions per second once the burst is spent.
        public var ratePerSecond: Int
        /// Bucket depth — how many back-to-back attempts are admitted
        /// cold. Covers an honest client's retry burst (0443beb's
        /// lesson: one msg1 retransmitted on a timer) with room over.
        public var burst: Int

        public init(ratePerSecond: Int = 10, burst: Int = 10) {
            self.ratePerSecond = ratePerSecond
            self.burst = burst
        }
    }

    private let config: Config
    /// Tokens scaled by ratePerSecond so refill math stays integral:
    /// one admission costs `ratePerSecond` scaled tokens; one second
    /// refills `ratePerSecond × ratePerSecond`… i.e. we track
    /// nanosecond-credit directly instead.
    private var creditNS: UInt64
    private var lastRefillNS: UInt64?
    public private(set) var admitted = 0
    public private(set) var refused = 0

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

    /// True = process this message 1; false = drop it unread.
    public mutating func admit(now: UInt64) -> Bool {
        let cost = Self.costNS(config)
        let cap = UInt64(config.burst) * cost
        if let last = lastRefillNS, now > last {
            creditNS = min(cap, creditNS &+ (now - last))
        }
        lastRefillNS = now
        guard creditNS >= cost else {
            refused += 1
            return false
        }
        creditNS -= cost
        admitted += 1
        return true
    }
}
