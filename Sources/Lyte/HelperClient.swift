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

    var statusDescription: String {
        switch service.status {
        case .notRegistered: return "notRegistered — registration didn't stick"
        case .enabled: return "enabled — daemon ready"
        case .requiresApproval: return "requiresApproval — waiting for System Settings → Login Items"
        case .notFound: return "notFound — plist/binary missing from bundle or registration rejected"
        @unknown default: return "unknown (\(service.status.rawValue))"
        }
    }

    /// Try to register at app launch; no-op when already enabled.
    func registerIfNeeded() {
        switch service.status {
        case .notRegistered, .notFound:
            do {
                try service.register()   // may flip straight to enabled or requiresApproval
                NSLog("lyte helper: registered, status now \(service.status.rawValue)")
            } catch {
                NSLog("lyte helper: register FAILED — \(error.localizedDescription)")
            }
        default:
            NSLog("lyte helper: status \(service.status.rawValue) (0=notReg 1=enabled 2=requiresApproval 3=notFound)")
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
