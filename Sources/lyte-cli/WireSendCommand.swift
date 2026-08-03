import LyteIO
import ArgumentParser
import Foundation
import LyteTransport
import LyteWire

/// CL-2's loopback test rig and tomorrow's J-G1 sanity tool: read corpus
/// access units (Wire/Vectors/video-corpus-v1 layout), packetize through
/// the real VideoPacketizer, and send the shards over UDP at a paced
/// frame rate — with an optional seeded drop rate so the receive side's
/// FEC recovery can be exercised without a lossy network. Insecure
/// framing only (the crypto seam is W5's; re-gate when it lands).
///
/// CL-3 makes it the two-sided host stand-in (the host box is down; this is the
/// smoke's far end until J-G1): it RECEIVES on its connected socket and
/// logs the client's return traffic — chan=3 feedback reports (ledgers,
/// dispersion sample counts), beacon echoes (computing offset/RTT with a
/// locally measured t4, exactly what HS-16/CL-10 will consume), and IDR
/// requests. It also emits the 1 Hz CTRL ClockBeacon (HS-7's job) so the
/// client's echo path has something to answer, and it HEALS on an IDR
/// request by resending the corpus IDR frame — the §4.7 heal path,
/// demonstrated end to end on loopback.
struct WireSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-send",
        abstract: "DEBUG: packetize corpus frames and send them as Lyte-UDP video (loopback rig + host stand-in for wire-view).")

    @Argument(help: "Destination host (IP or name)") var host: String
    @Argument(help: "Destination UDP port") var port: UInt16

    @Option(name: .long, help: "Corpus directory (video-corpus-v1 layout: frame-*.annexb)")
    var corpus: String = "Wire/Vectors/video-corpus-v1"
    @Option(name: .long, help: "Frames per second") var fps: Int = 30
    @Option(name: .long, help: "Use only the first N corpus files, sorted (default: the decodable 10-frame prefix)")
    var frames: Int = 10
    @Option(name: .long, help: "Seeded per-datagram drop probability, 0…1 (simulated loss)")
    var drop: Double = 0
    @Option(name: .long, help: "Drop-simulation RNG seed") var seed: UInt64 = 2
    @Option(name: .long, help: "Loop the corpus this many times (0 = until Ctrl-C)")
    var loops: Int = 0
    @Option(name: .long, help: "FEC regime: clean or lossy") var regime: String = "clean"

    func validate() throws {
        guard (0.0...1.0).contains(drop) else {
            throw ValidationError("--drop must be within 0…1")
        }
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        guard FecRegime(rawValue: regime) != nil else {
            throw ValidationError("--regime must be clean or lossy")
        }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fecRegime = FecRegime(rawValue: regime)!

        // Sorted corpus files: frame-000-idr … frame-009-p sort ahead of
        // the frame-10x packetization fixtures, so the default N=10 is
        // exactly the decodable prefix (IDR first).
        let names = try FileManager.default.contentsOfDirectory(atPath: corpus)
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".annexb") }
            .sorted()
            .prefix(frames)
        guard !names.isEmpty else {
            throw ValidationError("no frame-*.annexb files in \(corpus)")
        }
        let accessUnits: [[UInt8]] = try names.map {
            [UInt8](try Data(contentsOf: URL(fileURLWithPath: corpus + "/" + $0)))
        }
        print("wire-send: \(accessUnits.count) access units from \(corpus) → " +
              "\(host):\(port) at \(fps) fps, drop \(String(format: "%.1f%%", drop * 100)) " +
              "(seed \(seed)), regime \(fecRegime.rawValue)")
        print("wire-send: *** INSECURE framing — no crypto until W5 ***")

        let sender = try UdpSender(host: host, port: port)
        defer { sender.close() }

        // CL-3: the host stand-in half — receive/log the client's return
        // traffic on the same connected socket, and beacon at 1 Hz.
        let standIn = HostStandIn(fd: sender.fileDescriptor)
        standIn.start()
        defer { standIn.stop() }

        var packetizer = VideoPacketizer()
        var rng = SendSplitMix64(seed: seed)
        var frameNumber = FrameNumber(rawValue: 0)
        var sentShards = 0, droppedShards = 0, sentFrames = 0, healFrames = 0
        let interval = Duration.seconds(1) / fps

        var stop = false
        signal(SIGINT, SIG_IGN)
        let stopFlag = LockedCell(false)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { stopFlag.value = true }
        sigint.resume()
        defer { sigint.cancel() }

        var loop = 0
        while !stop, loops == 0 || loop < loops {
            loop += 1
            for annexB in accessUnits {
                if stopFlag.value { stop = true; break }

                // The §4.7 heal path: an IDR request from the client is
                // answered with the corpus IDR at the next frame slot,
                // exempt from simulated drop (the real host paces a
                // forced IDR urgently; re-dropping the heal would make
                // the smoke a coin flip).
                if standIn.takeIdrHealRequest() {
                    let idrShards = try packetizer.packetize(
                        frame: accessUnits[0],
                        frameNumber: frameNumber,
                        captureTimestamp: HostTimestamp(
                            microseconds: SystemMonotonicClock.nowMicroseconds),
                        isIDR: true,
                        regime: fecRegime)
                    print("wire-send: HEAL — IDR request answered with fresh IDR " +
                          "(frame \(frameNumber.rawValue), \(idrShards.count) shards, drop-exempt)")
                    frameNumber = frameNumber.next
                    for shard in idrShards {
                        try sender.send(shard.encodeDatagram())
                        sentShards += 1
                    }
                    healFrames += 1
                    try await Task.sleep(for: interval)
                }

                let shards = try packetizer.packetize(
                    frame: annexB,
                    frameNumber: frameNumber,
                    captureTimestamp: HostTimestamp(
                        microseconds: SystemMonotonicClock.nowMicroseconds),
                    isIDR: AnnexBCheck.containsIrap(annexB),
                    regime: fecRegime)
                frameNumber = frameNumber.next
                for shard in shards {
                    if drop > 0, Double.random(in: 0..<1, using: &rng) < drop {
                        droppedShards += 1
                        continue
                    }
                    try sender.send(shard.encodeDatagram())
                    sentShards += 1
                }
                sentFrames += 1
                if sentFrames % (fps * 5) == 0 {
                    print("… \(sentFrames) frames, \(sentShards) shards sent, " +
                          "\(droppedShards) dropped (simulated)")
                }
                try await Task.sleep(for: interval)
            }
        }
        var summary = "wire-send: done — \(sentFrames) frames, \(sentShards) shards sent, " +
                      "\(droppedShards) dropped (simulated), \(loop) loop(s)"
        if healFrames > 0 { summary += ", \(healFrames) heal IDR(s)" }
        if sender.refused > 0 {
            summary += ", \(sender.refused) refused (receiver gone?)"
        }
        print(summary)
        print(standIn.finalSummary())
    }
}

