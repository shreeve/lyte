// lyte-control-peer — DRM-free HostWire UDP peer for the browser client.
//
// Speaks the real host Noise / pairing / capabilities / teardown path via
// HostWire.Session over plain UDP. Optional `--emit-corpus` replays the
// frozen Wire video-corpus-v1 prefix (frames 000–009) through the sealed
// video channel; with corpus it also emits a short sealed Opus tone for the
// browser AudioWorklet organ. Input echoes and an in-memory clipboard
// announce loop prove sealed CTRL features without Direct Eye / DRM /
// Wayland clipboard. Safe beside a standing lyte-host on 41151. Chrome
// reaches this peer through lyte-wt-sidecar --udp-peer. Does not touch
// the host identity files.
//
// `--sessions N` serves N sessions in turn (0 = until killed), each with
// a fresh HostWire Session and pairing responder under the one PIN, so a
// page's Connect / Re-run can dial again without restarting the peer.

import Foundation
import HostAudio
import HostSession
import HostWire
import LyteCore
import LyteIO
import LyteWire

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum PeerError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
}

struct Options {
    var listenPort: UInt16 = 41234
    var bindHost = "127.0.0.1"
    var pin: String?
    var seconds: Double = 60
    /// Sessions to serve before exiting; 0 serves until killed.
    var sessions = 1
    var metaOut: String?
    var hostStaticHex: String?
    /// Directory with frame-000-idr.annexb … frame-009-p.annexb, or nil.
    var emitCorpusDir: String?
}

/// ~3 Conductor beats between frames: slower than 60 Hz so the browser's
/// WebTransport reader and WASM FEC drain are not starved by bursts.
/// Capture stamps follow wall time at emit so Conductor path delay stays
/// honest.
let corpusEmitIntervalNS: UInt64 = 50_001_000
/// 5 ms Opus cadence (AudioWire.packetDuration).
let tonePacketIntervalNS: UInt64 = 5_000_000
/// ~240 ms of tone — enough for WebCodecs + AudioWorklet smoke.
let tonePacketCount = 48
let toneHz: Float = 440

func parseArgs(_ argv: [String]) throws -> Options {
    var opts = Options()
    var rest = argv[...]
    /// The value after `flag` through `parse`, or a reason naming it.
    func value<T>(
        _ flag: String, _ want: String, _ parse: (String) -> T? = { $0 }
    ) throws -> T {
        guard let raw = rest.popFirst(), let value = parse(raw) else {
            throw PeerError.message("\(flag) needs \(want)")
        }
        return value
    }
    while let a = rest.popFirst() {
        switch a {
        case "--listen":
            opts.listenPort = try value(a, "a fresh 41xxx port (not 41151)") {
                UInt16($0).flatMap { $0 != 41151 ? $0 : nil }
            }
        case "--bind":
            opts.bindHost = try value(a, "a host")
        case "--pin":
            opts.pin = try value(a, "digits")
        case "--seconds":
            opts.seconds = try value(a, "a positive number") {
                Double($0).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            }
        case "--sessions":
            opts.sessions = try value(a, "a count (0 = unlimited)") {
                Int($0).flatMap { $0 >= 0 ? $0 : nil }
            }
        case "--meta-out":
            opts.metaOut = try value(a, "a path")
        case "--host-static-hex":
            opts.hostStaticHex = try value(a, "hex")
        case "--emit-corpus":
            opts.emitCorpusDir = try value(a, "a directory")
        case "--help", "-h":
            print(
                """
                lyte-control-peer — DRM-free HostWire peer for the browser proof

                  --listen P          UDP port (default 41234; never 41151)
                  --bind HOST         bind address (default 127.0.0.1)
                  --pin DIGITS        enable CPace pairing with this PIN
                  --seconds N         hold each session at most N s after
                                      its first datagram (default 60)
                  --sessions N        serve N sessions in turn, then exit
                                      (default 1; 0 = until killed). A
                                      single session must arrive within
                                      30 s; with more, the peer waits.
                  --meta-out PATH     write JSON (port, host static, pin)
                  --emit-corpus DIR   after ready, seal/pace video-corpus-v1
                                      frames 000–009 + Opus tone (no
                                      DRM). Declares clipboardText;
                                      echoes input; in-memory clipboard ack.

                Safe beside standing lyte-host on 41151 — no Direct Eye / DRM.
                """
            )
            exit(0)
        default:
            throw PeerError.message("unknown argument: \(a)")
        }
    }
    return opts
}

