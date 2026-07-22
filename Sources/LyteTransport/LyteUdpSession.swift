// LyteUdpSession (CL-8, absorbing CL-7's deferred session slice): the
// client's production Lyte-UDP session object — the thing behind the
// app's ConnectionModel and behind `lyte-cli wire-view`. It assembles
// the proven parts into one lifecycle:
//
//   Noise IK (persistent identity; W8 0x13→0x14 retry answer in the
//   dial path — NoiseTransportCrypto's leg)
//     → UdpReceiveEndpoint (bind, handshake, receive thread)
//     → ReceiveDemux / TransportSender (seal/unseal, header-as-AAD)
//     → ReliableCtrlEndpoint (CL-7's ARQ carriage)
//         → CapabilityNegotiator(client) — declaration 0x0F is the
//           FIRST reliable word each way; the intersection IS the
//           agreement (W7)
//         → SessionStateMachine(mediaReceiver) — mirrors ModeTransition
//           0x09, consumes SessionTeardown 0x0A, derives the FROZEN
//           pill (W4b)
//         → IdleFrame 0x15 → LyteVideoPipeline.ingestReliableFrame
//           (rendered through the SAME factory as datagram video; the
//           one-shot's ACK — the host's flip-to-IDLE gate — leaves in
//           the same ingest pass, nothing extra needed)
//     → LyteVideoPipeline (chan 2 datagram video), FeedbackSender,
//       BeaconEchoResponder → HostClockModel (CL-10), IdrRequester
//
// Split for the gate tests (the ReliableCtrlGateTests/PairingGateTests
// pattern): `LyteUdpSessionCore` is everything above the socket — it
// takes a demux, a sender, and an injected clock, so tests drive the
// REAL assembly through SimNet in virtual time against a LyteWire host
// build-up. `LyteUdpSession` is the thin production shell that binds
// the socket, runs the handshake, and owns the wall-clock timers.
//
// The client's silence detector — an honest deviation, documented:
// W4b's 350 ms detector is dimensioned for the media-path evidence
// stream (25–50 ms feedback for the host, 5 ms audio for the client).
// The client has no audio channel until H2, and an IDLE host sends
// only 1 Hz beacons — a 350 ms receiver detector would flap
// FROZEN↔IDLE between beacons forever. So the client (a) feeds EVERY
// authenticated host arrival to the detector (video shards, sealed
// CTRL, beacons — for the receiver they are all proof the host→client
// path moves), and (b) defaults the blackout threshold to 2.5 s,
// comfortably past the 1 Hz beacon cadence and still far under the
// 30 s liveness teardown. When H2's audio lands (the 5 ms path probe),
// the default tightens back to the pillar's 350 ms and the evidence
// split (media vs CTRL) becomes real. The machine's config is the
// injection point; nothing in Wire/ changes.

import CoreMedia
import Dispatch
import Foundation
import LyteWire

// MARK: - Events

/// Everything the session surfaces to its owner (the CLI's printer,
/// the app's ConnectionModel). Fired from receive/timer threads —
/// UI owners hop to the main actor themselves.
public enum LyteUdpSessionEvent: Sendable {
    /// The W7 exchange settled: this is the session's agreed set.
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection —
    /// the typed teardown followed automatically.
    case capabilitiesFailed(String)
    /// A host renegotiation proposal (0x11) was answered (0x12).
    case capabilityUpdateAnswered(accepted: Bool)
    /// The wire mode changed (a delivered ModeTransition, or RECOVERY
    /// re-entry semantics on the host's side reflected here).
    case modeChanged(SessionWireMode)
    /// The lifecycle state changed — `frozen` is the CL-8 pill.
    case stateChanged(SessionState)
    /// A reliable idle frame (0x15) arrived, with what became of it.
    case idleFrameReceived(frame: UInt32, outcome: ReliableFrameOutcome)
    /// Our typed teardown left on the ordered stream.
    case teardownSent(SessionTeardownReason)
    /// The session reached `closed` — peer teardown, local teardown,
    /// or the 30 s liveness timeout. The owner stops the session.
    case closed(SessionCloseReason)
    /// Protocol weather worth a log line, never fatal.
    case protocolNote(String)
}

