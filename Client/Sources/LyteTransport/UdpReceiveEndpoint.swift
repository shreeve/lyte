// The client's UDP socket: bind, the Noise handshake, one receive thread
// running decode + demux inline, and the send leg back to the host.
//
// Socket posture: a 2 MiB SO_RCVBUF so kernel drops never masquerade as
// network loss; SO_NET_SERVICE_TYPE VI to discourage Wi-Fi RX power-save;
// SO_TIMESTAMP kernel arrival stamps so gap measurements blame the radio
// rather than thread stalls; a 100 ms SO_RCVTIMEO so stop() unblocks the
// loop; ECONNREFUSED tolerance; and the protected CS6 lane (0xC0), since
// everything the client originates is control, input or feedback.
//
// The return leg: `sendToPeer` fires client→host datagrams (feedback,
// beacon echoes, IDR requests and reliable ARQ carriage) from the same
// socket, so replies carry the bound port and land inside the host's
// connected-socket filter. The peer is the handshake's host tuple, then
// the source of the latest authenticated datagram (roaming). Without a
// peer, sends report false; every sender treats that as loss.
//
// Start is two steps so the owner can publish its datagram consumer
// between them: `bindAndHandshake` (no thread reads yet — the host's
// first datagrams wait in the kernel buffer) and `startReceiving`.

import LyteCore
import LyteIO
import Foundation
import LyteWire
import Synchronization

public enum TransportEndpointError: Error, Sendable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case badAddress(String)
    /// A session-shell entry point was called before `start()` built
    /// the core (CL-9's sendInput is the first such surface).
    case notStarted
}

public final class UdpReceiveEndpoint: @unchecked Sendable {
    public let demux: ReceiveDemux

    private let requestedPort: UInt16
    private let bindAddress: String
    private let crypto: TransportCrypto
    /// Per-datagram hook, with the same arrival stamp the demux got
    /// (kernel SCM_TIMESTAMP wall-clock µs when available, monotonic µs
    /// otherwise) — a MIXED clock domain, never safe in monotonic math
    /// like RTT (A-25). Consumers needing a monotonic instant (the
    /// beacon echo's t2) take their own stamp — the hook runs inline on
    /// the receive thread, so it is within microseconds of true arrival.
    private let onDatagram: (@Sendable (IngestOutcome, _ arrivalMicroseconds: UInt64) -> Void)?

    /// Atomic because timer threads (ARQ PTO, feedback) read it in
    /// `sendToPeer` while `stop()` closes it. Internal so the stop-order
    /// pin can observe that the fd survives until the receive thread is
    /// joined.
    private let socketFd = Atomic<Int32>(-1)
    internal var fd: Int32 { socketFd.load(ordering: .acquiring) }
    private var receiveThread: Thread?
    private let running = Atomic<Bool>(false)
    private let receiveExit = NSCondition()
    private var receiveExited = true

    /// Spans every `sendto` and the close, so no send outlives the fd.
    private let sendLock = NSLock()
    // The last datagram's source address — the peer replies go to.
    private let peerLock = NSLock()
    private var peerAddress: sockaddr_in?

    /// The actual bound port — differs from the request when it was 0.
    public private(set) var boundPort: UInt16 = 0

    public init(
        port: UInt16,
        bindAddress: String = "0.0.0.0",
        crypto: TransportCrypto,
        onDatagram: (@Sendable (IngestOutcome, _ arrivalMicroseconds: UInt64) -> Void)? = nil
    ) {
        self.requestedPort = port
        self.bindAddress = bindAddress
        self.crypto = crypto
        self.demux = ReceiveDemux(crypto: crypto)
        self.onDatagram = onDatagram
    }

    /// `bindAndHandshake()` then `startReceiving()`, for owners that
    /// have nothing to publish in between.
    public func start() throws {
        try bindAndHandshake()
        startReceiving()
    }