func loadCorpusFrames(from directory: String) throws -> [[UInt8]] {
    let names = (0..<10).map {
        "frame-00\($0)-\($0 == 0 ? "idr" : "p").annexb"
    }
    var frames: [[UInt8]] = []
    for name in names {
        let path = (directory as NSString).appendingPathComponent(name)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PeerError.message("missing corpus frame \(path)")
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw PeerError.message("empty corpus frame \(path)")
        }
        frames.append(Array(data))
    }
    guard AnnexBCheck.containsIrap(frames[0]) else {
        throw PeerError.message("frame-000 is not IRAP-shaped")
    }
    return frames
}

func logPeer(_ message: String) {
    print(message)
    fflush(nil)
}

final class UdpSocket: @unchecked Sendable {
    let fd: Int32
    let localHost: String
    let localPort: UInt16

    init(host: String, port: UInt16) throws {
        #if canImport(Darwin)
        let datagram = SOCK_DGRAM
        #else
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #endif
        let fd = socket(AF_INET, datagram, 0)
        guard fd >= 0 else { throw PeerError.message("socket() failed") }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            close(fd)
            throw PeerError.message("bad bind host \(host)")
        }
        let bindRc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRc == 0 else {
            close(fd)
            throw PeerError.message("bind \(host):\(port) failed errno=\(errno)")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        self.fd = fd
        self.localHost = host
        self.localPort = UInt16(bigEndian: bound.sin_port)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit { close(fd) }

    struct Packet {
        var bytes: [UInt8]
        var host: String
        var port: UInt16
    }

    func recv() -> Packet? {
        var buf = [UInt8](repeating: 0, count: 2048)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &len)
            }
        }
        guard n > 0 else { return nil }
        var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = addr.sin_addr
        inet_ntop(AF_INET, &addrCopy, &hostBuf, socklen_t(INET_ADDRSTRLEN))
        let host = hostBuf.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
        let port = UInt16(bigEndian: addr.sin_port)
        return Packet(bytes: Array(buf.prefix(Int(n))), host: host, port: port)
    }

    func send(_ bytes: [UInt8], host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd,
                        raw.baseAddress,
                        bytes.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }
}

func loadHostStatic(hex: String?) throws -> NoiseKeyPair {
    if let hex {
        guard let bytes = Hex.bytes(hex), bytes.count == 32 else {
            throw PeerError.message("--host-static-hex must be 32 bytes")
        }
        return try NoiseKeyPair(privateKey: bytes)
    }
    return NoiseKeyPair.generate()
}

func writeMeta(_ path: String, body: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
    )
    var out = data
    out.append(0x0A)
    try out.write(to: URL(fileURLWithPath: path))
}

/// The sealed datagrams a Session released since the last flush. A box so
/// the Session's send sink can hold it before the owning PeerSession is
/// fully initialized.
final class Outbox {
    var datagrams: [VideoChannelDatagram] = []
}

/// How one served session ended.
enum SessionVerdict {
    case pass(String)
    case fail(String)
}

/// One client's session: a HostWire Session answering an authenticated
/// message 1, a pairing responder and media emitters, bound to the client
/// that sent it (the Session's primary path).
final class PeerSession {
    let session: Session
    let pairing: PairingResponderService
    let sock: UdpSocket
    let corpusFrames: [[UInt8]]?
    let toneEncoder: HostOpusEncoder?
    let outbox = Outbox()

    var paired = false
    var capabilitiesAgreed = false
    var closed = false
    var corpusIndex = 0
    var corpusNextEmitNS: UInt64 = 0
    var corpusEmitFinished = false
    var toneIndex = 0
    var toneNextEmitNS: UInt64 = 0
    var toneEmitFinished = false
    var inputEventsEchoed = 0
    var clipboardSetsAcked = 0

