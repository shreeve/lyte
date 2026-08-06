// EyeCursor: the cursor half of the direct eye (E3). The hardware
// cursor plane never touches the encoded frames — by design (cursor
// motion produces zero video frames). This watcher polls the plane's
// FB_ID exactly like the primary doorbell; on change it reads the
// LINEAR ARGB8888 cursor buffer (GETFB2 + PRIME + mmap — CPU-readable,
// unlike the primary's CCS scanout), crops it to the content box
// (cursor buffers are mostly transparent padding), and hands the
// tight BGRA image up. Hotspot derivation lives in HostCore.CursorHotspot:
// i915 exposes no HOTSPOT_X/Y plane props, so the hotspot is recovered
// from (last injected pointer − plane CRTC − crop). CRTC_X/Y require
// DRM_CLIENT_CAP_ATOMIC on the shared DRM fd.

#if os(Linux)

import CDRM
import Glibc

/// A named property's current value on a plane (the planeType read,
/// generalized). Values are raw UInt64 — CRTC_X/CRTC_Y carry signed
/// positions, bit-cast by the caller.
func planePropValue(
    fd: Int32, planeId: UInt32, name: String
) -> UInt64? {
    guard let props = drmModeObjectGetProperties(
        fd, planeId, UInt32(DRM_MODE_OBJECT_PLANE))
    else { return nil }
    defer { drmModeFreeObjectProperties(props) }
    for i in 0..<Int(props.pointee.count_props) {
        guard let prop = drmModeGetProperty(fd, props.pointee.props[i])
        else { continue }
        defer { drmModeFreeProperty(prop) }
        let propName = withUnsafeBytes(of: prop.pointee.name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(
                to: CChar.self))
        }
        if propName == name { return props.pointee.prop_values[i] }
    }
    return nil
}

/// One read cursor image: the content-cropped BGRA pixels plus where
/// the crop sits — in the buffer (cropX/Y, the hotspot's shift) and
/// on screen (planeCrtc at grab time, the hotspot's anchor).
public struct CursorFrame {
    public var width: Int
    public var height: Int
    /// The content box's origin inside the full cursor buffer.
    public var cropX: Int
    public var cropY: Int
    /// The PLANE's position on the CRTC when grabbed (device pixels;
    /// negative when the cursor overhangs the top-left edge). `nil`
    /// when CRTC_X/Y props are absent — the caller must not invent
    /// `(0,0)`, which is indistinguishable from a real origin park
    /// and was the E3 tip/hotspot mismatch.
    public var planeCrtc: (x: Int, y: Int)?
    /// width*height*4 BGRA bytes, rows top-to-bottom, tightly packed.
    public var pixels: [UInt8]
}

public enum CursorPoll {
    /// Same fb as last poll — nothing to do (the steady state).
    case unchanged
    /// The plane holds fb 0 (or the buffer is fully transparent).
    case hidden
    case shape(CursorFrame)
    /// Grab/import failed this round; retried on the next fb change.
    case failed(String)
}

/// Watches one cursor plane. Poll at the doorbell cadence — the
/// steady-state cost is the same single drmModeGetPlane read as the
/// primary doorbell (~4 µs).
public final class EyeCursorWatcher {
    private let fd: Int32
    public let planeId: UInt32
    private var lastFB: UInt32?

    /// Finds the cursor plane (type CURSOR, preferring one live on a
    /// CRTC — an inactive plane still watches correctly: its first
    /// nonzero fb is the first shape). nil when the device has none.
    public init?(fd: Int32) {
        self.fd = fd
        guard let planeRes = drmModeGetPlaneResources(fd) else {
            return nil
        }
        defer { drmModeFreePlaneResources(planeRes) }
        var found: (id: UInt32, live: Bool)?
        for i in 0..<Int(planeRes.pointee.count_planes) {
            guard let plane = drmModeGetPlane(
                fd, planeRes.pointee.planes[i])
            else { continue }
            defer { drmModeFreePlane(plane) }
            let p = plane.pointee
            guard planeType(fd: fd, planeId: p.plane_id)
                == UInt64(DRM_PLANE_TYPE_CURSOR) else { continue }
            let live = p.crtc_id != 0
            if found == nil || (live && found?.live == false) {
                found = (p.plane_id, live)
            }
        }
        guard let cursor = found else { return nil }
        self.planeId = cursor.id
    }

