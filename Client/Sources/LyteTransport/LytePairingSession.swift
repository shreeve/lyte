// The client pairing flow as one blocking call (CLI and app sheet): Noise
// IK with the persistent client static, then PairingInitiatorService over
// the sealed ordered CTRL stream, echoing beacons meanwhile.
//
// "Paired" is reported only once the confirm is acknowledged, so both
// keystores move together. Persistence is the caller's job.

import LyteIO
import Dispatch
import Foundation
import LyteWire

public enum LytePairing {
    /// Everything one pairing run needs.
    public struct Config: Sendable {
        public var hostAddress: String
        public var hostPort: UInt16
        /// The host's 32-byte Noise static, dialed trust-on-first-use.
        public var hostStaticPublicKey: [UInt8]
        /// The PIN shown on the host's console, as typed.
        public var pin: String
        /// The client's persistent identity, which the host pins.
        public var clientStaticKeys: NoiseKeyPair
        /// Overall deadline for the run, handshake included.
        public var timeoutSeconds: Double
        /// Progress lines, fired from worker threads.
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
        /// Confirmed both ways: pin this static.
        case paired(hostStaticPublicKey: [UInt8])
        /// The PIN disagreed with the host's tag (or tampering; the two
        /// are indistinguishable). We aborted with the typed reject.
        case pinMismatch
        /// The host refused with a typed 0x0E reason.
        case hostRejected(PairingRejectReason)
        /// The host's share was cryptographically invalid.
        case invalidShare
        /// No verdict inside the deadline — wrong port, dead host, or a
        /// burned PIN's deliberate wire silence.
        case timedOut
        /// The stack failed before pairing could speak.
        case failed(String)
    }

    /// Runs one pairing flow to its verdict. Blocking.
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
        } catch let error where error is TransportCryptoError
                    || error is HandshakeExhausted {
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

        // Wait for an acknowledged verdict.
        let deadline = SystemMonotonicClock.nowNanoseconds
            + UInt64(Int(config.timeoutSeconds * 1000)) * 1_000_000
        var settled: Outcome?
        while settled == nil, SystemMonotonicClock.nowNanoseconds < deadline {
            settled = flow.settledOutcome
            if settled == nil { usleep(50_000) }
        }
        // The typed goodbye frees the host's session now rather than at
        // its idle timeout; the linger is bounded.
        do { try flow.sendTeardown() }
        catch { progress("teardown send refused: \(error)") }
        let lingerEnd = SystemMonotonicClock.nowNanoseconds + 500_000_000
        while !flow.isReliableQuiescent,
              SystemMonotonicClock.nowNanoseconds < lingerEnd {
            usleep(10_000)
        }
        // A lost final ACK must not un-pair a paired run.
        return settled ?? flow.outcome ?? .timedOut
    }
}

/// One pairing run over an established Noise session with injected IO:
/// sealed sends go to `transmit`, accepted datagrams come in through
/// `handle`. Beacons are echoed; host video/audio is ignored.
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

    /// Ends the run with the typed 0x0A (`shuttingDown`) on the ordered
    /// stream, behind whatever the exchange still has in flight.
    public func sendTeardown(now: ClientTimestamp? = nil) throws {
        try reliable.send(
            SessionTeardown(reason: .shuttingDown).encode(),
            now: now ?? self.now())
    }

    /// Only CTRL matters: ARQ frames feed pairing, beacons are echoed.
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

    /// Virtual-time PTO beat.
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
    }

    public func startTimers() { reliable.start() }
    public func stopTimers() { reliable.stop() }

    /// The verdict, once the service reached one.
    public var outcome: LytePairing.Outcome? {
        lock.withLock { verdict }
    }

    /// The verdict once the host acknowledged it.
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

/// Locked box for late-binding construction.
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
