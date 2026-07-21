// SessionPath + PathValidator: the host's connection-migration decision
// logic (HS-12). Sessions are identified by ConnectionId, not 4-tuple
// (resiliency §6); when datagrams bearing a known connection ID arrive
// from a NEW source 4-tuple, the host must not just believe the address —
// it validates the path with an echo challenge (QUIC §9 semantics) and
// only then promotes it, requesting a fresh IDR so the client can decode
// immediately on the new path (the RECOVERY rule: fresh IDR on a new
// path, resiliency §4/§6).
//
// Sans-IO in the HostCore/Pacer style: no sockets, no threads, no clock —
// every entry point takes `now` (monotonic ns), randomness is an injected
// generator, and outputs are value-typed events the send loop executes
// (send this challenge datagram on that tuple; switch the peer address;
// force a keyframe). The Linux send loop that actually rebinds the socket
// is deliberately thin and lands when `pop` returns; everything decidable
// is decided here, on the Mac, under test.
//
// The state machine, per candidate 4-tuple relative to one session:
//
//   unknown ──datagram bearing the session's conn-id──▶ PROBING
//       (challenge with a fresh random token sent on the new tuple,
//        subject to the anti-amplification budget)
//   PROBING ──PathResponse from that tuple, token matches──▶ PRIMARY
//       (old primary demoted to FALLBACK; freshKeyframeNeeded fires
//        exactly once; media output switches tuples)
//   PROBING ──validation timeout, or a matching response never came──▶
//       unknown (the probe slot frees; a later datagram re-probes with a
//        NEW token — a stale or guessed token can never promote)
//   FALLBACK ──retention window expires──▶ unknown
//
// One probe slot: while a probe is outstanding, datagrams from *other*
// new tuples are ignored rather than queued — probe thrash is an attack
// surface (an off-path flooder must not be able to evict a genuine
// client's probe), and a genuine roam re-triggers on its next datagram.
//
// Anti-amplification (the reflection-attack guard, QUIC §8 shape): until
// a tuple is validated, bytes sent to it are capped at
// `amplificationFactor ×` bytes received from it (factor 3, QUIC's
// number). The validator does its own accounting for the challenges it
// emits; media never targets an unvalidated tuple at all (media flows to
// the primary until promotion — the stronger rule, and the budget is the
// backstop enforcing it).

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

/// What the send loop must do. Values, not callbacks — the caller
/// executes them in order, which keeps the machine testable and the
/// syscall layer thin.
public enum PathValidatorEvent: Hashable, Sendable {
    /// Transmit this challenge body (CTRL, ARQ-exempt, conn-id TLV
    /// attached by the send loop) on the given — unvalidated — tuple.
    case sendChallenge(on: FourTuple, challenge: PathChallenge)
    /// The probed tuple answered: it is now the primary; route all media
    /// there. The old primary is retained as `fallback` until its
    /// retention window lapses.
    case promoted(primary: SessionPath, fallback: SessionPath)
    /// Fires exactly once per promotion: force the encoder's next frame
    /// to be an IDR (VideoChannel's urgent-keyframe path drains it ahead
    /// of queued P-frames).
    case freshKeyframeNeeded
    /// A probe timed out unanswered — spoofed, or the roam evaporated.
    case probeAbandoned(FourTuple)
    /// The old path's retention window lapsed; forget it.
    case fallbackExpired(FourTuple)
}

public struct PathValidatorConfig: Sendable {
    /// How long a challenge may sit unanswered before the probe slot
    /// frees. Generous versus any sane RTT; a genuine roam simply
    /// re-probes on its next datagram.
    public var validationTimeoutNS: UInt64
    /// How long the demoted primary stays known after a promotion — the
    /// escape hatch if the new path dies immediately.
    public var fallbackRetentionNS: UInt64
    /// Pre-validation send cap: ≤ factor × bytes received on that tuple.
    public var amplificationFactor: Int
    /// What one challenge costs against the budget on the wire: 24 B
    /// envelope + 11 B conn-id TLV block + 10 B body = 45 B.
    public var challengeDatagramByteCount: Int

