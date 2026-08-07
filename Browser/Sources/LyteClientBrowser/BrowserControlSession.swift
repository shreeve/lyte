import LyteClientSession
import LyteCore
import LyteWire

/// WASM initiator for B-3…B-6: Noise IK → PIN PAKE → capabilities, then
/// sealed video assemble + Conductor schedule, input/clipboard on the
/// reliable CTRL stream, audio depacketize (B-6), then teardown.
/// Carriage is injected (JS owns WebTransport + clocks); this type only
/// speaks LyteWire / LyteClientSession / LyteCore policy.
final class BrowserControlSession {
    enum Status: String {
        case idle
        case handshaking
        case established
        case ready
        case closed
        case failed
    }

    struct Step {
        var outboundHex: [String]
        var events: [String]
        var status: Status
        var detail: String
        var passed: Bool
        /// Newly Conductor-scheduled frames this step (metadata only).
        var scheduled: [BrowserVideoPlayout.ScheduledFrame]
    }

    private let hostStaticPublicKey: [UInt8]
    private let clientStatic: NoiseKeyPair
    private let pin: [UInt8]

    private var status: Status = .idle
    private var handshake: NoiseSession?
    private var message1: [UInt8]?
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
    private var pairingDone = false
    private var capabilitiesDone = false
    private var events: [String] = []
    private var failure: String?
    private var video = BrowserVideoPlayout()
    private var audio = BrowserAudioPlayout()
    private var nextInputSeq: UInt32 = 0
    private var inputEventsSent: UInt64 = 0
    private var inputEchoTuples: UInt64 = 0
    private var clipboardSetsSent: UInt64 = 0
    private var clipboardAnnounces: UInt64 = 0
    private var lastClipboardAnnounce: String?

    var clientStaticPublicKeyHex: String { Hex.string(clientStatic.publicKey) }
    var hostStaticPublicKeyHex: String { Hex.string(hostStaticPublicKey) }

    var framesAssembled: UInt64 { video.framesAssembled }
    var framesPresented: UInt64 { video.framesPresented }
    var audioPacketsAssembled: UInt64 { audio.packetsAssembled }
    var audioPacketsPopped: UInt64 { audio.packetsPopped }
    var inputsSent: UInt64 { inputEventsSent }
    var inputEchoes: UInt64 { inputEchoTuples }
    var clipboardSent: UInt64 { clipboardSetsSent }
    var clipboardReceived: UInt64 { clipboardAnnounces }
    var lastClipboardText: String? { lastClipboardAnnounce }
    var clipboardNegotiated: Bool { control?.clipboardNegotiated ?? false }

    func annexBHex(frameNumber: UInt32) -> String? {
        guard let bytes = video.annexB(frameNumber: frameNumber) else {
            return nil
        }
        return Hex.string(bytes)
    }

    func annexBBytes(frameNumber: UInt32) -> [UInt8]? {
        video.annexB(frameNumber: frameNumber)
    }

    func popDueFrame(nowMicros: UInt64) -> BrowserVideoPlayout.ScheduledFrame? {
        video.popDue(nowMicros: nowMicros)
    }

    func notePresented(frameNumber: UInt32) {
        video.notePresented(frameNumber: frameNumber)
    }

    func noteDropped(frameNumber: UInt32) {
        video.noteDropped(frameNumber: frameNumber)
    }

    func popAudioPacket() -> BrowserAudioPlayout.Packet? {
        audio.popPacket()
    }

    /// Queue one HS-13 InputEvent on the reliable CTRL stream.
    func sendInput(body: InputEvent.Body, nowMicros: UInt64) -> Step {
        guard status == .ready else {
            // Soft refuse — DOM capture may fire before READY; never
            // poison the session for a premature pointer event.
            return Step(
                outboundHex: [],
                events: ["input: ignored (status \(status.rawValue))"],
                status: status,
                detail: "input ignored until ready",
                passed: false,
                scheduled: []
            )
        }
        do {
            let seq = nextInputSeq
            let event = InputEvent(
                seq: seq, clientMicroseconds: nowMicros, body: body
            )
            try arq.send(
                message: event.encode(),
                now: ClientTimestamp(microseconds: nowMicros)
            )
            nextInputSeq &+= 1
            inputEventsSent += 1
            note("input: sent seq=\(seq)")
            return step(outbound: try pollArq(nowMicros: nowMicros))
        } catch {
            return failStep("input send: \(error)")
        }
    }

