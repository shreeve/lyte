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
    }
}
