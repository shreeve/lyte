// The receive-side UDP endpoint — CL-1's shell around ReceiveDemux. BSD
// sockets, matching the frozen GameStream stack whose craft this imports
// (Video/AudioStream lessons, kept, not the files): a large SO_RCVBUF so
// kernel drops never masquerade as network loss, SO_NET_SERVICE_TYPE VI to
// discourage Wi-Fi RX power-save, SO_TIMESTAMP kernel arrival stamps so
// gap measurements blame the radio rather than our own thread stalls, a
// 100 ms SO_RCVTIMEO so stop() unblocks the loop, and ECONNREFUSED
// tolerance. One receive thread runs decode + demux inline.

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
    private let onDatagram: (@Sendable (IngestOutcome) -> Void)?

    private var fd: Int32 = -1
    private var receiveThread: Thread?
    private let running = TransportAtomicFlag()

    /// The actual bound port — differs from the request when it was 0.
    public private(set) var boundPort: UInt16 = 0

    public init(
        port: UInt16,
        bindAddress: String = "0.0.0.0",
        crypto: TransportCrypto,
        onDatagram: (@Sendable (IngestOutcome) -> Void)? = nil
    ) {
        self.requestedPort = port
        self.bindAddress = bindAddress
        self.crypto = crypto
        self.demux = ReceiveDemux(crypto: crypto)
        self.onDatagram = onDatagram
    }

    /// Transport-open, then bind and start the receive thread. The crypto
    /// seam gates the socket: no datagram is read before `open()` succeeds.
    public func start() throws {
        try crypto.open()

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
            let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                control.withUnsafeMutableBufferPointer { ctrl -> Int in
                    var iov = iovec(iov_base: UnsafeMutableRawPointer(buf.baseAddress),
                                    iov_len: buf.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int in
                        var msg = msghdr()
                        msg.msg_iov = iovPtr
                        msg.msg_iovlen = 1
                        msg.msg_control = UnsafeMutableRawPointer(ctrl.baseAddress)
                        msg.msg_controllen = socklen_t(ctrl.count)
                        let r = recvmsg(fd, &msg, 0)
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
            if n < 0 {
                // ICMP port-unreachable bounced off a peer is transient.
                if errno == ECONNREFUSED { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return   // socket closed by stop()
            }

            let arrivalUs = kernelUs ?? (DispatchTime.now().uptimeNanoseconds / 1000)
            let outcome = demux.ingest(datagram: buffer[0..<n],
                                       arrivalMicroseconds: arrivalUs)
            onDatagram?(outcome)
        }
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
