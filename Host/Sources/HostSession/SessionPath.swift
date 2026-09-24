// SessionPath + PathValidator: the host's connection-migration logic.
// Sessions are identified by ConnectionId, not 4-tuple; when datagrams
// bearing a known connection ID arrive from a NEW source 4-tuple, the host
// validates the path with an echo challenge (QUIC §9 semantics) before
// promoting it, then requests a fresh IDR so the client decodes at once.
//
// Sans-IO: every entry point takes `now` (monotonic ns), randomness is
// injected, and outputs are value-typed events the send loop executes.
//
// The state machine, per candidate 4-tuple relative to one session:
//
//   unknown ──authenticated datagram bearing the conn-id──▶ PROBING
//       (challenge with a fresh random token sent on the new tuple,
//        subject to the anti-amplification budget)
//   PROBING ──PathResponse from that tuple, token matches──▶ PRIMARY
//       (old primary demoted to FALLBACK; freshKeyframeNeeded fires
//        exactly once; media output switches tuples)
//   PROBING ──validation timeout, or a matching response never came──▶
//       unknown (the probe slot frees; a later datagram re-probes with a
//        NEW token — a stale or guessed token can never promote)
//   FALLBACK ──authenticated datagram from that tuple──▶ PRIMARY
//       (no probe: it was validated inside the retention window, QUIC
//        §9.3; the primary it replaces becomes the FALLBACK and
//        freshKeyframeNeeded fires — a Wi-Fi flap A→B→A costs no RTT)
//   FALLBACK ──retention window expires──▶ unknown
//
// One probe slot: while a probe is outstanding, datagrams from *other*
// new tuples are ignored, not queued — an off-path flooder must not evict
// a genuine client's probe; a genuine roam re-triggers on its next datagram.
//
// Anti-amplification (QUIC §8 shape): until a tuple is validated, bytes
// sent to it are capped at `amplificationFactor ×` bytes received from it.
// Challenges are the only datagrams a candidate tuple ever receives; media
// flows to the primary until promotion.

import LyteWire

/// One UDP 4-tuple, as opaque routing data. Address strings are whatever
/// the socket layer reports (dotted quad today); the validator only ever
/// compares them.
public struct FourTuple: Hashable, Sendable {
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16

    public init(
        localAddress: String, localPort: UInt16,
        remoteAddress: String, remotePort: UInt16
    ) {
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }
}

/// A validated path the session has used: the tuple plus when it was
/// (last) validated, for telemetry and the fallback retention timer.
public struct SessionPath: Hashable, Sendable {
    public let tuple: FourTuple
    /// Monotonic ns of validation — session start for the initial path,
    /// the promoting PathResponse for migrated ones.
    public let validatedAt: UInt64

    public init(tuple: FourTuple, validatedAt: UInt64) {
        self.tuple = tuple
        self.validatedAt = validatedAt
    }
}

/// What the send loop must do, in order.
public enum PathValidatorEvent: Hashable, Sendable {
    /// Transmit this challenge body (CTRL, ARQ-exempt, conn-id TLV
    /// attached by the send loop) on the given — unvalidated — tuple.
    case sendChallenge(on: FourTuple, challenge: PathChallenge)
    /// The probed tuple answered, or the fallback spoke again: it is now
    /// the primary; route all media there. The old primary is retained as
    /// `fallback` until its retention window lapses.
    case promoted(primary: SessionPath, fallback: SessionPath)
    /// Fires exactly once per promotion: force the encoder's next frame
    /// to be an IDR.
    case freshKeyframeNeeded
    /// A probe timed out unanswered — spoofed, or the roam evaporated.
    case probeAbandoned(FourTuple)
    /// The old path's retention window lapsed; forget it.
    case fallbackExpired(FourTuple)
}

public struct PathValidatorConfig: Sendable {
    /// How long a challenge may sit unanswered before the probe slot
    /// frees; a genuine roam re-probes on its next datagram.
    public var validationTimeoutNS: UInt64
    /// How long the demoted primary stays known after a promotion — the
    /// escape hatch if the new path dies immediately: an authenticated
    /// datagram from it inside this window re-promotes it without a probe.
    public var fallbackRetentionNS: UInt64
    /// Pre-validation send cap: ≤ factor × bytes received on that tuple.
    public var amplificationFactor: Int
    /// What one challenge costs against the budget on the wire: 24 B
    /// envelope + 11 B conn-id TLV block + 10 B body + 16 B AEAD tag
    /// = 61 B (challenges are sealed like every post-handshake datagram).
    public var challengeDatagramByteCount: Int

    public init(
        validationTimeoutNS: UInt64 = 1_000_000_000,
        fallbackRetentionNS: UInt64 = 3_000_000_000,
        amplificationFactor: Int = 3,
        challengeDatagramByteCount: Int = 61
    ) {
        self.validationTimeoutNS = validationTimeoutNS
        self.fallbackRetentionNS = fallbackRetentionNS
        self.amplificationFactor = amplificationFactor
        self.challengeDatagramByteCount = challengeDatagramByteCount
    }
}

public struct PathValidator {
    private struct Probe {
        let tuple: FourTuple
        let token: UInt64
        let deadline: UInt64
        var bytesReceived: Int
        var bytesSent: Int
    }

