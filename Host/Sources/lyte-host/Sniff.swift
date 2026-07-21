// `lyte-host sniff` (HS-5): the live Lyte-UDP header dissector. Binds a
// UDP port through CNetIO and prints one decoded line per datagram —
// envelope fields plus the fec interior (chan/seq/frame/ts/k/m/idx) —
// via HostWire.SniffFormat, whose output format is pinned by the macOS
// tests. The envelope is cleartext AAD by design, so this keeps working
// unchanged once Noise (HS-7) seals payloads; payload decryption behind
// a key flag is an explicitly deferred slice.

import CHevcEncode // lyte_stdout_linebuf
import CNetIO
import Foundation
import HostWire

func sniffMain(_ args: [String]) -> Never {
    var port: UInt16 = 0
    var seconds = 0.0 // 0 = run until the count is met (or forever)
    var count = 0     // 0 = unlimited

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]), v > 0 else {
                FileHandle.standardError.write(
                    Data("lyte-host sniff: --port needs 1–65535\n".utf8))
                exit(1)
            }
            port = v
        case "--seconds":
            i += 1
            guard i < args.count, let v = Double(args[i]), v > 0 else {
                FileHandle.standardError.write(
                    Data("lyte-host sniff: --seconds needs a positive number\n".utf8))
                exit(1)
            }
            seconds = v
        case "--count":
            i += 1
            guard i < args.count, let v = Int(args[i]), v > 0 else {
                FileHandle.standardError.write(
                    Data("lyte-host sniff: --count needs a positive integer\n".utf8))
                exit(1)
            }
            count = v
        case "--help", "-h":
            print("""
            usage: lyte-host sniff --port PORT [--seconds N] [--count N]
            Binds PORT and prints one decoded Lyte-UDP header line per
            received datagram (envelope + fec fields; payload stays
            opaque). Stops after --count datagrams or --seconds, else
            runs until interrupted.
            """)
            exit(0)
        default:
            FileHandle.standardError.write(
                Data("lyte-host sniff: unknown argument \(args[i])\n".utf8))
            exit(1)
        }
        i += 1
    }
    guard port > 0 else {
        FileHandle.standardError.write(
            Data("lyte-host sniff: --port is required\n".utf8))
        exit(1)
    }

    lyte_stdout_linebuf()
    var err = [CChar](repeating: 0, count: 256)
    guard let rx = lyte_netio_new("0.0.0.0", port, &err, err.count) else {
        FileHandle.standardError.write(Data(
            "lyte-host sniff: bind 0.0.0.0:\(port) failed: \(errString(err))\n"
                .utf8))
        exit(1)
    }
    defer { lyte_netio_free(rx) }
    print("sniff: listening on 0.0.0.0:\(port)")

    // Slots sized to the datagram budget with slack; anything larger is
    // not ours and formats as a malformed line anyway.
    let slotCap = 2048
    let storage = UnsafeMutablePointer<UInt8>.allocate(
        capacity: Int(LYTE_NETIO_MAX_BATCH) * slotCap)
    defer { storage.deallocate() }
    var slots = (0..<Int(LYTE_NETIO_MAX_BATCH)).map { k -> lyte_netio_slot in
        var slot = lyte_netio_slot()
        slot.data = storage.advanced(by: k * slotCap)
        slot.cap = slotCap
        return slot
    }

    var seen = 0
    let deadline = seconds > 0
        ? monotonicNS() + UInt64(seconds * 1e9) : UInt64.max
    while monotonicNS() < deadline {
        let got = lyte_netio_recv_batch(rx, &slots, Int32(LYTE_NETIO_MAX_BATCH),
                                        &err, err.count)
        if got < 0 {
            FileHandle.standardError.write(Data(
                "lyte-host sniff: recv failed: \(errString(err))\n".utf8))
            exit(1)
        }
        if got == 0 {
            usleep(1000)
            continue
        }
        for s in slots.prefix(Int(got)) {
            let bytes = Array(UnsafeBufferPointer(start: s.data, count: s.len))
            let tosHex = String(s.tos, radix: 16, uppercase: true)
            print("tos=0x\(tosHex.count == 1 ? "0" + tosHex : tosHex) "
                + SniffFormat.line(datagram: bytes))
            seen += 1
            if count > 0, seen >= count {
                print("sniff: \(seen) datagrams")
                exit(0)
            }
        }
    }
    print("sniff: \(seen) datagrams in \(seconds)s")
    exit(0)
}
