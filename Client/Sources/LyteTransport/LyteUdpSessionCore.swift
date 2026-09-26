// LyteUdpSessionCore: the client's synchronized protocol/media shell above
// the socket. It composes demux/sender, two ARQ endpoints (CTRL and chan 8,
// so a file transfer never head-of-line-blocks a keystroke), the IO-free
// ClientControlSession, and the media organs, behind one lock with an
// injected clock so tests drive the real assembly in virtual time.
// `LyteUdpSession` is the production shell that owns the socket.

import LyteClientCore
import LyteIO
import LyteCore
import LyteClientSession
import Dispatch
import Foundation
import LyteWire
import Synchronization

public final class LyteUdpSessionCore: @unchecked Sendable {
    public let config: LyteUdpSessionCoreConfig

    private let now: @Sendable () -> ClientTimestamp
    private let sender: TransportSender
    /// Makes the clipboard-image hasher (LyteCore's SHA-256 unless
    /// injected): a local copy is hashed whole, outside the lock; an
    /// incoming image one chunk per message.
    private let imageHasher: @Sendable () -> any ClipboardImageHasher
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let onVideoRecoveryDemand:
        @Sendable (VideoRecoveryCause, FrameNumber) -> Void
    private let onVideoRecoveryTrace:
        @Sendable (VideoRecoveryTraceEvent) -> Void

    // IUO because their callbacks reference self.
    public private(set) var pipeline: LyteVideoPipeline!
    public private(set) var reliable: ReliableCtrlEndpoint!
    public private(set) var bulkReliable: ReliableCtrlEndpoint!
    public private(set) var echoResponder: BeaconEchoResponder!
    public private(set) var feedback: FeedbackSender!
    public private(set) var input: InputSender!
    public private(set) var audio: AudioReceiver!
    public let clockModel: HostClockModel
    /// The IDR episode (also the render gate) and the NACK book, each under
    /// its own lock; their decisions execute after it is released.
    private let idrRecovery = Mutex(ClientIdrRecovery())
    private let nackPolicy: Mutex<ClientNackPolicy>

    // IO-free session policy + transport-owned counters, one lock.
    private let lock = NSLock()
    private var controlSession: ClientControlSession
    /// Transfer-id randomness injected into the IO-free image policy.
    private var imageRng = SystemRandomNumberGenerator()
    /// Every IDR's SPS chroma_format_idc against the agreed chroma.
    private var chromaAudit = ChromaStreamAudit()
    private var counters = LyteUdpSessionCounters()
    private var streamPoisoned = false
    /// The production machine-poll wake; nil until `startTimers()`.
    private var machineTimer: DispatchSourceTimer?

