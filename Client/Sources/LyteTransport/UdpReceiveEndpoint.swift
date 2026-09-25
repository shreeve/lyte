// The client's UDP socket: bind, the Noise handshake, one receive thread
// running decode + demux inline, and the send leg back to the host.
//
// Kernel monotonic arrival stamps let gap measurements blame the radio,
// not thread stalls. `sendToPeer` uses the same socket so replies pass
// the host's connected-socket filter; the peer is the handshake's host
// tuple, then the source of the latest authenticated datagram (roaming).
// Start is two steps (`bindAndHandshake`, `startReceiving`) so the owner
// can publish its datagram consumer in between.

import LyteCore
import LyteIO
import Foundation
import LyteWire
import Synchronization

public enum TransportEndpointError: Error, Sendable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case badAddress(String)
    /// A session-shell entry point was called before `start()`.
    case notStarted
    /// The owner stopped the endpoint (or its session) while it dialed.
    case cancelled
}

public final class UdpReceiveEndpoint: @unchecked Sendable {
    public let demux: ReceiveDemux

    private let requestedPort: UInt16
    private let bindAddress: String
    private let crypto: TransportCrypto
    /// Per-datagram hook with the demux's arrival stamp: SystemMonotonic
    /// µs (kernel stamp when present, else the thread's own reading).
    private let onDatagram: (@Sendable (IngestOutcome, _ arrivalMicroseconds: UInt64) -> Void)?

    /// Atomic because timer threads read it in `sendToPeer` while
    /// `stop()` closes it.
    private let socketFd = Atomic<Int32>(-1)
    internal var fd: Int32 { socketFd.load(ordering: .acquiring) }
    private var receiveThread: Thread?
    private let running = Atomic<Bool>(false)
    /// Set by `stop()`; a dial in flight ends within one handshake poll.
    private let cancelled = Atomic<Bool>(false)
    private let receiveExit = NSCondition()
    private var receiveExited = true

    /// Spans every `sendto` and the close, so no send outlives the fd.
    private let sendLock = NSLock()
    // The last datagram's source address — the peer replies go to.
    private let peerLock = NSLock()
    private var peerAddress: sockaddr_in?

    /// Arrivals stamped by the kernel rather than the fallback reading.
    let kernelStampedArrivals = Atomic<UInt64>(0)

    private let receiveTimeout: Duration

    /// The actual bound port — differs from the request when it was 0.
    public private(set) var boundPort: UInt16 = 0

    /// `receiveTimeout` bounds each blocking receive, and so how long
    /// `stop()` waits for the receive thread to notice.
    public init(
        port: UInt16,
        bindAddress: String = "0.0.0.0",
        crypto: TransportCrypto,
        receiveTimeout: Duration = .milliseconds(100),
        onDatagram: (@Sendable (IngestOutcome, _ arrivalMicroseconds: UInt64) -> Void)? = nil
    ) {
        self.receiveTimeout = receiveTimeout
        self.requestedPort = port
        self.bindAddress = bindAddress
        self.crypto = crypto
        self.demux = ReceiveDemux(crypto: crypto)
        self.onDatagram = onDatagram
    }

    public func start() throws {
        try bindAndHandshake()
        startReceiving()
    }

    /// Opens the transport and binds the socket; a handshaking crypto
    /// handshakes over the bound socket before opening. No datagram is
    /// read until `startReceiving()`. On failure the socket is closed.
    public func bindAndHandshake() throws {
        guard !cancelled.load(ordering: .acquiring) else {
            throw TransportEndpointError.cancelled
        }
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
        // A stop() that ran before the store found no fd to close; whichever
        // side takes it from `socketFd` closes it, exactly once.
        if cancelled.load(ordering: .acquiring) {
            let orphan = socketFd.exchange(-1, ordering: .acquiringAndReleasing)
            if orphan >= 0 { close(orphan) }
            throw TransportEndpointError.cancelled
        }
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

        // Kernel monotonic arrival stamps (SCM_TIMESTAMP_MONOTONIC cmsg).
        var tsOn: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &tsOn,
                       socklen_t(MemoryLayout<Int32>.size))

