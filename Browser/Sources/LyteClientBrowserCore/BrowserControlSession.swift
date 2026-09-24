import LyteClientCore
import LyteClientSession
import LyteCore
import LyteWire

/// The browser's sans-IO session: LyteClientSession's initiator pieces
/// (handshake, pairing, control session, beacon echo, envelope sequencer,
/// conn-id book, lifecycle) composed over one reliable CTRL stream, plus the
/// demux of sealed video/audio to the playout organs.
///
/// The page owns WebTransport and clocks; every call takes injected time and
/// returns a `Step` of datagrams to send and notes to log. Per-datagram
/// faults are counted and dropped; only protocol and policy failures end
/// the session. A closed or failed session keeps ingesting acknowledgements
/// and retransmitting until its reliable stream is quiescent, so a
/// teardown it queued reaches the host.
public final class BrowserControlSession {
    public enum Status: String, Sendable {
        case idle
        case handshaking
        case established
        case ready
        case closed
        case failed
    }

    public struct Step: Sendable {
        public var outbound: [[UInt8]]
        public var events: [String]
        public var status: Status
        public var detail: String
        public var passed: Bool
        /// Frames the Conductor scheduled during this step (metadata only).
        public var scheduled: [BrowserVideoPlayout.ScheduledFrame]

        /// True when the step carries nothing for the page to act on.
        public var isQuiet: Bool {
            outbound.isEmpty && events.isEmpty && scheduled.isEmpty
        }
    }

    /// Message-1 retransmit schedule (the native initiator's defaults).
    public typealias HandshakeRetry = ClientHandshakeInitiator.Retry

    /// The chan-3 report cadence, the native shell's: inside the 25–50 ms
    /// band the host's estimator and its 350 ms freeze detector expect.
    public static let feedbackIntervalMicroseconds: UInt64 = 40_000
    /// Arrival samples kept between reports.
    public static let maxRetainedArrivalSamples = 512
    /// The receiver machine's timing, the native shell's: the baseline
    /// blackout bound sits past an idle host's 1 Hz beacons, and the first
    /// audio datagram (a dense path probe) tightens it.
    public static let machineConfig = SessionMachineConfig(
        blackoutSilenceMicroseconds: 2_500_000)
    public static let tightenedBlackoutSilenceMicroseconds: Int64 = 350_000

    public struct Counters: Sendable, Equatable {
        /// Datagrams whose envelope did not decode.
        public var undecodableDatagrams: UInt64 = 0
        /// Sealed datagrams that failed authentication or the replay window.
        public var unsealFailures: UInt64 = 0
        /// Authenticated CTRL words (and retry challenges) that did not
        /// decode (dropped).
        public var malformedControl: UInt64 = 0
        /// Message-2 candidates the handshake rejected.
        public var rejectedMessage2: UInt64 = 0
        /// Message-1 transmissions, the first included.
        public var message1Transmissions: UInt64 = 0
        public var retryChallengesAnswered: UInt64 = 0
        public var pathChallengesAnswered: UInt64 = 0
        /// 0x23 refusals: the host will not repair a NACKed frame.
        public var repairRefusals: UInt64 = 0
        public var idrRequestsSent: UInt64 = 0
        /// Input events dropped because the reliable queue was full.
        public var inputsRefused: UInt64 = 0
        public var feedbackReportsSent: UInt64 = 0
        /// Reports that did not encode or seal (the next beat rebuilds).
        public var feedbackReportsFailed: UInt64 = 0
        /// Arrival samples past the per-report retention bound.
        public var arrivalSamplesDropped: UInt64 = 0

        public init() {}
    }

    private let hostStaticPublicKey: [UInt8]
    private let clientStatic: NoiseKeyPair
    private let pin: [UInt8]
    private let handshakeRetry: HandshakeRetry