    /// Per-datagram evidence, off the hot path: each accepted datagram
    /// stamps this atomic instead of taking the lock for a machine pass.
    /// The 100 ms beat feeds the newest stamp at its true arrival instant,
    /// so detector and liveness bookkeeping stay exact; only the FROZEN
    /// exit needs datagram latency, which `machineFrozen` routes directly.
    private let lastEvidenceMicros = Atomic<UInt64>(0)
    private let machineFrozen = Atomic<Bool>(false)
    /// The stamp last fed to the machine (guarded by `lock`).
    private var lastFedEvidenceMicros: UInt64 = 0
    /// Lifecycle decisions are numbered under `lock` as they are made
    /// (the beat and the receive thread both make them) so their state
    /// and mode edges reach the owner in decision order: an edge older
    /// than one already delivered is superseded and dropped.
    /// `lifecycleTicketsIssued` is guarded by `lock`;
    /// `lifecycleEdgeDelivered` by `edgeLock`, which is held across the
    /// edge callbacks.
    private var lifecycleTicketsIssued: UInt64 = 0
    private var lifecycleEdgeDelivered: UInt64 = 0
    private let edgeLock = NSLock()
    /// Test hook between a lifecycle decision and its execution.
    var testingBeforeLifecycleExecution: (() -> Void)?

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        config: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        clockModel: HostClockModel = HostClockModel(),
        asynchronousVideoBuild: Bool = false,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(
                microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        imageHasher: @escaping @Sendable () -> any ClipboardImageHasher = {
            Sha256()
        },
        onVideoRecoveryDemand: @escaping @Sendable (
            VideoRecoveryCause, FrameNumber
        ) -> Void = { _, _ in },
        onVideoRecoveryTrace: @escaping @Sendable (
            VideoRecoveryTraceEvent
        ) -> Void = { _ in },
        videoSink: any VideoSink,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        let sessionSink = SessionVideoSink(downstream: videoSink)
        self.config = config
        self.clockModel = clockModel
        self.now = now
        self.sender = sender
        self.imageHasher = imageHasher
        self.onEvent = onEvent
        self.onVideoRecoveryDemand = onVideoRecoveryDemand
        self.onVideoRecoveryTrace = onVideoRecoveryTrace
        self.nackPolicy = Mutex(ClientNackPolicy(config: config.nackPolicy))
        // Constructed only after the handshake, so the machine starts ACTIVE.
        self.controlSession = ClientControlSession(
            localCapabilities: config.capabilities,
            desiredHostAudioRouting: config.desiredHostAudioRouting,
            clipboardSharingAtStart: config.shareClipboard,
            clipboardImageSharingAtStart: config.shareClipboardImages,
            tightenedBlackoutSilenceMicroseconds:
                config.tightenedBlackoutSilenceMicroseconds,
            now: now()
        )

        self.pipeline = LyteVideoPipeline(
            asynchronousSampleBuild: asynchronousVideoBuild,
            nowNanoseconds: { now().microseconds &* 1_000 },
            sink: sessionSink,
            onFecImpossible: { [weak self] frame, _, _ in
                // A frame with a live repair ask holds its IDR for the
                // repair window; everything else requests an IDR now.
                guard let self else { return }
                let now = self.now()
                if !self.nackPolicy.withLock({
                    $0.shouldDeferFecImpossible(frame: frame, now: now)
                }) {
                    self.beginVideoRecovery(
                        cause: .fecAssemblerDamage, frame: frame, now: now)
                }
            },
            onRepairSignal: { [weak self] signal, now in
                guard let self else { return }
                if case .framesGone(let from, _) = signal {
                    self.beginVideoRecovery(
                        cause: .hostPurgeInferredDamage,
                        frame: from, now: now)
                }
                self.handleRepairSignal(signal, now: now)
            },
            onSampleFailure: { [weak self] frame in
                // The frame never reaches the renderer, so the chain after
                // it cannot decode: the same coalesced IDR recovery.
                guard let self else { return }
                self.beginVideoRecovery(
                    cause: .rendererFailure, frame: frame, now: self.now())
            })
        self.reliable = ReliableCtrlEndpoint(
            sender: sender,
            now: now,
            onEvent: { [weak self] event in
                self?.dispatchReliable(event)
            })
        self.bulkReliable = ReliableCtrlEndpoint(
            sender: sender,
            channel: .bulkTransfer,
            now: now,
            onEvent: { [weak self] event in
                self?.dispatchBulk(event)
            })
        self.input = InputSender(
            clockModel: clockModel,
            send: { [weak self] message, now in
                try self?.reliable.send(message, now: now)
            })
        self.echoResponder = BeaconEchoResponder(
            now: now,
            onClockSample: { [weak self] in self?.clockModel.ingest($0) },
            emit: { [weak self] echo in
                guard let self else { return }
                _ = try? sender.send(
                    channel: .ctrl, timestamp: self.now(),
                    plaintext: echo.encode())
            })
        // The cadence beat retries an open IDR episode and runs the NACK
        // deadlines.
        self.feedback = FeedbackSender(
            demux: demux, sender: sender,
            onTick: { [weak self] tickNow in
                guard let self else { return }
                self.sendIdrRequest(
                    self.idrRecovery.withLock { $0.requestDue(now: tickNow) })
                self.tickNackPolicy(now: tickNow)
            })
        self.audio = AudioReceiver(jitterConfig: config.audioJitter)
        sessionSink.bind(self)
    }

    /// Pure session verdict at the native-media boundary. CoreMedia forwarding
    /// stays in `SessionVideoSink`; the core sees only the decoded wire unit.
    /// Returns true exactly when the adapter may submit downstream.
    func admitVideoUnit(_ unit: DecodeUnit) -> Bool {
        // Input→photon: delivery (not shard arrival) of a frame stamped
        // with lastInputSeq closes every pending event at or below it.
        // Upstream half of the renderer recovery gate: P samples already
        // queued when damage is discovered must not race the handoff flush.
        guard idrRecovery.withLock({ $0.admits(isRandomAccess: unit.isIDR) })
        else {
            onVideoRecoveryTrace(.init(
                kind: "coreRejectedNonIrap",
                frame: unit.frameNumber,
                isRandomAccess: false))
            return false
        }
        if unit.isIDR {
            onVideoRecoveryTrace(.init(
                kind: "coreForwardedIrap",
                frame: unit.frameNumber,
                isRandomAccess: true))
        }
        input.noteFrameDelivered(frame: unit.frameNumber, now: now())
        // Mismatched chroma is a doctor line, never a silent resample.
        if unit.isIDR {
            auditStreamChroma(annexB: unit.annexB)
        }
        return true
    }

    // MARK: Lifecycle

    /// Sends the capability declaration (0x0F) as the first reliable
    /// word, so everything gated on a capability orders behind it.
    public func open(now: ClientTimestamp? = nil) throws {
        guard let declaration = try lock.withLock({
            try controlSession.start()
        }) else { return }
        try reliable.send(declaration, now: now)
    }

