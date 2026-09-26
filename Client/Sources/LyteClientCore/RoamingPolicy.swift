// RoamingPolicy: pure client dial policy — the window's first connect,
// and what to do when the host moves out from under a standing session
// or the Mac itself hops networks mid-session. FROZEN/RECOVERY are local
// overlays of the session machine; its 30 s liveness clock closes a dead
// session.
//
// Before any session, `connect` dials at once and a silent dial climbs
// the ladders below as a lost session does, inside the establishment
// budget; past it the policy gives up (`.expired`).
//
// The detection ladder:
//   1. A short gap is the machine's FROZEN; this policy only starts its
//      silence clock.
//   2. Silence past `scanAfterSilence` (3 s) begins quiet discovery
//      re-browsing; returning evidence cancels everything.
//   3. The same host identity (advertised pkh — sha256 of the Noise
//      static, the pinned-host store's key) at a NEW address means the
//      host moved: tear down and re-dial now. Pairing is identity-keyed;
//      the address is only a dial hint, so no re-PIN.
//   4. The same identity at the SAME address while silent means the path
//      works but the session is dark: re-dial after
//      `redialSameAddressAfter` (8 s) — well before the 30 s liveness
//      close, late enough that an ordinary Wi-Fi roam never triggers it.
//   5. The liveness close flips to full roaming: scan on a backoff
//      ladder and probe-dial the last-known address between fruitless
//      scans (mDNS-less routed networks have nothing to sight).
//
// Client-side path changes: the host's path validation owns migration,
// so a path change gets a grace window (3 s — past the 2.5 s detector,
// so a dead path is observably FROZEN at expiry) before escalating, and
// the same-address re-dial is allowed at once.
//
// Once established there is no give-up: backoff ladders are capped
// (scan 1 s → 15 s, dial 2 s → 30 s); Disconnect is the exit and
// Reconnect resets every ladder. While scanning is wanted, a scan is
// always in flight, scheduled, or waiting on the one dial in flight; a
// sighting that lands mid-dial is held and dialed the moment that dial
// fails.
//
// Sans-IO: a struct fed inputs with an injected monotonic `now` (µs),
// returning actions; `nextDeadline` tells the driver (ConnectionModel)
// when to tick. A failed dial is never fatal — a host still holding the
// dead session answers with silence, so the ladder keeps climbing.

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
/// `expired` = the first connect's establishment budget ran out with no
/// session: the driver ends the window.
public enum RoamingAction: Equatable, Sendable {
    case beginScan
    case dial(address: String, port: UInt16, discovered: Bool)
    case expired
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
    /// Continuous silence before the quiet re-browse begins; above the
    /// blackout detector's tiers (350 ms tightened, 2.5 s untightened).
    public var scanAfterSilenceMicroseconds: Int64
    /// Silence before a SAME-address sighting justifies tearing the
    /// standing session down for a fresh dial.
    public var redialSameAddressAfterMicroseconds: Int64
    /// The migration grace after a client-side path change, past the
    /// 2.5 s untightened detector so a dead path is observably FROZEN
    /// when the deadline fires.
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
    /// The first connect's patience: silence keeps re-dialing until the
    /// budget runs out — a full host restart (10–15 s) with margin.
    public var establishBudgetMicroseconds: Int64

    public init(
        scanAfterSilenceMicroseconds: Int64 = 3_000_000,
        redialSameAddressAfterMicroseconds: Int64 = 8_000_000,
        pathChangeGraceMicroseconds: Int64 = 3_000_000,
        scanIntervalFloorMicroseconds: Int64 = 1_000_000,
        scanIntervalCeilingMicroseconds: Int64 = 15_000_000,
        dialRetryFloorMicroseconds: Int64 = 2_000_000,
        dialRetryCeilingMicroseconds: Int64 = 30_000_000,
        establishBudgetMicroseconds: Int64 = 45_000_000
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
        self.establishBudgetMicroseconds = establishBudgetMicroseconds
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
    /// to tear it down for a dial, and before the first establishment.
    private var sessionAlive = true
    /// Armed by `connect`, cleared by the first establishment.
    private var establishDeadline: UInt64?
    /// The budget ran out: nothing more is ever dialed or scanned.
    private var expired = false
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
    /// A dial-worthy sighting that arrived while a dial was in flight.
    private var sightingAwaitingDial: RoamingSighting?
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
        // The budget is judged between dials: one in flight finishes.
        if let deadline = establishDeadline, !dialInFlight {
            deadlines.append(deadline)
        }
        return deadlines.min()
    }

