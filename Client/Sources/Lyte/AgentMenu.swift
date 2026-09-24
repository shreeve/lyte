import LyteClientCore
import LyteTransport
import ServiceManagement
import SwiftUI

/// Lyte's quiet menu-bar presence — the same binary wearing its always-on
/// face: stream status, the helper's approval nudge, new connections.
struct AgentMenu: View {
    @Environment(\.openWindow) private var openWindow
    private var agent = AgentState.shared

    var body: some View {
        Text(agent.statusLine)

        if let hint = agent.helperHint {
            Button(hint) { SMAppService.openSystemSettingsLoginItems() }
        }

        Button("New Connection…") { openWindow(id: "connection") }

        Divider()

        Button("Quit Lyte") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Process-wide stream state, shared across scenes: the stream count that
/// brackets the AWDL helper's hold, and the radio watchdog.
@MainActor
@Observable
final class AgentState {
    static let shared = AgentState()

    /// Streams currently running across all connection windows.
    private(set) var activeStreams = 0

    /// A user-facing nudge when the privileged helper needs its one-time
    /// System Settings approval (nil once enabled). Shown by the agent
    /// menu; set on the first stream of a run.
    private(set) var helperHint: String?
    /// Streams are active but awdl0 stayed UP for three consecutive
    /// checks, one re-engage notwithstanding. Drives the overlay's
    /// caps-alarm token; the debounce is RadioHoldPolicy.
    private(set) var radioAlarm = false
    private var radioWatchdog: Task<Void, Never>?
    private var radioPolicy = RadioHoldPolicy()
    private var activity = StreamActivity.live

    private var helperRegistration: HelperClient.RegistrationPosture {
        DiagnosticRunIdentity.isRequested ? .existingOnly : .ensure
    }

    func streamBegan() {
        activeStreams += 1
        activity.streamsChanged(to: activeStreams)
        // The AWDL hold rides the stream lifecycle: engage on the first
        // stream, release on the last (the radio's channel scans cause
        // 100–220 ms delay bursts with zero loss).
        if activeStreams == 1 {
            helperHint = HelperClient.shared.streamBegan(
                registration: helperRegistration)
            if let helperHint { NSLog("lyte helper: \(helperHint)") }
            startRadioWatchdog()
        }
    }
    func streamEnded() {
        activeStreams = max(0, activeStreams - 1)
        activity.streamsChanged(to: activeStreams)
        if activeStreams == 0 {
            HelperClient.shared.streamEnded()
            radioWatchdog?.cancel()
            radioWatchdog = nil
            radioPolicy.reset()
            radioAlarm = false
        }
    }

    /// The hold's watchdog: every 5 s while streaming, ask the interface
    /// (the void-returning XPC call cannot report a dead daemon). Loose →
    /// re-engage through the full client path (launchd respawns the
    /// daemon); still loose after two more checks → raise the alarm.
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
                    // First loose sighting: re-engage, minting a fresh
                    // connection if the old one invalidated.
                    NSLog("lyte helper: awdl0 UP while streaming — re-engaging")
                    if !HelperClient.shared.engaged {
                        self.helperHint = HelperClient.shared.streamBegan(
                            registration: self.helperRegistration)
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

/// One latency-critical activity held exactly while any stream runs: App
/// Nap would coalesce the feedback, ARQ and audio timers of an occluded
/// window, and a watched stream must keep the display awake.
struct StreamActivity {
    var begin: () -> any NSObjectProtocol
    var end: (any NSObjectProtocol) -> Void
    private var token: (any NSObjectProtocol)?

    init(
        begin: @escaping () -> any NSObjectProtocol,
        end: @escaping (any NSObjectProtocol) -> Void
    ) {
        self.begin = begin
        self.end = end
    }

    static var live: StreamActivity {
        StreamActivity(
            begin: {
                ProcessInfo.processInfo.beginActivity(
                    options: [
                        .userInitiated, .latencyCritical,
                        .idleDisplaySleepDisabled,
                    ],
                    reason: "Lyte stream")
            },
            end: { ProcessInfo.processInfo.endActivity($0) })
    }

    mutating func streamsChanged(to count: Int) {
        if count > 0, token == nil {
            token = begin()
        } else if count == 0, let held = token {
            end(held)
            token = nil
        }
    }
}
