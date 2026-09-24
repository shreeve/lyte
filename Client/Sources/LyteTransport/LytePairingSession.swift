// The whole client pairing flow as one blocking call — what the CLI
// (`wire-pair`) and the app's pairing sheet both drive:
//
//   Noise IK (NoiseTransportCrypto, PERSISTENT client static)
//     → UdpReceiveEndpoint (bind, handshake, receive thread)
//     → LytePairingFlow: ReliableCtrlEndpoint (pairing messages ride the
//       sealed ordered CTRL stream, exactly-once, in order) and
//       PairingInitiatorService (share A → share B/Tb → confirm)
//
// plus beacon echoes while connected (the host's clock stays honest
// during the run) — video datagrams from a `--pair` host that is also
// streaming are counted by the demux and otherwise ignored.
//
// "Paired" is only reported once the confirm's ARQ segment is
// acknowledged (reliable endpoint quiescent): the host really consumed
// the message that completes ITS side, so both keystores can move
// together. Persistence is the caller's move on `.paired` — this file
// touches neither the Keychain nor the pinned-host store.

import LyteIO
import Dispatch
import Foundation
import LyteWire

public enum LytePairing {
    /// Everything one pairing run needs. The host key comes from the
    /// host's console banner (or a prior pin) — the TXT record only
    /// carries its hash; `LyteDiscovery.publicKeyHash` validates a
    /// pasted key against an advertisement before dialing.
    public struct Config: Sendable {
        public var hostAddress: String
        public var hostPort: UInt16
        /// The host's 32-byte Noise static — dialed trust-on-first-use;
        /// pairing's confirmation is what earns it the pin.
        public var hostStaticPublicKey: [UInt8]
        /// The PIN shown on the host's console, as typed.
        public var pin: String
        /// The client's persistent identity (ClientNoiseIdentity) — the
        /// static the host pins.
        public var clientStaticKeys: NoiseKeyPair
        /// Overall deadline for the run, handshake included.
        public var timeoutSeconds: Double
        /// Progress lines for the console / UI, fired from worker
        /// threads.
        public var onProgress: (@Sendable (String) -> Void)?

