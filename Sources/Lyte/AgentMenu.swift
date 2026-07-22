import SwiftUI

/// The agent (A0): Lyte's quiet menu-bar presence — the same binary wearing
/// its always-on face (LYTE-PLAN §3: one program per platform, living in the
/// menu bar). Fronts the client role today: new connections.
/// The Host toggle is visible but disabled until the Lyte host lands.
struct AgentMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var agent = AgentState.shared

    var body: some View {
        Text(agent.statusLine)

        Button("New Connection…") { openWindow(id: "connection") }

        Divider()

        Toggle("Be a Host", isOn: $agent.hostEnabled)
            .disabled(!agent.hostAvailable)
            .help("Stream this Mac to other Lyte clients — arrives with the Lyte host")

        Divider()

        Button("Quit Lyte") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Role state, shared across scenes. Born in A0 so the host role has a home
/// to land in: the H-ladder flips `hostAvailable`, H6 wires the toggle.
@MainActor
@Observable
final class AgentState {
    static let shared = AgentState()

    /// Streams currently running across all connection windows.
    private(set) var activeStreams = 0

    /// Reserved for the Lyte host role; stays false until the host ships.
    var hostAvailable: Bool { false }
    var hostEnabled = false

    func streamBegan() { activeStreams += 1 }
    func streamEnded() { activeStreams = max(0, activeStreams - 1) }

    var statusLine: String {
        switch activeStreams {
        case 0: "Lyte — idle"
        case 1: "Lyte — streaming"
        default: "Lyte — \(activeStreams) streams"
        }
    }
}
