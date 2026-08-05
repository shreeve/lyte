#if os(Linux)

import CDRM
import Glibc
import HostCore

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
    func resetIdentityObservation()
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

    private let primaryPlaneId: UInt32
    private var identityTracker = FramebufferIdentityTracker()

    public init(device: String) throws {
        let fd = open(device, O_RDWR)
        guard fd >= 0 else {
            throw DirectScreenSourceError.openDevice(
                path: device, errno: errno)
        }
        drmSetClientCap(
            fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
        guard let planes = findActivePlanes(fd: fd) else {
            close(fd)
            throw DirectScreenSourceError.noActivePrimaryPlane(path: device)
        }
        guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
            close(fd)
            throw DirectScreenSourceError.initialTicketDenied(path: device)
        }

        fileDescriptor = fd
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
            return nil
        }
    }

    public func capture(
        _ observation: ScreenSourceObservation
    ) -> ScanoutTicket? {
        grabTicket(
            fd: fileDescriptor, fbId: observation.framebufferIdentity)
    }

    public func resetIdentityObservation() {
        identityTracker.reset()
    }
}

#endif
