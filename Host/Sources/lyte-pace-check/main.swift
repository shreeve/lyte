// HS-6 verification harness: proves the pure Pacer schedule drives real
// sendmmsg batches sanely through the CNetIO leaf (HS-4) on loopback.
// A 60 fps mix (5 ms audio, 10 ms control, 2-shard P-frames) plus one
// forced IDR runs through the Pacer against the real monotonic clock;
// each emitted batch becomes one lyte_netio_send_batch call with
// per-packet TOS mapped from the pacer class (HostCore's WireTos —
// outside the pure Pacer by design: ctrl/audio/repairs 0xC0 CS6,
// video 0xA0 CS5).
// Kernel software TX timestamps then measure what actually left the
// host: inter-batch spacing during the saturated IDR drain (≈ one
// quantum), the IDR's wall-clock drain, and audio's worst queue delay.
// Exits nonzero when any HS-6 gate bound is violated. No protocol,
// no envelope — byte counts and class tags only.

import LyteIO
import LyteCore
import CNetIO
import Foundation
import HostCore

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func errString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func realtimeNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

/// Class → IPv4 TOS byte: HostCore's WireTos, the product policy the
/// session shell also applies (HS-20 unified the two verbatim copies).
func tos(for c: PacerClass) -> UInt8 {
    WireTos.byte(for: c)
}

func fmtMS(_ ns: UInt64) -> String { String(format: "%7.3f", Double(ns) / 1e6) }
func fmtMS(_ ns: Double) -> String { String(format: "%7.3f", ns / 1e6) }

// MARK: - Traffic schedule

let ms: UInt64 = 1_000_000
let rateBPS = 20_000_000
// One IDR shard is sized just under the 1 ms quantum (2,500 B at
// 20 Mbps) so a saturated drain emits ≈quantum-sized batches — the
// spacing evidence. Loopback MTU makes 2,400 B datagrams fine; the
// on-wire shard budget (1,152 B) is envelope policy, not this leaf's.
let idrShardBytes = 2400
// 20 × 2,400 = 48,000 B: well under the 60,000 B frameByteCeiling at
// 20 Mbps, leaving headroom for usleep scheduling overshoot on the ~20
// wakeups the drain needs (the sim proves the tight bound; the harness
// proves real syscalls under a real clock stay inside it).
let idrShards = 20
let idrAt = 30 * ms
let runLength = 100 * ms

struct Arrival {
    let at: UInt64 // relative ns
    let cls: PacerClass
    let bytes: Int
    let urgent: Bool
}

func schedule() -> [Arrival] {
    var a: [Arrival] = []
    var t: UInt64 = 0
    while t < runLength {
        a.append(Arrival(at: t, cls: .audio, bytes: 320, urgent: false))
        t += 5 * ms
    }
    t = 0
    while t < runLength {
        a.append(Arrival(at: t, cls: .control, bytes: 64, urgent: false))
        t += 10 * ms
    }
    t = 0
    while t < runLength {
        for _ in 0..<2 {
            a.append(Arrival(at: t, cls: .freshVideo, bytes: 2400,
                             urgent: false))
        }
        t += 16_666_667
    }
    for _ in 0..<idrShards {
        a.append(Arrival(at: idrAt, cls: .freshVideo, bytes: idrShardBytes,
                         urgent: true))
    }
    return a.sorted { $0.at < $1.at }
}

// MARK: - Run

struct SentPacket {
    let pktID: UInt32
    let cls: PacerClass
    let bytes: Int
    let batchIndex: Int
    let urgent: Bool
}

struct SentBatch {
    let index: Int
    let emittedAtRel: UInt64
    let bytes: Int
    let wireNS: UInt64
    let firstPktID: UInt32
}