    /// Opens the transport and binds the socket. A handshaking crypto
    /// (Noise) needs the bound socket for the IK exchange, so it binds
    /// first, handshakes over the socket, then opens; any other crypto
    /// opens before the socket exists. No datagram is read until
    /// `startReceiving()`: the peer's first datagrams wait in the kernel
    /// buffer while the owner publishes the consumer `onDatagram` feeds.
    /// On failure the socket is closed.
    public func bindAndHandshake() throws {
        let handshaking = crypto as? any HandshakingTransportCrypto
        if handshaking == nil {
            try crypto.open()
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TransportEndpointError.socketFailed(errno: errno) }
        HandshakeWitness.record("socketCreated", fields: ["fd": String(fd)])
        do {
            try configureAndBind(fd, handshaking: handshaking)
            if let handshaking {
                try handshake(fd, crypto: handshaking)
                try crypto.open()
            }
        } catch {
            close(fd)
            throw error
        }
        socketFd.store(fd, ordering: .releasing)
    }

    /// Starts the receive thread on the bound socket.
    public func startReceiving() {
        running.store(true, ordering: .releasing)
        receiveExit.lock()
        receiveExited = false
        receiveExit.unlock()
        let recv = Thread { [weak self] in self?.receiveLoop() }
        recv.name = "lyte-wire-recv"
        recv.qualityOfService = .userInteractive
        recv.start()
        receiveThread = recv
    }

    private func configureAndBind(
        _ fd: Int32, handshaking: (any HandshakingTransportCrypto)?
    ) throws {
        // Bursts must not drop in-kernel: room for ~1800 max-size datagrams.
        var rcvbuf: Int32 = 2 * 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        // Interactive-video service class (NET_SERVICE_TYPE_VI).
        var serviceType: Int32 = NET_SERVICE_TYPE_VI
        _ = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                       &serviceType, socklen_t(MemoryLayout<Int32>.size))

