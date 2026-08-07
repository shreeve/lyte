// lyte-control-peer — DRM-free HostWire UDP peer for browser B-3…B-6.
//
// Speaks the real host Noise / pairing / capabilities / teardown path via
// HostWire.Session over plain UDP. Optional `--emit-corpus` replays the
// frozen Wire video-corpus-v1 prefix (frames 000–009) through the sealed
// video channel; with corpus it also emits a short sealed Opus tone for the
// browser AudioWorklet organ. Input echoes and an in-memory clipboard
// announce loop prove sealed CTRL features without Direct Eye / DRM /
// Wayland clipboard. Safe beside a standing lyte-host on 41151. Chrome
// reaches this peer through lyte-wt-sidecar --udp-peer. Does not touch
// ~/.config/lyte-host identity.

import Foundation
import HostAudio
import HostSession
import HostWire
import LyteCore
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
    var metaOut: String?
    var hostStaticHex: String?
    /// Directory with frame-000-idr.annexb … frame-009-p.annexb, or nil.
    var emitCorpusDir: String?
}

/// Emit pacing is slower than the 60 Hz score so the browser WT reader is
/// not starved by FEC bursts. Capture stamps follow wall time at emit
/// (not a synthetic 60 Hz ladder) so Conductor path delay stays honest.
// ~3 Conductor beats between frames — headroom for Chrome+WASM FEC drain.
let corpusEmitIntervalNS: UInt64 = 50_001_000
/// 5 ms Opus cadence (AudioWire.packetDuration).
let tonePacketIntervalNS: UInt64 = 5_000_000
/// ~240 ms of tone — enough for WebCodecs + AudioWorklet smoke.
let tonePacketCount = 48
let toneHz: Float = 440

func parseArgs(_ argv: [String]) throws -> Options {
    var opts = Options()
    var i = 0
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--listen":
            i += 1
            guard i < argv.count, let p = UInt16(argv[i]), p != 41151 else {
                throw PeerError.message("--listen needs a fresh 41xxx port (not 41151)")
            }
            opts.listenPort = p
        case "--bind":
            i += 1
            guard i < argv.count else { throw PeerError.message("--bind needs a host") }
            opts.bindHost = argv[i]
        case "--pin":
            i += 1
            guard i < argv.count else { throw PeerError.message("--pin needs digits") }
            opts.pin = argv[i]
        case "--seconds":
            i += 1
            guard i < argv.count, let s = Double(argv[i]) else {
                throw PeerError.message("--seconds needs a number")
            }
            opts.seconds = s
        case "--meta-out":
            i += 1
            guard i < argv.count else { throw PeerError.message("--meta-out needs a path") }
            opts.metaOut = argv[i]
        case "--host-static-hex":
            i += 1
            guard i < argv.count else {
                throw PeerError.message("--host-static-hex needs hex")
            }
            opts.hostStaticHex = argv[i]
        case "--emit-corpus":
            i += 1
            guard i < argv.count else {
                throw PeerError.message("--emit-corpus needs a directory")
            }
            opts.emitCorpusDir = argv[i]
        case "--help", "-h":
            print(
                """
                lyte-control-peer — DRM-free HostWire peer (browser B-3…B-6)

                  --listen P          UDP port (default 41234; never 41151)
                  --bind HOST         bind address (default 127.0.0.1)
                  --pin DIGITS        enable CPace pairing with this PIN
                  --seconds N         hold after establish (default 60)
                  --meta-out PATH     write JSON (port, host static, pin)
                  --emit-corpus DIR   after ready, seal/pace video-corpus-v1
                                      frames 000–009 + Opus tone (B-5/B-6;
                                      no DRM). Declares clipboardText;
                                      echoes input; in-memory clipboard ack.

                Safe beside standing lyte-host on 41151 — no Direct Eye / DRM.
                """
            )
            exit(0)
        default:
            throw PeerError.message("unknown argument: \(a)")
        }
        i += 1
    }
    return opts
}