        // The receive timeout lets stop() interrupt the loop. A zero
        // SO_RCVTIMEO means "block forever", so it floors at 1 µs.
        let (seconds, attoseconds) = receiveTimeout.components
        let micros = max(1, seconds * 1_000_000 + attoseconds / 1_000_000_000_000)
        var tv = timeval(
            tv_sec: Int(micros / 1_000_000),
            tv_usec: Int32(micros % 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // The client never sends video: the protected CS6 lane.
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
                port: handshaking.hostPort,
                isCancelled: { [weak self] in
                    self?.cancelled.load(ordering: .acquiring) ?? true
                }
            )
            try handshaking.performHandshake(io: io)
            HandshakeWitness.record("noiseHandshakeCompleted")
            // The host tuple is the peer until an authenticated arrival.
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
        cancelled.store(true, ordering: .releasing)
        running.store(false, ordering: .releasing)
        // Join before close: closing first frees the fd number while
        // recvmsg is in flight, and a re-dial could reuse it. The receive
        // timeout bounds the join; 1 s is the wedge backstop.
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
        // Oversized datagrams must be seen, not truncated: Envelope.decode
        // rejects the length.
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
                            if r > 0, let base = ctrl.baseAddress {
                                kernelUs = Self.monotonicArrivalMicroseconds(
                                    control: UnsafeRawBufferPointer(
                                        start: base,
                                        count: Int(msg.msg_controllen)))
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

            if kernelUs != nil {
                kernelStampedArrivals.add(1, ordering: .relaxed)
            }
            let arrivalUs = kernelUs ?? SystemMonotonicClock.nowMicroseconds
            if PipelineWitness.isEnabled,
               let envelope = try? Envelope.decode(buffer[0..<n]).0,
               envelope.channel.rawValue == 2 {
                var fields = [
                    "frame": String(envelope.frame.rawValue),
                    "seq": String(envelope.seq.rawValue),
                    "shard": "", "dataShards": "", "parityShards": "",
                    "kernelArrivalMicroseconds": String(arrivalUs),
                    "hasKernelTimestamp": String(kernelUs != nil),
                    "receiveMonotonicNanoseconds":
                        String(SystemMonotonicClock.nowNanoseconds),
                ]
                if case .reedSolomon(let index, let geometry) =
                    try? FecField.decode(envelope.fec) {
                    fields["shard"] = String(index)
                    fields["dataShards"] = String(geometry.dataShards)
                    fields["parityShards"] = String(geometry.parityShards)
                }
                PipelineWitness.record("udpReceive", fields: fields)
            }
            let outcome = demux.ingest(datagram: buffer[0..<n],
                                       arrivalMicroseconds: arrivalUs)
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

    /// The arrival stamp from a single SCM_TIMESTAMP_MONOTONIC cmsg, as
    /// SystemMonotonicClock µs; nil when absent. The payload is a uint64
    /// of mach absolute-time ticks at data offset 12 (4-byte len, level,
    /// type; Darwin aligns cmsg data to 4 bytes, so the read is unaligned).
    static func monotonicArrivalMicroseconds(
        control: UnsafeRawBufferPointer
    ) -> UInt64? {
        guard control.count >= 12 + 8,
              control.loadUnaligned(fromByteOffset: 4, as: Int32.self)
                == SOL_SOCKET,
              control.loadUnaligned(fromByteOffset: 8, as: Int32.self)
                == SCM_TIMESTAMP_MONOTONIC
        else { return nil }
        let ticks = control.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
        return machTicksToNanoseconds(ticks) / 1_000
    }

    /// Mach absolute-time ticks → the nanoseconds DispatchTime's uptime
    /// (and so SystemMonotonicClock) reports.
    static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let (numer, denom) = machTimebase
        guard numer != denom else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        return UInt64(denom).dividingFullWidth(product).quotient
    }

    private static let machTimebase: (UInt32, UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    // MARK: - Send path

    /// Sends one datagram to the current peer. Returns false with no peer,
    /// a closed socket, or a kernel refusal; callers treat that as loss.
    /// Runs under `sendLock`, which `stop()` holds while closing, so a send
    /// never reaches a reused fd number.
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

/// Blocking datagram IO over the bound socket for the Noise handshake,
/// before the receive thread exists. Every send and each ≤100 ms receive
/// slice first checks `isCancelled`, so a stopped dial ends promptly.
final class SocketHandshakeIO: NoiseHandshakeIO {
    private let fd: Int32
    private let isCancelled: () -> Bool
    let hostSockaddr: sockaddr_in

    init(
        fd: Int32, host: String, port: UInt16,
        isCancelled: @escaping () -> Bool = { false }
    ) throws {
        self.fd = fd
        self.isCancelled = isCancelled
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
        guard !isCancelled() else { throw TransportEndpointError.cancelled }
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

    /// Takes the errno captured right after the syscall, so logging can
    /// never change the error that reaches recovery policy.
    static func validateSend(
        sent: Int, expected: Int, capturedErrno: Int32
    ) throws {
        guard sent == expected else {
            throw TransportEndpointError.socketFailed(errno: capturedErrno)
        }
    }

    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        guard !isCancelled() else { throw TransportEndpointError.cancelled }
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
            // Transient; the caller retries.
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
