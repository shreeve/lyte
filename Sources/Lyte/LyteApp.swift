import SwiftUI
import LyteUI

/// The Lyte app (M5): D6 window-is-the-app. Each window is one connection;
/// a new window opens in the connect state and becomes a stream.
@main
struct LyteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless helper registration: lets tooling (and CI) drive the
        // SMAppService dance without opening windows or streams.
        if CommandLine.arguments.contains("--register-helper") {
            HelperClient.shared.registerIfNeeded()
            print("helper status: \(HelperClient.shared.statusDescription)")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup(id: "connection") {
            ConnectionWindow()
        }
        .defaultSize(width: 1024, height: 640)
        .commands {
            LyteCommands()
        }

        // The agent (A0): always-on menu-bar presence — status, new
        // connections, resume, and the future host toggle.
        MenuBarExtra("Lyte", systemImage: "bolt.fill") {
            AgentMenu()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unbundled dev builds inherit the launcher's identity otherwise
        ProcessName.set("Lyte")
        NSApp.applicationIconImage = AppIcon.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quietly register the AWDL helper; approval happens at first stream
        HelperClient.shared.registerIfNeeded()
    }
}
