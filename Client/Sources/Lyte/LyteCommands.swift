import SwiftUI
import LyteClientCore
import LyteTransport
import LyteUI

/// The Actions menu, driven by the focused window's connection. Every
/// item is the same ConnectionModel verb the control strip drives, so
/// menu and strip cannot disagree. The menu is also the strip's full
/// fallback: with the strip hidden, everything here still works.
struct LyteCommands: Commands {
    @FocusedValue(\.connection) private var connection

    // Same keys the stream container binds.
    @AppStorage(StripPreferences.edgeKey)
    private var stripEdgeRaw = StripEdge.bottom.rawValue
    @AppStorage(StripPreferences.hiddenKey)
    private var stripHidden = false
    @AppStorage(LyteInputCapture.secureKeyboardEntryKey)
    private var secureKeyboardEntry = false

    var body: some Commands {
        CommandMenu("Actions") {
            // The titles name the machine, not just "audio".
            Toggle("Mute Playback on This Mac", isOn: Binding(
                get: { connection?.muted ?? false },
                set: { connection?.muted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(connection?.lyteSession == nil)

            // Capability-gated like the strip's button, but present and
            // disabled rather than hidden. The check mark is the
            // 0x19-confirmed posture, never the ask.
            Toggle("Mute Host Speakers", isOn: Binding(
                get: { connection?.hostMuted ?? false },
                set: { connection?.setHostMuted($0) }
            ))
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(connection?.negotiated.hostAudioRouting != true
                || connection?.hostAudioPosture == nil)

            // The per-host session-start default (unset means muted),
            // applied at the next connect to this host.
            Toggle("Start Sessions with Host Muted", isOn: Binding(
                get: { connection?.hostPreference(.startHostMuted) ?? true },
                set: { connection?.setHostPreference(.startHostMuted, $0) }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Divider()

            // Present but disabled without capability key 10. The check
            // mark is the live consent state. ⌘⇧C and ⌘⇧V stay the host's
            // (a Linux terminal's copy and paste).
            Toggle("Share Clipboard", isOn: Binding(
                get: { connection?.clipboardSharing ?? false },
                set: { connection?.setClipboardSharing($0) }
            ))
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(connection?.negotiated.clipboardText != true)

            // Gated on keys 10 and 12; images move only while "Share
            // Clipboard" is also on.
            Toggle("Share Clipboard Images", isOn: Binding(
                get: { connection?.clipboardImageSharing ?? false },
                set: { connection?.setClipboardImageSharing($0) }
            ))
            .disabled(connection?.negotiated.clipboardImages != true)

            // Per-host consent defaults, applied at the next connect.
            Toggle("Share Clipboard with This Host by Default", isOn: Binding(
                get: { connection?.hostPreference(.shareClipboard) ?? false },
                set: { connection?.setHostPreference(.shareClipboard, $0) }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Toggle("Share Clipboard Images by Default", isOn: Binding(
                get: { connection?.hostPreference(.shareClipboardImages) ?? false },
                set: { connection?.setHostPreference(.shareClipboardImages, $0) }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Divider()

            // Files travel by drop; the menu carries the cancel (active
            // transfer and queue) so a hidden strip loses nothing.
            Button("Cancel File Transfer") {
                connection?.cancelBulkTransfers()
            }
            .disabled(connection?.bulkActive != true)

            Divider()

            // Picking a tier reconnects with the new declaration; the
            // dormant Better row has no wire id and stays disabled.
            Menu("Chroma") {
                ForEach(ChromaTier.allCases, id: \.self) { tier in
                    Toggle(tier.menuTitle, isOn: Binding(
                        get: { connection?.chromaTier == tier },
                        set: { on in
                            if on { connection?.setChromaTier(tier) }
                        }
                    ))
                    .disabled(!tier.isSelectable)
                }
            }
            .disabled(connection?.canReconnect != true)

            Divider()

            // Terminal's posture: while a stream window is key, other
            // apps' keystroke taps see nothing (and neither do password
            // managers' autotype or text expanders).
            Toggle("Secure Keyboard Entry", isOn: $secureKeyboardEntry)

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

            Picker("Control Strip Position", selection: $stripEdgeRaw) {
                Text("Bottom Edge").tag(StripEdge.bottom.rawValue)
                Text("Top Edge").tag(StripEdge.top.rawValue)
            }

            Toggle("Hide Control Strip", isOn: $stripHidden)

            Divider()

            // Tears the wire session down and dials fresh at the
            // last-known address while a scan runs, ladders reset.
            Button("Reconnect") { connection?.reconnectNow() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(connection?.canReconnect != true)

            // Works during roaming too: the window still hunts.
            Button("Disconnect") { connection?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(connection?.canEndSession != true)
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