    init(
        answering handshake: AuthenticatedHandshake,
        sock: UdpSocket,
        hostStatic: NoiseKeyPair,
        pin: String,
        corpusFrames: [[UInt8]]?,
        now: UInt64
    ) throws {
        self.sock = sock
        self.corpusFrames = corpusFrames
        pairing = PairingResponderService(
            pin: Array(pin.utf8),
            hostStaticPublicKey: hostStatic.publicKey
        )
        if corpusFrames != nil {
            toneEncoder = try HostOpusEncoder(bitrate: 96_000)
        } else {
            toneEncoder = nil
            toneEmitFinished = true
        }
        // Corpus→WT needs a modest pace: 50 Mbps blasts the
        // sidecar/Chrome datagram path and FEC-impossibles.
        // Control-only keeps the native-like ceiling.
        let pace = corpusFrames == nil ? 50_000_000 : 3_000_000
        // Corpus runs widen the blackout clocks so no silence freezes
        // video before every corpus frame has left.
        let lifecycle = corpusFrames == nil
            ? SessionMachineConfig()
            : SessionMachineConfig(
                blackoutSilenceMicroseconds: 30_000_000,
                recoveryBlackoutSilenceMicroseconds: 30_000_000
            )
        let outbox = self.outbox
        let opening: [SessionEvent]
        (session, opening) = try Session.answer(
            handshake,
            config: SessionConfig(
                rateBitsPerSecond: pace,
                capabilities: .wireDefault.declaringClipboardText(),
                lifecycle: lifecycle
            ),
            now: now,
            hostMicroseconds: now / 1_000,
            rng: SystemRandomNumberGenerator()
        ) { datagram in
            outbox.datagrams.append(datagram)
        }
        let client = handshake.clientTuple
        print("session: answered \(client.remoteAddress):\(client.remotePort)")
        handleEvents(opening, now: now)
        service(now: now)
    }

    var mediaReady: Bool {
        paired && capabilitiesAgreed
    }

    /// One inbound datagram, then the emitters and a flush.
    func receive(_ packet: UdpSocket.Packet, now: UInt64) {
        let tuple = FourTuple(
            localAddress: sock.localHost,
            localPort: sock.localPort,
            remoteAddress: packet.host,
            remotePort: packet.port
        )
        handleEvents(
            session.receive(
                packet.bytes, from: tuple,
                now: now, hostMicroseconds: now / 1_000
            ),
            now: now
        )
        service(now: now)
    }

    /// A timer pass with no datagram.
    func tick(now: UInt64) {
        handleEvents(
            session.advance(now: now, hostMicroseconds: now / 1_000),
            now: now
        )
        service(now: now)
    }

    private func service(now: UInt64) {
        maybeEmitTone(now: now)
        maybeEmitCorpus(now: now)
        session.pump(now: now)
        flushOutbox()
    }

    /// Pace one corpus frame when the video channel is idle.
    func maybeEmitCorpus(now: UInt64) {
        guard let frames = corpusFrames, mediaReady,
              !corpusEmitFinished, !closed
        else { return }
        if corpusIndex >= frames.count {
            if session.isIdle {
                corpusEmitFinished = true
                print(
                    """
                        corpus: emitted \(frames.count) frames \
                        (sealed Lyte-UDP video; not live Direct Eye)
                        """
                )
            }
            return
        }
        guard session.isIdle, now >= corpusNextEmitNS else { return }
        let i = corpusIndex
        let frame = frames[i]
        // Wall-aligned capture keeps mapped path delay ≈ seal+wire delay;
        // a synthetic 60 Hz ladder under slower emit would inflate delay
        // and mark later parts late (shouldPresent=false).
        let capture = now / 1_000
        do {
            _ = try session.ingestVideoFrame(
                frame,
                captureTimestampMicroseconds: capture,
                isKeyframe: AnnexBCheck.containsIrap(frame),
                now: now
            )
            corpusIndex = i + 1
            corpusNextEmitNS = now &+ corpusEmitIntervalNS
            logPeer("corpus: emitted frame \(i)/\(frames.count - 1)")
            if corpusIndex == frames.count {
                logPeer("corpus: last frame ingested — draining pacer…")
            }
        } catch {
            logPeer("corpus: ingest frame \(i) failed: \(error)")
        }
    }

