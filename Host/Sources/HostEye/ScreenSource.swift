#if os(Linux)

import CDRM
import Glibc
import HostCore

/// One changed screen generation. The DRM framebuffer id stays private to
/// HostEye; consumers can only ask the source to turn it into a held ticket.
public struct ScreenSourceChange {
    fileprivate let framebufferId: UInt32
}

/// Capture organ above the operating system's display buffer. The direct-eye
/// implementation owns DRM device/plane lifetime and the FB_ID doorbell; a
/// future Lyte OS source can implement the same change → ticket contract.
public protocol ScreenSource: AnyObject {
    var width: Int32 { get }
    var height: Int32 { get }
    var fileDescriptor: Int32 { get }

    func poll() -> ScreenSourceChange?
    func capture(_ change: ScreenSourceChange) -> ScanoutTicket?
    func resetDoorbell()
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
    private var doorbell = ScreenDoorbell()

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

    public func poll() -> ScreenSourceChange? {
        switch doorbell.observe(currentFB(
            fd: fileDescriptor, planeId: primaryPlaneId)) {
        case .changed(let framebufferId):
            return ScreenSourceChange(framebufferId: framebufferId)
        case .unavailable, .held:
            return nil
        }
    }

    public func capture(_ change: ScreenSourceChange) -> ScanoutTicket? {
        grabTicket(fd: fileDescriptor, fbId: change.framebufferId)
    }

    public func resetDoorbell() {
        doorbell.reset()
    }
}

#endif