        public init(
            hostAddress: String,
            hostPort: UInt16,
            hostStaticPublicKey: [UInt8],
            pin: String,
            clientStaticKeys: NoiseKeyPair,
            timeoutSeconds: Double = 20,
            onProgress: (@Sendable (String) -> Void)? = nil
        ) {
            self.hostAddress = hostAddress
            self.hostPort = hostPort
            self.hostStaticPublicKey = hostStaticPublicKey
            self.pin = pin
            self.clientStaticKeys = clientStaticKeys
            self.timeoutSeconds = timeoutSeconds
            self.onProgress = onProgress
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Confirmed both ways: pin this static (the caller's
        /// PinnedHostStore write).
        case paired(hostStaticPublicKey: [UInt8])
        /// Our PIN entry disagreed with the host's tag (or the session
        /// was tampered with — indistinguishable by design). We aborted
        /// with the typed reject.
        case pinMismatch
        /// The host refused: wrong PIN spent host-side, a burned PIN's
        /// silence would surface as `timedOut` instead — 0x0E carries
        /// only the typed reasons.
        case hostRejected(PairingRejectReason)
        /// The host's share was cryptographically invalid (G.I abort).
        case invalidShare
        /// No verdict inside the deadline — wrong port, dead host, or a
        /// burned PIN's deliberate wire silence.
        case timedOut
        /// The stack failed before pairing could speak (bind, handshake,
        /// send errors) — the message says where.
        case failed(String)
    }

    /// Runs one pairing flow to its verdict. Blocking — call it off the
    /// main thread (the CLI's async run() context or a Task).
    public static func run(_ config: Config) -> Outcome {
        let progress = config.onProgress ?? { _ in }

        // Only the host's six ASCII digits reach CPace; any other form
        // would spend one of the host's guesses on a certain mismatch.
        guard let pinBytes = PairingPin.normalize(config.pin) else {
            return .failed("the PIN must be the host's 6 digits")
        }

        let crypto: NoiseTransportCrypto
        do {
            crypto = try NoiseTransportCrypto(
                hostAddress: config.hostAddress,
                hostPort: config.hostPort,
                hostStaticPublicKey: config.hostStaticPublicKey,
                staticKeys: config.clientStaticKeys)
        } catch {
            return .failed("host key rejected: \(error)")
        }

        // The endpoint's datagram hook late-binds the flow, which needs
        // the handshake hash the endpoint's handshake produces.
        let flowBox = PairingLockedBox<LytePairingFlow?>(nil)
        let endpoint = UdpReceiveEndpoint(
            port: 0, crypto: crypto,
            onDatagram: { outcome, _ in flowBox.value?.handle(outcome) })

        progress("Noise IK handshake → "
            + "\(config.hostAddress):\(config.hostPort) …")
        do {
            try endpoint.bindAndHandshake()
        } catch let error as TransportCryptoError {
            return .failed("handshake failed: \(error)")
        } catch {
            return .failed("bind/handshake failed: \(error)")
        }
        defer { endpoint.stop() }
        if let ms = crypto.handshakeMillisecondsSnapshot {
            progress(String(format: "handshake complete in %.1f ms", ms))
        }

        let flow: LytePairingFlow
        do {
            flow = try LytePairingFlow(
                crypto: crypto,
                hostStaticPublicKey: config.hostStaticPublicKey,
                pin: pinBytes,
                transmit: { endpoint.sendToPeer($0) },
                progress: progress)
        } catch {
            return .failed("pairing init: \(error)")
        }
        flowBox.value = flow
        // Consumers are published; only now may host datagrams flow.
        endpoint.startReceiving()
        flow.startTimers()
        defer { flow.stopTimers() }

        do {
            try flow.start()
        } catch {
            return .failed("share A send: \(error)")
        }

        // Wait for the verdict; honesty needs quiescence (the confirm or
        // reject really reached the host and was acknowledged).
        let deadline = SystemMonotonicClock.nowNanoseconds
            + UInt64(Int(config.timeoutSeconds * 1000)) * 1_000_000
        while SystemMonotonicClock.nowNanoseconds < deadline {
            if let outcome = flow.settledOutcome { return outcome }
            usleep(50_000)
        }
        // Deadline with a verdict in hand but ACKs outstanding: report
        // the verdict anyway — the ARQ retransmitted for the whole
        // window, and a lost final ACK must not un-pair a paired run.
        return flow.outcome ?? .timedOut
    }
}

/// One pairing run's composition over an established Noise session, with
/// the datagram IO injected: sealed sends go to `transmit`, accepted
/// datagrams come in through `handle`, and time is `now`. The ARQ carries
/// the pairing words on the sealed ordered CTRL stream, beacons are echoed
/// while the run lasts, and host video/audio is ignored. `LytePairing.run`
/// drives it over a UDP endpoint; the cross-role gate drives it in virtual
/// time against a real host session.
public final class LytePairingFlow: @unchecked Sendable {
    private let service: PairingInitiatorService
    private let reliable: ReliableCtrlEndpoint
    private let echo: BeaconEchoResponder
    private let now: @Sendable () -> ClientTimestamp
    private let lock = NSLock()
    private var verdict: LytePairing.Outcome?
    private var serviceEvents: [PairingInitiatorService.Event] = []