    /// The plane's current CRTC position (atomic property state —
    /// drmModeGetPlane's crtc_x/y fields are NOT filled by the legacy
    /// ioctl). Requires `DRM_CLIENT_CAP_ATOMIC` on the fd; without it
    /// the props are absent and this returns nil. nil must stay nil —
    /// collapsing to `(0,0)` is the tip/hotspot mismatch.
    public func planeCrtcPosition() -> (x: Int, y: Int)? {
        guard let rawX = planePropValue(
                  fd: fd, planeId: planeId, name: "CRTC_X"),
              let rawY = planePropValue(
                  fd: fd, planeId: planeId, name: "CRTC_Y")
        else { return nil }
        return (Int(Int64(bitPattern: rawX)),
                Int(Int64(bitPattern: rawY)))
    }

    /// One doorbell-cadence poll. Reports each fb transition once; a
    /// failed grab does not latch the fb, so the next poll retries.
    public func poll() -> CursorPoll {
        guard let fb = currentFB(fd: fd, planeId: planeId) else {
            return .unchanged
        }
        guard fb != lastFB else { return .unchanged }
        if fb == 0 {
            lastFB = 0
            return .hidden
        }
        switch readCursorFB(fb) {
        case .success(let frame):
            lastFB = fb
            // A buffer of pure transparent padding IS the hidden
            // state (some themes "hide" by uploading empty).
            return frame.map(CursorPoll.shape) ?? .hidden
        case .failure(let why):
            return .failed(why)
        }
    }

    private enum ReadResult {
        case success(CursorFrame?)
        case failure(String)
    }

    /// GETFB2 → PRIME → mmap → crop. Cursor buffers are LINEAR
    /// ARGB8888 (the KMS cursor contract on i915); anything else is a
    /// loud failure, not a guess.
    private func readCursorFB(_ fb: UInt32) -> ReadResult {
        guard let ticket = grabTicket(fd: fd, fbId: fb) else {
            return .failure("GETFB2/PRIME failed for cursor fb \(fb)")
        }
        defer { ticket.release() }
        // 'AR24' little-endian fourcc = ARGB8888 = BGRA byte order.
        let AR24: UInt32 = 0x3432_5241
        guard ticket.fourcc == AR24, ticket.modifier == 0,
              let plane = ticket.planes.first else {
            return .failure(String(
                format: "cursor fb %u is not linear ARGB8888 "
                    + "(fourcc %08x, modifier %llx)",
                fb, ticket.fourcc, ticket.modifier))
        }
        let width = Int(ticket.width), height = Int(ticket.height)
        let pitch = Int(plane.pitch)
        let mapLength = Int(plane.offset) + pitch * height
        guard let base = mmap(
            nil, mapLength, PROT_READ, MAP_SHARED, plane.fd, 0),
            base != MAP_FAILED else {
            return .failure("mmap of cursor dmabuf failed "
                + "(errno \(errno))")
        }
        defer { munmap(base, mapLength) }
        dmabufSync(plane.fd, start: true)
        defer { dmabufSync(plane.fd, start: false) }
        let bytes = base.advanced(by: Int(plane.offset))
            .assumingMemoryBound(to: UInt8.self)

        // The content box: rows/columns with any nonzero alpha
        // (BGRA — alpha at byte 3 of each pixel).
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = bytes.advanced(by: y * pitch)
            for x in 0..<width where row[x * 4 + 3] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return .success(nil) // fully transparent — hidden
        }
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: cw * ch * 4)
        pixels.withUnsafeMutableBytes { dst in
            for y in 0..<ch {
                let src = bytes.advanced(
                    by: (minY + y) * pitch + minX * 4)
                memcpy(dst.baseAddress!.advanced(by: y * cw * 4),
                       src, cw * 4)
            }
        }
        return .success(CursorFrame(
            width: cw, height: ch, cropX: minX, cropY: minY,
            planeCrtc: planeCrtcPosition(),
            pixels: pixels))
    }

    /// DMA_BUF_IOCTL_SYNC bracketing for the CPU read — best-effort
    /// (cursor buffers are CPU-uploaded and coherent on this
    /// hardware; the sync is correctness insurance, not a gate).
    private func dmabufSync(_ fd: Int32, start: Bool) {
        // _IOW('b', 0, __u64): dir=write(1)<<30 | size 8<<16 |
        // 'b'(0x62)<<8 | nr 0.
        let DMA_BUF_IOCTL_SYNC: UInt = 0x4008_6200
        let READ: UInt64 = 1 << 0
        let START: UInt64 = 0, END: UInt64 = 1 << 2
        var flags = READ | (start ? START : END)
        _ = ioctl(fd, DMA_BUF_IOCTL_SYNC, &flags)
    }
}

#endif
