import Foundation
import ServiceManagement
import LyteHelperProtocol

/// App-side face of the privileged helper: registration via SMAppService
/// (one-time user approval in System Settings → Login Items) and the XPC
/// calls that bracket each stream. Fails soft everywhere — streaming never
/// depends on the helper; it just sounds better with it.
@MainActor
final class HelperClient {
    enum RegistrationPosture: Equatable {
        case ensure
        case existingOnly
    }

    static let shared = HelperClient()

    private let service = SMAppService.daemon(plistName: LyteHelper.plistName)
    private var connection: NSXPCConnection?
    private(set) var engaged = false
    private var promptedThisRun = false

    var status: SMAppService.Status { service.status }

    /// The ground truth the watchdog trusts: awdl0's own UP flag, read
    /// directly via getifaddrs (no privileges needed). The XPC call is
    /// fire-and-forget — a daemon that failed to spawn produces no
    /// error, only an interface that never went down; asking the
    /// interface is the only claim that cannot lie.
    nonisolated static func awdlIsUp() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let entry = cursor {
            if String(cString: entry.pointee.ifa_name) == "awdl0" {
                return (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            }
            cursor = entry.pointee.ifa_next
        }
        // No awdl0 at all (some Macs/configs): nothing to hold — treat
        // as "not up" so the watchdog stays silent.
        return false
    }

    var statusDescription: String {
        switch service.status {
        case .notRegistered: return "notRegistered — registration didn't stick"
        case .enabled: return "enabled — daemon ready"
        case .requiresApproval: return "requiresApproval — waiting for System Settings → Login Items"
        case .notFound: return "notFound — plist/binary missing from bundle or registration rejected"
        @unknown default: return "unknown (\(service.status.rawValue))"
        }
    }

    /// App-launch refresh: EVERY rebuild re-signs the helper, and the
    /// lightweight code requirement (LWCR) BTM stored at registration
    /// goes stale — launchd then refuses the spawn with EX_CONFIG
    /// forever ("needs LWCR update" in launchctl print; found live
    /// 2026-07-30 after 28,916 silent crash-loops). Unregister +
    /// re-register refreshes the LWCR; BTM keys the user's approval
    /// by identifier, so the toggle normally survives the cycle.
    nonisolated static func refreshRegistration() {
        // SMAppService performs synchronous BTM/XPC work and emits Apple's
        // main-thread performance diagnostic when called from app launch.
        // Registration is process-global; a local service handle keeps this
        // blocking refresh completely outside the MainActor.
        let refreshService = SMAppService.daemon(
            plistName: LyteHelper.plistName)
        try? refreshService.unregister()
        do {
            try refreshService.register()
            NSLog(
                "lyte helper: re-registered, status "
                    + "\(refreshService.status.rawValue)")
        } catch {
            NSLog("lyte helper: refresh register FAILED — \(error.localizedDescription)")
        }
    }

    /// Explicit registration entry point used by the headless maintenance
    /// command. Normal app launches use `refreshRegistration()` instead.
    /// A missing service means the app bundle is incomplete or disappeared;
    /// asking ServiceManagement to register that state crashes inside
    /// `_load_plist_from_bundle` on macOS 26.6, so it must fail soft here.
    func registerIfNeeded() {
        switch service.status {
        case .notRegistered:
            do {
                try service.register()   // may flip straight to enabled or requiresApproval
                NSLog("lyte helper: registered, status now \(service.status.rawValue)")
            } catch {
                NSLog("lyte helper: register FAILED — \(error.localizedDescription)")
            }
        case .notFound:
            NSLog("lyte helper: unavailable — embedded service is missing")
        default:
            NSLog("lyte helper: status \(service.status.rawValue) (0=notReg 1=enabled 2=requiresApproval 3=notFound)")
        }
    }

    /// Called when a stream starts. Returns a user-facing hint when the
    /// helper needs approval, nil otherwise.
    func streamBegan(
        registration: RegistrationPosture = .ensure
    ) -> String? {
        // Registration is app-lifecycle work, never stream-lifecycle work.
        // A stream may begin after an external build has removed the running
        // bundle from disk; querying status is safe, but registration is not.
        switch service.status {
        case .enabled:
            proxy()?.streamBegan()
            engaged = true
            return nil
        case .requiresApproval:
            guard registration == .ensure else { return nil }
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
            c.interruptionHandler = { [weak self, weak c] in
                c?.invalidate()
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