    /// - Parameters:
    ///   - crypto: the established session; the run binds to its
    ///     transcript hash and client static.
    ///   - pin: the host's six ASCII digits (`PairingPin.normalize`).
    ///   - transmit: hands one sealed datagram to the carrier.
    public init(
        crypto: NoiseTransportCrypto,
        hostStaticPublicKey: [UInt8],
        pin: [UInt8],
        transmit: @escaping @Sendable ([UInt8]) -> Bool,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        guard let handshakeHash = crypto.handshakeHashSnapshot else {
            throw TransportCryptoError.handshakeFailed(
                "pairing before the Noise handshake completed")
        }
        let service = try PairingInitiatorService(
            pin: pin,
            clientStaticPublicKey: crypto.clientStaticPublicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: handshakeHash)
        let sender = TransportSender(crypto: crypto, transmit: transmit)
        let reliableBox = PairingLockedBox<ReliableCtrlEndpoint?>(nil)
        // Weak: the flow owns the reliable endpoint that owns this hook.
        let verdictSink = WeakPairingFlow()
        let reliable = ReliableCtrlEndpoint(
            sender: sender,
            now: now,
            onEvent: { event in
                guard case .message(_, let bytes) = event,
                      let output = service.handleReliableCtrl(bytes)
                else { return }
                for reply in output.replies {
                    do { try reliableBox.value?.send(reply) }
                    catch { progress("reliable reply refused: \(error)") }
                }
                verdictSink.value?.record(output.events, progress: progress)
            })
        reliableBox.value = reliable
        self.service = service
        self.reliable = reliable
        self.now = now
        self.echo = BeaconEchoResponder(
            now: now,
            emit: { echo in
                _ = try? sender.send(channel: .ctrl, timestamp: now(),
                                     plaintext: echo.encode())
            })
        verdictSink.value = self
    }

    /// Opens the run: share A on the reliable stream.
    public func start() throws {
        try start(now: now())
    }

    public func start(now: ClientTimestamp) throws {
        try reliable.send(try service.start(), now: now)
    }

    /// One demuxed datagram. Only CTRL matters: ARQ frames feed the
    /// pairing words, beacons are echoed.
    public func handle(_ outcome: IngestOutcome) {
        handle(outcome, now: now())
    }

    public func handle(_ outcome: IngestOutcome, now: ClientTimestamp) {
        guard case .accepted(let envelope, let payload) = outcome,
              envelope.channel == .ctrl
        else { return }
        if reliable.handleCtrlDatagram(
            envelope: envelope, payload: payload, now: now) {
            return
        }
        echo.handleCtrlPayload(payload, arrivalMicroseconds: now.microseconds)
    }

    /// Virtual-time PTO beat (production arms the reliable endpoint's
    /// own timer with `startTimers`).
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
    }

    public func startTimers() { reliable.start() }
    public func stopTimers() { reliable.stop() }

    /// The verdict, once the service reached one.
    public var outcome: LytePairing.Outcome? {
        lock.withLock { verdict }
    }

    /// The verdict once it is also acknowledged: the confirm or reject
    /// reached the host, so both keystores can move together.
    public var settledOutcome: LytePairing.Outcome? {
        guard let outcome, reliable.isQuiescent else { return nil }
        return outcome
    }

    /// The service's events so far, in order.
    public var events: [PairingInitiatorService.Event] {
        lock.withLock { serviceEvents }
    }

    public var pairedHostStaticPublicKey: [UInt8]? {
        service.pairedHostStaticPublicKey
    }

    public var isTerminal: Bool { service.isTerminal }
    public var isReliableQuiescent: Bool { reliable.isQuiescent }
    public var nextDeadline: ClientTimestamp? { reliable.nextDeadline }

    private func record(
        _ events: [PairingInitiatorService.Event],
        progress: (String) -> Void
    ) {
        for event in events {
            let outcome: LytePairing.Outcome?
            switch event {
            case .paired(let key):
                progress("host tag verified — confirm sent")
                outcome = .paired(hostStaticPublicKey: key)
            case .pinMismatch:
                progress("host tag MISMATCH — wrong PIN; "
                    + "aborting with the typed reject")
                outcome = .pinMismatch
            case .invalidShare:
                progress("host share invalid — aborting")
                outcome = .invalidShare
            case .hostRejected(let reason):
                progress("host rejected the run (\(reason))")
                outcome = .hostRejected(reason)
            case .malformed:
                progress("malformed pairing bytes dropped")
                outcome = nil
            }
            lock.withLock {
                serviceEvents.append(event)
                if let outcome { verdict = outcome }
            }
        }
    }
}

/// Tiny locked box for the late-binding construction order (the
/// file-private LockedCell pattern; types don't travel between files).
final class PairingLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class WeakPairingFlow: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: LytePairingFlow?
    var value: LytePairingFlow? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
