import Foundation
import LyteTransport
import SwiftUI

/// One window = one connection (D6). Starts in the connect state; becomes a
/// pure stream when a session launches.
struct ConnectionWindow: View {
    var autoconnect: String?
    @State private var model = ConnectionModel()
    @State private var didAutoconnect = false

    init(autoconnect: String? = nil) {
        self.autoconnect = autoconnect
    }

    var body: some View {
        Group {
            switch model.phase {
            case .pickHost, .connecting, .failed:
                ConnectView(model: model)
            case .streaming:
                // CL-13: the stream + its overlays (FROZEN pill, stats
                // readout, the auto-hiding control strip) live in
                // StreamContainer.
                StreamContainer(model: model)
            }
        }
        .navigationTitle(model.windowTitle)
        .focusedSceneValue(\.connection, model)
        .frame(minWidth: 480, minHeight: 320)
        .task {
            // Repeatable real-app diagnostics without UI scripting. Normal
            // launches never enter this path; setting LYTE_AUTOCONNECT to a
            // pinned host's name exercises the exact production window,
            // renderer, input, helper, and session lifecycle.
            guard !didAutoconnect, let requested = autoconnect else { return }
            didAutoconnect = true
            let store = PinnedHostStore.load()
            guard let pinned = store.hosts.values.first(where: {
                $0.name.localizedCaseInsensitiveContains(requested)
                    || $0.address == requested
            }), let publicKeyHash = pinned.publicKeyHash else {
                NSLog(
                    "lyte diagnostic: no pinned host matches %@ (%d pins)",
                    requested, store.hosts.count)
                return
            }
            NSLog(
                "lyte diagnostic: autoconnecting %@:%d",
                pinned.address, pinned.port)
            await model.connectLyte(DiscoveredLyteHost(
                name: pinned.name,
                address: pinned.address,
                port: pinned.port,
                wireVersion: nil,
                publicKeyHash: publicKeyHash))
        }
        .onDisappear {
            // The ⌘W seam (v1-final analysis, finding 1): closing the
            // window is the most natural macOS exit, and it was the one
            // verb with no teardown — the receive thread, 100 ms
            // machine beat, and feedback cadence outlived the window,
            // no typed 0x0A left, the host kept encoding full-rate
            // into the void, and awdl0 stayed held down until app
            // quit. One window = one connection (D6), so the window's
            // disappearance IS the disconnect. This modifier sits on
            // the whole body — phase flips inside the Group never
            // detach it, only the window going away does — and
            // endLyteSession's guard makes the already-disconnected
            // and app-quit paths harmless no-ops.
            model.disconnect()
        }
    }
}