        // Kernel arrival timestamps (SCM_TIMESTAMP cmsg on recvmsg).
        var tsOn: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &tsOn, socklen_t(MemoryLayout<Int32>.size))

        // 100 ms receive timeout so stop() can interrupt the loop.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // The client sends control/input/feedback, never fresh video:
        // the protected CS6 lane, not the video queue.
        var tos = Int32(WireTos.protected)
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
            throw TransportEndpointError.badAddress(bindAddress)
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            throw TransportEndpointError.bindFailed(errno: errno)
        }

        // Learn the kernel-assigned port when the request was 0 (tests).
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        boundPort = UInt16(bigEndian: bound.sin_port)
        HandshakeWitness.record("socketBound", fields: [
            "bindAddress": bindAddress,
            "localPort": String(boundPort),
            "targetHost": handshaking?.hostAddress ?? "",
            "targetPort": String(handshaking?.hostPort ?? 0),
            "tos": String(tos),
        ])
    }

    private func handshake(
        _ fd: Int32, crypto handshaking: any HandshakingTransportCrypto
    ) throws {
        do {
            HandshakeWitness.record("noiseHandshakeBegin")
            let io = try SocketHandshakeIO(
                fd: fd,
                host: handshaking.hostAddress,
                port: handshaking.hostPort
            )
            try handshaking.performHandshake(io: io)
            HandshakeWitness.record("noiseHandshakeCompleted")
            // The host tuple is the peer from the first byte, so the
            // return leg (feedback ticks before any sealed host datagram
            // arrives) has somewhere to go.
            peerLock.lock()
            peerAddress = io.hostSockaddr
            peerLock.unlock()
        } catch {
            HandshakeWitness.record("noiseHandshakeFailed", fields: [
                "error": String(describing: error),
            ])
            throw error
        }
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        // Join BEFORE close (analysis finding 12's residue): the receive
        // thread may be inside recvmsg on this fd, and closing first
        // frees the fd number while that syscall is in flight — a
        // roaming re-dial can then bind a fresh socket onto the same
        // number and the old loop steals its datagrams. The 100 ms
        // SO_RCVTIMEO bounds the join; the 1 s deadline is the wedge
        // backstop, after which close() proceeds as the forcing move.
        if Thread.current !== receiveThread {
            receiveExit.lock()
            let deadline = Date(timeIntervalSinceNow: 1)
            while !receiveExited, receiveExit.wait(until: deadline) {}
            receiveExit.unlock()
            receiveThread = nil
        }
        sendLock.lock()
        let closing = socketFd.exchange(-1, ordering: .acquiringAndReleasing)
        if closing >= 0 {
            close(closing)
        }
        sendLock.unlock()
    }

    // MARK: - Receive thread

    private func receiveLoop() {
        defer {
            receiveExit.lock()
            receiveExited = true
            receiveExit.broadcast()
            receiveExit.unlock()
        }
        // Datagrams over the 1152 B budget must be *seen* over-budget, not
        // silently truncated to it — read into a larger buffer and let
        // Envelope.decode reject the length.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var control = [UInt8](repeating: 0, count: 64)
        // stop() joins this thread before closing, so the fd is stable
        // for the loop's lifetime.
        let fd = self.fd

        while running.load(ordering: .acquiring) {
            var kernelUs: UInt64? = nil
            var source = sockaddr_in()
            var sourceCaptured = false
            let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                control.withUnsafeMutableBufferPointer { ctrl -> Int in
                    var iov = iovec(iov_base: UnsafeMutableRawPointer(buf.baseAddress),
                                    iov_len: buf.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int in
                        withUnsafeMutablePointer(to: &source) { srcPtr -> Int in
                            var msg = msghdr()
                            msg.msg_name = UnsafeMutableRawPointer(srcPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = UnsafeMutableRawPointer(ctrl.baseAddress)
                            msg.msg_controllen = socklen_t(ctrl.count)
                            let r = recvmsg(fd, &msg, 0)
                            if r > 0, msg.msg_namelen >= socklen_t(MemoryLayout<sockaddr_in>.size),
                               srcPtr.pointee.sin_family == sa_family_t(AF_INET) {
                                sourceCaptured = true
                            }
                            // Single SCM_TIMESTAMP cmsg: timeval at data offset
                            // 12 (4-byte len + 4-byte level + 4-byte type).
                            if r > 0, msg.msg_controllen >= 12 + 16,
                               let base = ctrl.baseAddress {
                                let level = base.withMemoryRebound(to: Int32.self, capacity: 3) { ($0[1], $0[2]) }
                                if level.0 == SOL_SOCKET, level.1 == SCM_TIMESTAMP {
                                    var tv = timeval()
                                    memcpy(&tv, base + 12, MemoryLayout<timeval>.size)
                                    kernelUs = UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)
                                }
                            }
                            return r
                        }
                    }
                }
            }
            if n < 0 {
                // ICMP port-unreachable bounced off a peer is transient.
                if errno == ECONNREFUSED { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if errno == EINTR { continue }
                return   // socket closed by stop()
            }

            let arrivalUs = kernelUs ?? (SystemMonotonicClock.nowMicroseconds)
            let receivedAtNS = SystemMonotonicClock.nowNanoseconds
            let witnessEnvelope = PipelineWitness.isEnabled
                ? (try? Envelope.decode(buffer[0..<n]).0) : nil
            if let envelope = witnessEnvelope, envelope.channel.rawValue == 2 {
                let fec = try? FecField.decode(envelope.fec)
                let shard: String
                let dataShards: String
                let parityShards: String
                if case .reedSolomon(let index, let geometry) = fec {
                    shard = String(index)
                    dataShards = String(geometry.dataShards)
                    parityShards = String(geometry.parityShards)
                } else {
                    shard = ""
                    dataShards = ""
                    parityShards = ""
                }
                PipelineWitness.record("udpReceive", fields: [
                    "frame": String(envelope.frame.rawValue),
                    "seq": String(envelope.seq.rawValue),
                    "shard": shard,
                    "dataShards": dataShards,
                    "parityShards": parityShards,
                    "kernelArrivalMicroseconds": String(arrivalUs),
                    "hasKernelTimestamp": String(kernelUs != nil),
                    "receiveMonotonicNanoseconds": String(receivedAtNS),
                ])
            }
            let outcome = demux.ingest(datagram: buffer[0..<n],
                                       arrivalMicroseconds: arrivalUs)
            if let envelope = witnessEnvelope, envelope.channel.rawValue == 2 {
                let outcomeName: String
                switch outcome {
                case .accepted: outcomeName = "accepted"
                case .reservedChannel: outcomeName = "reservedChannel"
                case .malformed: outcomeName = "malformed"
                case .unsealFailed: outcomeName = "unsealFailed"
                }
                PipelineWitness.record("udpIngestCompleted", fields: [
                    "frame": String(envelope.frame.rawValue),
                    "seq": String(envelope.seq.rawValue),
                    "outcome": outcomeName,
                ])
            }
            // Roaming retarget is authenticated-only: an arbitrary UDP
            // packet must never redirect our sealed return traffic.
            if sourceCaptured, case .accepted = outcome {
                peerLock.lock()
                peerAddress = source
                peerLock.unlock()
            }
            onDatagram?(outcome, arrivalUs)
        }
    }

    // MARK: - Send path (CL-3)

    /// Sends one encoded datagram back at the current peer, from the same
    /// socket (so the source port matches what the peer's connected
    /// socket filters for). Returns false when no peer is known yet, the
    /// socket is closed, or the kernel refused — each counted by the
    /// caller and healed like loss (reliable carriage retransmits).
    ///
    /// The send runs under `sendLock`, which `stop()` also holds while it
    /// closes, so a timer thread's send can never reach an fd number a
    /// later socket has reused.
    @discardableResult
    public func sendToPeer(_ datagram: [UInt8]) -> Bool {
        peerLock.lock()
        let peerSnapshot = peerAddress
        peerLock.unlock()
        guard var peer = peerSnapshot else { return false }
        sendLock.lock()
        defer { sendLock.unlock() }
        let fd = self.fd
        guard fd >= 0 else { return false }

        let sent = datagram.withUnsafeBufferPointer { buf -> Int in
            withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == datagram.count
    }

    /// True once at least one datagram has arrived (a reply address exists).
    public var hasPeer: Bool {
        peerLock.lock()
        defer { peerLock.unlock() }
        return peerAddress != nil
    }
}

