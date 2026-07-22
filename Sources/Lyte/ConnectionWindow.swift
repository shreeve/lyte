import SwiftUI
import LyteKit

/// One window = one connection (D6). Starts in the connect state; becomes a
/// pure stream when a session launches.
struct ConnectionWindow: View {
    @State private var model = ConnectionModel()

    var body: some View {
        Group {
            switch model.phase {
            case .pickHost, .pairing, .apps, .connecting, .failed:
                ConnectView(model: model)
            case .streaming:
                StreamView(model: model)
                    .overlay(alignment: .topTrailing) {
                        if model.showDoctor {
                            DoctorPill(diagnosis: model.diagnosis, policy: model.policy)
                        }
                    }
                    .overlay(alignment: .top) {
                        // CL-8: the FROZEN pill — subtle, never modal.
                        // The path went dark (350 ms-class silence on
                        // the Lyte session's detector); it clears by
                        // itself when host traffic returns.
                        if model.lyteFrozen {
                            Label("Connection interrupted…",
                                  systemImage: "wifi.exclamationmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.ultraThinMaterial))
                                .foregroundStyle(.orange)
                                .padding(.top, 10)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: model.lyteFrozen)
            }
        }
        .navigationTitle(model.windowTitle)
        .focusedSceneValue(\.connection, model)
        .frame(minWidth: 480, minHeight: 320)
        .task {
            // Agent-menu resume (A0): a window opened from the menu bar
            // carries its target via PendingConnect and skips the picker.
            if let target = PendingConnect.target {
                PendingConnect.target = nil
                LaunchReconnect.consumed = true
                await model.reconnect(address: target.address, appTitle: target.app)
                return
            }
            // Relaunch = resume (D6): the first window auto-reconnects to the
            // most recent session. ⌘N windows (and ⌥ at launch) get the picker.
            guard !LaunchReconnect.consumed else { return }
            LaunchReconnect.consumed = true
            guard !NSEvent.modifierFlags.contains(.option),
                  let last = RecentConnections.load().first else { return }
            await model.reconnect(address: last.address, appTitle: last.app)
        }
    }
}

/// One-shot flag: only the first window at launch auto-reconnects.
@MainActor
enum LaunchReconnect {
    static var consumed = false
}
