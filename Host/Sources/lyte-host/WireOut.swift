// WireOut: lyte-host's Lyte-UDP send leg (HS-5's Linux half, thin over
// HostWire). Encoded packets from the NVENC callback go through
// HostWire.VideoChannel (packetize + FEC + pacer) and each drained
// datagram leaves through CNetIO with per-packet TOS — video 0xA0
// (CS5/DSCP 40), matching lyte-pace-check's class→TOS ruling.
//
// Threading honesty: sendFrame runs on the PipeWire loop thread (same
// place the encoder runs) and drains the pacer to empty before
// returning, sleeping at the pacer's nextWake instants — at 20 Mbps a
// 60 fps frame drains in well under its 16.7 ms interval (the HS-5 gate
// measures this on the simulated clock). A dedicated send thread is the
// host event-loop era's job; this slice keeps the wiring observable and
// single-threaded.

import CNetIO
import Foundation
import HostCore
import HostWire
import LyteWire

/// Class → IPv4 TOS byte, the lyte-pace-check policy verbatim.
private func tos(for c: PacerClass) -> UInt8 {
    switch c {
    case .control, .audio: return 0xC0 // CS6 / DSCP 48
    case .freshVideo, .videoTail, .refinement: return 0xA0 // CS5 / DSCP 40
    case .telemetry: return 0x00
    }
}

func monotonicNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

final class WireOut {
    private let netio: OpaquePointer
    private var channel: VideoChannel!
    private var outbox: [VideoChannelDatagram] = []
    private var nextFrameNumber = FrameNumber(rawValue: 0)

    /// Scratch for one sendmmsg batch: pointers must stay valid for the
    /// duration of the call, so datagrams are staged here.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity =
        Int(LYTE_NETIO_MAX_BATCH) * 1_200

    private(set) var framesSent = 0
    private(set) var datagramsSent = 0
    private(set) var bytesSent = 0
    private(set) var lastSendError: String?

    var counters: VideoChannelCounters { channel.counters }
    var pacerTelemetry: PacerTelemetry { channel.pacerTelemetry }

    init(host: String, port: UInt16, rateBitsPerSecond: Int) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", 0, &err, err.count) else {
            throw HostError("wire-out socket open failed: \(errString(err))")
        }
        guard lyte_netio_set_peer(n, host, port, &err, err.count) == 0 else {
            lyte_netio_free(n)
            throw HostError("wire-out connect to \(host):\(port) failed: "
                + errString(err))
        }
        netio = n
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Self.scratchCapacity)
        channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: rateBitsPerSecond),
            now: monotonicNS()
        ) { [weak self] datagram in
            self?.outbox.append(datagram)
        }
    }

    deinit {
        scratch.deallocate()
        lyte_netio_free(netio)
    }

    /// One encoded Annex-B packet → shards on the wire. Runs on the
    /// PipeWire loop thread; returns once the pacer has fully drained.
    func sendFrame(
        data: UnsafePointer<UInt8>, size: Int, isKeyframe: Bool,
        captureMicros: UInt64
    ) throws {
        let frame = Array(UnsafeBufferPointer(start: data, count: size))
        try channel.ingest(
            frame: frame,
            frameNumber: nextFrameNumber,
            captureTimestampMicroseconds: captureMicros,
            isKeyframe: isKeyframe,
            now: monotonicNS()
        )
        nextFrameNumber = nextFrameNumber.next
        framesSent += 1
        try drain()
    }

    /// Pumps the pacer at its own wake instants until empty, flushing
    /// each pump's datagrams as one CNetIO batch.
    private func drain() throws {
        while true {
            let now = monotonicNS()
            channel.pump(now: now)
            try flushOutbox()
            guard let wake = channel.nextWake(now: monotonicNS()) else {
                return // pacer empty
            }
            let now2 = monotonicNS()
            if wake > now2 {
                usleep(UInt32((wake - now2) / 1000 + 1))
            }
        }
    }

    private func flushOutbox() throws {
        guard !outbox.isEmpty else { return }
        defer { outbox.removeAll(keepingCapacity: true) }
        var err = [CChar](repeating: 0, count: 256)

        var staged = 0
        while staged < outbox.count {
            let batch = outbox[staged..<min(
                staged + Int(LYTE_NETIO_MAX_BATCH), outbox.count)]
            var pkts: [lyte_netio_pkt] = []
            pkts.reserveCapacity(batch.count)
            var offset = 0
            for d in batch {
                precondition(offset + d.bytes.count <= Self.scratchCapacity)
                d.bytes.withUnsafeBufferPointer { src in
                    scratch.advanced(by: offset)
                        .update(from: src.baseAddress!, count: src.count)
                }
                pkts.append(lyte_netio_pkt(
                    data: scratch.advanced(by: offset),
                    len: d.bytes.count,
                    tos: tos(for: d.pacerClass)
                ))
                offset += d.bytes.count
            }

            var sentTotal = 0
            while sentTotal < pkts.count {
                let sent = pkts[sentTotal...].withUnsafeBufferPointer { buf in
                    lyte_netio_send_batch(netio, buf.baseAddress,
                                          Int32(buf.count), nil,
                                          &err, err.count)
                }
                if sent < 0 {
                    lastSendError = errString(err)
                    throw HostError("wire-out send failed: \(errString(err))")
                }
                if sent == 0 { usleep(200); continue }
                sentTotal += Int(sent)
            }
            for d in batch {
                datagramsSent += 1
                bytesSent += d.bytes.count
            }
            staged += batch.count
        }
    }
}
