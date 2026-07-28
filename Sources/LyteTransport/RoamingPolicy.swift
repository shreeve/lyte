// RoamingPolicy (F-5): the client's roaming/reconnect brain — what to
// do when the host moves out from under a standing session (the hotel
// move: the host's address changed and the old experience was "No
// hosts found" + a frozen frame with no recovery story), or when the
// Mac itself hops networks mid-session.
//
// The detection ladder, tiered on top of the session machine's own
// semantics (W4b — FROZEN/RECOVERY are local overlays, never wire
// states; the 30 s liveness clock closes a dead session):
//
//   1. A short gap (350 ms tightened / 2.5 s beacon-bounded) is the
//      machine's FROZEN — the CL-8 pill covers it, this policy only
//      starts its silence clock.
//   2. Silence past `scanAfterSilence` (3 s) means the blip is not
//      blinking away: begin QUIET discovery re-browsing (`_lyte._udp`
//      multicast is cheap; the session still stands and evidence
//      returning cancels everything).
//   3. The same host identity (the advertisement's TXT pkh — sha256
//      of the Noise static, the same hash the pinned-host store keys
//      by) appearing at a NEW address is the "host moved" verdict:
//      the old session is unreachable by construction — tear it down
//      and re-dial immediately. A fresh 1-RTT Noise IK against the
//      pinned static is the whole re-acquisition: same pairing, no
//      re-PIN (pairing is identity-keyed, address is a dial hint).
//   4. The same identity at the SAME address while we are this silent
//      means the network path works but the session is dark (host
//      restarted, or our source address changed under a host whose
//      HS-12 migration didn't bite): re-dial after
//      `redialSameAddressAfter` (8 s) — early enough to beat the 30 s
//      liveness close by a wide margin, late enough that an ordinary
//      Wi-Fi roam never triggers it.
//   5. The liveness close itself (the session machine's verdict that
//      the peer is gone) flips to full roaming: scan on a backoff
//      ladder, and probe-dial the last-known address between fruitless
//      scans (mDNS-less routed networks have no advertisement to
//      sight — the last dial hint is the only target).
//
// CLIENT-SIDE path changes (the Mac hops Wi-Fi; the host stays put):
// HS-12's PathValidator on the host owns migration — the client keeps
// sending from its new source address (the feedback cadence does that
// unprompted) and to the receiver a migrated peer is just evidence
// returning. So a path change gets a GRACE window (3 s — past the
// 2.5 s untightened detector, so a dead path is observably FROZEN at
// expiry) before this policy escalates; if the path healed itself the
// deadline dissolves. On expiry the same scan/dial ladder runs, with
// the same-address re-dial allowed at once (our own address changed —
// a fresh handshake is the mechanism when migration didn't carry).
//
// GIVE-UP POSTURE: there isn't one — the policy keeps looking
// passively, forever, with the backoff ladders capped (scan gap 1 s
// doubling to 15 s, dial retry 2 s doubling to 30 s) so it never spins
// hot; the human's Disconnect is the exit, and the manual Reconnect
// verb resets every ladder and acts immediately.
//
// Sans-IO, the SessionStateMachine discipline exactly: a struct,
// inputs applied with an injected `now` (monotonic microseconds),
// decisions returned as actions, `nextDeadline` tells the driver when
// to tick — the whole thing pins in virtual time. The driver
// (ConnectionModel) owns the sockets, the browse passes, and the
// re-dial; one failed dial is never fatal — a re-dial against a host
// that still holds the dead session draws silence until the host's
// own liveness frees it (the host-side busy/takeover story is the
// F-5 Host half), so the ladder simply keeps climbing.

/// One discovery sighting the driver feeds back after a browse pass:
/// the advertisement's identity hash and resolved dial target.
public struct RoamingSighting: Equatable, Sendable {
    public let publicKeyHash: String
    public let address: String
    public let port: UInt16

    public init(publicKeyHash: String, address: String, port: UInt16) {
        self.publicKeyHash = publicKeyHash
        self.address = address
        self.port = port
    }
}

