import Foundation
import CommonCrypto

/// Drives the audio UDP socket: SS_PING keepalives (pings and receives MUST
/// share one socket — Sunshine learns our RTP address from the pings), the
/// receive loop, the FEC queue, AES-CBC decrypt, Opus decode, and playback.
///
/// Mirrors AudioStream.c: ping starts pre-PLAY (created in onPortsKnown),
/// the first ~500 ms of audio is dropped (host buffer flush), and missing
/// packets run loss concealment (silence here; libopus PLC in M7).
public final class AudioStream: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let pingPayload: Data
    private let riKey: Data
    private let riKeyId: UInt32              // host byte order (== rikeyid sent at launch)
    private var encrypted = true             // final value passed to start()
    private let packetDurationMs: Int
    private let channels: Int

    private var fd: Int32 = -1
    private var pingThread: Thread?
    private var receiveThread: Thread?
    private let running = AtomicFlag()

    private let queue: RtpAudioQueue
    private let decoder: OpusDecoder
    private let player: AudioPlayer

    // Stats (receive-thread written)
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var framesDecoded: UInt64 = 0
    public private(set) var decryptFailures: UInt64 = 0
    /// Arrival-jitter probe: audio packets arrive every ~5 ms on a healthy
    /// path; a reception gap is the radio's fault regardless of buffering.
    /// This is the objective AWDL/contention signal (doctor probe #1).
    public private(set) var gapsOver20ms: UInt64 = 0
    public private(set) var gapsOver50ms: UInt64 = 0
    public private(set) var maxGapMs: Int = 0
    private var lastArrivalUs: UInt64 = 0
    public var packetsRecovered: UInt64 { queue.packetsRecovered }
    public var packetsLost: UInt64 { queue.packetsLost }
    public var underruns: UInt64 { player.underruns }
    public var queuedMs: Int { player.queuedMs }
    public var peak: Float { player.lastPeak }

    public init?(host: String, port: UInt16, pingPayload: Data,
                 riKey: Data, riKeyId: Int32,
                 packetDurationMs: Int = 5, channels: Int = 2) {
        self.host = host
        self.port = port
        self.pingPayload = pingPayload
        self.riKey = riKey
        self.riKeyId = UInt32(bitPattern: riKeyId)
        self.packetDurationMs = packetDurationMs
        self.channels = channels
        self.queue = RtpAudioQueue(packetDurationMs: packetDurationMs)
        guard let decoder = OpusDecoder(channels: channels,
                                        samplesPerFrame: 48 * packetDurationMs) else { return nil }
        self.decoder = decoder
        self.player = AudioPlayer(channels: channels)
    }

    /// Bind + start pinging. Must run before RTSP PLAY (host requirement).
    public func startPinging() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LyteError.host("audio: socket() failed: \(errno)") }
        self.fd = fd

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Voice service class (NET_SERVICE_TYPE_VO): an actively-transmitting
        // VO flow (our 500 ms pings) signals the Wi-Fi driver to curb RX
        // power-save dozing — the supported lever against gaps-without-loss.
        var serviceType: Int32 = 4   // NET_SERVICE_TYPE_VO (sys/socket.h)
        _ = setsockopt(fd, SOL_SOCKET, 0x1116 /* SO_NET_SERVICE_TYPE */,
                       &serviceType, socklen_t(MemoryLayout<Int32>.size))

        // Bursts deliver 4-20 packets at once after a radio stall; never let
        // the kernel turn jitter into loss.
        var rcvbuf: Int32 = 512 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd); self.fd = -1
            throw LyteError.host("audio: bad IPv4 address \(host)")
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            close(fd); self.fd = -1
            throw LyteError.host("audio: connect() failed: \(errno)")
        }

        running.set(true)
        let ping = Thread { [weak self] in self?.pingLoop() }
        ping.name = "lyte-audio-ping"
        ping.qualityOfService = .userInteractive
        ping.start()
        pingThread = ping
    }

    /// Start playback + the receive/decode loop. Call after PLAY, when the
    /// negotiated encryption state is known (SSEnc.audio bit from ANNOUNCE).
    public func start(encrypted: Bool) throws {
        self.encrypted = encrypted
        try player.start()
        let recv = Thread { [weak self] in self?.receiveLoop() }
        recv.name = "lyte-audio-recv"
        recv.qualityOfService = .userInteractive
        recv.start()
        receiveThread = recv
    }

    public func setMuted(_ muted: Bool) {
        player.setMuted(muted)
    }

    public func stop() {
        running.set(false)
        player.stop()
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
        // Debug: LYTE_DROP_PCT randomly drops received packets to exercise
        // audio FEC + loss concealment (same env hook as VideoStream).
        let dropPercent = ProcessInfo.processInfo.environment["LYTE_DROP_PCT"].flatMap(Int.init) ?? 0

        var buffer = [UInt8](repeating: 0, count: 1400)
        var packetsToDrop = 500 / packetDurationMs    // flush host's queued backlog
        var receivedAny = false

        while running.get() {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n < 0 {
                if errno == ECONNREFUSED { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if receivedAny { packetsToDrop = 0 }   // host queue is empty; no backlog
                    continue
                }
                return   // socket closed by stop()
            }
            guard n >= RtpAudioQueue.rtpHeaderSize else { continue }
            receivedAny = true
            packetsReceived += 1

            let nowUs = DispatchTime.now().uptimeNanoseconds / 1000
            if lastArrivalUs > 0 {
                let gapMs = Int((nowUs - lastArrivalUs) / 1000)
                if gapMs > 20 { gapsOver20ms += 1 }
                if gapMs > 50 { gapsOver50ms += 1 }
                if gapMs > maxGapMs { maxGapMs = gapMs }
            }
            lastArrivalUs = nowUs

            let packet = Data(buffer[0..<n])
            if packetsToDrop > 0 {
                if packet[1] == 97 { packetsToDrop -= 1 }
                continue
            }
            if dropPercent > 0, Int.random(in: 0..<100) < dropPercent { continue }

            switch queue.addPacket(packet) {
            case .handleNow:
                decodeAndPlay(packet)
            case .packetReady:
                while let (queued, isPlaceholder) = queue.getQueuedPacket() {
                    if isPlaceholder {
                        player.enqueue(decoder.decode(nil))   // loss concealment
                    } else if let queued {
                        decodeAndPlay(queued)
                    }
                }
            case .consumed:
                break
            }
        }
    }

    private func decodeAndPlay(_ packet: Data) {
        let payload = packet.dropFirst(RtpAudioQueue.rtpHeaderSize)
        let opus: Data?
        if encrypted {
            let seq = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
            opus = decrypt(payload: Data(payload), rtpSequence: seq)
            if opus == nil { decryptFailures += 1 }
        } else {
            opus = Data(payload)
        }
        player.enqueue(decoder.decode(opus))
        framesDecoded += 1
    }

    /// AES-128-CBC, PKCS7; IV = BE32(riKeyId + rtpSeq) zero-padded to 16.
    private func decrypt(payload: Data, rtpSequence: UInt16) -> Data? {
        var iv = [UInt8](repeating: 0, count: 16)
        let ivSeq = riKeyId &+ UInt32(rtpSequence)
        iv[0] = UInt8((ivSeq >> 24) & 0xff)
        iv[1] = UInt8((ivSeq >> 16) & 0xff)
        iv[2] = UInt8((ivSeq >> 8) & 0xff)
        iv[3] = UInt8(ivSeq & 0xff)

        var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = payload.withUnsafeBytes { input in
            riKey.withUnsafeBytes { key in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, kCCKeySizeAES128, &iv,
                        input.baseAddress, payload.count,
                        &output, output.count, &outLength)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(output[0..<outLength])
    }
}
