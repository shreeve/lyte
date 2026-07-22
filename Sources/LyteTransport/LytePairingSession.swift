// LytePairingSession (CL-6): the whole client pairing flow as one
// blocking call — the shell around PairingInitiatorService that the CLI
// (`wire-pair`) and the app's pairing sheet both drive. Assembles the
// exact production stack the probe modeled and CL-7 landed:
//
//   Noise IK (NoiseTransportCrypto, PERSISTENT client static)
//     → UdpReceiveEndpoint (bind, handshake, receive thread)
//     → ReliableCtrlEndpoint (the ARQ carriage — pairing messages ride
//       the sealed ordered CTRL stream, exactly-once, in order)
//     → PairingInitiatorService (share A → share B/Tb → confirm)
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

        // ── The stack (WireViewCommand's construction order: the
        // endpoint's datagram hook late-binds the reliable endpoint). ──
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

        let clientNow: @Sendable () -> ClientTimestamp = {
            ClientTimestamp(
                microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
        }
        let reliableBox = PairingLockedBox<ReliableCtrlEndpoint?>(nil)
        let echoBox = PairingLockedBox<BeaconEchoResponder?>(nil)

        let endpoint = UdpReceiveEndpoint(
            port: 0, crypto: crypto,
            onDatagram: { outcome, _ in
                guard case .accepted(let envelope, let payload) = outcome,
                      envelope.channel == .ctrl
                else { return }   // video/audio from a streaming host: ignored
                if reliableBox.value?.handleCtrlDatagram(
                    envelope: envelope, payload: payload) == true {
                    return
                }
                echoBox.value?.handleCtrlPayload(
                    payload, arrivalMicroseconds: clientNow().microseconds)
            })

        progress("Noise IK handshake → "
            + "\(config.hostAddress):\(config.hostPort) …")
        do {
            try endpoint.start()
        } catch let error as TransportCryptoError {
            return .failed("handshake failed: \(error)")
        } catch {
            return .failed("bind/handshake failed: \(error)")
        }
        defer { endpoint.stop() }
        if let ms = crypto.handshakeMillisecondsSnapshot {
            progress(String(format: "handshake complete in %.1f ms", ms))
        }

        let sender = TransportSender(crypto: crypto, transmit: { datagram in
            endpoint.sendToPeer(datagram)
        })
        let echoResponder = BeaconEchoResponder(
            now: clientNow,
            emit: { echo in
                _ = try? sender.send(channel: .ctrl, timestamp: clientNow(),
                                     plaintext: echo.encode())
            })
        echoBox.value = echoResponder

        // ── The pairing machine, bound to THIS session's transcript. ──
        guard let handshakeHash = crypto.handshakeHashSnapshot else {
            return .failed("no handshake hash after handshake")   // unreachable
        }
        let service: PairingInitiatorService
        do {
            service = try PairingInitiatorService(
                pin: Array(config.pin.utf8),
                clientStaticPublicKey: crypto.clientStaticPublicKey,
                hostStaticPublicKey: config.hostStaticPublicKey,
                noiseHandshakeHash: handshakeHash)
        } catch {
            return .failed("pairing init: \(error)")
        }

        let verdict = PairingLockedBox<Outcome?>(nil)
        let reliable = ReliableCtrlEndpoint(
            sender: sender,
            onEvent: { event in
                guard case .message(_, let bytes) = event,
                      let output = service.handleReliableCtrl(bytes)
                else { return }
                for reply in output.replies {
                    do { try reliableBox.value?.send(reply) }
                    catch {
                        progress("reliable reply refused: \(error)")
                    }
                }
                for event in output.events {
                    switch event {
                    case .paired(let key):
                        progress("host tag verified — confirm sent")
                        verdict.value = .paired(hostStaticPublicKey: key)
                    case .pinMismatch:
                        progress("host tag MISMATCH — wrong PIN; "
                            + "aborting with the typed reject")
                        verdict.value = .pinMismatch
                    case .invalidShare:
                        progress("host share invalid — aborting")
                        verdict.value = .invalidShare
                    case .hostRejected(let reason):
                        progress("host rejected the run (\(reason))")
                        verdict.value = .hostRejected(reason)
                    case .malformed:
                        progress("malformed pairing bytes dropped")
                    }
                }
            })
        reliable.start()
        defer { reliable.stop() }
        reliableBox.value = reliable

        do {
            try reliable.send(service.start())
            progress("share A sent (PIN bound to this session)")
        } catch {
            return .failed("share A send: \(error)")
        }

        // ── Wait for the verdict; honesty needs quiescence (the confirm
        // or reject really reached the host and was acknowledged). ──
        let deadline = DispatchTime.now()
            + .milliseconds(Int(config.timeoutSeconds * 1000))
        while DispatchTime.now() < deadline {
            if let outcome = verdict.value, reliable.isQuiescent {
                return outcome
            }
            usleep(50_000)
        }
        // Deadline with a verdict in hand but ACKs outstanding: report
        // the verdict anyway — the ARQ retransmitted for the whole
        // window, and a lost final ACK must not un-pair a paired run.
        if let outcome = verdict.value { return outcome }
        return .timedOut
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
