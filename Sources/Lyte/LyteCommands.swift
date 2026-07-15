import SwiftUI
import LyteKit
import LyteUI

/// The Actions menu (same shape the CLI proved out), driven by the focused
/// window's connection.
struct LyteCommands: Commands {
    @FocusedValue(\.connection) private var connection

    var body: some Commands {
        CommandMenu("Actions") {
            Button(connection?.inputCapture?.locked == true ? "Release Mouse" : "Lock Mouse") {
                connection?.inputCapture?.toggleLock()
            }
            .keyboardShortcut("l", modifiers: [.control, .option])
            .disabled(connection?.session == nil)

            Button("Paste to Host") {
                guard let connection, let session = connection.session,
                      let text = NSPasteboard.general.string(forType: .string) else { return }
                var chunk = ""
                for ch in text {
                    if chunk.utf8.count + String(ch).utf8.count > 32 {
                        if let p = InputPacket.utf8Text(chunk) {
                            session.sendInput(p, channel: InputPacket.channelUTF8)
                        }
                        chunk = ""
                    }
                    chunk.append(ch)
                }
                if let p = InputPacket.utf8Text(chunk) {
                    session.sendInput(p, channel: InputPacket.channelUTF8)
                }
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(connection?.session == nil)

            Divider()

            Button("Refresh Video") { connection?.session?.requestIdr() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(connection?.session == nil)

            Toggle("Mute Audio", isOn: Binding(
                get: { connection?.muted ?? false },
                set: { connection?.muted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(connection?.session == nil)

            Divider()

            Button("Disconnect") { connection?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(connection?.session == nil)
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