    /// Capability-gated ClipboardSet (0x1A) via ClientControlSession.
    func shareClipboard(text: String, nowMicros: UInt64) -> Step {
        guard status == .ready else {
            return Step(
                outboundHex: [],
                events: ["clipboard: ignored (status \(status.rawValue))"],
                status: status,
                detail: "clipboard ignored until ready",
                passed: false,
                scheduled: []
            )
        }
        guard var control else {
            return failStep("no control session")
        }
        let decision = control.shareLocalClipboard(text)
        self.control = control
        guard decision.shareOutcome == .shared,
              let message = decision.outboundReliable.first
        else {
            let why = String(describing: decision.shareOutcome)
            return failStep("clipboard share refused: \(why)")
        }
        do {
            try arq.send(
                message: message,
                now: ClientTimestamp(microseconds: nowMicros)
            )
            control.noteLocalClipboardSent(text)
            self.control = control
            clipboardSetsSent += 1
            note("clipboard: set sent (\(text.utf8.count) B)")
            return step(outbound: try pollArq(nowMicros: nowMicros))
        } catch {
            return failStep("clipboard send: \(error)")
        }
    }

    init(hostStaticPublicKeyHex: String, pin: String) throws {
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
    }

    /// Opens Noise IK message 1 as a bare CTRL carriage datagram.
    func begin(nowMicros: UInt64) throws -> Step {
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
        let carriage = try encodeBareCarriage(
            payload: [CtrlMessageType.noiseHandshake1] + msg1,
            nowMicros: nowMicros
        )
        return step(outbound: [carriage])
    }

    /// Ingest one opaque datagram from the host (via WT↔UDP).
    func ingest(datagramHex: String, nowMicros: UInt64) -> Step {
        guard let datagram = Hex.bytes(datagramHex) else {
            return failStep("malformed datagram hex")
        }
        return ingest(datagram: datagram, nowMicros: nowMicros)
    }

    /// Binary ingest — preferred for video shards (hex copies starve WT).
    func ingest(datagram: [UInt8], nowMicros: UInt64) -> Step {
        if status == .failed || status == .closed {
            return step(outbound: [])
        }
        do {
            switch status {
            case .handshaking:
                return try ingestHandshake(datagram, nowMicros: nowMicros)
            case .established, .ready:
                return try ingestSealed(datagram, nowMicros: nowMicros)
            default:
                return step(outbound: [])
            }
        } catch {
            return failStep("ingest: \(error)")
        }
    }

    /// Drive ARQ PTO / lifecycle / assembler eviction with injected time.
    func tick(nowMicros: UInt64) -> Step {
        if status == .failed || status == .closed || status == .idle
            || status == .handshaking
        {
            return step(outbound: [])
        }
        do {
            var outbound: [[UInt8]] = []
            outbound += try pollArq(nowMicros: nowMicros)
            if capabilitiesDone, pairingDone, status == .ready,
               var control
            {
                // Keep lifecycle clock moving so liveness stays honest.
                _ = control.advance(
                    now: ClientTimestamp(microseconds: nowMicros))
                self.control = control
            }
            for line in video.evictStale(nowMicros: nowMicros) {
                note(line)
            }
            return step(outbound: outbound)
        } catch {
            return failStep("tick: \(error)")
        }
    }

    /// Typed SessionTeardown once the control bar is green.
    func teardown(nowMicros: UInt64) -> Step {
        guard status == .ready || status == .established else {
            return failStep("teardown before ready")
        }
        do {
            guard var control else {
                return failStep("no control session")
            }
            let decision = control.advance(
                .teardownRequest(.shuttingDown),
                now: ClientTimestamp(microseconds: nowMicros)
            )
            self.control = control
            var outbound: [[UInt8]] = []
            for action in decision.actions {
                if case .sendTeardownMessage(let reason) = action {
                    try arq.send(
                        message: SessionTeardown(reason: reason).encode(),
                        now: ClientTimestamp(microseconds: nowMicros)
                    )
                }
            }
            outbound += try pollArq(nowMicros: nowMicros)
            status = .closed
            note("teardown: shuttingDown")
            return step(outbound: outbound)
        } catch {
            return failStep("teardown: \(error)")
        }
    }

    // MARK: Handshake

