// lyte-control-peer — DRM-free HostWire UDP peer for browser B-3.
//
// Speaks the real host Noise / pairing / capabilities / teardown path via
// HostWire.Session over plain UDP. No Direct Eye, no PipeWire, no DRM —
// safe beside a standing lyte-host on 41151. Chrome reaches this peer through
// lyte-wt-sidecar --udp-peer. Does not touch ~/.config/lyte-host identity.

import Foundation
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
}

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
        case "--help", "-h":
            print(
                """
                lyte-control-peer — DRM-free HostWire control peer (browser B-3)

                  --listen P          UDP port (default 41234; never 41151)
                  --bind HOST         bind address (default 127.0.0.1)
                  --pin DIGITS        enable CPace pairing with this PIN
                  --seconds N         hold after establish (default 60)
                  --meta-out PATH     write JSON (port, host static, pin)

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

func nowNS() -> UInt64 {
#if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
#else
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
#endif
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

    var outbox: [VideoChannelDatagram] = []
    var session: Session?
    var peerHost: String?
    var peerPort: UInt16?
    var established = false
    var paired = false
    var capabilitiesAgreed = false
    var closed = false

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

        print("lyte-control-peer — DRM-free HostWire control peer (B-3)")
        print("listen: \(sock.localHost):\(sock.localPort)")
        print("noise: host static public key \(Hex.string(hostStatic.publicKey))")
        print("pairing: PIN \(pin) — enter it in the browser client")
        print("note: no Direct Eye; safe beside standing UDP 41151")

        if let metaOut = opts.metaOut {
            try writeMeta(metaOut, body: [
                "adapter": "lyte-control-peer",
                "bindHost": sock.localHost,
                "listenPort": Int(sock.localPort),
                "hostStaticPublicKeyHex": Hex.string(hostStatic.publicKey),
                "pin": pin,
                "seconds": opts.seconds,
                "shape": "hostwire-control-only-udp",
            ])
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
                )
            case .capabilitiesFailed(let why):
                print("capabilities: FAILED — \(why)")
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
                    session = Session(
                        config: SessionConfig(
                            crypto: .noise(hostStatic: hostStatic),
                            rateBitsPerSecond: 50_000_000,
                            capabilities: .wireDefault
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
                session.pump(now: now)
                flushOutbox()
                continue
            }

            if let session {
                let advanced = session.advance(
                    now: now, hostMicroseconds: now / 1_000
                )
                handleEvents(advanced, now: now)
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
        print("PASS — control-only session (Noise + pair + capabilities)")
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
