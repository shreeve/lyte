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

    /// App-launch refresh: every rebuild re-signs the helper, and the
    /// lightweight code requirement (LWCR) BTM stored at registration
    /// goes stale — launchd then refuses the spawn with EX_CONFIG
    /// ("needs LWCR update" in launchctl print). Unregister + re-register
    /// refreshes the LWCR; BTM keys the user's approval by identifier, so
    /// the toggle normally survives the cycle.
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