    /// Pace sealed Opus tone packets (440 Hz sine) for the browser audio organ.
    func maybeEmitTone(now: UInt64) {
        guard let encoder = toneEncoder,
              mediaReady, !toneEmitFinished, !closed
        else { return }
        if toneIndex >= tonePacketCount {
            toneEmitFinished = true
            print(
                """
                    tone: emitted \(tonePacketCount) Opus packets \
                    (\(toneHz) Hz; sealed chan-1; not live host audio)
                    """
            )
            return
        }
        if toneNextEmitNS == 0 {
            toneNextEmitNS = now
        }
        guard now >= toneNextEmitNS else { return }
        var pcm = [Float](
            repeating: 0, count: HostOpus.samplesPerPacket
        )
        let baseSample = toneIndex * HostOpus.framesPerPacket
        for i in 0..<HostOpus.framesPerPacket {
            let t = Float(baseSample + i) / Float(HostOpus.sampleRate)
            let sample = 0.2 * sin(2 * Float.pi * toneHz * t)
            pcm[i * 2] = sample
            pcm[i * 2 + 1] = sample
        }
        var packet = [UInt8](repeating: 0, count: HostOpus.maxPacketBytes)
        do {
            let n = try pcm.withUnsafeBufferPointer {
                try encoder.encode($0, into: &packet)
            }
            packet.removeSubrange(n..<packet.count)
            let capture = now / 1_000
            _ = try session.ingestAudioPacket(
                packet, captureTimestampMicroseconds: capture, now: now
            )
            toneIndex += 1
            toneNextEmitNS = now &+ tonePacketIntervalNS
            if toneIndex == 1 || toneIndex == tonePacketCount {
                logPeer(
                    "tone: emitted packet \(toneIndex)/\(tonePacketCount)"
                )
            }
        } catch {
            logPeer("tone: encode/ingest failed: \(error)")
            toneEmitFinished = true
        }
    }

    /// Sends what the Session released: to the datagram's own
    /// destination when it names one (a path challenge), else to the
    /// primary path.
    func flushOutbox() {
        for datagram in outbox.datagrams {
            let tuple = datagram.destination ?? session.validator.primary.tuple
            sock.send(
                datagram.bytes, host: tuple.remoteAddress, port: tuple.remotePort
            )
        }
        outbox.datagrams.removeAll(keepingCapacity: true)
    }

    func logPairing(_ events: [PairingResponderService.Event]) {
        for event in events {
            switch event {
            case .paired(let key):
                paired = true
                print("pairing: PAIRED — client static \(Hex.string(key))")
            case .attemptOpened(let attempt, let of):
                print("pairing: attempt \(attempt)/\(of) — share B sent")
            case .rejected(let reason, let left):
                print("pairing: REJECTED (\(reason)) — \(left) left")
            case .clientAborted(let reason):
                print("pairing: client aborted (\(reason))")
            case .throttled:
                print("pairing: throttled")
            case .pinBurned:
                print("pairing: PIN BURNED")
            case .malformed:
                print("pairing: malformed")
            }
        }
    }

    func handleEvents(_ events: [SessionEvent], now: UInt64) {
        for event in events {
            switch event {
            case .handshakeCompleted(let remote):
                print("noise: handshake completed — client static \(Hex.string(remote))")
                if let hash = session.handshakeHash {
                    logPairing(pairing.sessionEstablished(
                        clientStaticPublicKey: remote,
                        noiseHandshakeHash: hash
                    ).events)
                }
            case .reliableCtrl(_, let message):
                if let output = pairing.handleReliableCtrl(message, now: now) {
                    for reply in output.replies {
                        do {
                            try session.sendReliable(
                                reply, now: now, hostMicroseconds: now / 1_000
                            )
                        } catch {
                            print("pairing: reply send failed: \(error)")
                        }
                    }
                    logPairing(output.events)
                }
            case .capabilitiesAgreed(let caps):
                capabilitiesAgreed = true
                print(
                    """
                        capabilities: agreed codecs=\(caps.videoCodecs) \
                        chroma=\(caps.chromaModes) maxDatagram=\(caps.maxDatagramBytes)\
                         clipboardText=\(caps.clipboardText)
                        """
                )
            case .capabilitiesFailed(let why):
                print("capabilities: FAILED — \(why)")
            case .inputReceived(let event, let receivedAt):
                // No uinput / Direct Eye — report inject-at-receive so the
                // browser can close the sealed InputEcho loop honestly.
                session.noteInputInjected(
                    seq: event.seq,
                    receivedAtMicroseconds: receivedAt,
                    injectedAtMicroseconds: receivedAt
                )
                inputEventsEchoed += 1
                if inputEventsEchoed <= 3 || inputEventsEchoed % 25 == 0 {
                    logPeer(
                        """
                            input: echoed seq=\(event.seq) \
                            (total \(inputEventsEchoed); no OS inject)
                            """
                    )
                }
            case .clipboardSetReceived(let text):
                // In-memory ack announce — not Wayland/GNOME host clipboard.
                // Distinct text avoids ClipboardSyncBook loop-echo suppress.
                let ack = "lyte-peer-ack:\(text.utf8.count)"
                for ev in session.noteHostClipboardChanged(
                    ack, now: now, hostMicroseconds: now / 1_000
                ) {
                    if case .clipboardAnnounceSent(let n) = ev {
                        logPeer("clipboard: announce sent (\(n) B)")
                    } else if case .clipboardAnnounceSuppressed(let why) = ev {
                        logPeer("clipboard: announce suppressed (\(why))")
                    } else if case .sendFailed(let why) = ev {
                        logPeer("clipboard: announce send failed: \(why)")
                    }
                }
                clipboardSetsAcked += 1
                logPeer(
                    """
                        clipboard: set \(text.utf8.count) B → announce ack \
                        (in-memory; not OS clipboard)
                        """
                )
            case .clipboardAnnounceSent(let byteCount):
                logPeer("clipboard: announce sent (\(byteCount) B)")
            case .teardownSent(let reason):
                print("teardown: sent \(reason)")
            case .sessionClosed(let reason):
                print("session: closed (\(reason))")
                closed = true
            case .lifecycleChanged(let state):
                if state == .closed { closed = true }
                print("lifecycle: \(state)")
            default:
                break
            }
        }
    }

