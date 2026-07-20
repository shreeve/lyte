import Foundation

/// Drives the video UDP socket: SS_PING keepalives (which teach Sunshine our
/// RTP address — pings and receives MUST share one socket), the receive loop,
/// the FEC queue, and the depacketizer. Emits complete decode units.
///
/// Threading mirrors the reference: one ping thread, one receive thread that
/// runs the queue + depacketizer inline. Decode units are handed off via
/// `onDecodeUnit` on the receive thread — the consumer must not block.
public final class VideoStream: @unchecked Sendable {
    public enum Codec: Sendable { case h264, hevc }

    private let host: String
    private let port: UInt16
    private let pingPayload: Data
    private let packetSize: Int

    private let onDecodeUnit: @Sendable (DecodeUnit) -> Void
    private let onRequestIdr: @Sendable () -> Void
    private let onTerminate: @Sendable (String) -> Void

    private var fd: Int32 = -1
    private var pingThread: Thread?
    private var receiveThread: Thread?
    private let running = AtomicFlag()

    private let queue: RtpVideoQueue
    private let depacketizer: VideoDepacketizer

    // Stats (receive-thread written, main-thread read after stop)
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var framesDelivered: UInt64 = 0
    public var framesLost: UInt64 { queue.statsLostFrames }
    public var packetsRecovered: UInt64 { queue.statsRecoveredPackets }

    private static let firstTrafficTimeoutMs = 10_000
    private static let firstFrameTimeoutMs = 10_000

    public init(host: String, port: UInt16, pingPayload: Data, codec: Codec,
                packetSize: Int,
                onDecodeUnit: @escaping @Sendable (DecodeUnit) -> Void,
                onRequestIdr: @escaping @Sendable () -> Void,
                onTerminate: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.port = port
        self.pingPayload = pingPayload
        self.packetSize = packetSize
        self.onDecodeUnit = onDecodeUnit
        self.onRequestIdr = onRequestIdr
        self.onTerminate = onTerminate

        self.queue = RtpVideoQueue(packetSize: packetSize)
        self.depacketizer = VideoDepacketizer(codec: codec == .hevc ? .hevc : .h264)
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LyteError.host("video: socket() failed: \(errno)") }
        self.fd = fd

        // Big receive buffer: bursts of 2048 packets must not drop in-kernel
        var rcvbuf: Int32 = Int32(2048 * (packetSize + 16))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        // Interactive-video service class (NET_SERVICE_TYPE_VI): classifies
        // our TX (pings) and discourages RX power-save while the flow lives.
        var serviceType: Int32 = 3   // NET_SERVICE_TYPE_VI (sys/socket.h)
        _ = setsockopt(fd, SOL_SOCKET, 0x1116 /* SO_NET_SERVICE_TYPE */,
                       &serviceType, socklen_t(MemoryLayout<Int32>.size))

