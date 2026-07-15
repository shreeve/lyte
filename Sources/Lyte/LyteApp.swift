import SwiftUI
import LyteKit
import LyteUI

/// The Lyte app (M5): D6 window-is-the-app. Each window is one connection;
/// a new window opens in the connect state and becomes a stream.
@main
struct LyteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ConnectionWindow()
        }
        .defaultSize(width: 1024, height: 640)
        .commands {
            LyteCommands()
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