/// What the driver must do. `beginScan` = one bounded discovery browse
/// (the driver answers with `scanCompleted`); `dial` = tear down any
/// standing wire session and run a fresh 1-RTT handshake at the target
/// (the driver answers with `sessionEstablished` or `dialFailed`).
public enum RoamingAction: Equatable, Sendable {
    case beginScan
    case dial(address: String, port: UInt16, discovered: Bool)
}

/// The UI-facing posture (the stream overlay's banner reads this).
public enum RoamingStatus: Equatable, Sendable {
    /// Session healthy — no roaming surface at all.
    case attached
    /// Silent, but below the scan threshold — the FROZEN pill's tier.
    case silent
    /// Actively looking: scans running (or scheduled) and no dial in
    /// flight.
    case searching
    /// A re-dial is in flight. `discovered` distinguishes "found at a
    /// new address" from a blind probe of the last-known address.
    case reconnecting(address: String, discovered: Bool)
}

public struct RoamingPolicyConfig: Hashable, Sendable {
    /// Continuous silence before the quiet re-browse begins. Sits
    /// above the blackout detector's tiers (350 ms tightened, 2.5 s
    /// beacon-bounded) — FROZEN alone is a blip, this is a story.
    public var scanAfterSilenceMicroseconds: Int64
    /// Silence before a SAME-address sighting justifies tearing the
    /// standing session down for a fresh dial.
    public var redialSameAddressAfterMicroseconds: Int64
    /// The migration grace after a client-side path change: HS-12
    /// gets this long to carry the session before roaming escalates.
    /// Deliberately past the 2.5 s untightened detector so a dead
    /// path is observably FROZEN when the deadline fires.
    public var pathChangeGraceMicroseconds: Int64
    /// The gap between fruitless scans: starts at the floor, doubles
    /// to the ceiling, never past it — passive looking, never hot.
    public var scanIntervalFloorMicroseconds: Int64
    public var scanIntervalCeilingMicroseconds: Int64
    /// The gap between dial attempts at one target: floor, doubling,
    /// ceiling. A host that hasn't freed the dead session yet answers
    /// a dial with silence — retry, don't hammer.
    public var dialRetryFloorMicroseconds: Int64
    public var dialRetryCeilingMicroseconds: Int64

    public init(
        scanAfterSilenceMicroseconds: Int64 = 3_000_000,
        redialSameAddressAfterMicroseconds: Int64 = 8_000_000,
        pathChangeGraceMicroseconds: Int64 = 3_000_000,
        scanIntervalFloorMicroseconds: Int64 = 1_000_000,
        scanIntervalCeilingMicroseconds: Int64 = 15_000_000,
        dialRetryFloorMicroseconds: Int64 = 2_000_000,
        dialRetryCeilingMicroseconds: Int64 = 30_000_000
    ) {
        self.scanAfterSilenceMicroseconds = scanAfterSilenceMicroseconds
        self.redialSameAddressAfterMicroseconds =
            redialSameAddressAfterMicroseconds
        self.pathChangeGraceMicroseconds = pathChangeGraceMicroseconds
        self.scanIntervalFloorMicroseconds = scanIntervalFloorMicroseconds
        self.scanIntervalCeilingMicroseconds =
            scanIntervalCeilingMicroseconds
        self.dialRetryFloorMicroseconds = dialRetryFloorMicroseconds
        self.dialRetryCeilingMicroseconds = dialRetryCeilingMicroseconds
    }
}

public struct RoamingPolicy: Sendable {
    public let config: RoamingPolicyConfig
    /// The host identity this policy hunts — the pinned static's
    /// sha256, matched against advertisement pkh. Never an address.
    public let targetPublicKeyHash: String

    /// The most recent successful dial target — the probe target when
    /// no advertisement is in sight, and the "same address" baseline.
    public private(set) var lastKnownAddress: String
    public private(set) var lastKnownPort: UInt16

    /// False once the session closed (liveness) or the policy decided
    /// to tear it down for a dial.
    private var sessionAlive = true
    /// The silence clock: set at FROZEN entry, cleared by evidence.
    private var silentSince: UInt64?
    /// The path-change grace deadline; dissolves on evidence.
    private var pathChangeDeadline: UInt64?
    /// Path-change escalation (or manual reconnect) waives the
    /// same-address redial threshold — our own address moved.
    private var sameAddressRedialWaived = false