        // 100ms receive timeout so stop() and timeout checks can run
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd); self.fd = -1
            throw LyteError.host("video: bad IPv4 address \(host)")
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            close(fd); self.fd = -1
            throw LyteError.host("video: connect() failed: \(errno)")
        }

        queue.onFrameLost = { [depacketizer] frame, speculative in
            depacketizer.notifyFrameLost(frame, speculative: speculative)
        }
        depacketizer.onRequestIdr = { [onRequestIdr] in onRequestIdr() }
        depacketizer.onDecodeUnit = { [weak self] du in
            self?.framesDelivered += 1
            self?.onDecodeUnit(du)
        }

        running.set(true)

        let ping = Thread { [weak self] in self?.pingLoop() }
        ping.name = "lyte-video-ping"
        ping.qualityOfService = .userInteractive
        ping.start()
        pingThread = ping

        let recv = Thread { [weak self] in self?.receiveLoop() }
        recv.name = "lyte-video-recv"
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

    // MARK: - Threads

    private func pingLoop() {
        var sequence: UInt32 = 0
        var packet = [UInt8](pingPayload) + [0, 0, 0, 0]
        while running.get() {
            sequence &+= 1
            packet[16] = UInt8((sequence >> 24) & 0xff)
            packet[17] = UInt8((sequence >> 16) & 0xff)
            packet[18] = UInt8((sequence >> 8) & 0xff)
            packet[19] = UInt8(sequence & 0xff)
            _ = packet.withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress, buf.count, 0)
            }
            usleep(500_000)
        }
    }

    private func receiveLoop() {
        // Debug: LYTE_DROP_PCT=5 randomly drops 5% of received packets to
        // exercise FEC recovery and IDR-request recovery without real loss.
        let dropPercent = ProcessInfo.processInfo.environment["LYTE_DROP_PCT"].flatMap(Int.init) ?? 0

        // Debug: LYTE_GAP_SIM="15:45" discards ALL video packets from 15s
        // after the first frame for 45s — simulates a silent/idle host
        // (harsher than true idle: resume exposes a frame-index jump).
        let gapSim: (startUs: UInt64, endUs: UInt64)? = ProcessInfo.processInfo
            .environment["LYTE_GAP_SIM"].flatMap { spec in
                let parts = spec.split(separator: ":").compactMap { UInt64($0) }
                guard parts.count == 2 else { return nil }
                return (parts[0] * 1_000_000, (parts[0] + parts[1]) * 1_000_000)
            }
        var firstFrameAtNs: UInt64 = 0

        let receiveSize = packetSize + 16
        var buffer = [UInt8](repeating: 0, count: receiveSize + 64)
        var receivedAny = false
        var receivedFullFrame = false
        var waitingMs = 0
        var firstDataAt = DispatchTime.now()

        while running.get() {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n < 0 {
                // Pinging before the host binds its port bounces ICMP
                // port-unreachable back at our connected socket — transient.
                if errno == ECONNREFUSED { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !receivedAny {
                        waitingMs += 100
                        if waitingMs >= Self.firstTrafficTimeoutMs {
                            if running.get() { onTerminate("no video traffic from host (10s)") }
                            return
                        }
                    } else if !receivedFullFrame,
                              DispatchTime.now().uptimeNanoseconds - firstDataAt.uptimeNanoseconds
                                > UInt64(Self.firstFrameTimeoutMs) * 1_000_000 {
                        if running.get() { onTerminate("no complete video frame (10s)") }
                        return
                    }
                    continue
                }
                if running.get() { onTerminate("video recv failed: \(errno)") }
                return
            }
            guard n >= 12 + 16 else { continue }   // runt: smaller than RTP + NV header

            if !receivedAny {
                receivedAny = true
                firstDataAt = DispatchTime.now()
            } else if !receivedFullFrame,
                      DispatchTime.now().uptimeNanoseconds - firstDataAt.uptimeNanoseconds
                        > UInt64(Self.firstFrameTimeoutMs) * 1_000_000 {
                if running.get() { onTerminate("no complete video frame (10s)") }
                return
            }

            packetsReceived += 1
            if dropPercent > 0, Int.random(in: 0..<100) < dropPercent { continue }
            if let gapSim, firstFrameAtNs > 0 {
                let sinceFirstFrameUs = (DispatchTime.now().uptimeNanoseconds - firstFrameAtNs) / 1000
                if sinceFirstFrameUs >= gapSim.startUs && sinceFirstFrameUs < gapSim.endUs { continue }
            }
            let raw = Array(buffer[0..<n])
            let nowUs = DispatchTime.now().uptimeNanoseconds / 1000
            let (_, frame) = queue.addPacket(raw, receiveTimeUs: nowUs)
            if let frame {
                if !receivedFullFrame {
                    receivedFullFrame = true
                    firstFrameAtNs = DispatchTime.now().uptimeNanoseconds
                }
                for entry in frame {
                    depacketizer.processEntry(entry)
                }
            }
        }
    }
}

/// Tiny lock-protected boolean (Thread interruption flag).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