    /// Production timers: ARQ PTO, pipeline eviction, feedback cadence and
    /// a 100 ms machine beat. Tests drive `tick(now:)` instead.
    public func startTimers() {
        reliable.start()
        bulkReliable.start()
        pipeline.start()
        feedback.start()
        lock.lock()
        defer { lock.unlock() }
        guard machineTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.machineBeat(now: self.now())
        }
        timer.resume()
        machineTimer = timer
    }

    public func stopTimers() {
        lock.lock()
        let timer = machineTimer
        machineTimer = nil
        lock.unlock()
        timer?.cancel()
        feedback.stop()
        reliable.stop()
        bulkReliable.stop()
        pipeline.stop()
    }

    /// One virtual-time beat for tests; feedback stays caller-driven.
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
        bulkReliable.tick(now: now)
        pipeline.tick(now: now)
        tickNackPolicy(now: now)
        machineBeat(now: now)
    }

    /// Feeds evidence stamped since the last beat at its true arrival
    /// instant, then polls the machine at `now`.
    private func machineBeat(now: ClientTimestamp) {
        let stamped = lastEvidenceMicros.load(ordering: .relaxed)
        var feed: ClientTimestamp?
        lock.lock()
        if stamped > lastFedEvidenceMicros {
            lastFedEvidenceMicros = stamped
            feed = ClientTimestamp(microseconds: stamped)
        }
        lock.unlock()
        if let feed { applyMachine(.mediaPathEvidence, now: feed) }
        applyMachine(nil, now: now)
    }

    /// Orderly local close: the typed teardown rides the ordered stream
    /// and the machine closes. The caller lingers on `isReliableQuiescent`
    /// before tearing the socket down.
    public func beginTeardown(
        reason: SessionTeardownReason, now: ClientTimestamp? = nil
    ) {
        applyMachine(.teardownRequest(reason), now: now ?? self.now())
    }

    // MARK: Input

    /// Queues one input event (0x16) on the reliable ordered stream and
    /// returns its seq. Never gated on wire mode or FROZEN: the host
    /// pre-arms on every delivered event, so input in IDLE is the wake.
    @discardableResult
    public func sendInput(
        _ body: InputEvent.Body, now: ClientTimestamp? = nil
    ) throws -> UInt32 {
        try input.send(body, now: now ?? self.now())
    }

    /// The event carries `captured`; ARQ runs at `now()` so queue wait
    /// never inflates RTT samples.
    @discardableResult
    public func sendInput(
        _ body: InputEvent.Body, captured: ClientTimestamp
    ) throws -> UInt32 {
        try input.send(body, captured: captured, now: now())
    }

    /// Renderer failure/backpressure joins the coalesced IDR recovery. The
    /// handoff raised it and already awaits an IRAP, so it is not told.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause = .rendererFailure
    ) {
        beginVideoRecovery(
            cause: cause, frame: frame, now: now(), notifyHandoff: false)
    }

    /// The sole close seam: AVFoundation accepted the IRAP into its queue.
    /// Only an IRAP that closed the handoff's own gate closes the episode:
    /// one enqueued before the handoff has learned of the damage leaves
    /// the episode (and its retries) open for the gate that follows.
    public func noteVideoIrapEnqueued(
        frame: FrameNumber = FrameNumber(rawValue: 0),
        closesRecovery: Bool = true
    ) {
        guard closesRecovery else {
            onVideoRecoveryTrace(.init(
                kind: "coreIrapEnqueuedOutsideRendererGate",
                frame: frame,
                isRandomAccess: true))
            return
        }
        idrRecovery.withLock { $0.noteUsableIrapAccepted() }
        onVideoRecoveryTrace(.init(
            kind: "coreRecoveryClosedAfterIrapEnqueue",
            frame: frame,
            isRandomAccess: true))
    }

    /// The handoff opened an await-IRAP gate for this core's demand: an
    /// episode closed meanwhile reopens, with an IDR request due now.
    public func ensureVideoRecoveryOpen(
        after frame: FrameNumber, cause: VideoRecoveryCause
    ) {
        let now = now()
        let request = idrRecovery.withLock { recovery -> IdrRequest? in
            guard !recovery.isOutstanding else { return nil }
            recovery.recordDemand(frame: frame)
            return recovery.requestDue(now: now)
        }
        guard let request else { return }
        sendIdrRequest(request)
        noteVideoRecoveryOpened(cause: cause, frame: frame)
        onVideoRecoveryTrace(.init(
            kind: "coreRecoveryReopenedForRendererGate",
            frame: frame,
            cause: cause))
    }

    /// Damage found upstream of the handoff opens its gate too
    /// (`notifyHandoff`); a demand the handoff raised is never echoed back
    /// into it, where it would discard the IRAP it already holds.
    func beginVideoRecovery(
        cause: VideoRecoveryCause,
        frame: FrameNumber,
        now: ClientTimestamp,
        notifyHandoff: Bool = true
    ) {
        // The episode gates this core's render seam at once; the
        // handoff's own gate follows before any later sink submit.
        // The first verdict emits at once; later ones join its episode and
        // emit only when its retry is due.
        let (overlap, request) = idrRecovery.withLock {
            ($0.recordDemand(frame: frame), $0.requestDue(now: now))
        }
        sendIdrRequest(request)
        if !overlap { noteVideoRecoveryOpened(cause: cause, frame: frame) }
        onVideoRecoveryTrace(.init(
            kind: overlap ? "coreDamageOverlap" : "coreDamageKnown",
            frame: frame,
            cause: cause))
        if notifyHandoff { onVideoRecoveryDemand(cause, frame) }
    }

    /// The one place an episode's cause is booked and announced.
    private func noteVideoRecoveryOpened(
        cause: VideoRecoveryCause, frame: FrameNumber
    ) {
        lock.withLock {
            counters.videoRecoveryEpisodesByCause[cause, default: 0] &+= 1
        }
        onEvent(.videoRecoveryRequested(cause: cause, frame: frame))
    }

    private func sendIdrRequest(_ request: IdrRequest?) {
        guard let request else { return }
        _ = try? sender.send(
            channel: .ctrl, timestamp: now(), plaintext: request.encode())
    }

    // MARK: NACK repair

    /// The clock model's RTT (a lock of its own) is read only for the
    /// signal that uses it: every shard's signal passes here.
    private func handleRepairSignal(
        _ signal: VideoRepairSignal, now: ClientTimestamp
    ) {
        var rtt: Int64?
        if case .nackCandidates = signal {
            rtt = clockModel.estimate()?.minRttMicroseconds
        }
        executeNack(nackPolicy.withLock {
            $0.handle(signal, rttMicroseconds: rtt, now: now)
        }, now: now)
    }

    /// Rule-4 deadlines and book hygiene.
    private func tickNackPolicy(now: ClientTimestamp) {
        executeNack(nackPolicy.withLock { $0.tick(now: now) }, now: now)
    }

    /// Asks are reported at once: the host's freeze budget derives from
    /// the feedback cadence. Escalations (expiries, framesGone and host
    /// refusals alike) join the IDR recovery.
    private func executeNack(
        _ decision: ClientNackPolicy.Decision, now: ClientTimestamp
    ) {
        if !decision.nacks.isEmpty {
            feedback.enqueueNacks(decision.nacks)
            feedback.tick(now: self.now())
            for entry in decision.nacks {
                onEvent(.protocolNote(
                    "nack: frame \(entry.frame.rawValue) asks "
                    + "shards \(entry.missingShards)"))
            }
        }
        for frame in decision.escalations {
            beginVideoRecovery(
                cause: .repairAbandoned, frame: frame, now: now)
            onEvent(.protocolNote(
                "nack: frame \(frame.rawValue) repair abandoned — "
                + "IDR instead"))
        }
    }

    // MARK: Host audio routing

    /// Asks the host to flip its own speakers (0x18). Refused without
    /// negotiated key 9 or before the exchange settled. The posture changes
    /// only when the host's 0x19 answer says so.
    public func requestHostAudioRouting(
        _ mode: HostAudioRoutingMode, now: ClientTimestamp? = nil
    ) throws {
        let bytes = try lock.withLock {
            let bytes = try controlSession.requestHostAudioRouting(mode)
            counters.audioRoutingRequestsSent += 1
            return bytes
        }
        try reliable.send(bytes, now: now)
    }

    // MARK: Clipboard

    /// True when capability key 10 survived intersection.
    public var clipboardNegotiated: Bool {
        lock.withLock { controlSession.clipboardNegotiated }
    }

    /// Local policy only (no wire message): a disabled end goes quiet
    /// and deaf.
    public func setClipboardSharing(_ enabled: Bool) {
        lock.withLock { controlSession.setClipboardSharing(enabled) }
    }

    /// Shares one local clipboard change as 0x1A when policy allows.
    /// Never throws; the outcome is counted and returned.
    @discardableResult
    public func shareLocalClipboard(
        _ text: String, now: ClientTimestamp? = nil
    ) -> ClipboardShareOutcome {
        lock.lock()
        let decision = controlSession.shareLocalClipboard(text)
        switch decision.shareOutcome {
        case .suppressedEcho, .suppressedDuplicate:
            counters.clipboardLoopSuppressed += 1
        default:
            break
        }
        lock.unlock()
        guard decision.shareOutcome == .shared,
              let message = decision.outboundReliable.first
        else {
            return decision.shareOutcome ?? .sendRefused(
                "clipboard policy returned no outcome")
        }
        do { try reliable.send(message, now: now) }
        catch { return .sendRefused(String(describing: error)) }
        lock.lock()
        controlSession.noteLocalClipboardSent(text)
        counters.clipboardSharesSent += 1
        lock.unlock()
        return .shared
    }

    // MARK: Clipboard images

    /// Local policy only; a disabled end answers an inbound marker with
    /// abort(declined) because the image sender waits on a verdict.
    public func setClipboardImageSharing(_ enabled: Bool) {
        lock.withLock { controlSession.setClipboardImageSharing(enabled) }
    }

    /// Shares one local image copy as 0x22 cargo on chan 8 when policy
    /// allows. Never throws. Cheap gates run under the lock, the digest
    /// outside it (tens of MiB must not stall dispatch), then the full
    /// judgment; a refused image is never hashed.
    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8], now: ClientTimestamp? = nil
    ) -> ClipboardShareOutcome {
        let now = now ?? self.now()
        lock.lock()
        let refusal = controlSession.prejudgeLocalClipboardImage(
            byteCount: data.count)
        lock.unlock()
        if let refusal {
            return executeClipboardDecision(refusal, now: now)
        }
        var hasher = imageHasher()
        hasher.absorb(data[...])
        let digest = hasher.finish()
        lock.lock()
        let decision = controlSession.shareLocalClipboardImage(
            data, sha256: { digest }, rng: &imageRng
        )
        lock.unlock()
        return executeClipboardDecision(decision, now: now)
    }

    /// Executes a clipboard decision's sends and events and returns the
    /// share verdict. Called outside the lock (ARQ callbacks take it).
    @discardableResult
    private func executeClipboardDecision(
        _ decision: ClientClipboardSessionDecision,
        now: ClientTimestamp
    ) -> ClipboardShareOutcome {
        var outcome = decision.shareOutcome ?? .shared
        for bytes in decision.outboundBulk {
            do {
                try bulkReliable.send(bytes, now: now)
            } catch {
                outcome = .sendRefused(String(describing: error))
            }
        }
        for event in decision.events {
            switch event {
            case .image(.shareCompleted(_, let byteCount)):
                onEvent(.protocolNote(
                    "clipboard image landed on the host sha-exact "
                        + "(\(byteCount) B)"))
            case .image(.shareAborted(let reason, let byRemote)):
                onEvent(.protocolNote(
                    "clipboard image share aborted "
                        + "(\(reason), \(byRemote ? "remote" : "local"))"))
            case .image(.receiveAborted(let reason, let byRemote)):
                onEvent(.protocolNote(
                    "incoming clipboard image aborted "
                        + "(\(reason), \(byRemote ? "remote" : "local"))"))
            case .image(.refused(let reason)):
                onEvent(.protocolNote(
                    "incoming clipboard image refused (\(reason))"))
            case .image(.applyImage(let data, let mime)):
                onEvent(.hostClipboardImageChanged(data: data, mime: mime))
            case .image(.violated(let violation)):
                onEvent(.protocolNote(
                    "clipboard image lane violation: \(violation)"))
            case .image(.send):
                onEvent(.protocolNote(
                    "clipboard policy leaked an unseparated send event"))
            default:
                break
            }
        }
        return outcome
    }

    // MARK: Bulk transfer

    /// Queues one bulk message on chan 8; refused without key 11.
    public func sendBulkMessage(
        _ message: [UInt8], now: ClientTimestamp? = nil
    ) throws {
        lock.lock()
        guard controlSession.agreedCapabilities?.bulkTransfer == true else {
            lock.unlock()
            throw BulkChannelError.notNegotiated
        }
        counters.bulkMessagesSent += 1
        lock.unlock()
        try bulkReliable.send(message, now: now)
    }

    // MARK: Ingest

    /// Routes one accepted datagram to its consumer and stamps it as path
    /// evidence. The arrival stamp is discarded: it is SystemMonotonicClock
    /// time, while every clock here runs on the injected `now()`.
    public func handleDatagram(
        _ outcome: IngestOutcome, arrivalMicroseconds _: UInt64
    ) {
        guard case .accepted(let envelope, let payload) = outcome else {
            return
        }
        let now = now()
        if envelope.channel == .ctrl {
            // 0x07/0x08 are ARQ; everything else is an exempt path.
            if !reliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now
            ) {
                handleExemptCtrl(payload, now: now)
            }
            // Chan 8 borrows the conn-id the moment CTRL learns it, so its
            // first datagram already carries the tag.
            bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
        } else if envelope.channel == pipeline.channel {
            // Record the lastInputSeq TLV before ingest: delivery may
            // fire from this same pass.
            input.noteVideoShard(envelope: envelope)
            pipeline.ingest(envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .bulkTransfer {
            // Chan 8 is wholly ARQ.
            _ = bulkReliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .audio {
            // Audio flows in every non-closed state, so the first audio
            // datagram tightens the blackout detector.
            lock.lock()
            counters.audioDatagramsReceived += 1
            let posture = controlSession.noteAudioEvidence(now: now)
            lock.unlock()
            audio.ingest(envelope: envelope, payload: payload, now: now)
            // The next applyMachine pass surfaces any edge this caused.
            notePosture(posture)
        }
        // Stamp evidence for the beat; only FROZEN must act immediately.
        lastEvidenceMicros.store(now.microseconds, ordering: .relaxed)
        if machineFrozen.load(ordering: .relaxed) {
            applyMachine(.mediaPathEvidence, now: now)
        }
    }

    /// ARQ-exempt CTRL, classified by the shared session vocabulary: a
    /// beacon is echoed, a path challenge answered on the path it probed,
    /// a 0x23 repair refusal escalates that frame to an IDR now. Unknown
    /// types are skipped silently (the forward-compat contract);
    /// malformed words count and drop.
    private func handleExemptCtrl(
        _ payload: [UInt8], now: ClientTimestamp
    ) {
        switch ClientExemptControl(payload: payload) {
        case .clockBeacon(let beacon):
            echoResponder.answer(beacon, arrivalMicroseconds: now.microseconds)
        case .pathChallenge(let response):
            // The reply leaves from wherever this socket now sends, which
            // is the tuple the host probed; the tag names the session.
            let tag = reliable.learnedConnectionId.map { [$0.wireExtension] }
            do {
                _ = try sender.send(
                    channel: .ctrl, timestamp: self.now(),
                    plaintext: response.encode(), extensions: tag ?? [])
                lock.withLock { counters.pathChallengesAnswered += 1 }
            } catch {
                onEvent(.protocolNote("path response send refused: \(error)"))
            }
        case .repairRefused(let refusal):
            onEvent(.protocolNote(
                "nack: frame \(refusal.frame.rawValue) repair refused "
                + "by host (\(refusal.reason)) — IDR now"))
            executeNack(nackPolicy.withLock {
                $0.handleRefusal(frame: refusal.frame, now: now)
            }, now: now)
        case .malformed(type: CtrlMessageType.clockBeacon):
            echoResponder.noteMalformedBeacon()
        case .malformed(type: CtrlMessageType.pathChallenge):
            noteMalformed("path challenge")
        case .malformed:
            noteMalformed("repair refusal")
        case .unclaimed:
            break
        }
    }

    private func notePosture(_ posture: ClientDetectorPosture?) {
        if let posture { onEvent(.protocolNote(posture.note)) }
    }

    /// Audits one IDR's in-band SPS chroma; no parseable SPS says nothing.
    private func auditStreamChroma(annexB: [UInt8]) {
        guard let idc = HevcSpsChroma.chromaFormatIdc(inAnnexB: annexB)
        else { return }
        lock.lock()
        let line = chromaAudit.observe(
            chromaFormatIdc: idc,
            agreedChromaModes: controlSession.agreedCapabilities?.chromaModes)
        lock.unlock()
        if let line { onEvent(.protocolNote(line)) }
    }

    // MARK: Snapshots

    /// The control policy as it stands (a value copy).
    public var control: ClientControlSession {
        lock.withLock { controlSession }
    }

    /// True between an accepted quiet announcement and the next accepted
    /// active announcement or authenticated audio datagram.
    public var hostAnnouncedAudioQuiet: Bool {
        lock.withLock { controlSession.hostAnnouncedAudioQuiet }
    }

    /// Observed stream chroma ("4:2:0"/"4:4:4"); nil before the first
    /// IDR with in-band parameter sets.
    public var streamChromaDescription: String? {
        lock.withLock { chromaAudit.observedDescription }
    }

    public var state: SessionState {
        lock.withLock { controlSession.state }
    }

    /// True once a host message over the ARQ ceiling ended the session
    /// (the close itself reads `.localTeardown(.shuttingDown)`).
    public var orderedStreamPoisoned: Bool {
        lock.withLock { streamPoisoned }
    }

    public var agreedCapabilities: Capabilities? {
        lock.withLock { controlSession.agreedCapabilities }
    }

    /// True when capability key 9 survived intersection.
    public var hostAudioRoutingNegotiated: Bool {
        lock.withLock { controlSession.hostAudioRoutingNegotiated }
    }

    public var isReliableQuiescent: Bool { reliable.isQuiescent }

    public func snapshotCounters() -> LyteUdpSessionCounters {
        lock.withLock { counters }
    }

    public var idrStats: ClientIdrRecovery.Stats {
        idrRecovery.withLock { $0.stats }
    }

    public var nackStats: ClientNackPolicy.Stats {
        nackPolicy.withLock { $0.stats }
    }

    // MARK: The machine

    /// The single funnel for every lifecycle mutation (nil input = beat).
    private func applyMachine(
        _ input: SessionInput?, now: ClientTimestamp
    ) {
        lock.lock()
        let decision = controlSession.advance(input, now: now)
        machineFrozen.store(decision.state == .frozen, ordering: .relaxed)
        let ticket = issueLifecycleTicketLocked()
        lock.unlock()

        executeLifecycle(decision, ticket: ticket, now: now)
    }

    /// Call under `lock`, in the critical section that made the decision.
    private func issueLifecycleTicketLocked() -> UInt64 {
        lifecycleTicketsIssued += 1
        return lifecycleTicketsIssued
    }

    /// Executes a pure lifecycle decision after the session lock is
    /// released. Actions always run; state and mode edges are delivered
    /// only when no newer decision's edges already were.
    private func executeLifecycle(
        _ decision: ClientSessionLifecycleDecision,
        ticket: UInt64,
        now: ClientTimestamp
    ) {
        testingBeforeLifecycleExecution?()
        for effect in decision.effects {
            switch effect {
            case .sendTeardown(let reason, let message):
                do {
                    try reliable.send(message, now: now)
                    onEvent(.teardownSent(reason))
                } catch {
                    onEvent(.protocolNote(
                        "teardown send refused: \(error)"))
                }
            case .closed(let reason):
                onEvent(.closed(reason))
            }
        }
        guard decision.wireModeChange != nil || decision.stateChange != nil
        else { return }
        edgeLock.lock()
        defer { edgeLock.unlock() }
        guard ticket > lifecycleEdgeDelivered else { return }
        lifecycleEdgeDelivered = ticket
        if let mode = decision.wireModeChange {
            onEvent(.modeChanged(mode))
        }
        if let state = decision.stateChange {
            onEvent(.stateChanged(state))
        }
    }

    // MARK: Reliable dispatch

    /// Dispatches ARQ deliveries: the control session is offered every
    /// word first and claims the ones it owns, so a word added to it is
    /// routed here with no second list; the shell keeps only the media
    /// words. Hostile bytes are counted, never fatal.
    private func dispatchReliable(_ event: ArqEvent) {
        if event == .ignored(.orderedStreamPoisoned) {
            return endPoisonedSession(lane: "CTRL")
        }
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        if receiveControlWord(bytes, now: now) { return }
        switch bytes.first {
        case CtrlMessageType.idleFrame:
            receiveIdleFrame(bytes)

        case CtrlMessageType.inputEcho:
            guard let echo = try? InputEcho.decode(bytes) else {
                noteMalformed("input echo")
                return
            }
            lock.withLock { counters.inputEchoMessagesReceived += 1 }
            input.handleEcho(echo, now: now)

        default:
            lock.withLock { counters.unknownReliableTypes += 1 }
            onEvent(.protocolNote(
                "unregistered reliable CTRL type "
                    + Hex.string(bytes.first ?? 0, width: 2, prefix: true)
                    + " (\(bytes.count) B)"))
        }
    }

    /// The control session judges; the shell counts, sends, surfaces
    /// events and executes lifecycle actions. False when no control organ
    /// claims the word.
    private func receiveControlWord(
        _ bytes: [UInt8], now: ClientTimestamp
    ) -> Bool {
        lock.lock()
        let decision: ClientControlSessionDecision?
        do {
            decision = try controlSession.receiveReliable(bytes, now: now)
        } catch {
            lock.unlock()
            onEvent(.protocolNote(
                "control response encoding refused: \(error)"))
            return true
        }
        for counter in decision?.counters ?? [] {
            counters.bump(counter)
        }
        var lifecycleTicket: UInt64 = 0
        if let lifecycle = decision?.lifecycle {
            machineFrozen.store(
                lifecycle.state == .frozen, ordering: .relaxed)
            lifecycleTicket = issueLifecycleTicketLocked()
        }
        lock.unlock()
        guard let decision else { return false }

        if case .audioRouting(.status(let mode, startup: _)) = decision.event {
            onEvent(.hostAudioRoutingStatus(mode))
        }

        for outbound in decision.outboundReliable {
            do {
                try reliable.send(outbound, now: now)
            } catch {
                if case .audioRouting(.status(
                    _, startup: .requested
                )) = decision.event {
                    onEvent(.protocolNote(
                        "session-start posture ask refused: \(error)"))
                } else {
                    onEvent(.protocolNote(
                        "control response send refused: \(error)"))
                }
                return true
            }
        }

        if let note = decision.note {
            onEvent(.protocolNote(note))
        }
        notePosture(decision.detectorPosture)
        switch decision.event {
        case .capability(.agreed(let intersection)):
            onEvent(.capabilitiesAgreed(intersection))
        case .capability(.failed(let failure)):
            onEvent(.capabilitiesFailed(failure))
        case .capability(.updateAnswered(let accepted)):
            onEvent(.capabilityUpdateAnswered(accepted: accepted))
        case .clipboard(.textChanged(let text)):
            onEvent(.hostClipboardChanged(text))
        case .cursor(.shape(let shape)):
            onEvent(.hostCursorShapeChanged(shape))
        case .mediaPosture(.audioState(let state)) where state.state == .quiet:
            audio.noteAnnouncedQuiet()
        default:
            break
        }
        if let lifecycle = decision.lifecycle {
            executeLifecycle(lifecycle, ticket: lifecycleTicket, now: now)
        }
        return true
    }

    /// Chan 8 carries two lanes: 0x22 markers and bulk messages the image
    /// channel claims go to clipboard; the rest is the file lane. Each lane
    /// has its own capability gate; refused bytes drop loud, payload never
    /// logged.
    private func dispatchBulk(_ event: ArqEvent) {
        if event == .ignored(.orderedStreamPoisoned) {
            return endPoisonedSession(lane: "chan-8")
        }
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        if bytes.first == CtrlMessageType.clipboardImageCargo {
            receiveImageCargo(bytes, now: now)
            return
        }
        guard let message = try? BulkMessage.decode(bytes) else {
            lock.withLock { counters.bulkDropsLoud += 1 }
            onEvent(.protocolNote(
                "malformed bulk message dropped (type "
                    + Hex.string(bytes.first ?? 0, width: 2, prefix: true)
                    + ", \(bytes.count) B)"))
            return
        }
        lock.lock()
        if controlSession.clipboardClaimsBulk(message) {
            let decision = controlSession.receiveClipboardBulk(
                message, hasher: imageHasher)
            lock.unlock()
            executeClipboardDecision(decision, now: now)
            return
        }
        guard controlSession.agreedCapabilities?.bulkTransfer == true else {
            counters.bulkDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "bulk message without negotiated key 11 — dropped"))
            return
        }
        counters.bulkMessagesReceived += 1
        lock.unlock()
        onEvent(.bulkMessageReceived(message))
    }

    /// A welcome 0x22 marker arms the receive lane for the offer behind
    /// it; an unwelcome one draws abort(declined) so the trailing offer
    /// never leaks to the file lane.
    private func receiveImageCargo(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        let decision = lock.withLock {
            controlSession.receiveClipboardImageCargo(bytes)
        }
        for event in decision.events {
            let note: String
            switch event {
            case .malformedImageCargo(let byteCount):
                note = "malformed clipboard-image marker dropped "
                    + "(\(byteCount) B)"
            case .unnegotiatedImageCargo:
                note = "clipboard-image 0x22 without negotiated keys 10∧12 "
                    + "— dropped"
            default:
                continue
            }
            lock.withLock { counters.clipboardDropsLoud += 1 }
            onEvent(.protocolNote(note))
        }
        executeClipboardDecision(decision, now: now)
    }

    /// Renders a 0x15 idle frame through the pipeline (which dedupes it
    /// against the datagram path).
    private func receiveIdleFrame(_ bytes: [UInt8]) {
        guard let idle = try? IdleFrame.decode(bytes) else {
            noteMalformed("idle frame")
            return
        }
        lock.withLock { counters.idleFramesReceived += 1 }
        let outcome = pipeline.ingestReliableFrame(
            frame: idle.frame,
            captureTimestampMicroseconds: idle.captureTimestampMicroseconds,
            annexB: idle.annexB
        )
        onEvent(.idleFrameReceived(
            frame: idle.frame.rawValue, outcome: outcome))
    }

    /// The host broke an ordered stream with a message over the shared
    /// ceiling: it can never deliver in order again, so the session ends
    /// with a typed teardown. Later poisoned segments repeat the verdict;
    /// only the first acts.
    private func endPoisonedSession(lane: String) {
        lock.lock()
        let first = !streamPoisoned
        streamPoisoned = true
        lock.unlock()
        guard first else { return }
        onEvent(.protocolNote(
            "\(lane) ordered stream poisoned by an over-budget host "
            + "message — session ends"))
        onEvent(.orderedStreamPoisoned)
        applyMachine(.teardownRequest(.shuttingDown), now: now())
    }

    private func noteMalformed(_ what: String) {
        lock.withLock { counters.malformedReliableMessages += 1 }
        onEvent(.protocolNote("malformed \(what) dropped"))
    }
}

/// The core is the recovery peer behind `LyteUdpSession`'s forwarding
/// conformance; a handoff may bind it directly.
extension LyteUdpSessionCore: VideoRecoveryPeer {}