    private var status: Status = .idle
    private var initiator: ClientHandshakeInitiator?
    private var transport: NoiseTransport?
    private var sequencer = ClientEnvelopeSequencer()
    private var connectionIds = ClientConnectionIdBook()
    private var echoBook = ClientBeaconEchoBook()
    /// The host clock fit from the beacon book's closed samples; video
    /// capture times map through it.
    private var hostClock = ClientHostClock()
    private var arq = ArqEndpoint<ClientClock>(
        channel: .ctrl,
        config: {
            var config = ArqConfig()
            config.maxDatagramPayloadByteCount =
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            return config
        }()
    )
    private var control: ClientControlSession?
    private var pairing: ClientPairing?
    private var pendingEvidenceMicros: UInt64?
    private var events: [String] = []
    private var failure: String?
    private var video = BrowserVideoPlayout()
    private var audio = BrowserAudioPlayout()
    private var nextInputSeq: UInt32 = 0
    /// Receive ledgers per channel, cumulative since establishment: every
    /// authenticated datagram counts, whichever organ consumes it.
    private var ledgers: [ChannelId: SeqGapTracker] = [:]
    private var arrivals: [ClientFeedbackReporter.Arrival] = []
    private var feedback = ClientFeedbackReporter()
    private var nextFeedbackMicros: UInt64 = 0

    public private(set) var counters = Counters()
    public private(set) var handshakeCompleted = false
    public private(set) var paired = false
    public private(set) var capabilitiesAgreed = false
    public private(set) var closeReason: SessionCloseReason?
    public private(set) var inputsSent: UInt64 = 0
    public private(set) var inputEchoes: UInt64 = 0
    public private(set) var clipboardSent: UInt64 = 0
    public private(set) var clipboardReceived: UInt64 = 0
    public private(set) var lastClipboardText: String?

    public var currentStatus: Status { status }
    public var clientStaticPublicKeyHex: String { Hex.string(clientStatic.publicKey) }
    public var hostStaticPublicKeyHex: String { Hex.string(hostStaticPublicKey) }
    public var framesAssembled: UInt64 { video.framesAssembled }
    public var framesPresented: UInt64 { video.framesPresented }
    public var videoCounters: BrowserVideoPlayout.Counters { video.counters }
    public var nackStats: ClientNackPolicy.Stats { video.nackStats }
    /// Assembled frames whose Annex-B the page has not taken yet.
    public var videoDecodeBacklog: Int { video.decodeBacklogCount }
    /// Frames whose presentation metadata the playout still holds.
    public var videoPresentationBacklog: Int { video.presentationBacklogCount }
    public var audioPending: Int { audio.pendingCount }
    public var audioPacketsAssembled: UInt64 { audio.packetsAssembled }
    public var audioPacketsPopped: UInt64 { audio.packetsPopped }
    public var audioPacketsDroppedStale: UInt64 { audio.packetsDroppedStale }
    public var clipboardNegotiated: Bool { control?.clipboardNegotiated ?? false }
    /// The client lifecycle machine's state (FROZEN is a local overlay).
    public var sessionState: SessionState? { control?.state }
    /// True when every reliable CTRL word sent has been acknowledged.
    public var isReliableQuiescent: Bool { arq.isQuiescent }

    public init(
        hostStaticPublicKeyHex: String,
        pin: String,
        handshakeRetry: HandshakeRetry = HandshakeRetry()
    ) throws {
        guard let hostKey = Hex.bytes(hostStaticPublicKeyHex),
              hostKey.count == 32
        else {
            throw BrowserControlError.badHostStatic
        }
        guard let pinBytes = PairingPin.normalize(pin) else {
            throw BrowserControlError.badPin
        }
        self.hostStaticPublicKey = hostKey
        self.clientStatic = NoiseKeyPair.generate()
        self.pin = pinBytes
        self.handshakeRetry = handshakeRetry
    }

    // MARK: Media hand-off to the page

    /// Takes the Annex-B bytes of an assembled frame for decode. Each frame's
    /// bytes are handed out once; `nil` means they were never assembled or
    /// were evicted from an undrained decode backlog.
    public func takeAnnexB(frameNumber: UInt32) -> [UInt8]? {
        video.takeAnnexB(frameNumber: frameNumber)
    }

    public func popDueFrame(nowMicros: UInt64) -> BrowserVideoPlayout.ScheduledFrame? {
        video.popDue(nowMicros: nowMicros)
    }

    public func notePresented(frameNumber: UInt32) {
        video.notePresented(frameNumber: frameNumber)
    }

    public func noteDropped(frameNumber: UInt32) {
        video.noteDropped(frameNumber: frameNumber)
    }

    public func popAudioPacket() -> BrowserAudioPlayout.Packet? {
        audio.popPacket()
    }

    // MARK: Session drive