    /// True while the policy wants scans running (between silence
    /// onset/close and re-establishment).
    private var scanning = false
    /// A browse pass is in flight (the driver owes scanCompleted).
    private var scanInFlight = false
    private var nextScanAt: UInt64?
    private var scanIntervalMicroseconds: Int64

    private var dialInFlight = false
    private var dialInFlightTarget: (address: String, discovered: Bool)?
    private var nextDialAllowedAt: UInt64 = 0
    private var dialRetryMicroseconds: Int64

    public init(
        config: RoamingPolicyConfig = RoamingPolicyConfig(),
        targetPublicKeyHash: String,
        address: String,
        port: UInt16
    ) {
        self.config = config
        self.targetPublicKeyHash = targetPublicKeyHash.lowercased()
        self.lastKnownAddress = address
        self.lastKnownPort = port
        self.scanIntervalMicroseconds = config.scanIntervalFloorMicroseconds
        self.dialRetryMicroseconds = config.dialRetryFloorMicroseconds
    }

    // MARK: Snapshots

    public var status: RoamingStatus {
        if dialInFlight, let target = dialInFlightTarget {
            return .reconnecting(
                address: target.address, discovered: target.discovered)
        }
        if scanning || !sessionAlive { return .searching }
        if silentSince != nil { return .silent }
        return .attached
    }

    /// When the driver must tick next; nil when nothing is pending.
    public var nextDeadline: UInt64? {
        var deadlines: [UInt64] = []
        if sessionAlive, !scanning, let since = silentSince {
            deadlines.append(
                since &+ UInt64(config.scanAfterSilenceMicroseconds))
        }
        if let grace = pathChangeDeadline { deadlines.append(grace) }
        if scanning, !scanInFlight, let at = nextScanAt {
            deadlines.append(at)
        }
        // A probe dial pends whenever roaming is live and no dial is:
        // its readiness gate is nextDialAllowedAt.
        if probeDialPending { deadlines.append(nextDialAllowedAt) }
        // A same-address redial waits out the silence threshold.
        if let at = sameAddressRedialReadyAt { deadlines.append(at) }
        return deadlines.min()
    }

    /// Probe dials (blind, last-known address) run only once the
    /// session is GONE — while it merely stands silent, discovery
    /// sightings are the evidence that justifies a teardown.
    private var probeDialPending: Bool {
        !sessionAlive && !dialInFlight
    }

    /// A pending same-address sighting is remembered here until the
    /// silence threshold admits it.
    private var pendingSameAddressSighting: RoamingSighting?
    private var sameAddressRedialReadyAt: UInt64? {
        guard sessionAlive, pendingSameAddressSighting != nil,
              let since = silentSince, !sameAddressRedialWaived
        else { return nil }
        return since
            &+ UInt64(config.redialSameAddressAfterMicroseconds)
    }

    // MARK: Session lifecycle inputs

    /// A session (re)established at this target: everything resets.
    public mutating func sessionEstablished(
        address: String, port: UInt16, now: UInt64
    ) -> [RoamingAction] {
        lastKnownAddress = address
        lastKnownPort = port
        sessionAlive = true
        silentSince = nil
        pathChangeDeadline = nil
        sameAddressRedialWaived = false
        scanning = false
        scanInFlight = false
        nextScanAt = nil
        scanIntervalMicroseconds = config.scanIntervalFloorMicroseconds
        dialInFlight = false
        dialInFlightTarget = nil
        nextDialAllowedAt = now
        dialRetryMicroseconds = config.dialRetryFloorMicroseconds
        pendingSameAddressSighting = nil
        return []
    }

    /// The session machine entered FROZEN — the silence clock starts.
    public mutating func wentSilent(now: UInt64) -> [RoamingAction] {
        guard sessionAlive else { return [] }
        if silentSince == nil { silentSince = now }
        return tick(now: now)
    }

