// Doorbell mode (E0 milestone 1) — output format frozen for
// line-comparability with the fbid-poll.c feasibility probe (retired
// to git history with Host/Probes/kms-eye/).

#if os(Linux)

import LyteIO
import CDRM
import Foundation
import Glibc
import HostEye

// MARK: - Doorbell mode (milestone 1, output format frozen)

struct Watch {
    var planeId: UInt32
    var lastFB: UInt32
    var changes = 0
    var lastChangeAt = 0.0
    var minGap = 1e9
    var maxGap = 0.0

    mutating func observe(fb: UInt32, at t: Double) -> Bool {
        guard fb != lastFB else { return false }
        if lastChangeAt > 0 {
            let gap = t - lastChangeAt
            minGap = min(minGap, gap)
            maxGap = max(maxGap, gap)
        }
        lastChangeAt = t
        lastFB = fb
        changes += 1
        return true
    }
}

func runDoorbell(
    device: String, seconds: Double, intervalUs: UInt32
) -> Never {
    let fd = open(device, O_RDWR)
    guard fd >= 0 else {
        perror(device)
        exit(1)
    }
    drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
    guard let planes = findActivePlanes(fd: fd) else {
        FileHandle.standardError.write(
            Data("no active primary plane on \(device)\n".utf8))
        exit(1)
    }
    var primary = Watch(planeId: planes.primary.id, lastFB: planes.primary.fb)
    var cursor = planes.cursor.map { Watch(planeId: $0.id, lastFB: $0.fb) }
    print("device=\(device) primary_plane=\(primary.planeId) "
        + "cursor_plane=\(cursor?.planeId ?? 0) "
        + "poll=\(intervalUs)us run=\(Int(seconds))s [swift]")

    var polls = 0
    var pollCostNs = 0.0
    let t0 = SystemMonotonicClock.nowSeconds
    var nextReport = t0 + 1.0
    var primaryThisSecond = 0
    var t = t0

    while true {
        t = SystemMonotonicClock.nowSeconds
        guard t - t0 < seconds else { break }
        let costStart = SystemMonotonicClock.nowSeconds
        if let fb = currentFB(fd: fd, planeId: primary.planeId),
           primary.observe(fb: fb, at: t) {
            primaryThisSecond += 1
        }
        if cursor != nil, let fb = currentFB(fd: fd, planeId: cursor!.planeId) {
            _ = cursor!.observe(fb: fb, at: t)
        }
        pollCostNs += (SystemMonotonicClock.nowSeconds - costStart) * 1e9
        polls += 1
        if t >= nextReport {
            print("  t=\(String(format: "%2.0f", t - t0))s "
                + "primary_flips_this_sec=\(primaryThisSecond) "
                + "total=\(primary.changes)")
            primaryThisSecond = 0
            nextReport += 1.0
        }
        usleep(intervalUs)
    }

    let duration = t - t0
    print(String(
        format: "RESULT primary: %d flips in %.1fs = %.2f/s  "
            + "gap_min=%.1fms gap_max=%.1fms",
        primary.changes, duration,
        Double(primary.changes) / duration,
        primary.changes > 1 ? primary.minGap * 1e3 : 0,
        primary.changes > 1 ? primary.maxGap * 1e3 : 0))
    if let c = cursor {
        print(String(format: "RESULT cursor:  %d flips in %.1fs = %.2f/s",
                     c.changes, duration, Double(c.changes) / duration))
    }
    print(String(format: "RESULT poll cost: %.0f ns/poll (%d polls)",
                 pollCostNs / Double(max(polls, 1)), polls))
    close(fd)
    exit(0)
}

#endif