func run() throws {
    var err = [CChar](repeating: 0, count: 256)

    guard let rx = lyte_netio_new("127.0.0.1", 0, &err, err.count) else {
        throw CheckError("receiver open failed: \(errString(err))")
    }
    defer { lyte_netio_free(rx) }
    let port = lyte_netio_local_port(rx)

    guard let tx = lyte_netio_new("127.0.0.1", 0, &err, err.count) else {
        throw CheckError("sender open failed: \(errString(err))")
    }
    defer { lyte_netio_free(tx) }
    guard lyte_netio_set_peer(tx, "127.0.0.1", port, &err, err.count) == 0 else {
        throw CheckError("sender connect failed: \(errString(err))")
    }
    guard lyte_netio_enable_tx_timestamps(tx, &err, err.count) == 0 else {
        throw CheckError("SO_TIMESTAMPING arm failed: \(errString(err))")
    }

    let arrivals = schedule()
    print("pace-check: \(arrivals.count) tokens over \(runLength / ms) ms "
        + "at \(rateBPS / 1_000_000) Mbps to 127.0.0.1:\(port); forced IDR "
        + "\(idrShards)×\(idrShardBytes) B (\(idrShards * idrShardBytes) B) "
        + "at +\(idrAt / ms) ms")

    let pacer = Pacer(rateBitsPerSecond: rateBPS, now: 0)
    let scratch = UnsafeMutablePointer<UInt8>.allocate(
        capacity: Int(LYTE_NETIO_MAX_BATCH) * idrShardBytes)
    defer { scratch.deallocate() }

    var batches: [SentBatch] = []
    var packets: [SentPacket] = []
    var idrEnqueuedRealNS: UInt64 = 0

    let t0 = SystemMonotonicClock.nowNanoseconds
    var i = 0
    while true {
        let now = SystemMonotonicClock.nowNanoseconds - t0
        while i < arrivals.count, arrivals[i].at <= now {
            let a = arrivals[i]
            pacer.enqueue(a.cls, bytes: a.bytes, urgent: a.urgent,
                          now: max(a.at, now))
            if a.urgent, idrEnqueuedRealNS == 0 { idrEnqueuedRealNS = realtimeNS() }
            i += 1
        }
        while let batch = pacer.nextBatch(now: SystemMonotonicClock.nowNanoseconds - t0) {
            var pkts: [lyte_netio_pkt] = []
            var off = 0
            for t in batch.tokens {
                scratch.advanced(by: off)
                    .initialize(repeating: UInt8(truncatingIfNeeded: packets.count + pkts.count),
                                count: t.bytes)
                pkts.append(lyte_netio_pkt(data: scratch.advanced(by: off),
                                           len: t.bytes,
                                           tos: tos(for: t.priorityClass)))
                off += t.bytes
            }
            var firstID: UInt32 = 0
            var sentTotal = 0
            while sentTotal < pkts.count {
                var id: UInt32 = 0
                let sent = pkts[sentTotal...].withUnsafeBufferPointer { buf in
                    lyte_netio_send_batch(tx, buf.baseAddress,
                                          Int32(buf.count), &id,
                                          &err, err.count)
                }
                if sent < 0 { throw CheckError("send failed: \(errString(err))") }
                if sent == 0 { usleep(200); continue }
                if sentTotal == 0 { firstID = id }
                sentTotal += Int(sent)
            }
            for (k, t) in batch.tokens.enumerated() {
                packets.append(SentPacket(pktID: firstID + UInt32(k),
                                          cls: t.priorityClass,
                                          bytes: t.bytes,
                                          batchIndex: batches.count,
                                          urgent: t.urgent))
            }
            batches.append(SentBatch(index: batches.count,
                                     emittedAtRel: batch.emittedAt,
                                     bytes: batch.bytes,
                                     wireNS: batch.wireTimeNS,
                                     firstPktID: firstID))
        }

        if i >= arrivals.count, pacer.isEmpty { break }
        let now2 = SystemMonotonicClock.nowNanoseconds - t0
        let nextArrival: UInt64? = i < arrivals.count ? arrivals[i].at : nil
        let wake = pacer.nextWake(now: now2)
        let target = [nextArrival, wake].compactMap { $0 }.min() ?? (now2 + ms)
        if target > now2 { usleep(UInt32((target - now2) / 1000 + 1)) }
    }

    // Flush the receiver so nothing lingers in socket buffers.
    let rxCap = idrShardBytes
    let rxStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * rxCap)
    defer { rxStorage.deallocate() }
    var slots = (0..<64).map { k -> lyte_netio_slot in
        var slot = lyte_netio_slot()
        slot.data = rxStorage.advanced(by: k * rxCap)
        slot.cap = rxCap
        return slot
    }
    var received = 0
    var rxTosTally: [UInt8: Int] = [:]
    let rxDeadline = SystemMonotonicClock.nowNanoseconds + 500_000_000
    while received < packets.count, SystemMonotonicClock.nowNanoseconds < rxDeadline {
        let got = lyte_netio_recv_batch(rx, &slots, 64, &err, err.count)
        if got < 0 { throw CheckError("recv failed: \(errString(err))") }
        if got == 0 { usleep(1000); continue }
        for s in slots.prefix(Int(got)) { rxTosTally[s.tos, default: 0] += 1 }
        received += Int(got)
    }

    // Drain TX timestamps for every datagram sent.
    var stamps: [UInt32: UInt64] = [:]
    var stampBuf = [lyte_netio_txstamp](
        repeating: lyte_netio_txstamp(pkt_id: 0, ts_ns: 0), count: 64)
    let stampDeadline = SystemMonotonicClock.nowNanoseconds + 3_000_000_000
    while stamps.count < packets.count, SystemMonotonicClock.nowNanoseconds < stampDeadline {
        let got = lyte_netio_poll_txstamps(tx, &stampBuf, 64, &err, err.count)
        if got < 0 { throw CheckError("txstamp poll failed: \(errString(err))") }
        for s in stampBuf.prefix(Int(got)) { stamps[s.pkt_id] = s.ts_ns }
        if got == 0 { usleep(1000) }
    }

    var failures = 0
    print("sent \(packets.count) datagrams in \(batches.count) batches, "
        + "received \(received), tx stamps \(stamps.count)/\(packets.count)")

    // Per-class TOS marking, verified at the receiver via IP_RECVTOS.
    var sentTosTally: [UInt8: Int] = [:]
    for p in packets { sentTosTally[tos(for: p.cls), default: 0] += 1 }
    let tallyLine = sentTosTally.keys.sorted(by: >).map { t in
        Hex.string(t, uppercase: true, prefix: true)
            + " sent \(sentTosTally[t] ?? 0) recv \(rxTosTally[t] ?? 0)"
    }.joined(separator: "; ")
    print("per-class TOS (IP_RECVTOS): \(tallyLine)")
    if sentTosTally != rxTosTally {
        print("FAIL: received TOS tally does not match sent classes")
        failures += 1
    }
    if stamps.count < packets.count {
        print("FAIL: missing TX stamps")
        failures += 1
    }

    // Batch table with measured TX spacing (first stamp per batch).
    print("batch  t+ms     bytes  wire-µs  spacing-ms  classes")
    var prevStamp: UInt64 = 0
    var idrBatchStamps: [UInt64] = []
    var idrSpacings: [Double] = []
    for b in batches {
        let stamp = stamps[b.firstPktID] ?? 0
        let spacing = (prevStamp != 0 && stamp != 0)
            ? Double(stamp - prevStamp) : Double.nan
        let members = packets.filter { $0.batchIndex == b.index }
        let classes = members.map {
            ($0.urgent ? "!" : "") + $0.cls.name
        }.joined(separator: ",")
        let isIdrBatch = members.contains { $0.urgent }
        if isIdrBatch, stamp != 0 {
            idrBatchStamps.append(stamp)
            if !spacing.isNaN, idrBatchStamps.count > 1 {
                idrSpacings.append(spacing)
            }
        }
        print("\(String(format: "%4d", b.index))  \(fmtMS(b.emittedAtRel))  "
            + "\(String(format: "%5d", b.bytes))  "
            + "\(String(format: "%7.0f", Double(b.wireNS) / 1e3))  "
            + (spacing.isNaN ? "        -  " : "\(fmtMS(spacing))     ")
            + classes)
        if stamp != 0 { prevStamp = stamp }
        if b.wireNS > pacer.quantumNS {
            print("FAIL: batch \(b.index) exceeds the 1 ms quantum")
            failures += 1
        }
    }

    // Gate numbers, measured at the kernel TX stamp point.
    if let first = idrBatchStamps.first, let last = idrBatchStamps.last,
       idrEnqueuedRealNS != 0 {
        let drain = last - idrEnqueuedRealNS
        let span = last - first
        print("IDR drain (enqueue → last TX stamp): \(fmtMS(drain)) ms "
            + "(budget min(2×16.67, 25) = 25 ms); stamp span \(fmtMS(span)) ms")
        if drain > 25 * ms {
            print("FAIL: IDR drain exceeded 25 ms")
            failures += 1
        }
        if !idrSpacings.isEmpty {
            let mn = idrSpacings.min()!, mx = idrSpacings.max()!
            let avg = idrSpacings.reduce(0, +) / Double(idrSpacings.count)
            print("IDR-drain batch spacing min/avg/max: \(fmtMS(mn)) / "
                + "\(fmtMS(avg)) / \(fmtMS(mx)) ms (quantum 1.000)")
            if avg < 0.5e6 {
                print("FAIL: spacing collapsed — pacing not in effect")
                failures += 1
            }
        }
    } else {
        print("FAIL: IDR batches missing from TX stamps")
        failures += 1
    }

    let audioWait = pacer.telemetry[.audio].maxQueueDelayNS
    let controlWait = pacer.telemetry[.control].maxQueueDelayNS
    print("max queue delay: audio \(fmtMS(audioWait)) ms, control "
        + "\(fmtMS(controlWait)) ms, video "
        + "\(fmtMS(pacer.telemetry[.freshVideo].maxQueueDelayNS)) ms "
        + "(audio bound: 1 quantum + ε)")
    if audioWait > pacer.quantumNS + pacer.quantumNS / 5 {
        print("FAIL: audio waited more than a quantum (+20% sched slack)")
        failures += 1
    }
    print("max batch wire time \(fmtMS(pacer.telemetry.maxBatchWireTimeNS)) ms; "
        + "\(pacer.telemetry.bytesSent) B in \(pacer.telemetry.batches) batches")

    guard failures == 0 else { throw CheckError("\(failures) check(s) failed") }
    print("pace-check: OK — pacer schedule drove sendmmsg with per-class TOS; "
        + "gate bounds hold at the kernel TX stamp point")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-pace-check: error: \(error)\n".utf8))
    exit(1)
}
