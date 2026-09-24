import SwiftUI
import LyteUI

/// The Lyte app: each window is one connection; a new window opens in the
/// connect state and becomes a stream.
@main
struct LyteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
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
                autoconnect:
                    ProcessInfo.processInfo.environment["LYTE_AUTOCONNECT"])
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
        // Refresh (not just ensure) the AWDL helper registration: a
        // rebuilt binary's stale LWCR otherwise EX_CONFIGs every spawn.
        Task.detached(priority: .utility) {
            HelperClient.refreshRegistration()
        }
    }
}
