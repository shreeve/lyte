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
                StreamView(model: model)
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
    }
}
