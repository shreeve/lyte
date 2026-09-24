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

    /// awdl0's own UP flag, read via getifaddrs (no privileges needed).
    /// The XPC call is fire-and-forget, so a daemon that failed to spawn
    /// shows only as an interface that never went down.
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

    /// App-launch refresh: every rebuild re-signs the helper and stales
    /// the code requirement BTM stored at registration (launchd then
    /// refuses the spawn with EX_CONFIG). Unregister + re-register
    /// refreshes it; the user's approval normally survives the cycle.
    nonisolated static func refreshRegistration() {
        // SMAppService does synchronous BTM/XPC work; keep it off the
        // MainActor with a local service handle.
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

    /// Called when a stream starts. Returns a user-facing hint when the
    /// helper needs approval, nil otherwise.
    func streamBegan(
        registration: RegistrationPosture = .ensure
    ) -> String? {
        // Registration is app-lifecycle work: a stream may begin after an
        // external build removed the running bundle, so only query here.
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
            return "Approve the Lyte helper in System Settings → Login Items to quiet AWDL while streaming (smoother audio)"
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
            // Both handlers hop to the MainActor later; by then the
            // watchdog may have minted a newer connection, which a stale
            // handler must not clear.
            c.invalidationHandler = { [weak self, weak c] in
                Task { @MainActor in self?.forget(c) }
            }
            c.interruptionHandler = { [weak self, weak c] in
                c?.invalidate()
                Task { @MainActor in self?.forget(c) }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxy as? LyteHelperCommands
    }

    private func forget(_ dead: NSXPCConnection?) {
        guard let dead, connection === dead else { return }
        connection = nil
        engaged = false
    }
}
