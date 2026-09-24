import SwiftUI
import LyteUI

/// The Lyte app: each window is one connection; a new window opens in the
/// connect state and becomes a stream.
@main
struct LyteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if !DiagnosticEnvironment.isEnabled,
           ProcessInfo.processInfo.environment.keys.contains(where: {
               $0 == "LYTE_AUTOCONNECT" || $0.hasPrefix("LYTE_BENCHMARK_")
           })
        {
            NSLog("lyte: diagnostic environment ignored — this bundle was "
                + "built without LYTE_APP_DIAGNOSTICS=1")
        }
        do {
            _ = try DiagnosticRunIdentity.publishIfRequested()
        } catch {
            fputs(
                "lyte benchmark identity: \(error.localizedDescription)\n",
                stderr)
            exit(74)
        }
    }

    var body: some Scene {
        WindowGroup(id: "connection") {
            ConnectionWindow(
                autoconnect: DiagnosticEnvironment.current["LYTE_AUTOCONNECT"])
        }
        .defaultSize(width: 1024, height: 640)
        .commands {
            LyteCommands()
        }

        // The always-on menu-bar presence: status and new connections.
        MenuBarExtra("Lyte", systemImage: "bolt.fill") {
            AgentMenu()
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DiagnosticRunIdentity.isRequested else { return }
        Task.detached(priority: .utility) {
            HelperClient.registerIfNeeded()
        }
    }

    /// Quitting ends every window's session with the typed goodbye; the
    /// app waits for those closes (their ACK linger), boundedly, so no
    /// host keeps pacing video at a dead port until its liveness timeout.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        OpenConnections.shared.disconnectAll()
        SessionCloses.shared.whenDrained(within: .seconds(1)) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Every connection window's model, held weakly, so termination can end
/// each window's session.
@MainActor
final class OpenConnections {
    static let shared = OpenConnections()

    private let models = NSHashTable<ConnectionModel>.weakObjects()

    func insert(_ model: ConnectionModel) {
        models.add(model)
    }

    func disconnectAll() {
        for model in models.allObjects { model.disconnect() }
    }
}
