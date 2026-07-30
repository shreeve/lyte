import LyteTransport
import ServiceManagement
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

        if let hint = agent.helperHint {
            Button(hint) { SMAppService.openSystemSettingsLoginItems() }
        }

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

    /// A user-facing nudge when the privileged helper needs its one-time
    /// System Settings approval (nil once enabled). Shown by the agent
    /// menu; set on the first stream of a run.
    private(set) var helperHint: String?
    /// The watchdog's alarm: streams are active but awdl0 is UP and two
    /// re-engage attempts didn't cure it — the radio hold is NOT
    /// working. Drives the overlay's caps-alarm token. The debounce
    /// itself is RadioHoldPolicy (LyteTransport), pinned in
    /// RadioHoldPolicyTests; this is its rendered face.
    private(set) var radioAlarm = false
    private var radioWatchdog: Task<Void, Never>?
    private var radioPolicy = RadioHoldPolicy()

    func streamBegan() {
        activeStreams += 1
        // The AWDL hold rides the stream lifecycle: engage on the first
        // stream, release on the last (HelperClient/lyte-helperd — the
        // radio's channel-scan stalls are the choppiness signature:
        // 100–220 ms delay bursts, zero loss. Both ends existed since
        // M6; THIS call is what makes them meet).
        if activeStreams == 1 {
            helperHint = HelperClient.shared.streamBegan()
            if let helperHint { NSLog("lyte helper: \(helperHint)") }
            startRadioWatchdog()
        }
    }
    func streamEnded() {
        activeStreams = max(0, activeStreams - 1)
        if activeStreams == 0 {
            HelperClient.shared.streamEnded()
            radioWatchdog?.cancel()
            radioWatchdog = nil
            radioPolicy.reset()
            radioAlarm = false
        }
    }

    /// The hold's watchdog: every 5 s while streaming, ask the INTERFACE
    /// (the one witness that cannot lie — the XPC call is void-returning,
    /// so a daemon that failed to spawn or died mid-stream produces no
    /// error, only an awdl0 that never went down). Loose → re-engage
    /// through the full client path (a dead connection re-spawns the
    /// daemon via launchd); still loose after two more checks → raise
    /// the overlay alarm instead of pretending.
    private func startRadioWatchdog() {
        radioWatchdog?.cancel()
        radioPolicy.reset()
        radioWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.activeStreams > 0,
                      !Task.isCancelled else { return }
                let action = self.radioPolicy.check(
                    radioUp: HelperClient.awdlIsUp())
                if action == .reengage {
                    // First loose sighting: re-engage. A crashed daemon's
                    // connection already invalidated (engaged=false), so
                    // this mints a fresh connection and launchd respawns.
                    NSLog("lyte helper: awdl0 UP while streaming — re-engaging")
                    if !HelperClient.shared.engaged {
                        self.helperHint = HelperClient.shared.streamBegan()
                    }
                }
                self.radioAlarm = self.radioPolicy.alarm
            }
        }
    }

    var statusLine: String {
        switch activeStreams {
        case 0: "Lyte — idle"
        case 1: "Lyte — streaming"
        default: "Lyte — \(activeStreams) streams"
        }
    }
}