/// Session-level counters (the parts keep their own detailed stats;
/// these are the CL-8 dispatch layer's).
public struct LyteUdpSessionCounters: Sendable {
    public var modeTransitionsReceived: UInt64 = 0
    public var idleFramesReceived: UInt64 = 0
    public var capabilityUpdatesAnswered: UInt64 = 0
    public var unknownReliableTypes: UInt64 = 0
    public var malformedReliableMessages: UInt64 = 0
    /// 0x17 echo messages consumed (tuple-level books live on
    /// `InputSender`'s stats — CL-9).
    public var inputEchoMessagesReceived: UInt64 = 0
    /// Chan-1 datagrams routed to the audio receiver (CL-11).
    public var audioDatagramsReceived: UInt64 = 0
}

// MARK: - Config

public struct LyteUdpSessionCoreConfig: Sendable {
    /// What this client declares (0x0F). The default is the wire
    /// default: HEVC, 4:2:0, idle silence on, 1152 B ceiling.
    public var capabilities: Capabilities
    /// The receiver machine's timing. The default deviates from
    /// SessionMachineConfig's 350 ms blackout deliberately — see the
    /// file comment: 2.5 s is beacon-bounded until H2's audio provides
    /// the 5 ms path probe.
    public var machineConfig: SessionMachineConfig
    /// CL-11, the tightening the CL-8 deviation promised: once this
    /// session has SEEN audio (an authenticated chan-1 datagram — the
    /// 5 ms path probe, flowing in ACTIVE/IDLE/FROZEN per HS-15's
    /// lifecycle ruling), the blackout detector re-arms at this
    /// threshold — W4b's pillar figure. Evidence-gated rather than
    /// capability-gated deliberately: W7's registry carries only the
    /// reserved audioExpress escape hatch, no audio-presence key, so
    /// a no-audio host (--no-audio, or pre-HS-15) simply never
    /// tightens and keeps the 2.5 s beacon-bounded behavior. Nil
    /// disables tightening outright.
    public var tightenedBlackoutSilenceMicroseconds: Int64?
    /// The audio playout buffer's policy (CL-11).
    public var audioJitter: AudioJitterConfig
    /// The targeted-repair ask policy (CL-12).
    public var nackPolicy: NackPolicyConfig

    public init(
        capabilities: Capabilities = .wireDefault,
        machineConfig: SessionMachineConfig = SessionMachineConfig(
            blackoutSilenceMicroseconds: 2_500_000
        ),
        tightenedBlackoutSilenceMicroseconds: Int64? = 350_000,
        audioJitter: AudioJitterConfig = AudioJitterConfig(),
        nackPolicy: NackPolicyConfig = NackPolicyConfig()
    ) {
        self.capabilities = capabilities
        self.machineConfig = machineConfig
        self.tightenedBlackoutSilenceMicroseconds =
            tightenedBlackoutSilenceMicroseconds
        self.audioJitter = audioJitter
        self.nackPolicy = nackPolicy
    }
}

// MARK: - The core (everything above the socket)

public final class LyteUdpSessionCore: @unchecked Sendable {
    public let config: LyteUdpSessionCoreConfig

    private let now: @Sendable () -> ClientTimestamp
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void

    // The parts. IUO because their callbacks reference self (the
    // PairingGateTests construction order).
    public private(set) var pipeline: LyteVideoPipeline!
    public private(set) var reliable: ReliableCtrlEndpoint!
    public private(set) var echoResponder: BeaconEchoResponder!
    public private(set) var idrRequester: IdrRequester!
    public private(set) var feedback: FeedbackSender!
    public private(set) var input: InputSender!
    public private(set) var audio: AudioReceiver!
    /// CL-12: the targeted-repair ask policy behind the pipeline's
    /// repair-signal seam.
    public private(set) var nackPolicy: NackPolicy!
    public let clockModel = HostClockModel()

    // Machine + negotiator + dispatch state, one lock.
    private let lock = NSLock()
    private var machine: SessionStateMachine<ClientClock>
    private var negotiator: CapabilityNegotiator
    private var lastState: SessionState = .active
    private var lastWireMode: SessionWireMode = .active
    private var agreed: Capabilities?
    private var counters = LyteUdpSessionCounters()
    /// True once the first authenticated chan-1 datagram landed and
    /// (config permitting) the detector re-armed at 350 ms.
    public private(set) var detectorTightened = false