    /// The session machine left FROZEN — the path moves again. Only a
    /// STANDING session is saved by this; once roaming committed to a
    /// teardown, establishment is the only way back.
    public mutating func evidenceReturned(now: UInt64) -> [RoamingAction] {
        guard sessionAlive else { return [] }
        silentSince = nil
        pathChangeDeadline = nil
        sameAddressRedialWaived = false
        pendingSameAddressSighting = nil
        if scanning {
            scanning = false
            nextScanAt = nil
            scanIntervalMicroseconds = config.scanIntervalFloorMicroseconds
        }
        return []
    }

    /// The session closed under us (the 30 s liveness verdict, or the
    /// driver tore it down): full roaming mode.
    public mutating func sessionClosed(now: UInt64) -> [RoamingAction] {
        sessionAlive = false
        pendingSameAddressSighting = nil
        var actions = beginScanningIfNeeded(now: now)
        actions += tick(now: now)
        return actions
    }

    /// The Mac's network path changed (interface set / status edge).
    /// A healthy session gets the migration grace; an already-silent
    /// one escalates immediately — and either way our own address
    /// moved, so the same-address redial threshold is waived.
    public mutating func pathChanged(now: UInt64) -> [RoamingAction] {
        guard sessionAlive else { return [] }
        sameAddressRedialWaived = true
        if silentSince != nil {
            // Already dark: no grace to grant — scan now.
            pathChangeDeadline = nil
            return beginScanningIfNeeded(now: now) + tick(now: now)
        }
        pathChangeDeadline =
            now &+ UInt64(config.pathChangeGraceMicroseconds)
        return []
    }

    /// The human's Reconnect verb: reset every ladder, act now — an
    /// immediate probe dial at the last-known address plus a scan.
    /// The driver tears any standing session down first.
    public mutating func manualReconnect(now: UInt64) -> [RoamingAction] {
        sessionAlive = false
        pendingSameAddressSighting = nil
        scanIntervalMicroseconds = config.scanIntervalFloorMicroseconds
        dialRetryMicroseconds = config.dialRetryFloorMicroseconds
        nextDialAllowedAt = now
        var actions = beginScanningIfNeeded(now: now)
        actions += tick(now: now)
        return actions
    }

    // MARK: Driver answers

    /// One browse pass ended. Sightings not matching the target
    /// identity are other people's hosts — ignored wholesale.
    public mutating func scanCompleted(
        sightings: [RoamingSighting], now: UInt64
    ) -> [RoamingAction] {
        scanInFlight = false
        guard scanning else { return [] }   // evidence beat the scan back
        let match = sightings.first {
            $0.publicKeyHash.lowercased() == targetPublicKeyHash
        }
        guard let match else {
            // Fruitless: back off and keep looking.
            nextScanAt = now &+ UInt64(scanIntervalMicroseconds)
            scanIntervalMicroseconds = min(
                scanIntervalMicroseconds &* 2,
                config.scanIntervalCeilingMicroseconds)
            return tick(now: now)
        }
        if match.address != lastKnownAddress {
            // The host MOVED: the standing session (if any) is
            // unreachable by construction — dial the new address now.
            // A new target also resets the dial ladder.
            dialRetryMicroseconds = config.dialRetryFloorMicroseconds
            nextDialAllowedAt = now
            return dialNow(
                address: match.address, port: match.port,
                discovered: true, now: now)
        }
        // Same address: the network path demonstrably works. A dead
        // session (or a waived threshold) dials right away; a merely
        // silent one waits out the redial threshold — evidence may
        // still return.
        if !sessionAlive || sameAddressRedialWaived {
            return dialNow(
                address: match.address, port: match.port,
                discovered: true, now: now)
        }
        pendingSameAddressSighting = match
        // Keep scanning meanwhile (the host could still move).
        nextScanAt = now &+ UInt64(scanIntervalMicroseconds)
        scanIntervalMicroseconds = min(
            scanIntervalMicroseconds &* 2,
            config.scanIntervalCeilingMicroseconds)
        return tick(now: now)
    }