    /// Opens Noise IK message 1 as a bare CTRL carriage datagram.
    public func begin(nowMicros: UInt64) throws -> Step {
        guard status == .idle else {
            return failStep("begin called in status \(status.rawValue)")
        }
        var initiator = try ClientHandshakeInitiator(
            hostStaticPublicKey: hostStaticPublicKey,
            clientStatic: clientStatic,
            retry: handshakeRetry
        )
        let carriage = try initiator.begin(nowMicros: nowMicros)
        self.initiator = initiator
        status = .handshaking
        syncHandshakeCounters()
        note("noise: msg1 sent (\(initiator.message1ByteCount) B)")
        return step(outbound: [carriage])
    }

    /// Ingests one opaque datagram from the host.
    public func ingest(datagram: [UInt8], nowMicros: UInt64) -> Step {
        switch status {
        case .handshaking:
            return ingestHandshake(datagram, nowMicros: nowMicros)
        case .established, .ready, .closed:
            return ingestSealed(datagram, nowMicros: nowMicros)
        case .failed where transport != nil:
            return ingestSealed(datagram, nowMicros: nowMicros)
        case .idle, .failed:
            return step(outbound: [])
        }
    }

    /// Drives message-1 retransmit, ARQ PTO, the session lifecycle,
    /// assembler eviction and IDR-request retries with injected time.
    public func tick(nowMicros: UInt64) -> Step {
        switch status {
        case .handshaking:
            return handshakeTick(nowMicros: nowMicros)
        case .established, .ready, .closed:
            break
        case .failed where transport != nil:
            break
        case .idle, .failed:
            return step(outbound: [])
        }
        do {
            var outbound: [[UInt8]] = []
            if !isDraining {
                try advanceLifecycle(nowMicros: nowMicros)
                for line in video.evictStale(nowMicros: nowMicros) {
                    note(line)
                }
                outbound += try idrRequestsDue(nowMicros: nowMicros)
                if !isDraining, nowMicros >= nextFeedbackMicros {
                    outbound += feedbackReport(nowMicros: nowMicros)
                }
            }
            outbound += try pollArq(nowMicros: nowMicros)
            return step(outbound: outbound)
        } catch {
            return failStep("tick: \(error)")
        }
    }

    /// Orderly local close: a typed SessionTeardown on the reliable stream.
    /// Keep ticking and ingesting until `isReliableQuiescent` so it is
    /// retransmitted until acknowledged.
    public func teardown(nowMicros: UInt64) -> Step {
        // The session already ended; its own teardown (if any) is queued.
        if isDraining { return step(outbound: []) }
        guard status == .ready || status == .established, var control else {
            return failStep("teardown before established")
        }
        do {
            let decision = control.advance(
                .teardownRequest(.shuttingDown),
                now: ClientTimestamp(microseconds: nowMicros)
            )
            self.control = control
            try apply(decision, nowMicros: nowMicros)
            status = .closed
            note("teardown: shuttingDown")
            return step(outbound: try pollArq(nowMicros: nowMicros))
        } catch {
            return failStep("teardown: \(error)")
        }
    }

    /// Queues one InputEvent on the reliable CTRL stream.
    public func sendInput(body: InputEvent.Body, nowMicros: UInt64) -> Step {
        guard status == .ready else {
            // Soft refusal: DOM capture may fire before READY.
            note("input: ignored (status \(status.rawValue))")
            return step(outbound: [])
        }
        do {
            let event = InputEvent(
                seq: nextInputSeq, clientMicroseconds: nowMicros, body: body
            )
            try arq.send(
                message: event.encode(),
                now: ClientTimestamp(microseconds: nowMicros)
            )
            nextInputSeq &+= 1
            inputsSent += 1
            return step(outbound: try pollArq(nowMicros: nowMicros))
        } catch ArqSendError.queueFull {
            // Backpressure: the host has not acknowledged a full queue of
            // segments. Drop this event; the liveness clock judges the path.
            counters.inputsRefused += 1
            note("input: dropped (reliable queue full)")
            return step(outbound: [])
        } catch {
            return failStep("input send: \(error)")
        }
    }

