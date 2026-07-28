import SwiftUI
import LyteUI

/// The Actions menu, driven by the focused window's connection. Every
/// item is the SAME ConnectionModel verb the control strip drives
/// (CL-13) — menu and strip cannot disagree because neither holds
/// state of its own. The menu is also the strip's FULL FALLBACK
/// (CL-18): with the strip hidden or out of reach, everything here
/// still works, shortcuts included.
struct LyteCommands: Commands {
    @FocusedValue(\.connection) private var connection

    // CL-18: the strip's app-wide ergonomics preferences — same keys
    // the stream container binds, so menu and strip cannot disagree.
    @AppStorage(StripPreferences.edgeKey)
    private var stripEdgeRaw = StripEdge.bottom.rawValue
    @AppStorage(StripPreferences.hiddenKey)
    private var stripHidden = false

    var body: some Commands {
        CommandMenu("Actions") {
            // CL-18, the mute distinction: the titles name the machine
            // (the owner muted the wrong end when both said "audio").
            Toggle("Mute Playback on This Mac", isOn: Binding(
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
            Toggle("Mute Host Speakers", isOn: Binding(
                get: { connection?.hostMuted ?? false },
                set: { connection?.setHostMuted($0) }
            ))
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(connection?.hostAudioNegotiated != true
                || connection?.hostAudioPosture == nil)

            // The per-host session-start default (CL-13; opt-out
            // semantics since CL-18 — unset means muted, so this is
            // checked by default; unchecking is the "start audible"
            // opt-out). Applied at the NEXT connect to this host; the
            // toggles above are the live session.
            Toggle("Start Sessions with Host Muted", isOn: Binding(
                get: { connection?.startHostMutedPreference ?? true },
                set: { connection?.startHostMutedPreference = $0 }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Divider()

            // Clipboard sharing (CL-15): capability-gated like the
            // host-audio toggle — present but disabled when key 10
            // never survived intersection. The check mark is the live
            // consent state; while off, nothing leaves and nothing
            // lands.
            Toggle("Share Clipboard", isOn: Binding(
                get: { connection?.clipboardSharing ?? false },
                set: { connection?.setClipboardSharing($0) }
            ))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(connection?.clipboardNegotiated != true)

            // The per-host consent default (CL-15): applied at the
            // NEXT connect to this host.
            Toggle("Share Clipboard with This Host by Default", isOn: Binding(
                get: { connection?.shareClipboardPreference ?? false },
                set: { connection?.shareClipboardPreference = $0 }
            ))
            .disabled(connection?.hostPublicKeyHash == nil)

            Divider()

            // F-4: files travel by DROP (drag onto the stream window);
            // the menu carries the cancel so a hidden strip still has
            // a full surface (the CL-18 fallback rule). Cancels the
            // active transfer AND the queue.
            Button("Cancel File Transfer") {
                connection?.cancelBulkTransfers()
            }
            .disabled(connection?.bulkActive != true)

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

            // CL-18: the strip's ergonomics — app-wide, live. Hiding
            // the strip disables reveal-on-hover entirely; this menu
            // (and its shortcuts) remains the full surface.
            Picker("Control Strip Position", selection: $stripEdgeRaw) {
                Text("Bottom Edge").tag(StripEdge.bottom.rawValue)
                Text("Top Edge").tag(StripEdge.top.rawValue)
            }

            Toggle("Hide Control Strip", isOn: $stripHidden)

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