    public let connectionId: ConnectionId
    public let config: PathValidatorConfig
    /// Where media flows right now.
    public private(set) var primary: SessionPath
    /// The demoted-but-retained previous primary, if inside its window.
    public private(set) var fallback: SessionPath?

    private var probe: Probe?
    private var fallbackDeadline: UInt64 = 0
    private var rng: any RandomNumberGenerator
    private var keyframePending = false

    public init(
        connectionId: ConnectionId,
        initialPath: FourTuple,
        now: UInt64,
        config: PathValidatorConfig = PathValidatorConfig(),
        rng: some RandomNumberGenerator
    ) {
        self.connectionId = connectionId
        self.config = config
        self.primary = SessionPath(tuple: initialPath, validatedAt: now)
        self.rng = rng
    }

    // MARK: Inputs

    /// The demux trigger: every authenticated datagram (unsealed under
    /// the session keys) reports its source tuple, the connection ID its
    /// TLV carried (nil when absent), and its wire size. Unauthenticated
    /// arrivals must not reach here: the TLV is plaintext, and a forged
    /// one would hold the single probe slot. Returns the actions to take.
    public mutating func datagramReceived(
        from tuple: FourTuple,
        connectionId claimed: ConnectionId?,
        byteCount: Int,
        now: UInt64
    ) -> [PathValidatorEvent] {
        var events = expire(now: now)

        // The primary needs no probing; unknown tuples without our
        // conn-id are not ours to answer at all (never a challenge —
        // that would make the host a reflector for arbitrary sources).
        guard claimed == connectionId, tuple != primary.tuple
        else { return events }

        if let retained = fallback, retained.tuple == tuple {
            events += promote(retained, now: now)
            return events
        }

        if var active = probe {
            // One probe slot. Same tuple: the bytes raise the budget but
            // the outstanding token stands. The one resend: the budget
            // withheld the challenge earlier and now affords it.
            if active.tuple == tuple {
                active.bytesReceived += byteCount
                if active.bytesSent == 0,
                   let challenge = challengeWithinBudget(of: &active) {
                    events.append(.sendChallenge(
                        on: tuple, challenge: challenge
                    ))
                }
                probe = active
            }
            return events
        }

        var fresh = Probe(
            tuple: tuple,
            token: rng.next() as UInt64,
            deadline: now + config.validationTimeoutNS,
            bytesReceived: byteCount,
            bytesSent: 0
        )
        if let challenge = challengeWithinBudget(of: &fresh) {
            events.append(.sendChallenge(on: tuple, challenge: challenge))
        }
        probe = fresh
        return events
    }

    /// The reflection guard applies to our own challenge too: emit it
    /// only when the budget covers it, accounting the bytes on success.
    private mutating func challengeWithinBudget(
        of probe: inout Probe
    ) -> PathChallenge? {
        let budget = probe.bytesReceived * config.amplificationFactor
        guard probe.bytesSent + config.challengeDatagramByteCount <= budget
        else { return nil }
        probe.bytesSent += config.challengeDatagramByteCount
        return PathChallenge(token: probe.token)
    }

    /// A PathResponse arrived from `tuple`. Promotion requires BOTH the
    /// token match and the source being the probed tuple — an off-path
    /// attacker who somehow learned the token still cannot promote a
    /// tuple that was never probed.
    public mutating func pathResponseReceived(
        from tuple: FourTuple,
        response: PathResponse,
        now: UInt64
    ) -> [PathValidatorEvent] {
        var events = expire(now: now)

        guard let active = probe,
              active.tuple == tuple,
              active.token == response.token
        else { return events }

        probe = nil
        events += promote(SessionPath(tuple: tuple, validatedAt: now), now: now)
        return events
    }

    /// `path` becomes the primary; the one it replaces is retained as the
    /// fallback for a fresh window, and the encoder owes an IDR.
    private mutating func promote(
        _ path: SessionPath, now: UInt64
    ) -> [PathValidatorEvent] {
        let old = primary
        primary = path
        fallback = old
        fallbackDeadline = now + config.fallbackRetentionNS
        keyframePending = true
        return [.promoted(primary: path, fallback: old), .freshKeyframeNeeded]
    }

    /// Clock advance with no datagram — the caller's timer wake. Emits
    /// any expiries that fell due.
    public mutating func advance(now: UInt64) -> [PathValidatorEvent] {
        expire(now: now)
    }

    /// The next instant `advance` could have work; nil when no timer is
    /// armed. The caller's loop sleeps until this (Pacer semantics).
    public var nextDeadline: UInt64? {
        var deadline: UInt64?
        if let probe { deadline = probe.deadline }
        if fallback != nil {
            deadline = min(deadline ?? fallbackDeadline, fallbackDeadline)
        }
        return deadline
    }

    /// True exactly once after each promotion; the encoder loop polls it
    /// like a client IDR request.
    public mutating func takeFreshKeyframeRequest() -> Bool {
        defer { keyframePending = false }
        return keyframePending
    }

    // MARK: Timers

    private mutating func expire(now: UInt64) -> [PathValidatorEvent] {
        var events: [PathValidatorEvent] = []
        if let active = probe, now >= active.deadline {
            probe = nil
            events.append(.probeAbandoned(active.tuple))
        }
        if let old = fallback, now >= fallbackDeadline {
            fallback = nil
            events.append(.fallbackExpired(old.tuple))
        }
        return events
    }
}
