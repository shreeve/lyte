import LyteClientCore
import LyteTransport
import LyteWire

/// The roaming driver: executes `RoamingPolicy`'s actions (discovery
/// scans, re-dials) and feeds their results back. The policy decides; this
/// file owns the sockets, browses, and session swaps — and fences every
/// completion with the lifecycle generation, so a scan or dial that
/// outlives its roaming machinery (Disconnect, a new connect) is dropped
/// and any session it made is closed.
extension ConnectionModel {
    /// The Actions menu's Reconnect verb: tear the wire session down
    /// (typed goodbye) and act now — a probe dial at the last-known
    /// address plus a discovery scan, ladders reset.
    func reconnectNow() {
        guard roaming != nil else { return }
        detachWireSession(.goodbye)
        roamingInput { policy, now in policy.manualReconnect(now: now) }
    }

    func startRoamingMachinery(
        publicKeyHash: String, address: String, port: UInt16
    ) {
        advanceLifecycle()
        roaming = RoamingPolicy(
            targetPublicKeyHash: publicKeyHash,
            address: address, port: port)
        roamingStatus = .attached
        // The Mac hopped networks: migration gets the policy's grace to
        // carry the session; the ladder runs only if the path stays dark.
        stopPathWatch = services.watchPath { [weak self] in
            Task { @MainActor [weak self] in
                self?.roamingInput { policy, now in policy.pathChanged(now: now) }
            }
        }
    }

    func stopRoamingMachinery() {
        advanceLifecycle()
        roamingTask?.cancel()
        roamingTask = nil
        roaming = nil
        roamingStatus = .attached
        stopPathWatch?()
        stopPathWatch = nil
    }

    /// The peer is gone (liveness) or restarting (its goodbye): keep the
    /// window (the last frame + the roaming banner), keep everything
    /// per-host, drop the wire session, hunt the identity.
    func beginRoamingAfterLoss(_ reason: SessionCloseReason) {
        guard roaming != nil else {
            // No identity to hunt: the policy is born with a pinned
            // session, so only an unpinned window lands here.
            endLyteSession(reason: reason == .livenessTimeout
                ? "host unreachable for 30 s" : nil)
            return
        }
        // A closed session has nobody to say goodbye to.
        detachWireSession(.silent)
        roamingInput { policy, now in policy.sessionClosed(now: now) }
    }

    /// One policy interaction: mutate under the injected clock, execute
    /// the actions, mirror the status, re-arm the deadline task. The
    /// single funnel for every roaming mutation.
    func roamingInput(
        _ mutate: (inout RoamingPolicy, UInt64) -> [RoamingAction]
    ) {
        guard var policy = roaming else { return }
        let actions = mutate(&policy, services.now())
        roaming = policy
        roamingStatus = policy.status
        for action in actions {
            switch action {
            case .beginScan:
                runRoamingScan()
            case .dial(let address, let port, let discovered):
                runRoamingDial(address: address, port: port, discovered: discovered)
            }
        }
        armRoamingTask()
    }

    /// One standing task sleeps to the policy's next deadline and ticks.
    private func armRoamingTask() {
        roamingTask?.cancel()
        roamingTask = nil
        guard let deadline = roaming?.nextDeadline else { return }
        let clock = services.now
        roamingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = clock()
                guard now < deadline else { break }
                try? await Task.sleep(nanoseconds: (deadline - now) * 1_000)
            }
            guard !Task.isCancelled else { return }
            self?.roamingTask = nil
            self?.roamingInput { policy, now in policy.tick(now: now) }
        }
    }

    /// One quiet browse pass; the completion answers the policy that
    /// asked (the beginScan/scanCompleted contract) and nobody else.
    private func runRoamingScan() {
        let generation = lifecycleGeneration
        let browse = services.browse
        Task { @MainActor [weak self] in
            let hosts = await browse(2.0)
            guard let self, self.isCurrent(generation) else { return }
            if let name = self.hostName, let pkh = self.hostPublicKeyHash,
               Self.identityReplaced(in: hosts, name: name, publicKeyHash: pkh) {
                // No ladder can reach the pinned identity any more.
                self.endLyteSession(reason: Self.identityReplacedMessage(name))
                return
            }
            let sightings = hosts.compactMap { host -> RoamingSighting? in
                guard let pkh = host.publicKeyHash else { return nil }
                return RoamingSighting(
                    publicKeyHash: pkh, address: host.address, port: host.port)
            }
            self.roamingInput { policy, now in
                policy.scanCompleted(sightings: sightings, now: now)
            }
        }
    }

    /// One re-acquisition dial: fresh 1-RTT Noise IK against the same
    /// pinned static (no re-PIN). A shorter retry window than the first
    /// connect: a host that hasn't freed the dead session answers with
    /// silence, and the ladder retries rather than camping.
    private func runRoamingDial(address: String, port: UInt16, discovered: Bool) {
        detachWireSession(.goodbye)
        guard let pkh = hostPublicKeyHash,
              let pinned = services.loadPins().host(publicKeyHash: pkh),
              let hostStatic = pinned.staticPublicKey else {
            endLyteSession(reason: "\(hostName ?? "host") is no longer paired")
            return
        }
        // A roaming dial follows an established session, so the process
        // cache holds the identity. Never summon SecurityAgent from an
        // automatic path.
        guard let identity = services.cachedIdentity(),
              let crypto = try? NoiseTransportCrypto(
                hostAddress: address,
                hostPort: port,
                hostStaticPublicKey: hostStatic,
                staticKeys: identity,
                attempts: 3,
                attemptTimeoutMilliseconds: 700)
        else {
            roamingInput { policy, now in policy.dialFailed(now: now) }
            return
        }
        // The LIVE posture rides every re-dial, not the per-host default:
        // the confirmed host-audio state, the current consent, and the
        // tier a chroma flip or fallback means.
        let config = LyteUdpSession.Config(
            hostAudioRouting: hostAudioPosture ?? pinned.sessionStartHostAudioRouting,
            shareClipboard: clipboardSharing,
            shareClipboardImages: clipboardImageSharing,
            chroma: chromaTier)
        let lyte = makeLyteSession(crypto: crypto, config: config)
        let generation = lifecycleGeneration
        let start = services.startSession
        let endSession = services.endSession
        Task { @MainActor [weak self] in
            do {
                try await start(lyte)
            } catch {
                endSession(lyte, .silent)
                guard let self, self.isCurrent(generation) else { return }
                self.roamingInput { policy, now in policy.dialFailed(now: now) }
                return
            }
            // The window disconnected (and perhaps connected afresh)
            // while this dial ran: the session has no owner.
            guard let self, self.isCurrent(generation),
                  self.lyteSession == nil else {
                endSession(lyte, .goodbye)
                return
            }
            self.adoptReconnectedSession(lyte, address: address, port: port)
        }
    }

    /// A re-dial became a session: swap it in without touching per-host
    /// state and refresh the pinned dial hints (the host lives HERE now).
    private func adoptReconnectedSession(
        _ lyte: LyteUdpSession, address: String, port: UInt16
    ) {
        attach(lyte, address: address)
        // The refresh keeps pairedAt and every per-host preference.
        updatePin { store, pkh in
            guard let pinned = store.host(publicKeyHash: pkh),
                  let key = pinned.staticPublicKey else { return false }
            store.pin(
                staticPublicKey: key, name: pinned.name,
                address: address, port: port, pairedAt: pinned.pairedAt)
            return true
        }
        roamingInput { policy, now in
            policy.sessionEstablished(address: address, port: port, now: now)
        }
        replayPendingTerminal()
    }
}