/// The host's CL-3-facing half, stood in on the sender's connected socket:
/// receives and logs feedback reports, beacon echoes, and IDR requests;
/// emits the 1 Hz CTRL ClockBeacon (HS-7's job) with the lastEcho mirror
/// populated so the client can compute symmetric clock samples. Insecure
/// framing, like the send half — the crypto seam re-gates at W5.
private final class HostStandIn: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var thread: Thread?
    private var beaconTimer: DispatchSourceTimer?
    private let running = LockedCell(false)

    // Receive-side tallies.
    private var feedbackReports: UInt64 = 0
    private var dispersionSamples: UInt64 = 0
    private var nackEntries: UInt64 = 0
    private var echoes: UInt64 = 0
    private var idrRequests: UInt64 = 0
    private var malformed: UInt64 = 0
    private var lastOffsetMicroseconds: Int64?
    private var lastRttMicroseconds: Int64?

    // Send-side state.
    private var beaconSeq: UInt32 = 0
    private var ctrlSeq = ChannelSeq(rawValue: 0)
    private var lastEchoMirror: ClockBeacon.LastEcho?

    // The heal flag the send loop polls.
    private var idrHealPending = false

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        // 100 ms receive timeout so stop() can interrupt the loop.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        running.value = true
        let receiver = Thread { [weak self] in self?.receiveLoop() }
        receiver.name = "wire-send-standin-recv"
        receiver.start()
        thread = receiver

        // The 1 Hz beacon (plus one at start, per §4.6).
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendBeacon() }
        timer.resume()
        beaconTimer = timer
    }

    func stop() {
        running.value = false
        beaconTimer?.cancel()
        beaconTimer = nil
    }

    /// True at most once per received IDR request burst: the send loop
    /// consumes the flag and answers with a fresh IDR.
    func takeIdrHealRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = idrHealPending
        idrHealPending = false
        return pending
    }

    func finalSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        var s = "wire-send: stand-in received \(feedbackReports) feedback reports " +
                "(\(dispersionSamples) dispersion samples, \(nackEntries) NACK entries), " +
                "\(echoes) beacon echoes, \(idrRequests) IDR requests"
        if let offset = lastOffsetMicroseconds, let rtt = lastRttMicroseconds {
            s += String(format: ", last clock sample offset %+d µs rtt %d µs", offset, rtt)
        }
        if malformed > 0 { s += ", \(malformed) malformed" }
        return s
    }

    // MARK: - Receive

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running.value {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if errno == ECONNREFUSED { continue }
                return   // socket closed
            }
            guard n > 0 else { continue }
            handle(datagram: buffer[0..<n])
        }
    }

    private func handle(datagram: ArraySlice<UInt8>) {
        guard let (envelope, payload) = try? Envelope.decode(datagram) else {
            lock.lock(); malformed += 1; lock.unlock()
            return
        }
        switch envelope.channel {
        case .feedback:
            guard let report = try? FeedbackReport.decode(Array(payload)) else {
                lock.lock(); malformed += 1; lock.unlock()
                return
            }
            lock.lock()
            feedbackReports += 1
            dispersionSamples += UInt64(report.dispersion?.samples.count ?? 0)
            nackEntries += UInt64(report.nacks.count)
            let count = feedbackReports
            lock.unlock()
            // The first report and one per second at 40 ms cadence —
            // evidence without flooding.
            if count == 1 || count % 25 == 0 {
                var line = "wire-send: feedback #\(count) — "
                line += report.channels.map { c in
                    "chan\(c.channel.rawValue): \(c.received) rx/\(c.missing) miss/\(c.duplicates) dup"
                }.joined(separator: ", ")
                if let d = report.dispersion {
                    line += " | \(d.samples.count) dispersion samples"
                }
                line += " | \(report.nacks.count) NACKs (v1: empty until HS-17)"
                print(line)
            }
        case .ctrl:
            handleCtrl(payload: Array(payload))
        default:
            lock.lock(); malformed += 1; lock.unlock()
        }
    }

    private func handleCtrl(payload: [UInt8]) {
        switch CtrlMessageType.peek(payload) {
        case CtrlMessageType.beaconEcho:
            guard let echo = try? BeaconEcho.decode(payload) else {
                lock.lock(); malformed += 1; lock.unlock()
                return
            }
            // t4 measured locally at arrival — never on the wire.
            let t4 = HostTimestamp(
                microseconds: SystemMonotonicClock.nowMicroseconds)
            let sample = echo.clockSample(hostReceive: t4)
            lock.lock()
            echoes += 1
            lastOffsetMicroseconds = sample.offsetMicroseconds
            lastRttMicroseconds = sample.rttMicroseconds
            lastEchoMirror = ClockBeacon.LastEcho(
                beaconSeq: echo.beaconSeq,
                clientSend: echo.clientSend,
                hostReceive: t4)
            lock.unlock()
            print("wire-send: beacon echo #\(echo.beaconSeq) — offset " +
                  "\(sample.offsetMicroseconds) µs, rtt \(sample.rttMicroseconds) µs")
        case CtrlMessageType.idrRequest:
            guard let request = try? IdrRequest.decode(payload) else {
                lock.lock(); malformed += 1; lock.unlock()
                return
            }
            lock.lock()
            idrRequests += 1
            idrHealPending = true
            lock.unlock()
            print("wire-send: IDR-REQUEST #\(request.requestSeq) received " +
                  "(frame \(request.frame.rawValue), coalesced \(request.coalescedCount)) " +
                  "— healing at next frame slot")
        default:
            lock.lock(); malformed += 1; lock.unlock()
        }
    }

    // MARK: - Beacon

    private func sendBeacon() {
        lock.lock()
        let seq = beaconSeq
        beaconSeq &+= 1
        let ctrl = ctrlSeq
        ctrlSeq = ctrlSeq.next
        let mirror = lastEchoMirror
        lock.unlock()

        let nowUs = SystemMonotonicClock.nowMicroseconds
        let beacon = ClockBeacon(
            beaconSeq: seq,
            hostSend: HostTimestamp(microseconds: nowUs),
            lastEcho: mirror)
        let envelope = Envelope(
            channel: .ctrl,
            seq: ctrl,
            frame: FrameNumber(rawValue: 0),
            timestamp: nowUs,
            fec: 0)
        guard let datagram = try? envelope.encode(plaintextShard: beacon.encode()) else {
            return
        }
        _ = datagram.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }
}

