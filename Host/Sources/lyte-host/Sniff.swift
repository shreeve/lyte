// `lyte-host sniff`: the live Lyte-UDP header dissector. Binds a UDP port
// through CNetIO and prints one line per datagram — envelope fields plus
// the fec interior — via HostWire.SniffFormat. The envelope is cleartext
// AAD, so this works on sealed traffic; payloads are not decrypted.

import LyteIO
import LyteCore
import CNetIO
import Foundation
import HostWire

func sniff(_ args: [String]) throws {
    var port: UInt16?
    var seconds = 0.0 // 0 = run until the count is met (or forever)
    var count = 0     // 0 = unlimited

    var cursor = ArgumentCursor(args[...])
    while let flag = cursor.next() {
        switch flag {
        case "--port":
            port = try cursor.port(flag)
        case "--seconds":
            seconds = try cursor.positive(flag)
        case "--count":
            count = try cursor.value(flag, "a positive integer") {
                Int($0).flatMap { $0 > 0 ? $0 : nil }
            }
        case "--help", "-h":
            Swift.print("""
            usage: lyte-host sniff --port PORT [--seconds N] [--count N]
            Binds PORT and prints one decoded Lyte-UDP header line per
            received datagram (envelope + fec fields; payload stays
            opaque). Stops after --count datagrams or --seconds, else
            runs until interrupted.
            """)
            return
        default:
            throw HostError("sniff: unknown argument \(flag)")
        }
    }
    guard let port else { throw HostError("sniff: --port is required") }

    var err = [CChar](repeating: 0, count: 256)
    // A port another socket holds (the standing service) is refused:
    // SO_REUSEPORT would otherwise share that service's traffic.
    guard let rx = lyte_netio_new_listener(
        "0.0.0.0", port, &err, err.count
    ) else {
        throw HostError(
            "sniff: bind 0.0.0.0:\(port) failed: \(String(cBuffer: err))")
    }
    print("sniff: listening on 0.0.0.0:\(port)")

    // Slots sized to the datagram budget with slack; anything larger is
    // not ours and formats as a malformed line anyway.
    let slotCap = 2048
    let storage = UnsafeMutablePointer<UInt8>.allocate(
        capacity: Int(LYTE_NETIO_MAX_BATCH) * slotCap)
    var slots = (0..<Int(LYTE_NETIO_MAX_BATCH)).map { k -> lyte_netio_slot in
        var slot = lyte_netio_slot()
        slot.data = storage.advanced(by: k * slotCap)
        slot.cap = slotCap
        return slot
    }

    var seen = 0
    let deadline = seconds > 0
        ? SystemMonotonicClock.nowNanoseconds + UInt64(seconds * 1e9) : UInt64.max
    while SystemMonotonicClock.nowNanoseconds < deadline {
        let got = lyte_netio_recv_batch(rx, &slots, Int32(LYTE_NETIO_MAX_BATCH),
                                        &err, err.count)
        if got < 0 {
            throw HostError("sniff: recv failed: \(String(cBuffer: err))")
        }
        if got == 0 {
            usleep(1000)
            continue
        }
        for s in slots.prefix(Int(got)) {
            let bytes = Array(UnsafeBufferPointer(start: s.data, count: s.len))
            let tosHex = Hex.string(
                s.tos, width: 2, uppercase: true, prefix: true)
            print("tos=\(tosHex) "
                + SniffFormat.line(datagram: bytes))
            seen += 1
            if count > 0, seen >= count {
                print("sniff: \(seen) datagrams")
                return
            }
        }
    }
    print("sniff: \(seen) datagrams in \(seconds)s")
}