    /// Judges the session and, unless the client already closed it,
    /// tears it down.
    func finish(now: UInt64) -> SessionVerdict {
        defer {
            if !closed {
                handleEvents(
                    session.beginTeardown(
                        reason: .shuttingDown,
                        now: now,
                        hostMicroseconds: now / 1_000
                    ),
                    now: now
                )
                session.pump(now: now)
                flushOutbox()
            }
        }
        guard paired && capabilitiesAgreed else {
            return .fail("""
                incomplete (paired=\(paired) caps=\(capabilitiesAgreed))
                """)
        }
        if let frames = corpusFrames, !corpusEmitFinished {
            guard closed else {
                return .fail(
                    "corpus emit incomplete (index=\(corpusIndex)/\(frames.count))"
                )
            }
            print(
                """
                    WARN — corpus emit incomplete after client close \
                    (index=\(corpusIndex)/\(frames.count))
                    """
            )
        }
        if corpusFrames != nil, !toneEmitFinished, !closed {
            print(
                """
                    WARN — tone emit incomplete \
                    (index=\(toneIndex)/\(tonePacketCount))
                    """
            )
        }
        guard let frames = corpusFrames else {
            return .pass("PASS — control-only session (Noise + pair + capabilities)")
        }
        guard corpusEmitFinished else {
            return .pass(
                "PASS — control session (corpus partial \(corpusIndex)/\(frames.count))"
            )
        }
        return .pass(
            """
                PASS — control + corpus video + tone \
                (Noise + pair + capabilities + \(corpusIndex) frames \
                + \(toneIndex) Opus; inputEchoed=\(inputEventsEchoed) \
                clipboardAcked=\(clipboardSetsAcked))
                """
        )
    }
}

final class ControlPeer {
    let sock: UdpSocket
    let hostStatic: NoiseKeyPair
    let pin: String
    let seconds: Double
    let sessions: Int
    let corpusFrames: [[UInt8]]?