    private func ingestHandshake(
        _ datagram: [UInt8], nowMicros: UInt64
    ) throws -> Step {
        guard var handshake, let message1 else {
            return failStep("handshake state missing")
        }
        let (envelope, payload) = try Envelope.decode(datagram)
        guard envelope.channel == .ctrl, let type = payload.first else {
            return step(outbound: [])
        }

        if type == CtrlMessageType.retryChallenge {
            let challenge = try RetryChallenge.decode(payload)
            let resubmission = try RetryHandshake1(
                echoing: challenge, message1: message1
            ).encode()
            note("noise: answered retry challenge")
            let carriage = try encodeBareCarriage(
                payload: resubmission, nowMicros: nowMicros
            )
            return step(outbound: [carriage])
        }

        guard type == CtrlMessageType.noiseHandshake2 else {
            return step(outbound: [])
        }
        _ = try handshake.readMessage2(payload.dropFirst())
        let made = try handshake.makeTransport()
        self.handshake = nil
        self.transport = made
        self.status = .established
        note("noise: handshake completed")

        self.control = ClientControlSession(
            localCapabilities: .wireDefault.declaringClipboardText(),
            machineConfig: SessionMachineConfig(),
            desiredHostAudioRouting: nil,
            clipboardSharingAtStart: true,
            now: ClientTimestamp(microseconds: nowMicros)
        )
        self.pairing = try PairingPakeInitiator(
            pin: pin,
            clientStaticPublicKey: clientStatic.publicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: made.handshakeHash
        )
        pairingAwaitingShareB = true

        var outbound: [[UInt8]] = []
        // First reliable words: capability declaration, then pairing share A.
        if var control, let declaration = try control.start() {
            try arq.send(
                message: declaration,
                now: ClientTimestamp(microseconds: nowMicros)
            )
            note("capabilities: client declaration queued")
            self.control = control
        }
        if let pairing {
            let shareA = try pairing.makeShareA().encode()
            try arq.send(
                message: shareA,
                now: ClientTimestamp(microseconds: nowMicros)
            )
            note("pairing: share A queued")
        }
        outbound += try pollArq(nowMicros: nowMicros)
        return step(outbound: outbound)
    }

    // MARK: Established sealed path

    private func ingestSealed(
        _ datagram: [UInt8], nowMicros: UInt64
    ) throws -> Step {
        guard var transport else { return failStep("no transport") }
        let (envelope, wirePayload) = try Envelope.decode(datagram)
        if connectionId == nil,
           let claimed = try? ConnectionId.decode(
               extensions: envelope.extensions
           )
        {
            connectionId = claimed
            note("conn-id: learned")
        }

        // Exact received header bytes as AAD (fixed envelope + TLV block).
        let aad = datagram[datagram.startIndex..<wirePayload.startIndex]
        let plaintext = try transport.unseal(
            wirePayload: wirePayload,
            aad: aad,
            envelope: envelope
        )
        self.transport = transport

        if envelope.channel == .videoActive {
            let (notes, scheduled) = video.ingestShard(
                envelope: envelope,
                payload: plaintext[...],
                arrivalMicroseconds: nowMicros
            )
            for line in notes { note(line) }
            return step(outbound: [], scheduled: scheduled)
        }

        if envelope.channel == .audio {
            for line in audio.ingestShard(
                envelope: envelope, payload: plaintext[...]
            ) {
                note(line)
            }
            return step(outbound: [])
        }

        // Idle-video / feedback: ignore in the browser shell.
        guard envelope.channel == .ctrl else {
            return step(outbound: [])
        }

        var outbound: [[UInt8]] = []
        let now = ClientTimestamp(microseconds: nowMicros)

        guard let type = plaintext.first else { return step(outbound: []) }

        if type == CtrlMessageType.arqSegment
            || type == CtrlMessageType.arqAck
        {
            let arqEvents = arq.ingest(payload: plaintext, now: now)
            for event in arqEvents {
                if case .message(_, let message) = event {
                    outbound += try handleReliable(message, nowMicros: nowMicros)
                }
            }
            outbound += try pollArq(nowMicros: nowMicros)
            return step(outbound: outbound)
        }

        if type == CtrlMessageType.clockBeacon {
            let beacon = try ClockBeacon.decode(plaintext)
            let echo = BeaconEcho(
                beaconSeq: beacon.beaconSeq,
                hostSend: beacon.hostSend,
                clientReceive: now,
                clientSend: ClientTimestamp(microseconds: nowMicros)
            )
            outbound.append(
                try sealCtrl(plaintext: echo.encode(), nowMicros: nowMicros)
            )
            return step(outbound: outbound)
        }

        // Other CTRL (IDR, path, …): ignore in control-only mode.
        return step(outbound: [])
    }