    /// Capability-gated ClipboardSet via ClientControlSession. A share the
    /// policy declines (duplicate, echo, not negotiated) is a note, not a
    /// session failure.
    public func shareClipboard(text: String, nowMicros: UInt64) -> Step {
        guard status == .ready, var control else {
            note("clipboard: ignored (status \(status.rawValue))")
            return step(outbound: [])
        }
        let decision = control.shareLocalClipboard(text)
        self.control = control
        guard decision.shareOutcome == .shared,
              let message = decision.outboundReliable.first
        else {
            note("clipboard: not shared (\(String(describing: decision.shareOutcome)))")
            return step(outbound: [])
        }
        do {
            try arq.send(
                message: message,
                now: ClientTimestamp(microseconds: nowMicros)
            )
            control.noteLocalClipboardSent(text)
            self.control = control
            clipboardSent += 1
            note("clipboard: set sent (\(text.utf8.count) B)")
            return step(outbound: try pollArq(nowMicros: nowMicros))
        } catch ArqSendError.queueFull {
            // Backpressure, as for input: the next local change retries.
            note("clipboard: not shared (reliable queue full)")
            return step(outbound: [])
        } catch {
            return failStep("clipboard send: \(error)")
        }
    }

    // MARK: Handshake

    private func handshakeTick(nowMicros: UInt64) -> Step {
        guard var initiator else { return failStep("handshake state missing") }
        let tick = initiator.tick(nowMicros: nowMicros)
        self.initiator = initiator
        syncHandshakeCounters()
        switch tick {
        case .wait:
            return step(outbound: [])
        case .retransmit(let carriage):
            note("noise: msg1 retransmit #\(counters.message1Transmissions)")
            return step(outbound: [carriage])
        case .exhausted:
            return failStep(
                "noise: no answer after \(handshakeRetry.attempts) message-1 attempts"
            )
        }
    }

    private func ingestHandshake(
        _ datagram: [UInt8], nowMicros: UInt64
    ) -> Step {
        guard var initiator else { return failStep("handshake state missing") }
        let outcome = initiator.ingest(datagram[...], nowMicros: nowMicros)
        self.initiator = initiator
        syncHandshakeCounters()
        switch outcome {
        case .ignored, .rejectedMessage2:
            return step(outbound: [])
        case .reply(let carriage):
            note("noise: answered retry challenge")
            return step(outbound: [carriage])
        case .established(let made):
            do {
                return try establish(made, nowMicros: nowMicros)
            } catch {
                return failStep("handshake: \(error)")
            }
        }
    }

    /// Folds the initiator's books into the session counters.
    private func syncHandshakeCounters() {
        guard let books = initiator?.counters else { return }
        counters.message1Transmissions = books.message1Transmissions
        counters.retryChallengesAnswered = books.retryChallengesAnswered
        counters.rejectedMessage2 = books.rejectedMessage2
        counters.undecodableDatagrams = books.undecodableDatagrams
        counters.malformedControl = books.malformedRetryChallenges
    }

    private func establish(
        _ made: NoiseTransport, nowMicros: UInt64
    ) throws -> Step {
        let now = ClientTimestamp(microseconds: nowMicros)
        initiator = nil
        transport = made
        status = .established
        handshakeCompleted = true
        nextFeedbackMicros = nowMicros &+ Self.feedbackIntervalMicroseconds
        note("noise: handshake completed")

        var control = ClientControlSession(
            localCapabilities: .wireDefault.declaringClipboardText(),
            machineConfig: Self.machineConfig,
            desiredHostAudioRouting: nil,
            clipboardSharingAtStart: true,
            tightenedBlackoutSilenceMicroseconds:
                Self.tightenedBlackoutSilenceMicroseconds,
            now: now
        )
        var pairing = try ClientPairing(
            pin: pin,
            clientStaticPublicKey: clientStatic.publicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: made.handshakeHash
        )

        // First reliable words: capability declaration, then pairing share A.
        if let declaration = try control.start() {
            try arq.send(message: declaration, now: now)
            note("capabilities: client declaration queued")
        }
        self.control = control
        try arq.send(message: try pairing.start(), now: now)
        self.pairing = pairing
        note("pairing: share A queued")
        return step(outbound: try pollArq(nowMicros: nowMicros))
    }

    // MARK: Established sealed path

