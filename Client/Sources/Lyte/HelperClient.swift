import Foundation
import ServiceManagement
import LyteHelperProtocol
import LyteHelperSecurity
import Synchronization

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
    /// A hold was asked for during the current stream. Its end always
    /// reaches the helper, over a fresh connection if the old one died:
    /// launchd then respawns a helper that was killed mid-hold, and its
    /// startup reconcile restores the radio.
    private var heldThisStream = false
    private var promptedThisRun = false

    /// The requirement the helper must satisfy, derived from this app's own
    /// designated requirement; nil for an unsigned or unexpectedly signed
    /// build, which then never registers or talks to a root helper.
    nonisolated static let helperRequirement: String? =
        try? HelperClientRequirement.helperRequirementForCurrentProcess()

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

    /// App-launch registration; `HelperRegistration` owns the rules.
    nonisolated static func registerIfNeeded() {
        // SMAppService does synchronous BTM/XPC work; keep it off the
        // MainActor with a local service handle.
        let service = SMAppService.daemon(plistName: LyteHelper.plistName)
        let requirement = helperRequirement
        let embeddedHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/lyte-helperd")
        let outcome = HelperRegistration(
            expectedVersion: LyteHelper.version,
            status: {
                switch service.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notFound: .notFound
                default: .notRegistered
                }
            },
            probeVersion: { requirement.flatMap(probeVersion) },
            validateEmbeddedHelper: {
                guard let requirement else {
                    throw HelperClientRequirementError
                        .unexpectedDesignatedRequirement
                }
                try HelperClientRequirement.validateStaticCode(
                    at: embeddedHelper, satisfies: requirement)
            },
            unregister: { try service.unregister() },
            register: { try service.register() }
        ).run()
        NSLog("lyte helper: registration \(outcome), status "
            + "\(service.status.rawValue)")
    }

    /// Asks the registered helper for its version over a connection that
    /// accepts only a helper satisfying `requirement`. Blocking, bounded.
    nonisolated private static func probeVersion(
        requirement: String
    ) -> String? {
        let probe = NSXPCConnection(
            machServiceName: LyteHelper.machServiceName, options: .privileged)
        probe.remoteObjectInterface = NSXPCInterface(
            with: LyteHelperCommands.self)
        probe.setCodeSigningRequirement(requirement)
        probe.resume()
        defer { probe.invalidate() }
        let answer = VersionAnswer()
        let proxy = probe.remoteObjectProxyWithErrorHandler { _ in
            answer.finish(nil)
        } as? LyteHelperCommands
        proxy?.version { answer.finish($0) }
        return answer.wait(seconds: 5)
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
            heldThisStream = true
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
        guard heldThisStream else { return }
        proxy()?.streamEnded()
        engaged = false
        heldThisStream = false
    }

    private func proxy() -> LyteHelperCommands? {
        guard let requirement = Self.helperRequirement else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: LyteHelper.machServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: LyteHelperCommands.self)
            c.setCodeSigningRequirement(requirement)
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

/// One version probe's answer, taken at most once from any XPC queue.
private final class VersionAnswer: Sendable {
    private let value = Mutex<String??>(nil)
    private let done = DispatchSemaphore(value: 0)

    func finish(_ version: String?) {
        let first = value.withLock { stored -> Bool in
            guard stored == nil else { return false }
            stored = .some(version)
            return true
        }
        if first { done.signal() }
    }

    func wait(seconds: Int) -> String? {
        _ = done.wait(timeout: .now() + .seconds(seconds))
        return value.withLock { $0 ?? nil }
    }
}
