import SwiftUI

/// The Actions menu, driven by the focused window's connection.
struct LyteCommands: Commands {
    @FocusedValue(\.connection) private var connection

    var body: some Commands {
        CommandMenu("Actions") {
            Toggle("Mute Audio", isOn: Binding(
                get: { connection?.muted ?? false },
                set: { connection?.muted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])
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
