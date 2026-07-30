import SwiftUI

/// One window = one connection (D6). Starts in the connect state; becomes a
/// pure stream when a session launches.
struct ConnectionWindow: View {
    @State private var model = ConnectionModel()

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