    private func handleReliable(
        _ message: [UInt8], nowMicros: UInt64
    ) throws -> [[UInt8]] {
        let now = ClientTimestamp(microseconds: nowMicros)
        var outbound: [[UInt8]] = []

        // Pairing types first (ClientControlSession does not claim them).
        if let type = message.first,
           (0x0B...0x0E).contains(type)
        {
            outbound += try handlePairing(message, nowMicros: nowMicros)
            promoteIfReady()
            return outbound
        }

        // Input echoes are host→client accounting; not ClientControlSession.
        if message.first == CtrlMessageType.inputEcho {
            let echo = try InputEcho.decode(message)
            inputEchoTuples += UInt64(echo.tuples.count)
            note("input: echo \(echo.tuples.count) tuple(s)")
            return outbound
        }

        guard var control else { return outbound }
        if let decision = try control.receiveReliable(message, now: now) {
            for reply in decision.outboundReliable {
                try arq.send(message: reply, now: now)
            }
            switch decision.event {
            case .capability(.agreed(let caps)):
                capabilitiesDone = true
                var detail =
                    "capabilities: agreed codecs=\(caps.videoCodecs) "
                    + "maxDatagram=\(caps.maxDatagramBytes)"
                if caps.clipboardText {
                    detail += " clipboardText=true"
                }
                note(detail)
            case .capability(.failed(let err)):
                self.control = control
                _ = failStep("capabilities failed: \(err)")
                return outbound
            case .lifecycle(.sessionTeardown):
                status = .closed
                note("teardown: received from host")
            case .clipboard(.textChanged(let text)):
                clipboardAnnounces += 1
                lastClipboardAnnounce = text
                note("clipboard: announce (\(text.utf8.count) B)")
            case .clipboard(let other):
                note("clipboard: \(other)")
            default:
                break
            }
            if let life = decision.lifecycle {
                for action in life.actions {
                    if case .sendTeardownMessage(let reason) = action {
                        try arq.send(
                            message: SessionTeardown(reason: reason).encode(),
                            now: now
                        )
                    }
                }
            }
        }
        self.control = control
        promoteIfReady()
        return outbound
    }

    private func handlePairing(
        _ message: [UInt8], nowMicros: UInt64
    ) throws -> [[UInt8]] {
        let now = ClientTimestamp(microseconds: nowMicros)
        guard pairingAwaitingShareB, var pairing else { return [] }
        switch message.first {
        case CtrlMessageType.pairingShareB:
            let shareB = try PairingShareB.decode(message)
            do {
                let confirm = try pairing.receiveShareB(shareB)
                try arq.send(message: try confirm.encode(), now: now)
                pairingDone = true
                pairingAwaitingShareB = false
                self.pairing = pairing
                note("pairing: PAIRED — host static pinned")
            } catch PairingPakeError.confirmationFailed {
                let reject = PairingReject(reason: .confirmationFailed).encode()
                try arq.send(message: reject, now: now)
                pairingAwaitingShareB = false
                _ = failStep("pairing: PIN mismatch")
            } catch PairingPakeError.invalidPeerShare {
                let reject = PairingReject(reason: .invalidShare).encode()
                try arq.send(message: reject, now: now)
                pairingAwaitingShareB = false
                _ = failStep("pairing: invalid share")
            }
            return []
        case CtrlMessageType.pairingReject:
            pairingAwaitingShareB = false
            _ = failStep("pairing: host rejected")
            return []
        default:
            return []
        }
    }

    private func promoteIfReady() {
        if status == .established, capabilitiesDone, pairingDone {
            status = .ready
            note("session: READY (Noise + pair + capabilities; video arm open)")
        }
    }

    // MARK: Wire helpers

    private func pollArq(nowMicros: UInt64) throws -> [[UInt8]] {
        let now = ClientTimestamp(microseconds: nowMicros)
        let (payloads, _) = arq.poll(now: now)
        var datagrams: [[UInt8]] = []
        for payload in payloads {
            datagrams.append(
                try sealCtrl(plaintext: payload, nowMicros: nowMicros)
            )
        }
        return datagrams
    }

    private func sealCtrl(
        plaintext: [UInt8], nowMicros: UInt64
    ) throws -> [UInt8] {
        guard var transport else {
            throw BrowserControlError.notEstablished
        }
        let seq = ctrlSeq
        ctrlSeq = ctrlSeq.next
        let extensions = connectionId.map { [$0.wireExtension] } ?? []
        let envelope = Envelope(
            channel: .ctrl,
            seq: seq,
            frame: FrameNumber(rawValue: 0),
            timestamp: nowMicros,
            fec: 0,
            extensions: extensions
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

    private func step(
        outbound: [[UInt8]],
        scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
    ) -> Step {
        let passed = status == .ready || status == .closed
        // Drain notes each step — replaying the full history on every
        // video shard stalls the WT reader under FEC burst.
        let drained = events
        events.removeAll(keepingCapacity: true)
        return Step(
            outboundHex: outbound.map(Hex.string),
            events: drained,
            status: status,
            detail: failure
                ?? (status == .ready
                    ? "Noise + pair + capabilities"
                    : status.rawValue),
            passed: passed && failure == nil,
            scheduled: scheduled
        )
    }

    private func failStep(_ message: String) -> Step {
        status = .failed
        failure = message
        note("FAIL  \(message)")
        return Step(
            outboundHex: [],
            events: events,
            status: .failed,
            detail: message,
            passed: false,
            scheduled: []
        )
    }
}

enum BrowserControlError: Error {
    case badHostStatic
    case badPin
    case notEstablished
}
