// LyteUdpSessionCore: the client's synchronized protocol/media shell above
// the socket. It composes the parts —
//
//   ReceiveDemux / TransportSender (seal/unseal, header-as-AAD)
//     → ReliableCtrlEndpoint ×2 (ARQ on CTRL; a second on chan 8, so a
//       file transfer never head-of-line-blocks a keystroke)
//         → ClientControlSession (IO-free capability, lifecycle, audio
//           routing, clipboard, cursor and media-posture judgment). The
//           capability declaration (0x0F) is the first reliable word each
//           way; everything gated on a capability orders behind it.
//         → IdleFrame 0x15 → LyteVideoPipeline.ingestReliableFrame
//     → LyteVideoPipeline (chan 2 video), AudioReceiver (chan 1),
//       FeedbackSender, BeaconEchoResponder → HostClockModel,
//       IdrRequester, NackPolicy, InputSender
//
// — behind one lock, with an injected clock, so tests drive the real
// assembly in virtual time against a LyteWire host. `LyteUdpSession` is
// the production shell that binds the socket and runs the handshake.
//
// The blackout detector: every authenticated host arrival (video shards,
// sealed CTRL, beacons, audio) is receiver-side evidence that the
// host→client path moves. The default threshold is 2.5 s, past an idle
// host's 1 Hz beacons and far under the 30 s liveness teardown; the first
// audio datagram re-arms it at 350 ms, and an announced audio quiet
// relaxes it back until audio resumes.

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
    /// Makes the clipboard-image hasher (LyteCore's SHA-256 unless
    /// injected): a local copy is hashed whole, outside the lock; an
    /// incoming image one chunk per message.
    private let imageHasher: @Sendable () -> any ClipboardImageHasher
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let onVideoRecoveryDemand:
        @Sendable (VideoRecoveryCause, FrameNumber) -> Void
    private let onVideoRecoveryTrace:
        @Sendable (VideoRecoveryTraceEvent) -> Void

    // The parts. IUO because their callbacks reference self (the
    // PairingGateTests construction order).
    public private(set) var pipeline: LyteVideoPipeline!
    public private(set) var reliable: ReliableCtrlEndpoint!
    /// Chan 8's own ARQ endpoint: the bulk stream never shares CTRL's,
    /// so a file cannot head-of-line-block a keystroke.
    public private(set) var bulkReliable: ReliableCtrlEndpoint!
    public private(set) var echoResponder: BeaconEchoResponder!
    public private(set) var idrRequester: IdrRequester!
    public private(set) var feedback: FeedbackSender!
    public private(set) var input: InputSender!
    public private(set) var audio: AudioReceiver!
    /// The targeted-repair ask policy behind the pipeline's
    /// repair-signal seam.
    public private(set) var nackPolicy: NackPolicy!
    public let clockModel: HostClockModel

    // IO-free session policy + transport-owned counters, one lock.
    private let lock = NSLock()
    private var controlSession: ClientControlSession
    /// Transfer-id minting for image shares. System randomness is
    /// injected into the IO-free policy at its one minting decision.
    private var imageRng = SystemRandomNumberGenerator()
    /// The negotiated-posture audit — SPS chroma_format_idc off
    /// every IDR against the agreed chroma singleton (confirmation
    /// once, DOCTOR line on a mismatch edge).
    private var chromaAudit = ChromaStreamAudit()
    private var counters = LyteUdpSessionCounters()
    /// True once the first authenticated chan-1 datagram landed and
    /// (config permitting) the detector re-armed at 350 ms.
    public private(set) var detectorTightened = false
    /// The production machine-poll wake; nil until `startTimers()`.
    private var machineTimer: DispatchSourceTimer?

    /// The per-datagram evidence book, off the hot path: every accepted
    /// datagram stamps this relaxed atomic instead of taking the core
    /// lock for a machine pass (apply + poll + two action arrays,
    /// ~3k×/s). The 100 ms beat feeds the machine the newest stamp at
    /// its TRUE arrival instant, so the blackout detector's and the
    /// liveness clock's bookkeeping stay exact; only the FROZEN exit
    /// wants datagram latency, and `machineFrozen` routes those (rare)
    /// passes through the immediate path.
    private let lastEvidenceMicros = Atomic<UInt64>(0)
    private let machineFrozen = Atomic<Bool>(false)
    /// Beat-context bookkeeping (guarded by `lock`): the stamp last
    /// fed to the machine.
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
    /// Runs between a lifecycle decision and its execution — the edge
    /// ordering pin interleaves a second decision here.
    var testingBeforeLifecycleExecution: (() -> Void)?
    /// Upstream half of the renderer recovery gate. Sample construction may
    /// already be queued when assembler damage is discovered; this fence
    /// prevents those completed P samples from racing the handoff flush.
    /// It shares the exact same close seam as IdrRequester and the handoff.
    private var videoRecoveryOutstanding = false

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
        self.imageHasher = imageHasher
        self.onEvent = onEvent
        self.onVideoRecoveryDemand = onVideoRecoveryDemand
        self.onVideoRecoveryTrace = onVideoRecoveryTrace
        // The machine begins at establishment (the shell constructs the
        // core only after the Noise handshake), streaming: ACTIVE.
        self.controlSession = ClientControlSession(
            localCapabilities: config.capabilities,
            machineConfig: config.machineConfig,
            desiredHostAudioRouting: config.desiredHostAudioRouting,
            clipboardSharingAtStart: config.shareClipboard,
            clipboardImageSharingAtStart: config.shareClipboardImages,
            now: now()
        )

        self.pipeline = LyteVideoPipeline(
            asynchronousSampleBuild: asynchronousVideoBuild,
            nowNanoseconds: { now().microseconds &* 1_000 },
            sink: sessionSink,
            onFecImpossible: { [weak self] frame, _, _ in
                // A frame with a live repair ask holds its IDR for the
                // repair window; everything else requests an IDR now
                // (the policy escalates expiries back through the same
                // requester).
                guard let self else { return }
                let now = self.now()
                if !self.nackPolicy.shouldDeferFecImpossible(
                    frame: frame, now: now
                ) {
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
                self.nackPolicy.handle(signal, now: now)
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
        self.idrRequester = IdrRequester(emit: { [weak self] request in
            guard let self else { return }
            _ = try? sender.send(
                channel: .ctrl, timestamp: self.now(),
                plaintext: request.encode())
        })
        self.feedback = FeedbackSender(
            demux: demux, sender: sender,
            onTick: { [weak self] tickNow in
                self?.idrRequester.flushIfDue(now: tickNow)
                self?.nackPolicy.tick(now: tickNow)
            })
        self.nackPolicy = NackPolicy(
            config: config.nackPolicy,
            rtt: { [weak self] in
                self?.clockModel.estimate()?.minRttMicroseconds
            },
            emit: { [weak self] entries in
                guard let self else { return }
                // Enqueue + an immediate out-of-cadence report: the
                // host's rule-3 freeze budget is derived from the
                // cadence — an ask that skips the wait
                // spends none of it.
                self.feedback.enqueueNacks(entries)
                self.feedback.tick(now: self.now())
                for entry in entries {
                    self.onEvent(.protocolNote(
                        "nack: frame \(entry.frame.rawValue) asks "
                        + "shards \(entry.missingShards)"))
                }
            },
            escalate: { [weak self] frame, now in
                guard let self else { return }
                self.beginVideoRecovery(
                    cause: .fecAssemblerDamage, frame: frame, now: now)
                // Reason-neutral: this closure exits deadline expiries,
                // framesGone, and host refusals (which already printed
                // their own reasoned note); the books tell them apart.
                self.onEvent(.protocolNote(
                    "nack: frame \(frame.rawValue) repair abandoned — "
                    + "IDR instead"))
            })
        self.audio = AudioReceiver(jitterConfig: config.audioJitter)
        sessionSink.bind(self)
    }

    /// Pure session verdict at the native-media boundary. CoreMedia forwarding
    /// stays in `SessionVideoSink`; the core sees only the decoded wire unit.
    /// Returns true exactly when the adapter may submit downstream.
    func admitVideoUnit(_ unit: DecodeUnit) -> Bool {
        // The input→photon seam: a DELIVERED frame whose shards
        // carried the lastInputSeq TLV closes every pending event at or below
        // its stamp. Delivery — not shard arrival — is the honest instant.
        lock.lock()
        let mayRender = !videoRecoveryOutstanding || unit.isIDR
        lock.unlock()
        guard mayRender else {
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
        // IDRs carry parameter sets in-band. Audit actual chroma against
        // the negotiated posture; mismatch is a doctor line, never a silent
        // resample.
        if unit.isIDR {
            auditStreamChroma(annexB: unit.annexB)
        }
        return true
    }

    // MARK: Lifecycle

    /// The first reliable word: this end's capability declaration
    /// (0x0F) on the ARQ ordered stream — everything gated on a
    /// capability orders behind it for free (the host does the same
    /// from its side).
    public func open(now: ClientTimestamp) throws {
        lock.lock()
        let declaration: [UInt8]?
        do {
            declaration = try controlSession.start()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        guard let declaration else { return }
        try reliable.send(declaration, now: now)
    }

    public func open() throws {
        try open(now: now())
    }

    /// Production timers: the ARQ PTO wake, pipeline eviction, the
    /// feedback cadence, and a 100 ms machine-poll beat (granular
    /// enough for the 2.5 s detector and the 30 s liveness clock).
    /// Tests never call this — they drive `tick(now:)`.
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

    /// One virtual-time beat for tests: machine poll + ARQ PTO +
    /// pipeline eviction (feedback stays caller-driven — its reports
    /// are a cadence choice, not a correctness one).
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
        bulkReliable.tick(now: now)
        pipeline.tick(now: now)
        nackPolicy.tick(now: now)
        machineBeat(now: now)
    }

    /// The machine's beat (production timer and test tick alike): any
    /// evidence stamped since the last beat is fed first, at its true
    /// arrival instant — exact detector/liveness bookkeeping, deferred
    /// at most one beat — then the pure poll runs at `now`.
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

    /// An orderly local close: the typed teardown leaves on the
    /// ordered stream (retransmitting until acknowledged) and the
    /// machine closes. The caller lingers on `isReliableQuiescent`
    /// before tearing the socket down (the host's beginTeardown
    /// discipline, mirrored).
    public func beginTeardown(
        reason: SessionTeardownReason, now: ClientTimestamp
    ) {
        applyMachine(.teardownRequest(reason), now: now)
    }

    public func beginTeardown(reason: SessionTeardownReason) {
        beginTeardown(reason: reason, now: now())
    }

    // MARK: Input

    /// Queues one captured input event on the reliable ordered stream
    /// (0x16), stamped `now` and sequenced by the session's counter.
    /// NEVER gated on wire mode or the FROZEN overlay: the host runs
    /// `.preArmInput` on every delivered event BEFORE injecting, so an
    /// event in IDLE is the WAKE and one during a blackout persists
    /// through FROZEN into RECOVERY's IDR — sending
    /// promptly IS how this end drives the pre-arm seam. Returns the
    /// allocated seq; throws what the reliable endpoint throws.
    @discardableResult
    public func sendInput(
        _ body: InputEvent.Body, now: ClientTimestamp
    ) throws -> UInt32 {
        try input.send(body, now: now)
    }

    @discardableResult
    public func sendInput(_ body: InputEvent.Body) throws -> UInt32 {
        try sendInput(body, now: now())
    }

    /// The queued-capture form: the event and its latency books carry
    /// `captured`, while the reliable stream is driven at the session's
    /// own `now()` so queue wait never inflates ARQ RTT samples.
    @discardableResult
    public func sendInput(
        _ body: InputEvent.Body, captured: ClientTimestamp
    ) throws -> UInt32 {
        try input.send(body, captured: captured, now: now())
    }

    /// App renderer failure/backpressure joins the established IDR recovery
    /// policy instead of inventing an uncoalesced control path.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause = .rendererFailure
    ) {
        beginVideoRecovery(cause: cause, frame: frame, now: now())
    }

    /// The sole close seam: AVFoundation accepted the IRAP into its queue.
    public func noteVideoIrapEnqueued(
        frame: FrameNumber = FrameNumber(rawValue: 0)
    ) {
        lock.lock()
        videoRecoveryOutstanding = false
        lock.unlock()
        idrRequester.noteUsableIrapAccepted()
        onVideoRecoveryTrace(.init(
            kind: "coreRecoveryClosedAfterIrapEnqueue",
            frame: frame,
            isRandomAccess: true))
    }

    private func beginVideoRecovery(
        cause: VideoRecoveryCause,
        frame: FrameNumber,
        now: ClientTimestamp
    ) {
        lock.lock()
        let overlap = videoRecoveryOutstanding
        videoRecoveryOutstanding = true
        lock.unlock()
        onVideoRecoveryTrace(.init(
            kind: overlap ? "coreDamageOverlap" : "coreDamageKnown",
            frame: frame,
            cause: cause))
        // Queue the renderer gate before emitting the request. The app's
        // serial handoff then observes this before any later sink submit.
        onVideoRecoveryDemand(cause, frame)
        idrRequester.recordRecoveryDemand(frame: frame, now: now)
    }

    // MARK: Host audio routing

    /// Asks the host to flip its own speakers (0x18 on the ARQ ordered
    /// stream) — the strip's live override. The IO-free control session
    /// refuses it when key 9 never survived intersection (the rule-3 gate:
    /// the host would only drop the ask loud) or before the exchange settled.
    /// The posture does NOT change on send: it changes when the host's 0x19
    /// answer says it did.
    public func requestHostAudioRouting(
        _ mode: HostAudioRoutingMode, now: ClientTimestamp
    ) throws {
        lock.lock()
        let bytes: [UInt8]
        do {
            bytes = try controlSession.requestHostAudioRouting(mode)
        } catch {
            lock.unlock()
            throw error
        }
        counters.audioRoutingRequestsSent += 1
        lock.unlock()
        try reliable.send(bytes, now: now)
    }

    public func requestHostAudioRouting(_ mode: HostAudioRoutingMode) throws {
        try requestHostAudioRouting(mode, now: now())
    }

    // MARK: Clipboard

    /// True when capability key 10 survived intersection — the
    /// strip's clipboard toggle exists exactly when this is true.
    public var clipboardNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.clipboardNegotiated
    }

    /// The live sharing toggle's state (seeded from the per-host
    /// default; nothing leaves and nothing lands while false).
    public var clipboardSharingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.clipboardSharingEnabled
    }

    /// The strip's live override for clipboard sharing. Local policy
    /// only — no wire message exists for it in v1 (design doc §1's
    /// named non-goal), so a disabled end simply goes quiet and deaf.
    public func setClipboardSharing(_ enabled: Bool) {
        lock.lock()
        controlSession.setClipboardSharing(enabled)
        lock.unlock()
    }

    /// The pasteboard watcher's funnel: one local clipboard change,
    /// judged (negotiated → enabled → the sync book → the ceiling) and
    /// shared as a 0x1A when it survives. Never throws — the poller
    /// has nobody to catch for it; the outcome is counted and
    /// returned.
    @discardableResult
    public func shareLocalClipboard(
        _ text: String, now: ClientTimestamp
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

    @discardableResult
    public func shareLocalClipboard(_ text: String) -> ClipboardShareOutcome {
        shareLocalClipboard(text, now: now())
    }

    // MARK: Clipboard images

    /// True when capability keys 10 AND 12 both survived intersection
    /// — the images rung of the consent tier exists exactly when this
    /// is true. Key 11 (file consent) is deliberately not consulted:
    /// the tiers do not couple (a no-files host still syncs images).
    public var clipboardImagesNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.clipboardImagesNegotiated
    }

    /// The images rung's live state: images move only when sharing
    /// is on AND the rung is on (the clipboard design's Text + images tier).
    public var clipboardImageSharingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.clipboardImageSharingEnabled
    }

    /// The strip's live override for the images rung. Local policy
    /// only, like `setClipboardSharing` — but a disabled end is not
    /// merely deaf: an inbound marker draws abort(declined), because
    /// the image sender waits on a verdict.
    public func setClipboardImageSharing(_ enabled: Bool) {
        lock.lock()
        controlSession.setClipboardImageSharing(enabled)
        lock.unlock()
    }

    /// The image lane's own books (Wire's channel counts; these
    /// complement the session counters the same way audio's do).
    public var clipboardImageCounters: ClipboardImageChannelCounters {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.clipboardImageCounters
    }

    /// The pasteboard watcher's image funnel: one local image copy
    /// (PNG bytes in v2), judged (negotiated → tier → lane busy → the
    /// 32 MiB ceiling → the shared sync book) and shared as 0x22 cargo
    /// on chan 8 when it survives. Never throws — the poller has
    /// nobody to catch for it.
    ///
    /// Three phases: the digest-free gates under the lock, the digest
    /// outside it (tens of MiB must not stall datagram dispatch), then
    /// the full judgment under the lock again. A refused image is never
    /// hashed.
    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8], now: ClientTimestamp
    ) -> ClipboardShareOutcome {
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

    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8]
    ) -> ClipboardShareOutcome {
        shareLocalClipboardImage(data, now: now())
    }

    /// One batch of channel events into the world: `.send` rides
    /// chan 8's ordered stream, `.applyImage` becomes the typed event
    /// (payload bytes appear there and nowhere else),
    /// the rest is protocol weather. Returns the share verdict for
    /// the funnel's caller; called outside the lock (the reliable
    /// endpoint's callbacks take our lock).
    @discardableResult
    private func executeClipboardDecision(
        _ decision: ClientClipboardSessionDecision,
        now: ClientTimestamp
    ) -> ClipboardShareOutcome {
        var outcome = decision.shareOutcome ?? .shared
        for bytes in decision.outboundBulk {
            bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
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
            case .image(.shareStarted), .image(.suppressed):
                break
            case .textChanged, .malformedTextAnnounce,
                 .unnegotiatedTextAnnounce, .textIgnoredDisabled,
                 .roleConfusedTextSet, .malformedImageCargo,
                 .unnegotiatedImageCargo:
                break
            }
        }
        return outcome
    }

    // MARK: Bulk transfer

    /// True when capability key 11 survived intersection — the host's
    /// standing consent toggle is ON and it accepts file offers. The
    /// drop target's gate.
    public var bulkTransferNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.agreedCapabilities?.bulkTransfer == true
    }

    /// Queues one encoded bulk message on chan 8's ARQ ordered stream.
    /// Refused here when key 11 never survived intersection: the client
    /// offers only into an agreed set.
    public func sendBulkMessage(
        _ message: [UInt8], now: ClientTimestamp
    ) throws {
        lock.lock()
        guard controlSession.agreedCapabilities?.bulkTransfer == true else {
            lock.unlock()
            throw BulkChannelError.notNegotiated
        }
        counters.bulkMessagesSent += 1
        lock.unlock()
        // Chan 8 borrows the ctrl-learned connection ID so the very
        // first bulk datagram already carries the tag (every datagram
        // carries it; chan-8 inbound teaches it too).
        bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
        try bulkReliable.send(message, now: now)
    }

    public func sendBulkMessage(_ message: [UInt8]) throws {
        try sendBulkMessage(message, now: now())
    }

    // MARK: Ingest

    /// The endpoint's per-datagram hook: routes accepted payloads to
    /// their consumers and feeds the lifecycle machine's evidence
    /// clocks (every authenticated arrival — the file comment's
    /// receiver-side evidence rule).
    ///
    /// The arrival stamp is deliberately discarded: it is in the
    /// SystemMonotonicClock domain, while every clock in here — the echo
    /// responder's t2 included — lives on the session's injected `now()`,
    /// which tests drive virtually. Feeding it into t2 would mix clock
    /// domains whenever `now` is not the system clock.
    public func handleDatagram(
        _ outcome: IngestOutcome, arrivalMicroseconds _: UInt64
    ) {
        guard case .accepted(let envelope, let payload) = outcome else {
            return
        }
        let now = now()
        if envelope.channel == .ctrl {
            // CL-7's one-byte peek: 0x07/0x08 payloads are wholly ARQ
            // (delivery events dispatch from the endpoint's hook);
            // everything else falls through to the exempt paths.
            if !reliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now
            ) {
                if !echoResponder.handleCtrlPayload(
                    payload, arrivalMicroseconds: now.microseconds
                ) {
                    handleExemptCtrl(payload, now: now)
                }
            }
        } else if envelope.channel == pipeline.channel {
            // Any one shard's lastInputSeq TLV (0x03) associates the
            // frame with the newest injected input — recorded before
            // ingest so the association exists when delivery fires
            // from this same pass.
            input.noteVideoShard(envelope: envelope)
            pipeline.ingest(envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .bulkTransfer {
            // the whole channel is ARQ carriage by design — no
            // exempt path exists on chan 8.
            bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
            _ = bulkReliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .audio {
            // The 5 ms path probe. Depacketize/recover/buffer, and —
            // first time only — tighten the blackout detector to 350 ms:
            // with audio flowing in every non-closed state, 350 ms of
            // total silence means the path is dark.
            lock.lock()
            counters.audioDatagramsReceived += 1
            controlSession.noteAudioEvidence()
            lock.unlock()
            audio.ingest(envelope: envelope, payload: payload, now: now)
            tightenDetectorIfNeeded(now: now)
        }
        // Evidence is a timestamp, not work: stamp it and move on. The
        // beat feeds it to the machine; FROZEN (the one state where a
        // datagram must act NOW — the pill clears on this evidence)
        // keeps the immediate pass.
        lastEvidenceMicros.store(now.microseconds, ordering: .relaxed)
        if machineFrozen.load(ordering: .relaxed) {
            applyMachine(.mediaPathEvidence, now: now)
        }
    }

    /// the ARQ-exempt CTRL types beyond the beacon. A 0x23
    /// repair refusal ends the named frame's repair wait immediately —
    /// the policy escalates it to the existing rate-windowed IDR
    /// requester. Anything else (unknown types included) is skipped
    /// silently — the forward-compat contract this very message's
    /// key-free append relies on. Malformed refusals count and drop;
    /// hostile bytes never stop the exempt path.
    private func handleExemptCtrl(
        _ payload: [UInt8], now: ClientTimestamp
    ) {
        guard payload.first == CtrlMessageType.repairRefused else {
            return
        }
        guard let refusal = try? RepairRefusal.decode(payload) else {
            noteMalformed("repair refusal")
            return
        }
        onEvent(.protocolNote(
            "nack: frame \(refusal.frame.rawValue) repair refused "
            + "by host (\(refusal.reason)) — IDR now"))
        nackPolicy.handleRefusal(frame: refusal.frame, now: now)
    }

    /// The tighten's mirror: rebuilds the receiver machine at the
    /// beacon-bounded default and clears `detectorTightened`, so the
    /// wake's first audio datagram tightens it right back. No-op when
    /// already relaxed (check-ins repeat every ~5 s by design).
    private func relaxDetectorForAnnouncedQuiet(now: ClientTimestamp) {
        lock.lock()
        guard detectorTightened, controlSession.state != .closed else {
            lock.unlock()
            return
        }
        detectorTightened = false
        _ = controlSession.reconfigure(config.machineConfig, now: now)
        lock.unlock()
        onEvent(.protocolNote(String(
            format: "audio quiet announced — blackout detector relaxed "
                + "to %d ms",
            config.machineConfig.blackoutSilenceMicroseconds / 1_000)))
    }

    /// Rebuilds the receiver machine at the tightened threshold,
    /// transplanting the wire mode (a receiver machine's only durable
    /// state — FROZEN would exit on this very evidence anyway, and
    /// RECOVERY/pre-arm are sender-role). Wire/ stays untouched: the
    /// config was always the injection point.
    private func tightenDetectorIfNeeded(now: ClientTimestamp) {
        guard let tightened = config.tightenedBlackoutSilenceMicroseconds
        else { return }
        lock.lock()
        guard !detectorTightened, controlSession.state != .closed else {
            lock.unlock()
            return
        }
        detectorTightened = true
        var machineConfig = config.machineConfig
        machineConfig.blackoutSilenceMicroseconds = tightened
        _ = controlSession.reconfigure(machineConfig, now: now)
        // Edge reporting stays untouched: the next applyMachine
        // pass surfaces any edge this rebuild caused (e.g. a FROZEN
        // pill clearing on this very evidence).
        lock.unlock()
        onEvent(.protocolNote(String(
            format: "audio evidence — blackout detector tightened to %d ms",
            tightened / 1_000)))
    }

    /// One IDR's chroma audit pass: parse the in-band SPS, feed the
    /// audit under the lock, surface whatever it has to say. A frame
    /// without a parseable SPS says nothing (an IRAP without in-band
    /// parameter sets keeps the current posture — the factory's rule).
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

    /// The last negotiated video posture, or nil before the first accepted
    /// announcement. Portable state lives in `ClientControlSession`; this is
    /// the synchronized transport snapshot consumed by the UI.
    public var announcedVideoPosture: VideoPostureState? {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.announcedVideoPosture
    }

    /// True between an accepted quiet announcement and the next accepted
    /// active announcement or authenticated audio datagram.
    public var hostAnnouncedAudioQuiet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.hostAnnouncedAudioQuiet
    }

    /// the stream's observed chroma ("4:2:0"/"4:4:4"), nil
    /// before the first IDR with in-band parameter sets — the stats
    /// overlay's truth about what the wire actually carries.
    public var streamChromaDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return chromaAudit.observedDescription
    }

    public var state: SessionState {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.state
    }

    public var wireMode: SessionWireMode {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.wireMode
    }

    /// The pill: true while the local overlay says the path is
    /// dark. Never a wire state; never modal in the UI.
    public var isFrozen: Bool { state == .frozen }

    public var agreedCapabilities: Capabilities? {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.agreedCapabilities
    }

    /// True when capability key 9 survived intersection — the strip's
    /// host-mute button exists exactly when this is true.
    public var hostAudioRoutingNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.hostAudioRoutingNegotiated
    }

    /// The 0x19-confirmed posture of the host's own speakers; nil
    /// until the host's first status (or forever, against a no-key-9
    /// host). Never optimistic.
    public var hostAudioRoutingPosture: HostAudioRoutingMode? {
        lock.lock()
        defer { lock.unlock() }
        return controlSession.hostAudioRoutingPosture
    }

    public var isReliableQuiescent: Bool { reliable.isQuiescent }

    public func snapshotCounters() -> LyteUdpSessionCounters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    // MARK: The machine

    /// Applies one input (or none — a pure timer beat), fires the
    /// machine's timers, executes its actions, and surfaces state/mode
    /// edges. The single funnel for every lifecycle mutation.
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

    /// Runs under `lock`, in the same critical section that made the
    /// decision.
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

    /// Every ARQ delivery, dispatched by its own CTRL type byte — the
    /// host Session's consumeReliable, mirrored for the client's
    /// registered consumers. Hostile bytes are counted, never fatal.
    private func dispatchReliable(_ event: ArqEvent) {
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        switch bytes.first {
        case CtrlMessageType.modeTransition,
             CtrlMessageType.sessionTeardown,
             CtrlMessageType.capabilityDeclaration,
             CtrlMessageType.capabilityUpdate,
             CtrlMessageType.audioRoutingRequest,
             CtrlMessageType.audioRoutingStatus,
             CtrlMessageType.clipboardSet,
             CtrlMessageType.clipboardAnnounce,
             CtrlMessageType.cursorShape,
             CtrlMessageType.audioTrackState,
             CtrlMessageType.videoPostureState:
            receiveControlWord(bytes, now: now)

        case CtrlMessageType.idleFrame:
            receiveIdleFrame(bytes)

        case CtrlMessageType.inputEcho:
            guard let echo = try? InputEcho.decode(bytes) else {
                noteMalformed("input echo")
                return
            }
            lock.lock()
            counters.inputEchoMessagesReceived += 1
            lock.unlock()
            input.handleEcho(echo, now: now)

        default:
            lock.lock()
            counters.unknownReliableTypes += 1
            lock.unlock()
            onEvent(.protocolNote(
                "unregistered reliable CTRL type "
                    + Hex.string(bytes.first ?? 0, width: 2, prefix: true)
                    + " (\(bytes.count) B)"))
        }
    }

    /// The composed IO-free control session owns routing, decoding,
    /// cross-organ judgment, and the decision's books and note. The shell
    /// bumps the counters, performs the sends, surfaces typed events, and
    /// executes the effects and lifecycle actions.
    private func receiveControlWord(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        lock.lock()
        let decision: ClientControlSessionDecision?
        do {
            decision = try controlSession.receiveReliable(bytes, now: now)
        } catch {
            lock.unlock()
            onEvent(.protocolNote(
                "control response encoding refused: \(error)"))
            return
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
        guard let decision else { return }

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
                return
            }
        }

        if let note = decision.note {
            onEvent(.protocolNote(note))
        }
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
            relaxDetectorForAnnouncedQuiet(now: now)
        default:
            break
        }
        if let lifecycle = decision.lifecycle {
            executeLifecycle(lifecycle, ticket: lifecycleTicket, now: now)
        }
    }

    /// Every chan-8 ARQ delivery: the stream now carries TWO lanes.
    /// A 0x22 marker or any bulk message the image channel claims is
    /// the clipboard lane's; the rest is the file lane's,
    /// decoded and surfaced for the owner's BulkSendCoordinator. Each
    /// lane wears its OWN rule-3 gate — a file message without key 11
    /// drops loud even when images agreed, and vice versa (the tiers
    /// do not couple); bytes the codecs refuse drop loud too, payload
    /// never logged.
    private func dispatchBulk(_ event: ArqEvent) {
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        if bytes.first == CtrlMessageType.clipboardImageCargo {
            receiveImageCargo(bytes, now: now)
            return
        }
        guard let message = try? BulkMessage.decode(bytes) else {
            lock.lock()
            counters.bulkDropsLoud += 1
            lock.unlock()
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

    /// One 0x22 clipboard-image marker: gate (keys 10∧12), then
    /// tier — a welcome marker arms the channel's receive lane for the
    /// offer riding behind it; an unwelcome one draws abort(declined)
    /// through the channel so the trailing offer is swallowed rather
    /// than leaking to the file lane.
    private func receiveImageCargo(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        lock.lock()
        let decision = controlSession.receiveClipboardImageCargo(bytes)
        switch decision.events.first {
        case .malformedImageCargo:
            counters.clipboardDropsLoud += 1
        case .unnegotiatedImageCargo:
            counters.clipboardDropsLoud += 1
        default:
            break
        }
        lock.unlock()
        for event in decision.events {
            switch event {
            case .malformedImageCargo(let byteCount):
                onEvent(.protocolNote(
                    "malformed clipboard-image marker dropped "
                        + "(\(byteCount) B)"))
            case .unnegotiatedImageCargo:
                onEvent(.protocolNote(
                    "clipboard-image 0x22 without negotiated keys 10∧12 "
                        + "— dropped"))
            default:
                break
            }
        }
        executeClipboardDecision(decision, now: now)
    }

    /// The 0x15 idle frame: decode, render through the shared factory
    /// (dedupe against the datagram path inside the pipeline). The
    /// one-shot ACK the host's IDLE flip waits on already left in the
    /// ingest pass that delivered this message.
    private func receiveIdleFrame(_ bytes: [UInt8]) {
        guard let idle = try? IdleFrame.decode(bytes) else {
            noteMalformed("idle frame")
            return
        }
        lock.lock()
        counters.idleFramesReceived += 1
        lock.unlock()
        let outcome = pipeline.ingestReliableFrame(
            frame: idle.frame,
            captureTimestampMicroseconds: idle.captureTimestampMicroseconds,
            annexB: idle.annexB
        )
        onEvent(.idleFrameReceived(
            frame: idle.frame.rawValue, outcome: outcome))
    }

    private func noteMalformed(_ what: String) {
        lock.lock()
        counters.malformedReliableMessages += 1
        lock.unlock()
        onEvent(.protocolNote("malformed \(what) dropped"))
    }
}
