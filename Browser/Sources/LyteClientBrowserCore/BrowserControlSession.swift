import LyteClientSession
import LyteCore
import LyteWire

/// The browser's sans-IO session initiator: Noise IK over bare CTRL
/// carriage (with retry-challenge answers and message-1 retransmit), PIN
/// PAKE, capabilities and lifecycle via `ClientControlSession`, the reliable
/// CTRL stream, beacon echo, and demux of sealed video/audio to the playout
/// organs.
///
/// The page owns WebTransport and clocks; every call takes injected time and
/// returns a `Step` of datagrams to send and notes to log. Per-datagram
/// faults — undecodable bytes, a replayed/stale/unauthenticated datagram, a
/// rejected message 2 — are counted and dropped, as the native receive demux
/// does; only protocol and policy failures end the session.
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

    /// Message-1 retransmit schedule. The same message 1 is resent verbatim
    /// (a late host answer stays valid for this transcript), matching the
    /// native initiator's defaults.
    public struct HandshakeRetry: Sendable {
        public var attempts: Int
        public var intervalMicroseconds: UInt64

        public init(attempts: Int = 5, intervalMicroseconds: UInt64 = 1_000_000) {
            self.attempts = max(1, attempts)
            self.intervalMicroseconds = max(1, intervalMicroseconds)
        }
    }

    public struct Counters: Sendable, Equatable {
        /// Datagrams whose envelope did not decode.
        public var undecodableDatagrams: UInt64 = 0
        /// Sealed datagrams that failed authentication or the replay window.
        public var unsealFailures: UInt64 = 0
        /// Authenticated CTRL words that did not decode (dropped).
        public var malformedControl: UInt64 = 0
        /// Message-2 candidates the handshake rejected.
        public var rejectedMessage2: UInt64 = 0
        /// Message-1 transmissions, the first included.
        public var message1Transmissions: UInt64 = 0
        public var retryChallengesAnswered: UInt64 = 0
        public var idrRequestsSent: UInt64 = 0

        public init() {}
    }

    private let hostStaticPublicKey: [UInt8]
    private let clientStatic: NoiseKeyPair
    private let pin: [UInt8]
    private let handshakeRetry: HandshakeRetry

    private var status: Status = .idle
    private var handshake: NoiseSession?
    private var message1: [UInt8]?
    private var lastMessage1SentMicros: UInt64 = 0
    private var transport: NoiseTransport?
    private var ctrlSeq = ChannelSeq(rawValue: 0)
    private var connectionId: ConnectionId?
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
    private var pairing: PairingPakeInitiator?
    private var pairingAwaitingShareB = false
    private var pendingEvidenceMicros: UInt64?
    private var events: [String] = []
    private var failure: String?
    private var video = BrowserVideoPlayout()
    private var audio = BrowserAudioPlayout()
    private var nextInputSeq: UInt32 = 0

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
    /// Assembled frames whose Annex-B the page has not taken yet.
    public var videoDecodeBacklog: Int { video.decodeBacklogCount }
    /// Frames whose presentation metadata the playout still holds.
    public var videoPresentationBacklog: Int { video.presentationBacklogCount }
    public var audioPending: Int { audio.pendingCount }
    public var audioPacketsAssembled: UInt64 { audio.packetsAssembled }
    public var audioPacketsPopped: UInt64 { audio.packetsPopped }
    public var audioPacketsDroppedStale: UInt64 { audio.packetsDroppedStale }
    public var clipboardNegotiated: Bool { control?.clipboardNegotiated ?? false }
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
        let digits = pin.filter(\.isNumber)
        guard !digits.isEmpty else { throw BrowserControlError.badPin }
        self.hostStaticPublicKey = hostKey
        self.clientStatic = NoiseKeyPair.generate()
        self.pin = Array(digits.utf8)
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
        var session = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStaticPublicKey
        )
        let msg1 = try session.writeMessage1()
        handshake = session
        message1 = msg1
        status = .handshaking
        note("noise: msg1 sent (\(msg1.count) B)")
        return step(outbound: [try message1Carriage(nowMicros: nowMicros)])
    }

    /// Ingests one opaque datagram from the host.
    public func ingest(datagram: [UInt8], nowMicros: UInt64) -> Step {
        switch status {
        case .handshaking:
            return ingestHandshake(datagram, nowMicros: nowMicros)
        case .established, .ready, .closed:
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
            return retransmitMessage1IfDue(nowMicros: nowMicros)
        case .established, .ready, .closed:
            break
        case .idle, .failed:
            return step(outbound: [])
        }
        do {
            var outbound: [[UInt8]] = []
            if status != .closed {
                try advanceLifecycle(nowMicros: nowMicros)
                for line in video.evictStale(nowMicros: nowMicros) {
                    note(line)
                }
                outbound += try idrRequestsDue(nowMicros: nowMicros)
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
        } catch {
            return failStep("clipboard send: \(error)")
        }
    }

    // MARK: Handshake

    private func message1Carriage(nowMicros: UInt64) throws -> [UInt8] {
        guard let message1 else { throw BrowserControlError.notEstablished }
        counters.message1Transmissions += 1
        lastMessage1SentMicros = nowMicros
        return try encodeBareCarriage(
            payload: [CtrlMessageType.noiseHandshake1] + message1,
            nowMicros: nowMicros
        )
    }

    private func retransmitMessage1IfDue(nowMicros: UInt64) -> Step {
        guard nowMicros &- lastMessage1SentMicros
            >= handshakeRetry.intervalMicroseconds
        else {
            return step(outbound: [])
        }
        guard counters.message1Transmissions < UInt64(handshakeRetry.attempts) else {
            return failStep(
                "noise: no answer after \(handshakeRetry.attempts) message-1 attempts"
            )
        }
        do {
            let carriage = try message1Carriage(nowMicros: nowMicros)
            note("noise: msg1 retransmit #\(counters.message1Transmissions)")
            return step(outbound: [carriage])
        } catch {
            return failStep("noise: retransmit: \(error)")
        }
    }

    private func ingestHandshake(
        _ datagram: [UInt8], nowMicros: UInt64
    ) -> Step {
        guard let handshake, let message1 else {
            return failStep("handshake state missing")
        }
        guard let (envelope, payload) = try? Envelope.decode(datagram) else {
            counters.undecodableDatagrams += 1
            return step(outbound: [])
        }
        guard envelope.channel == .ctrl, let type = payload.first else {
            return step(outbound: [])
        }

        if type == CtrlMessageType.retryChallenge {
            // Answering does not consume an attempt: the challenge is the
            // host's liveness. The answer echoes the same message 1.
            guard let challenge = try? RetryChallenge.decode(payload),
                  let resubmission = try? RetryHandshake1(
                      echoing: challenge, message1: message1
                  ).encode(),
                  let carriage = try? encodeBareCarriage(
                      payload: resubmission, nowMicros: nowMicros
                  )
            else {
                counters.malformedControl += 1
                return step(outbound: [])
            }
            counters.retryChallengesAnswered += 1
            note("noise: answered retry challenge")
            return step(outbound: [carriage])
        }

        guard type == CtrlMessageType.noiseHandshake2 else {
            return step(outbound: [])
        }
        // A rejected candidate leaves the stored handshake untouched, so a
        // later genuine message 2 still completes it.
        var candidate = handshake
        do {
            _ = try candidate.readMessage2(payload.dropFirst())
        } catch {
            counters.rejectedMessage2 += 1
            return step(outbound: [])
        }
        do {
            return try establish(candidate, nowMicros: nowMicros)
        } catch {
            return failStep("handshake: \(error)")
        }
    }

    private func establish(
        _ completed: NoiseSession, nowMicros: UInt64
    ) throws -> Step {
        let made = try completed.makeTransport()
        let now = ClientTimestamp(microseconds: nowMicros)
        handshake = nil
        transport = made
        status = .established
        handshakeCompleted = true
        note("noise: handshake completed")

        var control = ClientControlSession(
            localCapabilities: .wireDefault.declaringClipboardText(),
            machineConfig: SessionMachineConfig(),
            desiredHostAudioRouting: nil,
            clipboardSharingAtStart: true,
            now: now
        )
        let pairing = try PairingPakeInitiator(
            pin: pin,
            clientStaticPublicKey: clientStatic.publicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: made.handshakeHash
        )
        self.pairing = pairing
        pairingAwaitingShareB = true

        // First reliable words: capability declaration, then pairing share A.
        if let declaration = try control.start() {
            try arq.send(message: declaration, now: now)
            note("capabilities: client declaration queued")
        }
        self.control = control
        try arq.send(message: try pairing.makeShareA().encode(), now: now)
        note("pairing: share A queued")
        return step(outbound: try pollArq(nowMicros: nowMicros))
    }

    // MARK: Established sealed path

    private func ingestSealed(
        _ datagram: [UInt8], nowMicros: UInt64
    ) -> Step {
        guard var transport else { return failStep("no transport") }
        guard let (envelope, wirePayload) = try? Envelope.decode(datagram) else {
            counters.undecodableDatagrams += 1
            return step(outbound: [])
        }
        // The exact received header bytes are the AAD (fixed envelope + TLVs).
        let aad = datagram[datagram.startIndex..<wirePayload.startIndex]
        let plaintext: [UInt8]
        do {
            plaintext = try transport.unseal(
                wirePayload: wirePayload,
                aad: aad,
                envelope: envelope
            )
        } catch {
            counters.unsealFailures += 1
            return step(outbound: [])
        }
        self.transport = transport
        pendingEvidenceMicros = nowMicros

        // Learned only from an authenticated datagram: a forged first
        // datagram must not choose the conn-id every later send carries.
        if connectionId == nil,
           let claimed = try? ConnectionId.decode(extensions: envelope.extensions)
        {
            connectionId = claimed
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
        if status == .closed {
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
                arrivalMicroseconds: nowMicros
            )
            for line in ingested.events { note(line) }
            return step(outbound: [], scheduled: ingested.scheduled)
        case .audio:
            control?.noteAudioEvidence()
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
        case CtrlMessageType.clockBeacon:
            guard let beacon = try? ClockBeacon.decode(plaintext) else {
                counters.malformedControl += 1
                return step(outbound: [])
            }
            let echo = BeaconEcho(
                beaconSeq: beacon.beaconSeq,
                hostSend: beacon.hostSend,
                clientReceive: now,
                clientSend: now
            )
            return step(outbound: [
                try sealCtrl(plaintext: echo.encode(), nowMicros: nowMicros),
            ])
        default:
            // Other ARQ-exempt CTRL (path, repair refusal, …) is not consumed
            // by the browser shell.
            return step(outbound: [])
        }
    }

    private func handleReliable(_ message: [UInt8], nowMicros: UInt64) throws {
        let now = ClientTimestamp(microseconds: nowMicros)

        // Pairing words first (ClientControlSession does not claim them).
        if let type = message.first, (0x0B...0x0E).contains(type) {
            try handlePairing(message, nowMicros: nowMicros)
            promoteIfReady()
            return
        }

        // Input echoes are host→client accounting.
        if message.first == CtrlMessageType.inputEcho {
            let echo = try InputEcho.decode(message)
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
            _ = failStep("capabilities failed: \(err)")
            return
        case .lifecycle(.sessionTeardown):
            note("teardown: received from host")
        case .clipboard(.textChanged(let text)):
            clipboardReceived += 1
            lastClipboardText = text
            note("clipboard: announce (\(text.utf8.count) B)")
        case .clipboard(let other):
            note("clipboard: \(other)")
        default:
            break
        }
        if let lifecycle = decision.lifecycle {
            try apply(lifecycle, nowMicros: nowMicros)
        }
        promoteIfReady()
    }

    private func handlePairing(_ message: [UInt8], nowMicros: UInt64) throws {
        let now = ClientTimestamp(microseconds: nowMicros)
        guard pairingAwaitingShareB, var pairing else { return }
        switch message.first {
        case CtrlMessageType.pairingShareB:
            let shareB = try PairingShareB.decode(message)
            do {
                let confirm = try pairing.receiveShareB(shareB)
                try arq.send(message: try confirm.encode(), now: now)
                paired = true
                pairingAwaitingShareB = false
                self.pairing = pairing
                note("pairing: PAIRED — host static pinned")
            } catch PairingPakeError.confirmationFailed {
                try arq.send(
                    message: PairingReject(reason: .confirmationFailed).encode(),
                    now: now
                )
                pairingAwaitingShareB = false
                _ = failStep("pairing: PIN mismatch")
            } catch PairingPakeError.invalidPeerShare {
                try arq.send(
                    message: PairingReject(reason: .invalidShare).encode(),
                    now: now
                )
                pairingAwaitingShareB = false
                _ = failStep("pairing: invalid share")
            }
        case CtrlMessageType.pairingReject:
            pairingAwaitingShareB = false
            _ = failStep("pairing: host rejected")
        default:
            break
        }
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
        for action in decision.actions {
            switch action {
            case .sendTeardownMessage(let reason):
                try arq.send(
                    message: SessionTeardown(reason: reason).encode(),
                    now: ClientTimestamp(microseconds: nowMicros)
                )
            case .sessionClosed(let reason):
                if status != .failed, status != .closed {
                    status = .closed
                    closeReason = reason
                    note("session: closed (\(reason))")
                }
            default:
                break
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

    // MARK: Wire helpers

    private func pollArq(nowMicros: UInt64) throws -> [[UInt8]] {
        let (payloads, _) = arq.poll(now: ClientTimestamp(microseconds: nowMicros))
        return try payloads.map { try sealCtrl(plaintext: $0, nowMicros: nowMicros) }
    }

    private func sealCtrl(
        plaintext: [UInt8], nowMicros: UInt64
    ) throws -> [UInt8] {
        guard var transport else {
            throw BrowserControlError.notEstablished
        }
        let seq = ctrlSeq
        ctrlSeq = ctrlSeq.next
        let envelope = Envelope(
            channel: .ctrl,
            seq: seq,
            frame: FrameNumber(rawValue: 0),
            timestamp: nowMicros,
            fec: 0,
            extensions: connectionId.map { [$0.wireExtension] } ?? []
        )
        let header = try envelope.encode(payload: [])
        let sealed = try transport.seal(
            plaintext: plaintext[...],
            aad: header[...],
            envelope: envelope
        )
        self.transport = transport
        return try envelope.encode(payload: sealed)
    }

    private func encodeBareCarriage(
        payload: [UInt8], nowMicros: UInt64
    ) throws -> [UInt8] {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: nowMicros,
            fec: 0
        )
        return try envelope.encode(payload: payload)
    }

    private func note(_ line: String) {
        events.append(line)
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

    private func failStep(_ message: String) -> Step {
        if status != .failed {
            status = .failed
            failure = message
            note("FAIL  \(message)")
        }
        return step(outbound: [])
    }
}

public enum BrowserControlError: Error {
    case badHostStatic
    case badPin
    case notEstablished
}
