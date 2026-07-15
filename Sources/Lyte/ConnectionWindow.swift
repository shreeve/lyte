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
            }
        }
        .navigationTitle(model.windowTitle)
        .focusedSceneValue(\.connection, model)
        .frame(minWidth: 480, minHeight: 320)
        .task {
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