    /// The dial the policy asked for never became a session (handshake
    /// timeout — commonly a host that hasn't freed the dead session
    /// yet). Back off on this target; scanning continues throughout.
    public mutating func dialFailed(now: UInt64) -> [RoamingAction] {
        dialInFlight = false
        dialInFlightTarget = nil
        nextDialAllowedAt = now &+ UInt64(dialRetryMicroseconds)
        dialRetryMicroseconds = min(
            dialRetryMicroseconds &* 2,
            config.dialRetryCeilingMicroseconds)
        return beginScanningIfNeeded(now: now) + tick(now: now)
    }

    // MARK: The beat

    /// Fires whatever deadlines have passed. Idempotent at one `now`.
    /// Dial-worthy verdicts are judged BEFORE scheduled scans, and a
    /// beat that commits to a dial launches no fresh browse — the
    /// dial is the decision; scanning resumes if it fails.
    public mutating func tick(now: UInt64) -> [RoamingAction] {
        var actions: [RoamingAction] = []
        var dialedThisBeat = false

        // The migration grace: dissolved by evidence (silentSince nil
        // means the path healed or never died); expiry over a frozen
        // path escalates straight to scanning.
        if let grace = pathChangeDeadline, now >= grace {
            pathChangeDeadline = nil
            if silentSince != nil {
                actions += beginScanningIfNeeded(now: now)
            } else {
                sameAddressRedialWaived = false   // healed — stand down
            }
        }

        // Silence past the scan threshold: the quiet re-browse begins.
        if sessionAlive, !scanning, let since = silentSince,
           now &- since >= UInt64(config.scanAfterSilenceMicroseconds) {
            actions += beginScanningIfNeeded(now: now)
        }

        // A remembered same-address sighting graduates past the
        // redial threshold.
        if let readyAt = sameAddressRedialReadyAt, now >= readyAt,
           let sighting = pendingSameAddressSighting, !dialInFlight {
            actions += dialNow(
                address: sighting.address, port: sighting.port,
                discovered: true, now: now)
            dialedThisBeat = true
        }

        // The blind probe of the last-known address (mDNS-less
        // networks have nothing to sight), on its own ladder.
        if probeDialPending, now >= nextDialAllowedAt {
            actions += dialNow(
                address: lastKnownAddress, port: lastKnownPort,
                discovered: false, now: now)
            dialedThisBeat = true
        }

        // A scheduled scan comes due — unless this very beat already
        // committed to a dial.
        if scanning, !scanInFlight, !dialedThisBeat,
           let at = nextScanAt, now >= at {
            nextScanAt = nil
            scanInFlight = true
            actions.append(.beginScan)
        }

        return actions
    }

    // MARK: Interior

    private mutating func beginScanningIfNeeded(
        now: UInt64
    ) -> [RoamingAction] {
        guard !scanning else { return [] }
        scanning = true
        scanIntervalMicroseconds = config.scanIntervalFloorMicroseconds
        guard !scanInFlight else { return [] }
        nextScanAt = nil
        scanInFlight = true
        return [.beginScan]
    }

    /// Commits to a dial: the standing session (if any) is forfeit —
    /// the DRIVER tears it down before handshaking (the typed goodbye
    /// frees the host side early when it can still hear one).
    private mutating func dialNow(
        address: String, port: UInt16, discovered: Bool, now: UInt64
    ) -> [RoamingAction] {
        guard !dialInFlight else { return [] }
        sessionAlive = false
        pendingSameAddressSighting = nil
        dialInFlight = true
        dialInFlightTarget = (address, discovered)
        return [.dial(address: address, port: port,
                      discovered: discovered)]
    }
}

// MARK: - The banner's words

public enum RoamingStatusLine {
    /// The stream overlay's line for one roaming posture; nil where
    /// no roaming surface belongs (attached, and the FROZEN-pill tier
    /// which the pill already covers).
    public static func line(
        for status: RoamingStatus, hostName: String
    ) -> String? {
        switch status {
        case .attached, .silent:
            return nil
        case .searching:
            return "Connection lost — looking for \(hostName)…"
        case .reconnecting(let address, let discovered):
            return discovered
                ? "\(hostName) found at \(address) — reconnecting…"
                : "Reconnecting to \(hostName) at \(address)…"
        }
    }
}