    /// Probe dials (blind, last-known address) run only once the
    /// session is GONE — while it merely stands silent, discovery
    /// sightings are the evidence that justifies a teardown.
    private var probeDialPending: Bool {
        !sessionAlive && !dialInFlight && !expired
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

    /// The window's first dial: no session yet, so the target is dialed
    /// now and the establishment budget starts.
    public mutating func connect(now: UInt64) -> [RoamingAction] {
        sessionAlive = false
        establishDeadline =
            now &+ UInt64(config.establishBudgetMicroseconds)
        nextDialAllowedAt = now
        return tick(now: now)
    }

    /// A session (re)established at this target: everything resets.
    public mutating func sessionEstablished(
        address: String, port: UInt16, now: UInt64
    ) -> [RoamingAction] {
        lastKnownAddress = address
        lastKnownPort = port
        sessionAlive = true
        establishDeadline = nil
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
        sightingAwaitingDial = nil
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
        scanning = false
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
            scheduleNextScan(now: now)
            return tick(now: now)
        }
        // The host MOVED: the standing session (if any) is unreachable by
        // construction — dial the new address now. Same address: the
        // network path demonstrably works, so a dead session (or a waived
        // threshold) dials right away; a merely silent one waits out the
        // redial threshold — evidence may still return.
        if match.address != lastKnownAddress
            || !sessionAlive || sameAddressRedialWaived {
            guard !dialInFlight else {
                // The dial in flight is the decision; this sighting is
                // next if it fails. Keep looking meanwhile.
                if match.address != dialInFlightTarget?.address {
                    sightingAwaitingDial = match
                }
                scheduleNextScan(now: now)
                return tick(now: now)
            }
            return dialSighting(match, now: now)
        }
        pendingSameAddressSighting = match
        // Keep scanning meanwhile (the host could still move).
        scheduleNextScan(now: now)
        return tick(now: now)
    }

    /// The dial the policy asked for never became a session (handshake
    /// timeout — commonly a host that hasn't freed the dead session
    /// yet). A sighting held during the dial is dialed now; otherwise
    /// back off on this target and resume scanning.
    /// Inert when no dial is in flight: a failure can only answer a dial
    /// this policy issued, never a straggler from an earlier session.
    public mutating func dialFailed(now: UInt64) -> [RoamingAction] {
        guard dialInFlight else { return [] }
        dialInFlight = false
        dialInFlightTarget = nil
        if let deadline = establishDeadline, now >= deadline {
            return expire()
        }
        if let held = sightingAwaitingDial {
            sightingAwaitingDial = nil
            return dialSighting(held, now: now)
        }
        nextDialAllowedAt = now &+ UInt64(dialRetryMicroseconds)
        dialRetryMicroseconds = min(
            dialRetryMicroseconds &* 2,
            config.dialRetryCeilingMicroseconds)
        if scanning, !scanInFlight, nextScanAt == nil { nextScanAt = now }
        return beginScanningIfNeeded(now: now) + tick(now: now)
    }

    // MARK: The beat

    /// Fires whatever deadlines have passed. Idempotent at one `now`.
    /// Dial-worthy verdicts are judged BEFORE scheduled scans, and a
    /// beat that commits to a dial launches no fresh browse — the
    /// dial is the decision; scanning resumes if it fails.
    public mutating func tick(now: UInt64) -> [RoamingAction] {
        if let deadline = establishDeadline, now >= deadline, !dialInFlight {
            return expire()
        }
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

    /// The first connect never established inside its budget.
    private mutating func expire() -> [RoamingAction] {
        establishDeadline = nil
        expired = true
        scanning = false
        nextScanAt = nil
        sightingAwaitingDial = nil
        return [.expired]
    }

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

    /// The next browse after the current gap, which then doubles.
    private mutating func scheduleNextScan(now: UInt64) {
        nextScanAt = now &+ UInt64(scanIntervalMicroseconds)
        scanIntervalMicroseconds = min(
            scanIntervalMicroseconds &* 2,
            config.scanIntervalCeilingMicroseconds)
    }

    /// Dials a sighted target at once. A new address also resets the
    /// dial ladder.
    private mutating func dialSighting(
        _ sighting: RoamingSighting, now: UInt64
    ) -> [RoamingAction] {
        if sighting.address != lastKnownAddress {
            dialRetryMicroseconds = config.dialRetryFloorMicroseconds
            nextDialAllowedAt = now
        }
        return dialNow(
            address: sighting.address, port: sighting.port,
            discovered: true, now: now)
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
