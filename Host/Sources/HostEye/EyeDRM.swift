// The kernel-facing half of the direct eye: plane discovery, the FB_ID
// import identity, and the scanout ticket (GETFB2 + dmabuf export).

#if os(Linux)

import CDRM
import Foundation
import Glibc

/// Opens a primary (card) node for observation, never as its master.
/// The kernel makes an opener the master whenever the node has none, and
/// a compositor starting after that (the greeter at boot, the user's
/// shell at login) could not take the display. Observation needs no
/// master: GETFB2 needs CAP_SYS_ADMIN, and the fd stays authenticated.
/// Returns -1 with `errno` set when the open fails.
public func openCardWithoutMaster(_ path: String) -> Int32 {
    let fd = open(path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return -1 }
    if drmIsMaster(fd) != 0 { _ = drmDropMaster(fd) }
    return fd
}

/// The render node of the GPU behind an open card fd — on a multi-GPU
/// host the one that can import this card's scanout. Nil when the
/// driver exposes none (a scanout-only device).
public func renderNode(forCard fd: Int32) -> String? {
    guard let name = drmGetRenderDeviceNameFromFd(fd) else { return nil }
    defer { free(name) }
    return String(cString: name)
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

/// A plane's FB_ID as the kernel reports it: nil when the plane cannot
/// be read, 0 when it scans out nothing (detached or disabled).
public func planeFramebuffer(fd: Int32, planeId: UInt32) -> UInt32? {
    guard let plane = drmModeGetPlane(fd, planeId) else { return nil }
    defer { drmModeFreePlane(plane) }
    return plane.pointee.fb_id
}

/// Current non-zero FB_ID of a plane — an import-cache key, not damage
/// evidence. nil covers both "unreadable" and "scans out nothing".
public func currentFB(fd: Int32, planeId: UInt32) -> UInt32? {
    guard let framebufferId = planeFramebuffer(fd: fd, planeId: planeId),
          framebufferId != 0
    else { return nil }
    return framebufferId
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

    /// The first plane's buffer as the kernel knows it: the dma-buf's
    /// inode. Every export of one buffer object shares one dma-buf, so it
    /// names the buffer whatever fd or framebuffer id carries it. Nil
    /// when it cannot be read.
    public var bufferIdentity: UInt64? {
        guard let first = planes.first else { return nil }
        var status = stat()
        guard fstat(first.fd, &status) == 0 else { return nil }
        return UInt64(status.st_ino)
    }

    public func release() {
        for p in planes { close(p.fd) }
    }
}

/// GETFB2 + PRIME export (privileged). nil on a stale fb id (freed
/// between poll and grab); the caller skips.
///
/// GETFB2 opens a GEM handle per plane's buffer object; the dmabuf fds
/// keep the BOs alive on their own, so every unique non-zero handle is
/// closed before return on every path. An unclosed handle pins its BO for
/// the life of the fd.
public func grabTicket(fd: Int32, fbId: UInt32) -> ScanoutTicket? {
    guard let fb2 = drmModeGetFB2(fd, fbId) else { return nil }
    defer { drmModeFreeFB2(fb2) }
    let fb = fb2.pointee
    let handles = [fb.handles.0, fb.handles.1, fb.handles.2, fb.handles.3]
    let offsets = [fb.offsets.0, fb.offsets.1, fb.offsets.2, fb.offsets.3]
    let pitches = [fb.pitches.0, fb.pitches.1, fb.pitches.2, fb.pitches.3]
    defer { closeGemHandles(fd: fd, handles) }
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

/// The distinct non-zero GEM handles among a framebuffer's planes, in
/// first-seen order. Multi-plane formats (CCS aux planes, NV12 in one
/// BO) repeat a handle; each handle is one reference and closes once.
func uniqueGemHandles(_ handles: [UInt32]) -> [UInt32] {
    var unique: [UInt32] = []
    for handle in handles where handle != 0 && !unique.contains(handle) {
        unique.append(handle)
    }
    return unique
}

private func closeGemHandles(fd: Int32, _ handles: [UInt32]) {
    for handle in uniqueGemHandles(handles) {
        _ = drmCloseBufferHandle(fd, handle)
    }
}

#endif
