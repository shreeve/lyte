import LyteClientCore
import LyteTransport
import LyteWire

/// The dial driver: executes `RoamingPolicy`'s actions (discovery scans,
/// dials) and feeds their results back, from the connect's first dial to
/// every re-acquisition. The policy decides; this file owns the sockets,
/// browses, and session swaps — and fences every completion with the
/// lifecycle generation, so a scan or dial that outlives its window's
/// machinery (Disconnect, a new connect) is dropped and any session it
/// made is closed.
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
    /// per-host, drop the wire session, hunt the identity. The policy is
    /// born before any session, so every attached session has one.
    func beginRoamingAfterLoss(_ reason: SessionCloseReason) {
        guard roaming != nil else { return }
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
            case .dial(let address, let port, _):
                runRoamingDial(address: address, port: port)
            case .expired:
                endLyteSession(reason:
                    "Lyte-UDP connect: \(lastDialFailure ?? "no answer")")
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

    /// One dial: a 1-RTT Noise IK against the pinned static (never a
    /// re-PIN). The connect's first dial retries longest; every later one
    /// is short — a host that hasn't freed a dead session answers with
    /// silence, and the ladder retries rather than camping.
    private func runRoamingDial(address: String, port: UInt16) {
        detachWireSession(.goodbye)
        guard let pkh = hostPublicKeyHash,
              let pinned = services.loadPins().host(publicKeyHash: pkh),
              let hostStatic = pinned.staticPublicKey else {
            endLyteSession(reason: "\(hostName ?? "host") is no longer paired")
            return
        }
        dialsSinceConnect += 1
        let round = dialsSinceConnect
        // The connect looked the identity up interactively, so the process
        // cache holds it. Never summon SecurityAgent from an automatic path.
        guard let identity = services.cachedIdentity(),
              let crypto = try? NoiseTransportCrypto(
                hostAddress: address,
                hostPort: port,
                hostStaticPublicKey: hostStatic,
                staticKeys: identity,
                retry: round == 1 ? .firstDial : .redial)
        else {
            roamingInput { policy, now in policy.dialFailed(now: now) }
            return
        }
        // The LIVE posture rides every dial, not the per-host default:
        // the confirmed host-audio state, the current consent, and the
        // tier a chroma flip or fallback means.
        let config = LyteUdpSession.Config(
            hostAudioRouting: hostAudioPosture ?? pinned.sessionStartHostAudioRouting,
            shareClipboard: clipboardSharing,
            shareClipboardImages: clipboardImageSharing,
            chroma: chromaTier)
        // A newer dial supersedes one still in flight.
        abandonDial()
        let lyte = makeLyteSession(crypto: crypto, config: config)
        beginDial(lyte)
        HandshakeWitness.record("sessionStartBegin", fields: [
            "round": String(round), "host": address, "port": String(port),
        ])
        let generation = lifecycleGeneration
        let start = services.startSession
        let endSession = services.endSession
        Task { @MainActor [weak self] in
            do {
                try await start(lyte)
            } catch {
                HandshakeWitness.record("sessionStartFailed", fields: [
                    "round": String(round), "error": String(describing: error),
                ])
                guard let self else { return endSession(lyte, .silent) }
                // Abandoned: whoever abandoned it ended it.
                guard self.claimDial(lyte) else { return }
                // A dial that failed after binding still holds its socket.
                endSession(lyte, .silent)
                guard self.isCurrent(generation) else { return }
                self.dialFailed(error)
                return
            }
            HandshakeWitness.record("sessionStartCompleted", fields: [
                "round": String(round),
            ])
            guard let self else { return endSession(lyte, .goodbye) }
            guard self.claimDial(lyte) else { return }
            // The window disconnected (and perhaps connected afresh)
            // while this dial ran: the session has no owner.
            guard self.isCurrent(generation), self.lyteSession == nil else {
                endSession(lyte, .goodbye)
                return
            }
            self.adoptDialedSession(lyte, address: address, port: port)
        }
    }

    /// Before the first establishment only silence is worth another dial
    /// — a restarting host looks exactly like it; Local Network privacy
    /// and every refusal end the connect at once. Once streaming, every
    /// failure climbs the ladder.
    private func dialFailed(_ error: any Error) {
        if case .connecting = phase {
            switch DialFailure(error) {
            case .unanswered:
                lastDialFailure = String(describing: error)
                phase = .connecting("\(hostName ?? "The host") isn't answering — "
                    + "it may be restarting; still trying…")
            case .localNetwork(let problem):
                return endLyteSession(failure: .localNetwork(
                    problem, diagnosticDetail: String(describing: error)))
            case .refused:
                return endLyteSession(reason: "Lyte-UDP connect: \(error)")
            }
        }
        roamingInput { policy, now in policy.dialFailed(now: now) }
    }

    /// A dial became a session: swap it in without touching per-host
    /// state and refresh the pinned dial hints (the host lives HERE now).
    /// The connect's first session also opens the stream.
    private func adoptDialedSession(
        _ lyte: LyteUdpSession, address: String, port: UInt16
    ) {
        let first = if case .connecting = phase { true } else { false }
        if first, let pkh = hostPublicKeyHash {
            prepareBulkCoordinator(hostKey: pkh)
        }
        attach(lyte, address: address)
        // The refresh keeps pairedAt and every per-host preference.
        updatePin { store, pkh in
            guard let pinned = store.host(publicKeyHash: pkh),
                  let key = pinned.staticPublicKey,
                  pinned.address != address || pinned.port != port
            else { return false }
            store.pin(
                staticPublicKey: key, name: pinned.name,
                address: address, port: port, pairedAt: pinned.pairedAt)
            return true
        }
        roamingInput { policy, now in
            policy.sessionEstablished(address: address, port: port, now: now)
        }
        if first {
            phase = .streaming
            services.streamBegan()
        }
        replayPendingTerminal()
    }
}