/// Blocking datagram IO over the endpoint's bound socket for the
/// pre-thread Noise handshake window: sends aim at the resolved host
/// tuple, receives poll() with the caller's timeout. Single-threaded by
/// construction (the receive thread does not exist yet).
final class SocketHandshakeIO: NoiseHandshakeIO {
    private let fd: Int32
    let hostSockaddr: sockaddr_in

    init(fd: Int32, host: String, port: UInt16) throws {
        self.fd = fd
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0 else {
                throw TransportEndpointError.badAddress(host)
            }
            defer { freeaddrinfo(result) }
            guard let sa = result?.pointee.ai_addr else {
                throw TransportEndpointError.badAddress(host)
            }
            memcpy(
                &addr.sin_addr,
                UnsafeRawPointer(sa)
                    + MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!,
                MemoryLayout<in_addr>.size
            )
        }
        hostSockaddr = addr
    }

    func sendToHost(_ datagram: [UInt8]) throws {
        var peer = hostSockaddr
        let started = SystemMonotonicClock.nowNanoseconds
        let sent = datagram.withUnsafeBufferPointer { buf -> Int in
            withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let sendErrno = sent == datagram.count ? 0 : errno
        HandshakeWitness.record("handshakeSend", fields: [
            "bytes": String(datagram.count),
            "sent": String(sent),
            "errno": String(sendErrno),
            "localPort": String(localPort()),
            "remoteAddress": String(cString: inet_ntoa(peer.sin_addr)),
            "remotePort": String(UInt16(bigEndian: peer.sin_port)),
            "durationNanoseconds": String(
                SystemMonotonicClock.nowNanoseconds &- started),
        ])
        try Self.validateSend(
            sent: sent, expected: datagram.count,
            capturedErrno: sendErrno)
    }

    /// `errno` belongs to the failing syscall, not to later diagnostics.
    /// Keep this seam executable so logging can never silently change the
    /// transport error that reaches recovery policy.
    static func validateSend(
        sent: Int, expected: Int, capturedErrno: Int32
    ) throws {
        guard sent == expected else {
            throw TransportEndpointError.socketFailed(errno: capturedErrno)
        }
    }

    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        var pollfds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&pollfds, 1, Int32(timeoutMilliseconds))
        guard ready > 0, pollfds[0].revents & Int16(POLLIN) != 0 else {
            if ready < 0 {
                HandshakeWitness.record("handshakePollError", fields: [
                    "errno": String(errno),
                ])
            }
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { buf in
            recv(fd, buf.baseAddress, buf.count, 0)
        }
        guard n > 0 else {
            // ECONNREFUSED bounced off the host between sends is
            // transient; timeouts and empties are the caller's retry.
            return nil
        }
        HandshakeWitness.record("handshakeReceive", fields: [
            "bytes": String(n),
            "localPort": String(localPort()),
        ])
        return Array(buffer[0..<n])
    }

    private func localPort() -> UInt16 {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        return rc == 0 ? UInt16(bigEndian: local.sin_port) : 0
    }
}