    private func ingestSealed(
        _ datagram: [UInt8], nowMicros: UInt64
    ) -> Step {
        guard var transport else { return failStep("no transport") }
        let envelope: Envelope
        let plaintext: [UInt8]
        do {
            (envelope, plaintext) = try transport.openDatagram(datagram)
        } catch is WireError {
            counters.undecodableDatagrams += 1
            return step(outbound: [])
        } catch {
            counters.unsealFailures += 1
            return step(outbound: [])
        }
        self.transport = transport
        pendingEvidenceMicros = nowMicros
        record(envelope, arrivalMicros: nowMicros)

        // Learned only from an authenticated datagram: a forged first
        // datagram must not choose the conn-id every later send carries.
        if connectionIds.learn(from: envelope) {
            note("conn-id: learned")
        }

        do {
            return try route(envelope, plaintext, nowMicros: nowMicros)
        } catch {
            return failStep("ingest: \(error)")
        }
    }

    private func route(
        _ envelope: Envelope, _ plaintext: [UInt8], nowMicros: UInt64
    ) throws -> Step {
        let now = ClientTimestamp(microseconds: nowMicros)
        if isDraining {
            // After close only acknowledgements matter: they let the
            // teardown's retransmits stop.
            if envelope.channel == .ctrl,
               plaintext.first == CtrlMessageType.arqAck
                || plaintext.first == CtrlMessageType.arqSegment
            {
                _ = arq.ingest(payload: plaintext, now: now)
                return step(outbound: try pollArq(nowMicros: nowMicros))
            }
            return step(outbound: [])
        }

        switch envelope.channel {
        case .videoActive:
            let ingested = video.ingestShard(
                envelope: envelope,
                payload: plaintext[...],
                arrivalMicroseconds: nowMicros,
                hostClock: hostClock.estimate()
            )
            for line in ingested.events { note(line) }
            guard !ingested.nacks.isEmpty else {
                return step(outbound: [], scheduled: ingested.scheduled)
            }
            // Report at once: the host's freeze budget is cadence-derived.
            for entry in ingested.nacks {
                note("nack: frame \(entry.frame.rawValue) asks shards \(entry.missingShards)")
            }
            feedback.enqueueNacks(ingested.nacks)
            return step(
                outbound: feedbackReport(nowMicros: nowMicros),
                scheduled: ingested.scheduled)
        case .audio:
            note(posture: control?.noteAudioEvidence(now: now))
            for line in audio.ingestShard(envelope: envelope, payload: plaintext[...]) {
                note(line)
            }
            return step(outbound: [])
        case .ctrl:
            break
        default:
            // Idle video and feedback are not consumed by the browser shell.
            return step(outbound: [])
        }

        switch plaintext.first {
        case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
            var outbound: [[UInt8]] = []
            for event in arq.ingest(payload: plaintext, now: now) {
                if case .message(_, let message) = event {
                    try handleReliable(message, nowMicros: nowMicros)
                }
            }
            outbound += try pollArq(nowMicros: nowMicros)
            return step(outbound: outbound)
        default:
            return step(outbound: try exemptControl(plaintext, nowMicros: nowMicros))
        }
    }

    /// ARQ-exempt CTRL, classified by the shared client vocabulary: a
    /// beacon is echoed, a path challenge answered at once on the path it
    /// probed, a repair refusal escalates to an IDR. Unknown types are
    /// skipped; malformed words count and drop.
    private func exemptControl(
        _ payload: [UInt8], nowMicros: UInt64
    ) throws -> [[UInt8]] {
        let now = ClientTimestamp(microseconds: nowMicros)
        switch ClientExemptControl(payload: payload) {
        case .clockBeacon(let beacon):
            let (echo, sample) = echoBook.answer(
                beacon, receivedAt: now, sendingAt: now)
            if let sample { hostClock.ingest(sample) }
            return [try sealCtrl(plaintext: echo.encode(), nowMicros: nowMicros)]
        case .pathChallenge(let response):
            counters.pathChallengesAnswered += 1
            return [try sealCtrl(plaintext: response.encode(), nowMicros: nowMicros)]
        case .repairRefused(let refusal):
            counters.repairRefusals += 1
            note("nack: frame \(refusal.frame.rawValue) repair refused (\(refusal.reason))")
            for line in video.handleRepairRefusal(
                frame: refusal.frame, nowMicros: nowMicros)
            {
                note(line)
            }
            return []
        case .malformed:
            counters.malformedControl += 1
            return []
        case .unclaimed:
            return []
        }
    }

