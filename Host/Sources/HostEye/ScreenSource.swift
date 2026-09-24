#if os(Linux)

import CDRM
import Glibc
import HostCore
import LyteIO

/// One observation of the currently scanned primary buffer. Identity is an
/// import-cache key, never evidence that its pixels are unchanged: Mutter may
/// render new pixels into the same framebuffer for minutes.
public struct ScreenSourceObservation {
    public let framebufferIdentity: UInt32
    public let identityChanged: Bool
}

/// Capture organ above the operating system's display buffer. The direct-eye
/// implementation owns DRM device/plane lifetime. Framebuffer identity says
/// when an imported scanout must be replaced; only pixel observation can say
/// whether content changed.
public protocol ScreenSource: AnyObject {
    var width: Int32 { get }
    var height: Int32 { get }
    var fileDescriptor: Int32 { get }

    func observe() -> ScreenSourceObservation?
    func capture(_ observation: ScreenSourceObservation) -> ScanoutTicket?
}

/// When a primary plane that stopped scanning out is worth finding
/// again: DPMS-off and a moved output both read as "no framebuffer", and
/// only a plane scan tells them apart. A scan per beat would enumerate
/// every plane 60 times a second, so it runs once per `intervalNS` of
/// unavailability.
struct PlaneRecheckClock {
    static let intervalNS: UInt64 = 3_000_000_000
    private var dueNS: UInt64?

    mutating func available() { dueNS = nil }

    /// True when a scan is due now.
    mutating func unavailable(now: UInt64) -> Bool {
        guard let due = dueNS else {
            dueNS = now + Self.intervalNS
            return false
        }
        guard now >= due else { return false }
        dueNS = now + Self.intervalNS
        return true
    }
}

public enum DirectScreenSourceError: Error, CustomStringConvertible {
    case openDevice(path: String, errno: Int32)
    case noActivePrimaryPlane(path: String)
    case initialTicketDenied(path: String)

    public var description: String {
        switch self {
        case .openDevice(let path, let code):
            return "open(\(path)) errno \(code)"
        case .noActivePrimaryPlane(let path):
            return "no active primary plane on \(path)"
        case .initialTicketDenied(let path):
            return "GETFB2 refused on \(path) — capture needs CAP_SYS_ADMIN"
        }
    }
}

/// The one DRM/KMS screen source used by both the production direct eye and
/// the standalone capture witness.
public final class DirectScreenSource: ScreenSource {
    public let width: Int32
    public let height: Int32
    public let fileDescriptor: Int32
    /// The card node this source observes.
    public let device: String
    /// The render node of the same GPU, which imports, blits and
    /// encodes this card's scanout.
    public let renderNode: String
    /// The driver named no render node for the card, so `renderNode` is
    /// `fallbackRenderNode`, which may belong to another GPU.
    public let renderNodeIsFallback: Bool
    /// This source is the card's DRM master and could not drop it (see
    /// `openCardWithoutMaster`).
    public let keptMaster: Bool

    private let primaryPlaneId: UInt32
    private var identityTracker = FramebufferIdentityTracker()
    private var planeRecheck = PlaneRecheckClock()
    /// The output now scans out from another primary plane (a hotplug,
    /// or the compositor re-assigning pipes): this source can observe
    /// nothing more, and the caller ends the session as for a mode change.
    public private(set) var primaryPlaneMoved = false

    /// Where the render node comes from when the driver names none.
    public static let fallbackRenderNode = "/dev/dri/renderD128"

    public init(device: String) throws {
        var keptMaster = false
        let fd = openCardWithoutMaster(device, keptMaster: &keptMaster)
        guard fd >= 0 else {
            throw DirectScreenSourceError.openDevice(
                path: device, errno: errno)
        }
        // UNIVERSAL_PLANES exposes cursor planes; ATOMIC exposes the
        // CRTC_X/Y props the cursor hotspot derivation needs.
        drmSetClientCap(
            fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
        drmSetClientCap(
            fd, UInt64(DRM_CLIENT_CAP_ATOMIC), 1)
        guard let planes = findActivePlanes(fd: fd) else {
            close(fd)
            throw DirectScreenSourceError.noActivePrimaryPlane(path: device)
        }
        guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
            close(fd)
            throw DirectScreenSourceError.initialTicketDenied(path: device)
        }

        fileDescriptor = fd
        self.device = device
        let named = HostEye.renderNode(forCard: fd)
        renderNode = named ?? Self.fallbackRenderNode
        renderNodeIsFallback = named == nil
        self.keptMaster = keptMaster
        primaryPlaneId = planes.primary.id
        width = Int32(probe.width)
        height = Int32(probe.height)
        probe.release()
    }

    deinit {
        close(fileDescriptor)
    }

    public func observe() -> ScreenSourceObservation? {
        let framebuffer = currentFB(
            fd: fileDescriptor, planeId: primaryPlaneId)
        if framebuffer != nil { planeRecheck.available() }
        switch identityTracker.observe(framebuffer) {
        case .changed(let framebufferId):
            return ScreenSourceObservation(
                framebufferIdentity: framebufferId,
                identityChanged: true)
        case .held:
            guard let framebuffer else { return nil }
            return ScreenSourceObservation(
                framebufferIdentity: framebuffer,
                identityChanged: false)
        case .unavailable:
            // DPMS-off also scans out nothing and must keep waiting; only
            // a live primary plane elsewhere means the output moved.
            if planeRecheck.unavailable(
                   now: SystemMonotonicClock.nowNanoseconds),
               let planes = findActivePlanes(fd: fileDescriptor),
               planes.primary.id != primaryPlaneId {
                primaryPlaneMoved = true
            }
            return nil
        }
    }

    public func capture(
        _ observation: ScreenSourceObservation
    ) -> ScanoutTicket? {
        grabTicket(
            fd: fileDescriptor, fbId: observation.framebufferIdentity)
    }
}

#endif