func loadCorpusFrames(from directory: String) throws -> [[UInt8]] {
    let names = [
        "frame-000-idr.annexb",
        "frame-001-p.annexb",
        "frame-002-p.annexb",
        "frame-003-p.annexb",
        "frame-004-p.annexb",
        "frame-005-p.annexb",
        "frame-006-p.annexb",
        "frame-007-p.annexb",
        "frame-008-p.annexb",
        "frame-009-p.annexb",
    ]
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

func nowNS() -> UInt64 {
#if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
#else
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
#endif
}

func logPeer(_ message: String) {
    print(message)
    fflush(stdout)
}

final class UdpSocket: @unchecked Sendable {
    let fd: Int32
    let localHost: String
    let localPort: UInt16

    init(host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
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

func looksLikeHandshakeInitiation(_ datagram: [UInt8]) -> Bool {
    guard let (envelope, payload) = try? Envelope.decode(datagram),
          envelope.channel == .ctrl
    else { return false }
    return payload.first == CtrlMessageType.noiseHandshake1
        || payload.first == CtrlMessageType.retryHandshake1
}

func mintPin() -> String {
    String(format: "%06d", Int.random(in: 0...999_999))
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

final class ControlPeer {
    let sock: UdpSocket
    let hostStatic: NoiseKeyPair
    let pairing: PairingResponderService
    let pin: String
    let seconds: Double
    let corpusFrames: [[UInt8]]?

    var outbox: [VideoChannelDatagram] = []
    var session: Session?
    var peerHost: String?
    var peerPort: UInt16?
    var established = false
    var paired = false
    var capabilitiesAgreed = false
    var closed = false
    var corpusIndex = 0
    var corpusNextEmitNS: UInt64 = 0
    var corpusEmitFinished = false
    var toneIndex = 0
    var toneNextEmitNS: UInt64 = 0
    var toneEmitFinished = false
    var toneEncoder: HostOpusEncoder?
    var inputEventsEchoed = 0
    var clipboardSetsAcked = 0

    init(opts: Options) throws {
        if opts.listenPort == 41151 {
            throw PeerError.message("refusing standing host UDP 41151")
        }
        hostStatic = try loadHostStatic(hex: opts.hostStaticHex)
        pin = opts.pin ?? mintPin()
        pairing = PairingResponderService(
            pin: Array(pin.utf8),
            hostStaticPublicKey: hostStatic.publicKey
        )
        sock = try UdpSocket(host: opts.bindHost, port: opts.listenPort)
        seconds = opts.seconds
        if let dir = opts.emitCorpusDir {
            corpusFrames = try loadCorpusFrames(from: dir)
            toneEncoder = try HostOpusEncoder(bitrate: 96_000)
        } else {
            corpusFrames = nil
            toneEmitFinished = true
        }

        let shape = corpusFrames == nil
            ? "hostwire-control-only-udp"
            : "hostwire-control-plus-corpus-video-audio"
        print("lyte-control-peer — DRM-free HostWire peer (B-3…B-6)")
        print("listen: \(sock.localHost):\(sock.localPort)")
        print("noise: host static public key \(Hex.string(hostStatic.publicKey))")
        print("pairing: PIN \(pin) — enter it in the browser client")
        if let frames = corpusFrames {
            print(
                "corpus: will emit \(frames.count) sealed frames + "
                    + "\(tonePacketCount) Opus tone packets after ready "
                    + "(no Direct Eye)"
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

    var mediaReady: Bool {
        established && paired && capabilitiesAgreed
    }

    /// Pace one corpus frame when the video channel is idle. Called from
    /// the receive/pump loop with wall monotonic time.
    func maybeEmitCorpus(now: UInt64) {
        guard let frames = corpusFrames, let session, mediaReady,
              !corpusEmitFinished, !closed
        else { return }
        if corpusIndex >= frames.count {
            if session.isIdle {
                corpusEmitFinished = true
                print(
                    "corpus: emitted \(frames.count) frames "
                        + "(sealed Lyte-UDP video; not live Direct Eye)"
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
        guard corpusFrames != nil, let session, let encoder = toneEncoder,
              mediaReady, !toneEmitFinished, !closed
        else { return }
        if toneIndex >= tonePacketCount {
            toneEmitFinished = true
            print(
                "tone: emitted \(tonePacketCount) Opus packets "
                    + "(\(toneHz) Hz; sealed chan-1; not live host audio)"
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

    func flushOutbox() {
        guard let peerHost, let peerPort else { return }
        for datagram in outbox {
            let destHost = datagram.destination?.remoteAddress ?? peerHost
            let destPort = datagram.destination?.remotePort ?? peerPort
            sock.send(datagram.bytes, host: destHost, port: destPort)
        }
        outbox.removeAll(keepingCapacity: true)
    }

    func handleEvents(_ events: [SessionEvent], now: UInt64) {
        for event in events {
            switch event {
            case .handshakeCompleted(let remote):
                established = true
                print("noise: handshake completed — client static \(Hex.string(remote))")
                if let hash = session?.handshakeHash {
                    pairing.sessionEstablished(
                        clientStaticPublicKey: remote,
                        noiseHandshakeHash: hash
                    )
                }
            case .reliableCtrl(_, let message):
                if let output = pairing.handleReliableCtrl(message, now: now) {
                    for reply in output.replies {
                        do {
                            try session?.sendReliable(
                                reply, now: now, hostMicroseconds: now / 1_000
                            )
                        } catch {
                            print("pairing: reply send failed: \(error)")
                        }
                    }
                    for pe in output.events {
                        switch pe {
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
            case .capabilitiesAgreed(let caps):
                capabilitiesAgreed = true
                print(
                    "capabilities: agreed codecs=\(caps.videoCodecs) "
                        + "chroma=\(caps.chromaModes) maxDatagram=\(caps.maxDatagramBytes)"
                        + " clipboardText=\(caps.clipboardText)"
                )
            case .capabilitiesFailed(let why):
                print("capabilities: FAILED — \(why)")
            case .inputReceived(let event, let receivedAt):
                // No uinput / Direct Eye — report inject-at-receive so the
                // browser can close the sealed InputEcho loop honestly.
                session?.noteInputInjected(
                    seq: event.seq,
                    receivedAtMicroseconds: receivedAt,
                    injectedAtMicroseconds: receivedAt
                )
                inputEventsEchoed += 1
                if inputEventsEchoed <= 3 || inputEventsEchoed % 25 == 0 {
                    logPeer(
                        "input: echoed seq=\(event.seq) "
                            + "(total \(inputEventsEchoed); no OS inject)"
                    )
                }
            case .clipboardSetReceived(let text):
                // In-memory ack announce — not Wayland/GNOME host clipboard.
                // Distinct text avoids ClipboardSyncBook loop-echo suppress.
                let ack = "lyte-peer-ack:\(text.utf8.count)"
                if let session {
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
                }
                clipboardSetsAcked += 1
                logPeer(
                    "clipboard: set \(text.utf8.count) B → announce ack "
                        + "(in-memory; not OS clipboard)"
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

    func run() throws {
        let deadline = nowNS() + UInt64(seconds * 1e9)
        let handshakeDeadline = nowNS() + 30_000_000_000
        print("noise: awaiting client handshake…")

        while nowNS() < deadline && !closed {
            let now = nowNS()
            if let packet = sock.recv() {
                if session == nil {
                    guard looksLikeHandshakeInitiation(packet.bytes) else { continue }
                    peerHost = packet.host
                    peerPort = packet.port
                    let tuple = FourTuple(
                        localAddress: sock.localHost,
                        localPort: sock.localPort,
                        remoteAddress: packet.host,
                        remotePort: packet.port
                    )
                    // Corpus→WT needs a modest pace: 50 Mbps blasts the
                    // sidecar/Chrome datagram path and FEC-impossibles.
                    // Control-only keeps the native-like ceiling.
                    let pace = corpusFrames == nil ? 50_000_000 : 3_000_000
                    // Browser B-5 has no chan-3 feedback yet; the default
                    // 350 ms blackout freezes video after ~3 frames and
                    // suppresses the rest of the corpus. Widen silence
                    // for corpus emit only — production lyte-host untouched.
                    let lifecycle = corpusFrames == nil
                        ? SessionMachineConfig()
                        : SessionMachineConfig(
                            blackoutSilenceMicroseconds: 30_000_000,
                            recoveryBlackoutSilenceMicroseconds: 30_000_000
                        )
                    session = Session(
                        config: SessionConfig(
                            crypto: .noise(hostStatic: hostStatic),
                            rateBitsPerSecond: pace,
                            capabilities: .wireDefault.declaringClipboardText(),
                            lifecycle: lifecycle
                        ),
                        clientTuple: tuple,
                        now: now
                    ) { [weak self] datagram in
                        self?.outbox.append(datagram)
                    }
                    print("session: latched \(packet.host):\(packet.port)")
                }
                guard let session else { continue }
                let tuple = FourTuple(
                    localAddress: sock.localHost,
                    localPort: sock.localPort,
                    remoteAddress: packet.host,
                    remotePort: packet.port
                )
                let events = session.receive(
                    packet.bytes,
                    from: tuple,
                    now: now,
                    hostMicroseconds: now / 1_000
                )
                handleEvents(events, now: now)
                maybeEmitTone(now: now)
                maybeEmitCorpus(now: now)
                session.pump(now: now)
                flushOutbox()
                continue
            }

            if let session {
                let advanced = session.advance(
                    now: now, hostMicroseconds: now / 1_000
                )
                handleEvents(advanced, now: now)
                maybeEmitTone(now: now)
                maybeEmitCorpus(now: now)
                session.pump(now: now)
                flushOutbox()
            } else if now > handshakeDeadline {
                throw PeerError.message("no handshake within 30s")
            }

            usleep(2_000)
        }

        guard established && paired && capabilitiesAgreed else {
            throw PeerError.message(
                "incomplete (established=\(established) paired=\(paired) caps=\(capabilitiesAgreed))"
            )
        }
        if let frames = corpusFrames, !corpusEmitFinished {
            if closed {
                print(
                    "WARN — corpus emit incomplete after client close "
                        + "(index=\(corpusIndex)/\(frames.count))"
                )
            } else {
                throw PeerError.message(
                    "corpus emit incomplete (index=\(corpusIndex)/\(frames.count))"
                )
            }
        }
        if corpusFrames != nil, !toneEmitFinished, !closed {
            print(
                "WARN — tone emit incomplete "
                    + "(index=\(toneIndex)/\(tonePacketCount))"
            )
        }
        if corpusFrames != nil, corpusEmitFinished {
            print(
                "PASS — control + corpus video + tone "
                    + "(Noise + pair + capabilities + \(corpusIndex) frames "
                    + "+ \(toneIndex) Opus; inputEchoed=\(inputEventsEchoed) "
                    + "clipboardAcked=\(clipboardSetsAcked))"
            )
        } else if corpusFrames == nil {
            print("PASS — control-only session (Noise + pair + capabilities)")
        } else {
            print(
                "PASS — control session (corpus partial "
                    + "\(corpusIndex)/\(corpusFrames?.count ?? 0))"
            )
        }
        if let session, !closed {
            let now = nowNS()
            let events = session.beginTeardown(
                reason: .shuttingDown,
                now: now,
                hostMicroseconds: now / 1_000
            )
            handleEvents(events, now: now)
            session.pump(now: now)
            flushOutbox()
        }
    }
}

do {
    let opts = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    let peer = try ControlPeer(opts: opts)
    try peer.run()
    exit(0)
} catch {
    fputs("lyte-control-peer: \(error)\n", stderr)
    exit(1)
}