    private func handleReliable(_ message: [UInt8], nowMicros: UInt64) throws {
        let now = ClientTimestamp(microseconds: nowMicros)

        // Pairing words first (ClientControlSession does not claim them).
        if let output = pairing?.handleReliableCtrl(message) {
            for reply in output.replies {
                try arq.send(message: reply, now: now)
            }
            for event in output.events {
                switch event {
                case .paired:
                    paired = true
                    note("pairing: PAIRED — host static pinned")
                case .pinMismatch:
                    fail("pairing: PIN mismatch")
                case .invalidShare:
                    fail("pairing: invalid share")
                case .hostRejected(let reason):
                    fail("pairing: host rejected (\(reason))")
                case .malformed:
                    counters.malformedControl += 1
                }
            }
            promoteIfReady()
            return
        }

        // Input echoes are host→client accounting.
        if message.first == CtrlMessageType.inputEcho {
            guard let echo = try? InputEcho.decode(message) else {
                counters.malformedControl += 1
                return
            }
            inputEchoes += UInt64(echo.tuples.count)
            return
        }

        guard var control else { return }
        guard let decision = try control.receiveReliable(message, now: now) else {
            return
        }
        self.control = control
        for reply in decision.outboundReliable {
            try arq.send(message: reply, now: now)
        }
        if decision.counters.contains(.malformedReliableMessage) {
            counters.malformedControl += 1
        }
        if let line = decision.note {
            note("control: \(line)")
        }
        note(posture: decision.detectorPosture)
        switch decision.event {
        case .capability(.agreed(let caps)):
            capabilitiesAgreed = true
            var detail =
                "capabilities: agreed codecs=\(caps.videoCodecs) maxDatagram=\(caps.maxDatagramBytes)"
            if caps.clipboardText {
                detail += " clipboardText=true"
            }
            note(detail)
        case .capability(.failed(let err)):
            // The composed teardown leaves before the session fails.
            if let lifecycle = decision.lifecycle {
                try apply(lifecycle, nowMicros: nowMicros)
            }
            fail("capabilities failed: \(err)")
            return
        case .lifecycle(.sessionTeardown):
            note("teardown: received from host")
        case .clipboard(.textChanged(let text)):
            clipboardReceived += 1
            lastClipboardText = text
            note("clipboard: announce (\(text.utf8.count) B)")
        default:
            break
        }
        if let lifecycle = decision.lifecycle {
            try apply(lifecycle, nowMicros: nowMicros)
        }
        promoteIfReady()
    }

    private func promoteIfReady() {
        if status == .established, capabilitiesAgreed, paired {
            status = .ready
            note("session: READY (Noise + pair + capabilities; video arm open)")
        }
    }

    // MARK: Lifecycle

    /// Feeds evidence stamped since the last beat at its arrival instant,
    /// then polls the lifecycle at `now`, executing the wire actions.
    private func advanceLifecycle(nowMicros: UInt64) throws {
        guard var control else { return }
        var decisions: [ClientSessionLifecycleDecision] = []
        if let evidence = pendingEvidenceMicros {
            pendingEvidenceMicros = nil
            decisions.append(control.advance(
                .mediaPathEvidence,
                now: ClientTimestamp(microseconds: evidence)
            ))
        }
        decisions.append(control.advance(now: ClientTimestamp(microseconds: nowMicros)))
        self.control = control
        for decision in decisions {
            try apply(decision, nowMicros: nowMicros)
        }
    }

    private func apply(
        _ decision: ClientSessionLifecycleDecision, nowMicros: UInt64
    ) throws {
        for effect in decision.effects {
            switch effect {
            case .sendTeardown(_, let message):
                try arq.send(
                    message: message,
                    now: ClientTimestamp(microseconds: nowMicros)
                )
            case .closed(let reason):
                if status != .failed, status != .closed {
                    status = .closed
                    closeReason = reason
                    note("session: closed (\(reason))")
                }
            }
        }
    }

    // MARK: Video recovery

    private func idrRequestsDue(nowMicros: UInt64) throws -> [[UInt8]] {
        guard let request = video.idrRequestDue(nowMicros: nowMicros) else {
            return []
        }
        counters.idrRequestsSent += 1
        note("video: IDR request #\(request.requestSeq) frame=\(request.frame.rawValue)")
        // ARQ-exempt fire-and-forget: a lost request is superseded by the
        // next retry of the same episode.
        return [try sealCtrl(plaintext: request.encode(), nowMicros: nowMicros)]
    }

