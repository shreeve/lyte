import ArgumentParser
import Foundation
import LyteTransport
import LyteWire

/// The H0b debug harness's first breath (CL-1): bind a Lyte-UDP receive
/// endpoint, decode envelopes, and print per-channel running stats. Grows
/// video assembly at CL-2 and feedback at CL-3; today it counts datagrams.
struct WireListen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-listen",
        abstract: "Listen for Lyte-UDP datagrams and print per-channel envelope stats.")

    @Argument(help: "UDP port to bind (0 picks a free port)") var port: UInt16
    @Option(name: .long, help: "Address to bind") var bind: String = "0.0.0.0"
    @Flag(name: .long, help: "CP-3 recorded fallback: accept payloads with NO crypto")
    var insecure = false
    @Option(name: .long, help: "Noise mode: the host's static public key, 64 hex digits")
    var hostKey: String?
    @Option(name: .long, help: "Noise mode: the host's address")
    var host: String = "10.0.0.249"
    @Option(name: .long, help: "Noise mode: the host's --wire-listen port (default: the bind port)")
    var hostPort: UInt16 = 0
    @Option(name: .long, help: "Auto-exit after this many seconds (default: until Ctrl-C)")
    var duration: Int = 0

    func validate() throws {
        if insecure, hostKey != nil {
            throw ValidationError("--insecure and --host-key are mutually exclusive")
        }
        if !insecure, hostKey == nil {
            throw ValidationError(
                "Noise mode needs --host-key <64-hex host static>, or pass --insecure for the recorded CP-3 fallback")
        }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped

        let crypto: any TransportCrypto
        if insecure {
            crypto = InsecureTransportCrypto()
        } else {
            crypto = try NoiseTransportCrypto(
                hostAddress: host,
                hostPort: hostPort == 0 ? port : hostPort,
                hostStaticPublicKey: NoiseTransportCrypto.parseKeyHex(hostKey!))
        }
        let endpoint = UdpReceiveEndpoint(port: port, bindAddress: bind, crypto: crypto)
        do {
            try endpoint.start()
        } catch let error as TransportCryptoError {
            switch error {
            case .invalidHostKey(let message), .handshakeFailed(let message):
                throw ValidationError("Noise: \(message)")
            case .unsealFailed(let message):
                throw ValidationError(message)
            }
        }
        print("wire-listen: bound \(bind):\(endpoint.boundPort) — \(crypto.modeDescription)")
        if insecure {
            print("wire-listen: *** INSECURE MODE — payloads are neither encrypted nor authenticated ***")
        }

        let printer = WireStatsPrinter(demux: endpoint.demux)

        // ~1 Hz running stats off the main queue.
        let ticker = DispatchSource.makeTimerSource(queue: .global())
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler { printer.printTick() }
        ticker.resume()

        let finish: @Sendable () -> Void = {
            ticker.cancel()
            endpoint.stop()
            printer.printFinal()
            Foundation.exit(0)
        }

        // Ctrl-C prints the final summary instead of dying mid-line.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler(handler: finish)
        sigint.resume()

        if duration > 0 {
            try await Task.sleep(for: .seconds(duration))
            finish()
        } else {
            try await Task.sleep(for: .seconds(86_400 * 365))
        }
        withExtendedLifetime((ticker, sigint, endpoint)) {}
    }
}

/// Formats demux snapshots; only prints a tick when something new arrived.
private final class WireStatsPrinter: Sendable {
    private let demux: ReceiveDemux
    private let lastCount = LockedBox<UInt64>(0)

    init(demux: ReceiveDemux) {
        self.demux = demux
    }

    func printTick() {
        let totals = demux.snapshotTotals()
        guard totals.datagrams != lastCount.value else { return }
        lastCount.value = totals.datagrams
        printSnapshot(prefix: "…", totals: totals)
    }

    func printFinal() {
        print("wire-listen: final")
        printSnapshot(prefix: "  ", totals: demux.snapshotTotals())
    }

    private func printSnapshot(prefix: String, totals: DemuxTotals) {
        var line = "\(prefix) total \(totals.datagrams) datagrams: \(totals.accepted) ok"
        if totals.malformed > 0 { line += ", \(totals.malformed) malformed" }
        if totals.reservedDropped > 0 { line += ", \(totals.reservedDropped) reserved-dropped" }
        if totals.unsealFailures > 0 { line += ", \(totals.unsealFailures) unseal-failed" }
        print(line)
        for (channel, stats) in demux.snapshotChannels() {
            print("\(prefix)   \(Self.channelLabel(channel)): \(Self.describe(stats))")
        }
    }

    private static func channelLabel(_ channel: UInt8) -> String {
        let name: String
        switch channel {
        case 0: name = "ctrl"
        case 1: name = "audio"
        case 2: name = "video-active"
        case 3: name = "feedback"
        case 4: name = "video-idle"
        case 5...7: name = "reserved"
        default: name = "feature"
        }
        return "chan \(channel) (\(name))"
    }

    private static func describe(_ s: ChannelStats) -> String {
        var parts = ["\(s.datagrams) dg", "\(s.payloadBytes) B"]
        if let high = s.seqHighest {
            parts.append(String(format: "seq→0x%04x", high))
        }
        parts.append("\(s.seqMissing) missing")
        if s.seqLateFilled > 0 { parts.append("\(s.seqLateFilled) late-filled") }
        if s.seqDuplicates > 0 { parts.append("\(s.seqDuplicates) dup") }
        if s.seqWrapEvents > 0 { parts.append("\(s.seqWrapEvents) wraps") }
        if s.seqBeyondWindow > 0 { parts.append("\(s.seqBeyondWindow) beyond-window") }
        if let first = s.firstFrame, let max = s.maxFrame {
            parts.append("frames \(first)–\(max) (\(s.frameTransitions + 1) seen)")
        }
        if let dt = s.lastTimestampDeltaMicros {
            parts.append(String(format: "tsΔ %.1fms", Double(dt) / 1000))
        }
        if let da = s.lastArrivalDeltaMicros {
            parts.append(String(format: "rxΔ %.1fms", Double(da) / 1000))
        }
        if s.unsealFailures > 0 { parts.append("\(s.unsealFailures) unseal-failed") }
        return parts.joined(separator: ", ")
    }
}

/// Lock-boxed value for cross-queue state (the CLI's Locked<T> sibling,
/// local so this file only needs Foundation).
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
