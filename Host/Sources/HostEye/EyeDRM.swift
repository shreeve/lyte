// EyeDRM: the kernel-facing half of the direct eye — plane discovery,
// the FB_ID doorbell (milestone 1), and the scanout ticket (GETFB2 +
// dmabuf export, milestone 2). All libdrm via the CDRM module map.

#if os(Linux)

import CDRM
import Foundation
import Glibc

public func nowSeconds() -> Double {
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

public struct ActivePlanes {
    public var primary: (id: UInt32, fb: UInt32)
    public var cursor: (id: UInt32, fb: UInt32)?
}

/// The active primary (and cursor) planes on a live CRTC.
public func findActivePlanes(fd: Int32) -> ActivePlanes? {
    guard let planeRes = drmModeGetPlaneResources(fd) else { return nil }
    defer { drmModeFreePlaneResources(planeRes) }
    var primary: (UInt32, UInt32)?
    var cursor: (UInt32, UInt32)?
    for i in 0..<Int(planeRes.pointee.count_planes) {
        guard let plane = drmModeGetPlane(fd, planeRes.pointee.planes[i])
        else { continue }
        defer { drmModeFreePlane(plane) }
        let p = plane.pointee
        guard p.crtc_id != 0, p.fb_id != 0,
              let type = planeType(fd: fd, planeId: p.plane_id)
        else { continue }
        if type == UInt64(DRM_PLANE_TYPE_PRIMARY), primary == nil {
            primary = (p.plane_id, p.fb_id)
        } else if type == UInt64(DRM_PLANE_TYPE_CURSOR), cursor == nil {
            cursor = (p.plane_id, p.fb_id)
        }
    }
    guard let prim = primary else { return nil }
    return ActivePlanes(primary: prim, cursor: cursor)
}

/// Current FB_ID of a plane — the doorbell's one register read.
public func currentFB(fd: Int32, planeId: UInt32) -> UInt32? {
    guard let plane = drmModeGetPlane(fd, planeId) else { return nil }
    defer { drmModeFreePlane(plane) }
    return plane.pointee.fb_id
}

/// One grabbed scanout frame: geometry plus per-plane dmabufs. The
/// dmabuf fds hold the buffer alive even if the compositor releases
/// the fb id mid-frame — close() them via release() after import.
public struct ScanoutTicket {
    public var width: UInt32
    public var height: UInt32
    public var fourcc: UInt32
    public var modifier: UInt64
    public var planes: [(fd: Int32, offset: UInt32, pitch: UInt32)]

    public func release() {
        for p in planes { close(p.fd) }
    }
}

/// GETFB2 + PRIME export (privileged). nil on a stale fb id — the
/// compositor flipped and freed between poll and grab; caller skips.
public func grabTicket(fd: Int32, fbId: UInt32) -> ScanoutTicket? {
    guard let fb2 = drmModeGetFB2(fd, fbId) else { return nil }
    defer { drmModeFreeFB2(fb2) }
    let fb = fb2.pointee
    let handles = [fb.handles.0, fb.handles.1, fb.handles.2, fb.handles.3]
    let offsets = [fb.offsets.0, fb.offsets.1, fb.offsets.2, fb.offsets.3]
    let pitches = [fb.pitches.0, fb.pitches.1, fb.pitches.2, fb.pitches.3]
    var planes: [(fd: Int32, offset: UInt32, pitch: UInt32)] = []
    for i in 0..<4 where handles[i] != 0 {
        var primeFd: Int32 = -1
        guard drmPrimeHandleToFD(
            fd, handles[i], UInt32(O_CLOEXEC), &primeFd) == 0
        else {
            for p in planes { close(p.fd) }
            return nil
        }
        planes.append((primeFd, offsets[i], pitches[i]))
    }
    guard !planes.isEmpty else { return nil }
    return ScanoutTicket(
        width: fb.width, height: fb.height, fourcc: fb.pixel_format,
        modifier: fb.modifier, planes: planes)
}

#endif
