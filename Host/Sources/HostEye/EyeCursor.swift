// The cursor half of the direct eye. The hardware cursor plane never
// touches encoded frames (cursor motion produces zero video frames).
// This watcher polls the plane's FB_ID like the primary doorbell; on
// change it reads the LINEAR ARGB8888 cursor buffer (GETFB2 + PRIME +
// mmap), crops it to the content box and hands the BGRA image up.
// HostCore.CursorHotspot recovers the hotspot (i915 exposes no
// HOTSPOT_X/Y). CRTC_X/Y require DRM_CLIENT_CAP_ATOMIC on the DRM fd.

#if os(Linux)

import CDRM
import Glibc

/// A named property's current value on a plane. Values are raw UInt64;
/// CRTC_X/CRTC_Y carry signed positions, bit-cast by the caller.
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
    /// The plane's position on the CRTC when grabbed (device pixels;
    /// negative when overhanging the top-left edge). `nil` when CRTC_X/Y
    /// props are absent; never substitute `(0,0)`, a real position.
    public var planeCrtc: (x: Int, y: Int)?
    /// width*height*4 BGRA bytes, rows top-to-bottom, tightly packed.
    public var pixels: [UInt8]
}

public enum CursorPoll {
    /// Same fb as last poll.
    case unchanged
    /// The plane holds fb 0 (or the buffer is fully transparent).
    case hidden
    case shape(CursorFrame)
    /// Grab/import failed this round; the fb does not latch, so the next
    /// poll retries it.
    case failed(String)
}

/// The cursor plane's framebuffer transitions, separated from the
/// reads. Each transition reports once: fb 0 (the plane disabled — a
/// hidden pointer or a software-cursor fallback) is `.hidden`, a new
/// non-zero fb is `.read` and latches only when the caller's read
/// succeeds (a failed read retries on the next poll). An unreadable
/// plane changes nothing.
struct CursorFramebufferLatch {
    enum Step: Equatable {
        case unchanged
        case hidden
        case read(UInt32)
    }

    private(set) var last: UInt32?

    mutating func observe(_ framebuffer: UInt32?) -> Step {
        guard let framebuffer, framebuffer != last else { return .unchanged }
        if framebuffer == 0 {
            last = 0
            return .hidden
        }
        return .read(framebuffer)
    }

    mutating func latch(_ framebuffer: UInt32) { last = framebuffer }
}

/// Watches one cursor plane. Poll at the doorbell cadence; the steady
/// state costs one drmModeGetPlane read.
public final class EyeCursorWatcher {
    private let fd: Int32
    public let planeId: UInt32
    private var latch = CursorFramebufferLatch()

    /// Finds the cursor plane, preferring one live on a CRTC (an
    /// inactive plane's first nonzero fb is its first shape). nil when
    /// the device has none.
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

    /// The plane's current CRTC position from atomic property state
    /// (the legacy ioctl does not fill crtc_x/y). Requires
    /// `DRM_CLIENT_CAP_ATOMIC`; nil without it, never `(0,0)`.
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
        let fb: UInt32
        switch latch.observe(planeFramebuffer(fd: fd, planeId: planeId)) {
        case .unchanged: return .unchanged
        case .hidden: return .hidden
        case .read(let framebuffer): fb = framebuffer
        }
        switch readCursorFB(fb) {
        case .success(let frame):
            latch.latch(fb)
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

    /// GETFB2 → PRIME → mmap → crop. Anything but LINEAR ARGB8888 fails
    /// loudly.
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
                format: """
                    cursor fb %u is not linear ARGB8888 \
                    (fourcc %08x, modifier %llx)
                    """,
                fb, ticket.fourcc, ticket.modifier))
        }
        let width = Int(ticket.width), height = Int(ticket.height)
        let pitch = Int(plane.pitch)
        let mapLength = Int(plane.offset) + pitch * height
        guard let base = mmap(
            nil, mapLength, PROT_READ, MAP_SHARED, plane.fd, 0),
            base != MAP_FAILED else {
            return .failure("mmap of cursor dmabuf failed (errno \(errno))")
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

    /// Best-effort DMA_BUF_IOCTL_SYNC bracketing for the CPU read.
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