    public init(
        validationTimeoutNS: UInt64 = 1_000_000_000,
        fallbackRetentionNS: UInt64 = 3_000_000_000,
        amplificationFactor: Int = 3,
        challengeDatagramByteCount: Int = 45
    ) {
        self.validationTimeoutNS = validationTimeoutNS
        self.fallbackRetentionNS = fallbackRetentionNS
        self.amplificationFactor = amplificationFactor
        self.challengeDatagramByteCount = challengeDatagramByteCount
    }
}

public final class PathValidator {
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
        rng: some RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.connectionId = connectionId
        self.config = config
        self.primary = SessionPath(tuple: initialPath, validatedAt: now)
        self.rng = rng
    }

    // MARK: Inputs

    /// The demux trigger: any received datagram, after envelope decode,
    /// reports its source tuple, the connection ID its TLV carried (nil
    /// when absent), and its wire size. Returns the actions to take.
    public func datagramReceived(
        from tuple: FourTuple,
        connectionId claimed: ConnectionId?,
        byteCount: Int,
        now: UInt64
    ) -> [PathValidatorEvent] {
        var events = expire(now: now)

        // Known tuples need no probing; unknown tuples without our
        // conn-id are not ours to answer at all (never a challenge —
        // that would make the host a reflector for arbitrary sources).
        guard claimed == connectionId,
              tuple != primary.tuple,
              tuple != fallback?.tuple
        else { return events }

        if var active = probe {
            // One probe slot (header comment). Same tuple: account the
            // bytes — they raise the amplification budget — but the
            // outstanding token stands; no re-challenge storm. The one
            // resend case: the budget withheld the challenge earlier
            // (a runt first datagram) and the new bytes now afford it.
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
    private func challengeWithinBudget(of probe: inout Probe) -> PathChallenge? {
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
    public func pathResponseReceived(
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
        let old = primary
        primary = SessionPath(tuple: tuple, validatedAt: now)
        fallback = old
        fallbackDeadline = now + config.fallbackRetentionNS
        keyframePending = true
        events.append(.promoted(primary: primary, fallback: old))
        events.append(.freshKeyframeNeeded)
        return events
    }

    /// Clock advance with no datagram — the caller's timer wake. Emits
    /// any expiries that fell due.
    public func advance(now: UInt64) -> [PathValidatorEvent] {
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

    // MARK: The send loop's queries

    /// How many more bytes may be sent to `tuple` right now. Validated
    /// tuples (primary, retained fallback) are uncapped (nil); the tuple
    /// under probe gets what remains of the amplification budget; every
    /// other tuple gets zero.
    public func sendAllowance(to tuple: FourTuple) -> Int? {
        if tuple == primary.tuple || tuple == fallback?.tuple {
            return nil
        }
        guard let probe, probe.tuple == tuple else { return 0 }
        return max(
            0,
            probe.bytesReceived * config.amplificationFactor
                - probe.bytesSent
        )
    }

    /// Accounts caller-originated bytes (retransmitted challenges, future
    /// probe padding) against an unvalidated tuple's budget. The
    /// validator already accounted the challenges it emitted itself.
    public func recordSend(to tuple: FourTuple, byteCount: Int) {
        guard var active = probe, active.tuple == tuple else { return }
        active.bytesSent += byteCount
        probe = active
    }

    /// The fresh-IDR seam: true exactly once after each promotion. The
    /// encoder loop polls this (exactly like a client 0x0302 IDR
    /// request) and feeds the forced IDR into VideoChannel, whose
    /// keyframe shards enqueue urgent (HS-5) — that is the whole wiring.
    public func takeFreshKeyframeRequest() -> Bool {
        defer { keyframePending = false }
        return keyframePending
    }

    // MARK: Timers

    private func expire(now: UInt64) -> [PathValidatorEvent] {
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
