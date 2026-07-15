import Foundation
import ServiceManagement
import LyteHelperProtocol

/// App-side face of the privileged helper: registration via SMAppService
/// (one-time user approval in System Settings → Login Items) and the XPC
/// calls that bracket each stream. Fails soft everywhere — streaming never
/// depends on the helper; it just sounds better with it.
@MainActor
final class HelperClient {
    static let shared = HelperClient()

    private let service = SMAppService.daemon(plistName: LyteHelper.plistName)
    private var connection: NSXPCConnection?
    private(set) var engaged = false
    private var promptedThisRun = false

    var status: SMAppService.Status { service.status }

    /// Try to register at app launch; quiet no-op when already enabled.
    func registerIfNeeded() {
        switch service.status {
        case .notRegistered, .notFound:
            try? service.register()   // may flip straight to enabled or requiresApproval
        default:
            break
        }
    }

    /// Called when a stream starts. Returns a user-facing hint when the
    /// helper needs approval, nil otherwise.
    func streamBegan() -> String? {
        registerIfNeeded()
        switch service.status {
        case .enabled:
            proxy()?.streamBegan()
            engaged = true
            return nil
        case .requiresApproval:
            if !promptedThisRun {
                promptedThisRun = true
                SMAppService.openSystemSettingsLoginItems()
            }
            return "Approve the Lyte helper in System Settings → Login Items to auto-quiet AWDL (+~50 ms smoother audio)"
        default:
            return nil
        }
    }

    func streamEnded() {
        guard engaged else { return }
        proxy()?.streamEnded()
        engaged = false
    }

    private func proxy() -> LyteHelperCommands? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: LyteHelper.machServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: LyteHelperCommands.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                    self?.engaged = false
                }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxy as? LyteHelperCommands
    }
}
