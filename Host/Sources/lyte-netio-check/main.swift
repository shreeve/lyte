// HS-4 verification harness: proves the CNetIO leaf can drive per-packet
// DSCP and kernel TX timestamps on loopback. Sends one sendmmsg batch to a
// paired socket with a rotating TOS cycle (0xB8/EF-46 for contrast,
// 0xA0/CS5-40 video, 0xC0/CS6-48 audio), reads the received TOS per packet
// via IP_RECVTOS, and drains software TX timestamps from the error queue.
// Exits nonzero on any mismatch. No protocol, no policy — a leaf check.

import CNetIO
import Foundation

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Decodes a NUL-terminated C error buffer.
func errString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func monotonicNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func realtimeNowNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

func hexTOS(_ tos: UInt8) -> String {
    let hex = String(tos, radix: 16, uppercase: true)
    return "0x" + (hex.count == 1 ? "0" : "") + hex + "/dscp\(tos >> 2)"
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func run() throws {
    var err = [CChar](repeating: 0, count: 256)

    // Optional receive-port override so the netem helper can target a
    // known port: lyte-netio-check [receive-port]
    var rxPort: UInt16 = 0
    if CommandLine.arguments.count > 1 {
        guard let p = UInt16(CommandLine.arguments[1]) else {
            throw CheckError("usage: lyte-netio-check [receive-port]")
        }
        rxPort = p
    }

    guard let rx = lyte_netio_new("127.0.0.1", rxPort, &err, err.count) else {
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

    let tosCycle: [UInt8] = [0xB8, 0xA0, 0xC0]
    let count = 12
    let payloadSize = 1152 // the universal datagram budget
    let sentTOS = (0..<count).map { tosCycle[$0 % tosCycle.count] }

    print("netio-check: \(count) datagrams of \(payloadSize) B to "
        + "127.0.0.1:\(port), TOS cycle "
        + tosCycle.map { hexTOS($0) }.joined(separator: " "))

    // Payload byte 0 identifies the datagram, so received TOS matches to
    // sent TOS regardless of delivery order.
    let payloads = UnsafeMutablePointer<UInt8>.allocate(
        capacity: count * payloadSize)
    defer { payloads.deallocate() }
    for i in 0..<count {
        payloads.advanced(by: i * payloadSize)
            .initialize(repeating: UInt8(i), count: payloadSize)
    }
    var pkts = (0..<count).map { i in
        lyte_netio_pkt(data: payloads.advanced(by: i * payloadSize),
                       len: payloadSize, tos: sentTOS[i])
    }

    var firstId: UInt32 = 0
    let sendStartNS = realtimeNowNS()
    let sendStartMono = monotonicNow()
    let sent = lyte_netio_send_batch(tx, &pkts, Int32(count), &firstId,
                                     &err, err.count)
    guard sent == count else {
        throw CheckError(sent < 0
            ? "send failed: \(errString(err))"
            : "short send: \(sent)/\(count)")
    }
    print("sent \(sent) in one sendmmsg batch (first pkt_id \(firstId))")

    // Receive with a bounded wait: loopback delivery is immediate unless a
    // netem delay profile is applied, so poll up to 3 s.
    let rxCap = 2048
    let rxStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: count * rxCap)
    defer { rxStorage.deallocate() }
    var slots = (0..<count).map { i -> lyte_netio_slot in
        var slot = lyte_netio_slot()
        slot.data = rxStorage.advanced(by: i * rxCap)
        slot.cap = rxCap
        return slot
    }
    var received = 0
    var lastRecvAt = sendStartMono
    let recvDeadline = monotonicNow() + 3.0
    while received < count, monotonicNow() < recvDeadline {
        let got = lyte_netio_recv_batch(rx, &slots[received],
                                        Int32(count - received),
                                        &err, err.count)
        guard got >= 0 else {
            throw CheckError("recv failed: \(errString(err))")
        }
        if got > 0 {
            received += Int(got)
            lastRecvAt = monotonicNow()
        } else {
            usleep(1000)
        }
    }
    guard received == count else {
        throw CheckError("received \(received)/\(count) within 3 s")
    }
    let deliveryMS = (lastRecvAt - sendStartMono) * 1000
    print("received \(received)/\(count), batch delivery "
        + String(Int(deliveryMS.rounded())) + " ms")

    // Drain TX timestamps; the kernel delivers them asynchronously.
    var stamps: [UInt32: UInt64] = [:]
    var stampBuf = [lyte_netio_txstamp](
        repeating: lyte_netio_txstamp(pkt_id: 0, ts_ns: 0), count: count)
    let stampDeadline = monotonicNow() + 3.0
    while stamps.count < count, monotonicNow() < stampDeadline {
        let got = lyte_netio_poll_txstamps(tx, &stampBuf, Int32(count),
                                           &err, err.count)
        guard got >= 0 else {
            throw CheckError("txstamp poll failed: \(errString(err))")
        }
        for s in stampBuf.prefix(Int(got)) {
            stamps[s.pkt_id] = s.ts_ns
        }
        if got == 0 { usleep(1000) }
    }

    // Per-packet verification: sent TOS == received TOS, length intact,
    // TX stamp present, nonzero, and monotonic in packet order.
    var failures = 0
    var prevStamp: UInt64 = 0
    print("pkt  sent          recv          len   tx-stamp (+µs after send)")
    for i in 0..<count {
        guard let slot = slots.first(where: {
            $0.len > 0 && $0.data!.pointee == UInt8(i)
        }) else {
            print("\(pad(String(i), 4)) \(pad(hexTOS(sentTOS[i]), 13)) MISSING")
            failures += 1
            continue
        }
        let id = firstId + UInt32(i)
        let stamp = stamps[id] ?? 0
        var marks = ""
        if slot.tos != sentTOS[i] { marks += " TOS-MISMATCH"; failures += 1 }
        if slot.len != payloadSize { marks += " LEN-MISMATCH"; failures += 1 }
        if stamp == 0 { marks += " NO-TX-STAMP"; failures += 1 }
        if stamp != 0, stamp < prevStamp {
            marks += " NON-MONOTONIC"
            failures += 1
        }
        if stamp != 0 { prevStamp = stamp }
        let deltaUS = stamp == 0 ? "-" : String((stamp &- sendStartNS) / 1000)
        print("\(pad(String(i), 4)) \(pad(hexTOS(sentTOS[i]), 13)) "
            + "\(pad(hexTOS(slot.tos), 13)) \(pad(String(slot.len), 5)) "
            + "\(stamp) (+\(deltaUS) µs)\(marks)")
    }
    if stamps.count < count {
        print("tx stamps: only \(stamps.count)/\(count) arrived within 3 s")
        failures += 1
    }

    guard failures == 0 else {
        throw CheckError("\(failures) check(s) failed")
    }
    print("netio-check: OK — per-packet TOS round-trip and TX timestamps verified")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-netio-check: error: \(error)\n".utf8))
    exit(1)
}
