import Sparkle
import SwiftUI

/// In-app updates through Sparkle (docs/RELEASING.md). Sparkle reads
/// `SUFeedURL` and `SUPublicEDKey` from Info.plist and owns every
/// user-facing moment: the first-run "check automatically?" prompt, the
/// update sheet, download, install on quit and relaunch. The app only
/// decides whether to start it and forwards Check for Updates….
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var started = false

    /// Only a bundle that carries a feed and a public key checks, and never
    /// a diagnostic build: `make-app.sh` writes both only into release
    /// bundles, so development builds stay silent, and a benchmark bundle
    /// must not offer to replace itself mid-run.
    nonisolated static func shouldStart(info: [String: Any]?) -> Bool {
        guard let info,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty,
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty
        else { return false }
        return info[DiagnosticEnvironment.infoKey] as? Bool != true
    }

    func startIfConfigured() {
        guard !started, Self.shouldStart(info: Bundle.main.infoDictionary)
        else { return }
        controller.startUpdater()
        started = true
    }
}

/// App menu → Check for Updates…, enabled while Sparkle can check. Present
/// only in a bundle whose updater started.
struct CheckForUpdatesCommand: Commands {
    @State private var updates = UpdateAvailability()

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if AppUpdater.shared.started {
                Button("Check for Updates…") {
                    AppUpdater.shared.controller.checkForUpdates(nil)
                }
                .disabled(!updates.canCheck)
            }
        }
    }
}

/// Mirrors `SPUUpdater.canCheckForUpdates` (KVO) for the menu item; one
/// observation for the app's lifetime.
@MainActor
@Observable
final class UpdateAvailability {
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AppUpdater.shared.controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }
}