    // MARK: Feedback

    private func record(_ envelope: Envelope, arrivalMicros: UInt64) {
        ledgers[envelope.channel, default: SeqGapTracker()].record(envelope.seq)
        guard arrivals.count < Self.maxRetainedArrivalSamples else {
            counters.arrivalSamplesDropped += 1
            return
        }
        arrivals.append(ClientFeedbackReporter.Arrival(
            channel: envelope.channel, seq: envelope.seq,
            arrivalMicroseconds: arrivalMicros))
    }

    /// This beat's chan-3 report: the ledgers, the arrivals since the last
    /// one and any queued NACK entries. Unreliable and bare, as native
    /// sends it; a lost report is superseded by the next.
    private func feedbackReport(nowMicros: UInt64) -> [[UInt8]] {
        nextFeedbackMicros = nowMicros &+ Self.feedbackIntervalMicroseconds
        let report = feedback.report(
            ledgers: ledgers.keys.sorted { $0.rawValue < $1.rawValue }.map {
                let tracker = ledgers[$0]!
                return ClientFeedbackReporter.Ledger(
                    channel: $0, highestSeq: tracker.highest,
                    datagrams: tracker.received,
                    duplicates: tracker.duplicates,
                    missing: tracker.datagramsMissing)
            },
            arrivals: arrivals,
            now: ClientTimestamp(microseconds: nowMicros))
        arrivals.removeAll(keepingCapacity: true)
        do {
            let datagram = try seal(
                channel: .feedback, plaintext: try report.encode(),
                extensions: [], nowMicros: nowMicros)
            counters.feedbackReportsSent += 1
            return [datagram]
        } catch {
            counters.feedbackReportsFailed += 1
            return []
        }
    }

    // MARK: Wire helpers

    private func pollArq(nowMicros: UInt64) throws -> [[UInt8]] {
        let (payloads, _) = arq.poll(now: ClientTimestamp(microseconds: nowMicros))
        return try payloads.map { try sealCtrl(plaintext: $0, nowMicros: nowMicros) }
    }

    private func sealCtrl(
        plaintext: [UInt8], nowMicros: UInt64
    ) throws -> [UInt8] {
        try seal(
            channel: .ctrl, plaintext: plaintext,
            extensions: connectionIds.extensions, nowMicros: nowMicros)
    }

    private func seal(
        channel: ChannelId, plaintext: [UInt8],
        extensions: [WireExtension], nowMicros: UInt64
    ) throws -> [UInt8] {
        guard var transport else {
            throw BrowserControlError.notEstablished
        }
        let envelope = sequencer.envelope(
            channel: channel,
            timestamp: nowMicros,
            extensions: extensions
        )
        let datagram = try transport.sealDatagram(envelope, plaintext: plaintext)
        self.transport = transport
        return datagram
    }

    private func note(_ line: String) {
        events.append(line)
    }

    private func note(posture: ClientDetectorPosture?) {
        switch posture {
        case .tightened(let bound):
            note("audio evidence — blackout detector tightened to \(bound / 1_000) ms")
        case .relaxed(let bound):
            note("audio quiet announced — blackout detector relaxed to \(bound / 1_000) ms")
        case nil:
            break
        }
    }

    /// Builds a step and drains the notes, so each note is reported once.
    private func step(
        outbound: [[UInt8]],
        scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
    ) -> Step {
        let drained = events
        events.removeAll(keepingCapacity: true)
        let passed = (status == .ready || status == .closed) && failure == nil
        return Step(
            outbound: outbound,
            events: drained,
            status: status,
            detail: failure
                ?? (status == .ready ? "Noise + pair + capabilities" : status.rawValue),
            passed: passed,
            scheduled: scheduled
        )
    }

    /// Ends the session once; the FAIL note rides the step being built.
    private func fail(_ message: String) {
        guard status != .failed else { return }
        status = .failed
        failure = message
        note("FAIL  \(message)")
    }

    private func failStep(_ message: String) -> Step {
        fail(message)
        return step(outbound: [])
    }

    private var isDraining: Bool { status == .closed || status == .failed }
}

public enum BrowserControlError: Error {
    case badHostStatic
    case badPin
    case notEstablished
}
