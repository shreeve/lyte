import ArgumentParser
import Foundation
import LyteWire

/// CL-2's loopback test rig and tomorrow's J-G1 sanity tool: read corpus
/// access units (Wire/Vectors/video-corpus-v1 layout), packetize through
/// the real VideoPacketizer, and send the shards over UDP at a paced
/// frame rate — with an optional seeded drop rate so the receive side's
/// FEC recovery can be exercised without a lossy network. Insecure
/// framing only (the crypto seam is W5's; re-gate when it lands).
struct WireSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-send",
        abstract: "DEBUG: packetize corpus frames and send them as Lyte-UDP video (loopback rig for wire-view).")

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

        var packetizer = VideoPacketizer()
        var rng = SendSplitMix64(seed: seed)
        var frameNumber = FrameNumber(rawValue: 0)
        var sentShards = 0, droppedShards = 0, sentFrames = 0
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
                let shards = try packetizer.packetize(
                    frame: annexB,
                    frameNumber: frameNumber,
                    captureTimestamp: HostTimestamp(
                        microseconds: DispatchTime.now().uptimeNanoseconds / 1000),
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
        if sender.refused > 0 {
            summary += ", \(sender.refused) refused (receiver gone?)"
        }
        print(summary)
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