/// Minimal UDP sender (connect + send).
private final class UdpSender {
    private let fd: Int32

    init(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw ValidationError("socket failed: errno \(errno)")
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            // Resolve names through getaddrinfo (IPv4 only — the
            // endpoint binds AF_INET).
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0,
                  let info = result,
                  let sa = info.pointee.ai_addr else {
                Darwin.close(fd)
                throw ValidationError("cannot resolve \(host)")
            }
            memcpy(&addr.sin_addr,
                   UnsafeRawPointer(sa) + MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!,
                   MemoryLayout<in_addr>.size)
            freeaddrinfo(result)
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw ValidationError("connect failed: errno \(e)")
        }
    }

    /// The connected socket, shared with the stand-in's receive/beacon
    /// half (datagram sends are atomic; concurrent send is safe).
    var fileDescriptor: Int32 { fd }

    /// Datagrams refused (ICMP unreachable bounced off a stopped
    /// receiver) — tolerated, counted: the rig outliving its viewer is
    /// normal, and UDP promises nothing anyway.
    private(set) var refused = 0

    func send(_ bytes: [UInt8]) throws {
        let sent = bytes.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        guard sent == bytes.count else {
            if errno == ECONNREFUSED {
                refused += 1
                return
            }
            throw ValidationError("send failed: errno \(errno)")
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

/// SplitMix64 (Vigna's reference constants) — the same seeded generator
/// the LyteWire test kit uses, duplicated locally so the shipping CLI
/// never links a TestKit product. Same seed → same drop pattern, so a
/// failing smoke reproduces exactly.
struct SendSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