    /// The production machine-poll wake; nil until `startTimers()`.
    private var machineTimer: DispatchSourceTimer?

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        config: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(
                microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
        },
        onSample: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        self.config = config
        self.now = now
        self.onEvent = onEvent
        // The machine begins at establishment (the shell constructs the
        // core only after the Noise handshake), streaming: ACTIVE.
        self.machine = SessionStateMachine(
            role: .mediaReceiver,
            config: config.machineConfig,
            now: now()
        )
        self.negotiator = CapabilityNegotiator(
            role: .client, local: config.capabilities
        )

        self.pipeline = LyteVideoPipeline(
            onSample: { [weak self] sample, unit in
                // The input→photon seam (CL-9): a DELIVERED frame whose
                // shards carried the lastInputSeq TLV closes every
                // pending event at or below its stamp. Delivery — not
                // shard arrival — is the honest instant.
                if let self {
                    self.input.noteFrameDelivered(
                        frame: unit.frameNumber, now: self.now())
                }
                onSample(sample, unit)
            },
            onFecImpossible: { [weak self] frame, _, _ in
                // CL-12: a frame with a live repair ask holds its IDR
                // for the rule-4 window; everything else requests as
                // CL-3 always did (the policy escalates expiries back
                // through the same requester).
                guard let self else { return }
                let now = self.now()
                if !self.nackPolicy.shouldDeferFecImpossible(
                    frame: frame, now: now
                ) {
                    self.idrRequester.recordFecImpossible(
                        frame: frame, now: now)
                }
            },
            onRepairSignal: { [weak self] signal, now in
                self?.nackPolicy.handle(signal, now: now)
            })
        self.reliable = ReliableCtrlEndpoint(
            sender: sender,
            now: now,
            onEvent: { [weak self] event in
                self?.dispatchReliable(event)
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
                // host's rule-3 freeze budget (~33 ms) is tighter than
                // the 25–50 ms cadence.
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
                self.idrRequester.recordFecImpossible(frame: frame, now: now)
                self.onEvent(.protocolNote(
                    "nack: frame \(frame.rawValue) repair expired — "
                    + "IDR instead"))
            })
        self.audio = AudioReceiver(jitterConfig: config.audioJitter)
    }

    // MARK: Lifecycle

    /// The first reliable word: this end's capability declaration
    /// (0x0F) on the ARQ ordered stream — everything gated on a
    /// capability orders behind it for free (W7's rule; the host does
    /// the same from its side).
    public func open(now: ClientTimestamp) throws {
        lock.lock()
        let declaration = negotiator.start()
        lock.unlock()
        try reliable.send(try declaration.encode(), now: now)
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
            self.applyMachine(nil, now: self.now())
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
        pipeline.stop()
    }

    /// One virtual-time beat for tests: machine poll + ARQ PTO +
    /// pipeline eviction (feedback stays caller-driven — its reports
    /// are a cadence choice, not a correctness one).
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
        pipeline.tick(now: now)
        nackPolicy.tick(now: now)
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

    // MARK: Input (CL-9)

    /// Queues one captured input event on the reliable ordered stream
    /// (0x16), stamped `now` and sequenced by the session's counter.
    /// NEVER gated on wire mode or the FROZEN overlay: the host runs
    /// `.preArmInput` on every delivered event BEFORE injecting, so an
    /// event in IDLE is the WAKE and one during a blackout persists
    /// through FROZEN into RECOVERY's IDR (W4b via HS-13) — sending
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

    // MARK: Ingest

    /// The endpoint's per-datagram hook: routes accepted payloads to
    /// their consumers and feeds the lifecycle machine's evidence
    /// clocks (every authenticated arrival — the file comment's
    /// receiver-side evidence rule).
    public func handleDatagram(
        _ outcome: IngestOutcome, arrivalMicroseconds: UInt64
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
                echoResponder.handleCtrlPayload(
                    payload, arrivalMicroseconds: now.microseconds)
            }
        } else if envelope.channel == pipeline.channel {
            // Any one shard's lastInputSeq TLV (0x03) associates the
            // frame with the newest injected input — recorded before
            // ingest so the association exists when delivery fires
            // from this same pass.
            input.noteVideoShard(envelope: envelope)
            pipeline.ingest(envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .audio {
            // CL-11: the 5 ms path probe. Depacketize/recover/buffer,
            // and — first time only — tighten the blackout detector
            // to the pillar's 350 ms: with audio flowing in every
            // non-closed state (HS-15's lifecycle ruling), 350 ms of
            // total silence honestly means the path is dark.
            lock.lock()
            counters.audioDatagramsReceived += 1
            lock.unlock()
            audio.ingest(envelope: envelope, payload: payload, now: now)
            tightenDetectorIfNeeded(now: now)
        }
        applyMachine(.mediaPathEvidence, now: now)
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
        guard !detectorTightened, machine.state != .closed else {
            lock.unlock()
            return
        }
        detectorTightened = true
        var machineConfig = config.machineConfig
        machineConfig.blackoutSilenceMicroseconds = tightened
        var rebuilt = SessionStateMachine<ClientClock>(
            role: .mediaReceiver, config: machineConfig, now: now)
        _ = rebuilt.apply(.modeMessage(machine.wireMode), now: now)
        // lastState/lastWireMode stay untouched: the next applyMachine
        // pass surfaces any edge this rebuild caused (e.g. a FROZEN
        // pill clearing on this very evidence).
        machine = rebuilt
        lock.unlock()
        onEvent(.protocolNote(String(
            format: "audio evidence — blackout detector tightened to %d ms",
            tightened / 1_000)))
    }

    // MARK: Snapshots

    public var state: SessionState {
        lock.lock()
        defer { lock.unlock() }
        return machine.state
    }

    public var wireMode: SessionWireMode {
        lock.lock()
        defer { lock.unlock() }
        return machine.wireMode
    }

    /// The CL-8 pill: true while the local overlay says the path is
    /// dark. Never a wire state; never modal in the UI.
    public var isFrozen: Bool { state == .frozen }

    public var agreedCapabilities: Capabilities? {
        lock.lock()
        defer { lock.unlock() }
        return agreed
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
        var actions: [SessionAction] = []
        if let input {
            actions += machine.apply(input, now: now)
        }
        let (polled, _) = machine.poll(now: now)
        actions += polled
        let state = machine.state
        let mode = machine.wireMode
        let stateEdge = state != lastState
        let modeEdge = mode != lastWireMode
        lastState = state
        lastWireMode = mode
        lock.unlock()

        for action in actions {
            switch action {
            case .sendTeardownMessage(let reason):
                do {
                    try reliable.send(
                        SessionTeardown(reason: reason).encode(), now: now)
                    onEvent(.teardownSent(reason))
                } catch {
                    onEvent(.protocolNote(
                        "teardown send refused: \(error)"))
                }
            case .sessionClosed(let reason):
                onEvent(.closed(reason))
            case .sendModeMessage, .sendFinalFrameReliably,
                 .armNextDamageAsIdr, .forceIdr,
                 .freezeDatagramSends, .resumeDatagramSends:
                break   // sender-role actions; a receiver never emits them
            }
        }
        if modeEdge { onEvent(.modeChanged(mode)) }
        if stateEdge { onEvent(.stateChanged(state)) }
    }

    // MARK: Reliable dispatch

    /// Every ARQ delivery, dispatched by its own CTRL type byte — the
    /// host Session's consumeReliable, mirrored for the client's
    /// registered consumers. Hostile bytes are counted, never fatal.
    private func dispatchReliable(_ event: ArqEvent) {
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        switch bytes.first {
        case CtrlMessageType.modeTransition:
            guard let transition = try? ModeTransition.decode(bytes) else {
                noteMalformed("mode transition")
                return
            }
            lock.lock()
            counters.modeTransitionsReceived += 1
            lock.unlock()
            applyMachine(.modeMessage(transition.mode), now: now)

        case CtrlMessageType.sessionTeardown:
            guard let teardown = try? SessionTeardown.decode(bytes) else {
                noteMalformed("session teardown")
                return
            }
            applyMachine(.teardownMessage(teardown.reason), now: now)

        case CtrlMessageType.capabilityDeclaration:
            receiveDeclaration(bytes, now: now)

        case CtrlMessageType.capabilityUpdate:
            receiveUpdate(bytes, now: now)

        case ClientCtrlMessageType.idleFrame:
            receiveIdleFrame(bytes)

        case ClientCtrlMessageType.inputEcho:
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
            onEvent(.protocolNote(String(
                format: "unregistered reliable CTRL type 0x%02x (%d B)",
                bytes.first ?? 0, bytes.count)))
        }
    }

    /// The host's declaration: intersection = agreement. An unworkable
    /// intersection (no common codec/chroma) draws the typed teardown —
    /// the host-side rule (HS-11), mirrored.
    private func receiveDeclaration(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        guard let declaration = try? CapabilityDeclaration.decode(bytes)
        else {
            noteMalformed("capability declaration")
            return
        }
        lock.lock()
        do {
            let event = try negotiator.receive(declaration)
            if case .agreed(let intersection) = event {
                agreed = intersection
                lock.unlock()
                onEvent(.capabilitiesAgreed(intersection))
                return
            }
            lock.unlock()
        } catch let failure as CapabilityNegotiationError
            where failure == .noCommonVideoCodec
                || failure == .noCommonChromaMode {
            lock.unlock()
            onEvent(.capabilitiesFailed(String(describing: failure)))
            beginTeardown(reason: .shuttingDown, now: now)
        } catch {
            lock.unlock()
            onEvent(.protocolNote(
                "capability declaration refused: \(error)"))
        }
    }

    /// A host renegotiation proposal (v1: maxDatagramBytes only). The
    /// negotiator judges it; the ack echoes the proposal verbatim.
    private func receiveUpdate(_ bytes: [UInt8], now: ClientTimestamp) {
        guard let update = try? CapabilityUpdate.decode(bytes) else {
            noteMalformed("capability update")
            return
        }
        lock.lock()
        let event: CapabilityEvent?
        do {
            event = try negotiator.receive(update)
        } catch {
            lock.unlock()
            onEvent(.protocolNote("capability update refused: \(error)"))
            return
        }
        counters.capabilityUpdatesAnswered += 1
        lock.unlock()
        guard case .answerUpdate(let ack) = event else { return }
        do {
            try reliable.send(try ack.encode(), now: now)
            onEvent(.capabilityUpdateAnswered(
                accepted: ack.status == .accepted))
        } catch {
            onEvent(.protocolNote("update ack send refused: \(error)"))
        }
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

// MARK: - The production shell

public final class LyteUdpSession: @unchecked Sendable {
    public struct Config: Sendable {
        /// The local bind (0 = kernel-assigned; wire-view binds its
        /// argued port for tcpdump-friendly runs).
        public var bindPort: UInt16 = 0
        public var bindAddress: String = "0.0.0.0"
        public var core = LyteUdpSessionCoreConfig()
        /// How long `close()` waits for the teardown segment's ACK
        /// before tearing the socket down anyway.
        public var teardownLingerMilliseconds = 500
        /// CL-11: decode + play the audio channel (AVAudioEngine).
        /// Default on — audio just plays; the receiver's stats exist
        /// either way. wire-view surfaces this as --audio.
        public var audioPlayback = true

        public init() {}
    }

    /// The crypto seam, prepared by the caller: NoiseTransportCrypto
    /// (persistent identity for the app's paired path, throwaway for
    /// the --host-key debug posture) or InsecureTransportCrypto for
    /// the recorded CP-3 fallback.
    public let crypto: any TransportCrypto
    public let config: Config
    public private(set) var endpoint: UdpReceiveEndpoint?
    public private(set) var core: LyteUdpSessionCore?
    /// The CL-11 playback unit, present when `config.audioPlayback`
    /// and the audio device came up.
    public private(set) var audioPlayer: LyteAudioPlayer?

    private let onSample: @Sendable (CMSampleBuffer, DecodeUnit) -> Void
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let coreBox = SessionCoreBox()
    private let closing = SessionFlag()
    /// CoreAudio engine start/stop runs HERE, never on the caller's
    /// thread: AVAudioEngine.start() can block on HAL/device
    /// arbitration (found live — wire-view's @MainActor run() wedged
    /// inside session.start() before NSApplication owned the run
    /// loop). One serial queue keeps start/stop ordered.
    private let audioQueue = DispatchQueue(
        label: "lyte.audio.engine", qos: .userInitiated)

    public init(
        crypto: any TransportCrypto,
        config: Config = Config(),
        onSample: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        self.crypto = crypto
        self.config = config
        self.onSample = onSample
        self.onEvent = onEvent
    }

    /// Bind → Noise handshake (blocking, retry timer inside; answers a
    /// W8 retry challenge with the verbatim msg1) → receive thread →
    /// capability declaration as the first reliable word → timers.
    /// Throws TransportCryptoError / TransportEndpointError on a dial
    /// that never became a session.
    public func start() throws {
        let coreBox = coreBox
        let endpoint = UdpReceiveEndpoint(
            port: config.bindPort,
            bindAddress: config.bindAddress,
            crypto: crypto,
            onDatagram: { outcome, arrivalMicroseconds in
                coreBox.value?.handleDatagram(
                    outcome, arrivalMicroseconds: arrivalMicroseconds)
            })
        try endpoint.start()
        self.endpoint = endpoint

        let sender = TransportSender(crypto: crypto, transmit: {
            [weak endpoint] datagram in
            endpoint?.sendToPeer(datagram) ?? false
        })
        let core = LyteUdpSessionCore(
            demux: endpoint.demux,
            sender: sender,
            config: config.core,
            onSample: onSample,
            onEvent: onEvent
        )
        self.core = core
        coreBox.value = core
        try core.open()
        core.startTimers()

        // Audio out (CL-11): a refused device is weather, never fatal —
        // the screen must stream even when audio cannot (the host's
        // rule, mirrored). Construction is cheap and synchronous; the
        // engine spin-up goes to the audio queue (see its comment).
        if config.audioPlayback {
            do {
                let player = try LyteAudioPlayer(receiver: core.audio)
                audioPlayer = player
                let onEvent = onEvent
                audioQueue.async {
                    do {
                        try player.start()
                    } catch {
                        onEvent(.protocolNote(
                            "audio playback unavailable (\(error)) — video-only"))
                    }
                }
            } catch {
                onEvent(.protocolNote(
                    "audio playback unavailable (\(error)) — video-only"))
            }
        }
    }

    /// The stream window's mute toggle (CL-11): playback keeps
    /// consuming (buffer discipline unaffected); only the mixer goes
    /// quiet.
    public func setAudioMuted(_ muted: Bool) {
        audioPlayer?.muted = muted
    }

    /// Orderly close: the typed 0x0A on the ordered stream, a linger
    /// for its ACK (≤ the configured window), then teardown. Blocking —
    /// call off the main thread.
    public func close(reason: SessionTeardownReason = .shuttingDown) {
        guard !closing.exchange(true) else { return }
        if let core {
            core.beginTeardown(reason: reason)
            let deadline = DispatchTime.now()
                + .milliseconds(config.teardownLingerMilliseconds)
            while !core.isReliableQuiescent, DispatchTime.now() < deadline {
                usleep(20_000)
            }
        }
        stopParts()
    }

    /// The shell's input leg (CL-9): captured events straight onto the
    /// reliable stream. A refused send (teardown races, mostly) is the
    /// caller's weather — count it, never crash the capture monitor.
    @discardableResult
    public func sendInput(_ body: InputEvent.Body) throws -> UInt32 {
        guard let core else { throw TransportEndpointError.notStarted }
        return try core.sendInput(body)
    }

    /// Hard stop, no wire goodbye — the path after a peer teardown or
    /// liveness close (the machine is already closed; there is nothing
    /// to say and possibly nobody to say it to).
    public func stop() {
        guard !closing.exchange(true) else { return }
        stopParts()
    }

    private func stopParts() {
        if let player = audioPlayer {
            audioPlayer = nil
            // Serialized behind the async start; never blocks teardown.
            audioQueue.async { player.stop() }
        }
        core?.stopTimers()
        endpoint?.stop()
        coreBox.value = nil
    }
}

/// Late-binding box for the endpoint-hook ↔ core construction cycle
/// (the file-private LockedCell pattern; types don't travel files).
final class SessionCoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LyteUdpSessionCore?
    var value: LyteUdpSessionCore? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Once-only latch for the two stop paths.
final class SessionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func exchange(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = raised
        raised = value
        return was
    }
}
