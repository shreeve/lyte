// lyte-eye (direct-eye plan E0, milestone 1): the doorbell, in Swift.
//
// A faithful port of the proven C probe (Host/Probes/kms-eye/
// fbid-poll.c, results in that directory's README): poll the active
// primary plane's FB_ID — the compositor flips a NEW framebuffer iff
// it repainted, so an unchanged ID is proof that zero pixels changed.
// Damage detection recovered from below, unprivileged, wedge-proof.
//
// This file doubles as the E0 proof that the eye needs no .c files:
// libdrm arrives through the CDRM module map and every call below is
// a direct C call in Swift dress. Output format matches the C probe
// so runs are comparable line-for-line.
//
// Usage: lyte-eye [device] [seconds] [poll_interval_us]

import Foundation

#if os(Linux)
import CDRM
import Glibc

func nowSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// The DRM "type" property of a plane (primary / overlay / cursor).
func planeType(fd: Int32, planeId: UInt32) -> UInt64? {
    guard let props = drmModeObjectGetProperties(
        fd, planeId, UInt32(DRM_MODE_OBJECT_PLANE))
    else { return nil }
    defer { drmModeFreeObjectProperties(props) }
    for i in 0..<Int(props.pointee.count_props) {
        guard let prop = drmModeGetProperty(fd, props.pointee.props[i])
        else { continue }
        defer { drmModeFreeProperty(prop) }
        let name = withUnsafeBytes(of: prop.pointee.name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(
                to: CChar.self))
        }
        if name == "type" { return props.pointee.prop_values[i] }
    }
    return nil
}

/// One watched plane: FB_ID transitions with gap statistics.
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

let device = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/dev/dri/card1"
let seconds = CommandLine.arguments.count > 2
    ? (Double(CommandLine.arguments[2]) ?? 15.0) : 15.0
let intervalUs = CommandLine.arguments.count > 3
    ? (UInt32(CommandLine.arguments[3]) ?? 1000) : 1000

let fd = open(device, O_RDWR)
guard fd >= 0 else {
    perror(device)
    exit(1)
}
drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)

guard let planeRes = drmModeGetPlaneResources(fd) else {
    FileHandle.standardError.write(Data("no plane resources\n".utf8))
    exit(1)
}
var primary: Watch?
var cursor: Watch?
for i in 0..<Int(planeRes.pointee.count_planes) {
    guard let plane = drmModeGetPlane(fd, planeRes.pointee.planes[i])
    else { continue }
    defer { drmModeFreePlane(plane) }
    let p = plane.pointee
    guard p.crtc_id != 0, p.fb_id != 0,
          let type = planeType(fd: fd, planeId: p.plane_id)
    else { continue }
    if type == UInt64(DRM_PLANE_TYPE_PRIMARY), primary == nil {
        primary = Watch(planeId: p.plane_id, lastFB: p.fb_id)
    } else if type == UInt64(DRM_PLANE_TYPE_CURSOR), cursor == nil {
        cursor = Watch(planeId: p.plane_id, lastFB: p.fb_id)
    }
}
drmModeFreePlaneResources(planeRes)

guard var primaryWatch = primary else {
    FileHandle.standardError.write(
        Data("no active primary plane on \(device)\n".utf8))
    exit(1)
}
var cursorWatch = cursor
print("device=\(device) primary_plane=\(primaryWatch.planeId) "
    + "cursor_plane=\(cursorWatch?.planeId ?? 0) "
    + "poll=\(intervalUs)us run=\(Int(seconds))s [swift]")

var polls = 0
var pollCostNs = 0.0
let t0 = nowSeconds()
var nextReport = t0 + 1.0
var primaryThisSecond = 0
var t = t0

func pollPlane(_ watch: inout Watch, at t: Double) -> Bool {
    guard let plane = drmModeGetPlane(fd, watch.planeId) else {
        return false
    }
    defer { drmModeFreePlane(plane) }
    return watch.observe(fb: plane.pointee.fb_id, at: t)
}

while true {
    t = nowSeconds()
    guard t - t0 < seconds else { break }
    let costStart = nowSeconds()
    if pollPlane(&primaryWatch, at: t) { primaryThisSecond += 1 }
    if cursorWatch != nil { _ = pollPlane(&cursorWatch!, at: t) }
    pollCostNs += (nowSeconds() - costStart) * 1e9
    polls += 1
    if t >= nextReport {
        print("  t=\(String(format: "%2.0f", t - t0))s "
            + "primary_flips_this_sec=\(primaryThisSecond) "
            + "total=\(primaryWatch.changes)")
        primaryThisSecond = 0
        nextReport += 1.0
    }
    usleep(intervalUs)
}

let duration = t - t0
print(String(
    format: "RESULT primary: %d flips in %.1fs = %.2f/s  "
        + "gap_min=%.1fms gap_max=%.1fms",
    primaryWatch.changes, duration,
    Double(primaryWatch.changes) / duration,
    primaryWatch.changes > 1 ? primaryWatch.minGap * 1e3 : 0,
    primaryWatch.changes > 1 ? primaryWatch.maxGap * 1e3 : 0))
if let c = cursorWatch {
    print(String(format: "RESULT cursor:  %d flips in %.1fs = %.2f/s",
                 c.changes, duration, Double(c.changes) / duration))
}
print(String(format: "RESULT poll cost: %.0f ns/poll (%d polls)",
             pollCostNs / Double(max(polls, 1)), polls))
close(fd)
#else
FileHandle.standardError.write(
    Data("lyte-eye is Linux-only (KMS/DRM).\n".utf8))
exit(1)
#endif
