import SwiftUI

/// The Actions menu, driven by the focused window's connection. Every
/// item is the SAME ConnectionModel verb the control strip drives
/// (CL-13) — menu and strip cannot disagree because neither holds
/// state of its own.
struct LyteCommands: Commands {
    @FocusedValue(\.connection) private var connection

    var body: some Commands {
        CommandMenu("Actions") {
            Toggle("Mute Audio on This Mac", isOn: Binding(
                get: { connection?.muted ?? false },
                set: { connection?.muted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(connection?.lyteSession == nil)

            // Host audio routing (CL-13): capability-gated exactly like
            // the strip's button — present but disabled when key 9
            // never survived intersection (menus can't vanish items
            // per-session as gracefully as the strip can). The check
            // mark is the 0x19-confirmed posture, never the ask.
            Toggle("Mute Host Audio", isOn: Binding(
                get: { connection?.hostMuted ?? false },
                set: { connection?.setHostMuted($0) }
            ))
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(connection?.hostAudioNegotiated != true
                || connection?.hostAudioPosture == nil)

            // The per-host session-start default (CL-13): applied at
            // the NEXT connect to this host; the toggles above are the
            // live session.
            Toggle("Start Sessions with Host Muted", isOn: Binding(
                get: { connection?.startHostMutedPreference ?? false },
                set: { connection?.startHostMutedPreference = $0 }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Divider()

            Toggle("Session Stats", isOn: Binding(
                get: { connection?.statsVisible ?? false },
                set: { connection?.statsVisible = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(connection?.lyteSession == nil)

            Button("Toggle Full Screen") { connection?.toggleFullscreen() }
                .disabled(connection?.lyteSession == nil)

            Divider()

            Button("Disconnect") { connection?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(connection?.lyteSession == nil)
        }
    }
}

private struct ConnectionFocusedKey: FocusedValueKey {
    typealias Value = ConnectionModel
}

extension FocusedValues {
    var connection: ConnectionModel? {
        get { self[ConnectionFocusedKey.self] }
        set { self[ConnectionFocusedKey.self] = newValue }
    }
}
