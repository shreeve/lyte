// The receive-side UDP endpoint — CL-1's shell around ReceiveDemux. BSD
// sockets, matching the frozen GameStream stack whose craft this imports
// (Video/AudioStream lessons, kept, not the files): a large SO_RCVBUF so
// kernel drops never masquerade as network loss, SO_NET_SERVICE_TYPE VI to
// discourage Wi-Fi RX power-save, SO_TIMESTAMP kernel arrival stamps so
// gap measurements blame the radio rather than our own thread stalls, a
// 100 ms SO_RCVTIMEO so stop() unblocks the loop, and ECONNREFUSED
// tolerance. One receive thread runs decode + demux inline.
//
// CL-3 adds the return leg: the receive loop captures each datagram's
// source address, and `sendToPeer` fires client→host datagrams (feedback,
// beacon echoes, IDR requests) back at the most recent source from the
// same socket — so replies carry this endpoint's bound port as their
// source and land inside the host's connected-socket filter. Until the
// first datagram arrives there is no peer and sends report false; every
// CL-3 message is telemetry-class, superseded by its next cadence, so
// "no peer yet" is a counted non-event, not an error. IP_TOS is set
// best-effort (Mac senders benefit little; the Linux host is the end
// that cares — its own send path handles DSCP).

import Foundation
import LyteWire

public enum TransportEndpointError: Error, Sendable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case badAddress(String)
}

public final class UdpReceiveEndpoint: @unchecked Sendable {
    public let demux: ReceiveDemux

    private let requestedPort: UInt16
    private let bindAddress: String
    private let crypto: TransportCrypto
    /// Per-datagram hook, with the same arrival stamp the demux got
    /// (kernel SCM_TIMESTAMP wall-clock µs when available, monotonic µs
    /// otherwise). Consumers needing a monotonic instant (the beacon
    /// echo's t2) take their own stamp — the hook runs inline on the
    /// receive thread, so it is within microseconds of true arrival.
    private let onDatagram: (@Sendable (IngestOutcome, _ arrivalMicroseconds: UInt64) -> Void)?

    private var fd: Int32 = -1
    private var receiveThread: Thread?
    private let running = TransportAtomicFlag()

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

    /// Transport-open, then bind and start the receive thread. The crypto
    /// seam gates the socket: no datagram is read before `open()` succeeds.
    /// A handshaking crypto (Noise) inverts the first step — it needs the
    /// bound socket to run the IK exchange, so the endpoint binds first,
    /// drives `performHandshake` over the socket, and only then starts the
    /// receive thread (open() then merely asserts the transport exists).
    public func start() throws {
        let handshaking = crypto as? any HandshakingTransportCrypto
        if handshaking == nil {
            try crypto.open()
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TransportEndpointError.socketFailed(errno: errno) }
        self.fd = fd

        // Bursts must not drop in-kernel: room for ~1800 max-size datagrams.
        var rcvbuf: Int32 = 2 * 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        // Interactive-video service class (NET_SERVICE_TYPE_VI).
        var serviceType: Int32 = 3
        _ = setsockopt(fd, SOL_SOCKET, 0x1116 /* SO_NET_SERVICE_TYPE */,
                       &serviceType, socklen_t(MemoryLayout<Int32>.size))

        // Kernel arrival timestamps (SCM_TIMESTAMP cmsg on recvmsg).
        var tsOn: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &tsOn, socklen_t(MemoryLayout<Int32>.size))

        // 100 ms receive timeout so stop() can interrupt the loop.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Outbound TOS (DSCP CS5-ish), best-effort on Mac — the return
        // leg's datagrams are small and rare, but marked is still better.
        var tos: Int32 = 0xA0
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
            close(fd); self.fd = -1
            throw TransportEndpointError.badAddress(bindAddress)
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd); self.fd = -1
            throw TransportEndpointError.bindFailed(errno: e)
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

        if let handshaking {
            do {
                let io = try SocketHandshakeIO(
                    fd: fd,
                    host: handshaking.hostAddress,
                    port: handshaking.hostPort
                )
                try handshaking.performHandshake(io: io)
                // The host tuple is the peer from the first byte, so the
                // return leg (feedback ticks before any sealed host
                // datagram arrives) has somewhere to go.
                peerLock.lock()
                peerAddress = io.hostSockaddr
                peerLock.unlock()
            } catch {
                close(fd)
                self.fd = -1
                throw error
            }
            try crypto.open()
        }

        running.set(true)
        let recv = Thread { [weak self] in self?.receiveLoop() }
        recv.name = "lyte-wire-recv"
        recv.qualityOfService = .userInteractive
        recv.start()
        receiveThread = recv
    }

    public func stop() {
        running.set(false)
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    // MARK: - Receive thread

    private func receiveLoop() {
        // Datagrams over the 1152 B budget must be *seen* over-budget, not
        // silently truncated to it — read into a larger buffer and let
        // Envelope.decode reject the length.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var control = [UInt8](repeating: 0, count: 64)

        while running.get() {
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
                return   // socket closed by stop()
            }

            if sourceCaptured {
                peerLock.lock()
                peerAddress = source
                peerLock.unlock()
            }

            let arrivalUs = kernelUs ?? (DispatchTime.now().uptimeNanoseconds / 1000)
            let outcome = demux.ingest(datagram: buffer[0..<n],
                                       arrivalMicroseconds: arrivalUs)
            onDatagram?(outcome, arrivalUs)
        }
    }

    // MARK: - Send path (CL-3)

    /// Sends one encoded datagram back at the most recent datagram source,
    /// from the same socket (so the source port matches what the peer's
    /// connected socket filters for). Returns false when no peer is known
    /// yet, the socket is closed, or the kernel refused — all counted by
    /// the caller (TransportSender), none fatal for telemetry-class
    /// datagrams.
    @discardableResult
    public func sendToPeer(_ datagram: [UInt8]) -> Bool {
        peerLock.lock()
        guard var peer = peerAddress else {
            peerLock.unlock()
            return false
        }
        peerLock.unlock()
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
            guard getaddrinfo(host, nil, &hints, &result) == 0,
                  let info = result,
                  let sa = info.pointee.ai_addr else {
                throw TransportEndpointError.badAddress(host)
            }
            memcpy(
                &addr.sin_addr,
                UnsafeRawPointer(sa)
                    + MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!,
                MemoryLayout<in_addr>.size
            )
            freeaddrinfo(result)
        }
        hostSockaddr = addr
    }

    func sendToHost(_ datagram: [UInt8]) throws {
        var peer = hostSockaddr
        let sent = datagram.withUnsafeBufferPointer { buf -> Int in
            withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == datagram.count else {
            throw TransportEndpointError.socketFailed(errno: errno)
        }
    }

    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        var pollfds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&pollfds, 1, Int32(timeoutMilliseconds))
        guard ready > 0, pollfds[0].revents & Int16(POLLIN) != 0 else {
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
        return Array(buffer[0..<n])
    }
}

/// Tiny lock-protected boolean (thread interruption flag) — same shape the
/// frozen stack uses; duplicated because LyteTransport never imports LyteKit.
final class TransportAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