    init(opts: Options) throws {
        hostStatic = try loadHostStatic(hex: opts.hostStaticHex)
        var rng = SystemRandomNumberGenerator()
        pin = opts.pin ?? PairingResponderService.mintPin(using: &rng)
        sock = try UdpSocket(host: opts.bindHost, port: opts.listenPort)
        seconds = opts.seconds
        sessions = opts.sessions
        corpusFrames = try opts.emitCorpusDir.map(loadCorpusFrames(from:))

        let shape = corpusFrames == nil
            ? "hostwire-control-only-udp"
            : "hostwire-control-plus-corpus-video-audio"
        print("lyte-control-peer — DRM-free HostWire peer for the browser proof")
        print("listen: \(sock.localHost):\(sock.localPort)")
        print("noise: host static public key \(Hex.string(hostStatic.publicKey))")
        print("pairing: PIN \(pin) — enter it in the browser client")
        print("sessions: \(sessions == 0 ? "until killed" : "\(sessions)")")
        if let frames = corpusFrames {
            print(
                """
                    corpus: will emit \(frames.count) sealed frames + \
                    \(tonePacketCount) Opus tone packets after ready \
                    (no Direct Eye)
                    """
            )
        }
        print("features: input echo + in-memory clipboardText (not Wayland OS)")
        print("note: no Direct Eye; safe beside standing UDP 41151")

        if let metaOut = opts.metaOut {
            var body: [String: Any] = [
                "adapter": "lyte-control-peer",
                "bindHost": sock.localHost,
                "listenPort": Int(sock.localPort),
                "hostStaticPublicKeyHex": Hex.string(hostStatic.publicKey),
                "pin": pin,
                "seconds": opts.seconds,
                "sessions": opts.sessions,
                "shape": shape,
                "clipboardText": true,
            ]
            if let frames = corpusFrames {
                body["corpusFrameCount"] = frames.count
                body["emitCorpus"] = true
                body["tonePacketCount"] = tonePacketCount
            }
            try writeMeta(metaOut, body: body)
        }
    }

    /// Serves sessions one at a time. A session ends when the client
    /// closes it, when its answer goes unconfirmed past the client's
    /// retransmit span, or `seconds` after the answer; then the peer
    /// waits for the next message 1. A single-session run must see its
    /// handshake within 30 s and fails the process when the session
    /// fails; a multi-session run logs a failed session and keeps serving.
    func run() throws {
        let start = SystemMonotonicClock.nowNanoseconds
        let handshakeDeadline: UInt64? =
            sessions == 1 ? start + 30_000_000_000 : nil
        var acceptor = HandshakeAcceptor(
            config: HandshakeAcceptor.Config(hostStatic: hostStatic))
        var current: PeerSession?
        var sessionDeadline: UInt64 = 0
        var served = 0
        var failed = 0
        print("noise: awaiting client handshake…")

        while true {
            let now = SystemMonotonicClock.nowNanoseconds
            if let peer = current,
               peer.closed || now >= sessionDeadline
                || peer.session.isUnconfirmedAnswerAbandoned(now: now) {
                current = nil
                served += 1
                switch peer.finish(now: now) {
                case .pass(let line):
                    print(line)
                case .fail(let why):
                    guard sessions != 1 else { throw PeerError.message(why) }
                    failed += 1
                    print("FAIL — session \(served): \(why)")
                }
                // A run the session carried can never confirm now.
                peer.logPairing(peer.pairing.sessionEnded().events)
                if peer.pairing.isBurned {
                    throw PeerError.message(
                        "PIN burned — restart the peer for a fresh PIN"
                    )
                }
                if sessions != 0 && served >= sessions {
                    if failed > 0 {
                        throw PeerError.message(
                            "\(failed) of \(served) sessions failed"
                        )
                    }
                    return
                }
                print("noise: awaiting client handshake… (session \(served + 1))")
                continue
            }

            if let packet = sock.recv() {
                if let peer = current {
                    peer.receive(packet, now: now)
                    continue
                }
                let tuple = FourTuple(
                    localAddress: sock.localHost, localPort: sock.localPort,
                    remoteAddress: packet.host, remotePort: packet.port)
                guard case .authenticated(let handshake) = acceptor.accept(
                    packet.bytes[...], from: tuple, now: now
                ).verdict else { continue }
                current = try PeerSession(
                    answering: handshake,
                    sock: sock,
                    hostStatic: hostStatic,
                    pin: pin,
                    corpusFrames: corpusFrames,
                    now: now
                )
                sessionDeadline = now + UInt64(seconds * 1e9)
                continue
            }

            if let peer = current {
                peer.tick(now: now)
            } else if served == 0, let handshakeDeadline,
                      now > handshakeDeadline {
                throw PeerError.message("no handshake within 30s")
            }
            usleep(2_000)
        }
    }
}

do {
    let opts = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    let peer = try ControlPeer(opts: opts)
    try peer.run()
    exit(0)
} catch {
    FileHandle.standardError.write(Data("lyte-control-peer: \(error)\n".utf8))
    exit(1)
}
