import SwiftUI
import LyteTransport

/// The streaming state's whole surface (CL-13): the stream view plus
/// its overlays — the FROZEN pill (CL-8), the stats readout, and the
/// auto-hiding control strip. Video-player rules, per the recorded
/// design guidance: the strip reveals on mouse movement, fades after
/// ~2 s idle (never while the pointer is on it), and is always one
/// wiggle away — available, never in the way. Buttons are
/// CAPABILITY-GATED: the strip shows what this session actually
/// supports (the negotiated set decides), not per-button preferences.
struct StreamContainer: View {
    let model: ConnectionModel

    @State private var stripVisible = false
    @State private var stripHovered = false
    /// The reveal clock's mutable interior (CL-16): a REFERENCE type,
    /// so pointer-rate activity lands as one timestamp write inside
    /// the box — the @State reference never changes, per-event traffic
    /// invalidates no view and spawns no task. CL-13's version bumped
    /// an observed @State counter and started a fresh 2 s Task per
    /// mouse event.
    @State private var fade = StripFadeBooks()

    private static let idleFadeSeconds: Double = 2

    var body: some View {
        StreamView(model: model, onMouseActivity: { reveal() })
            .overlay(alignment: .top) {
                // CL-8: the FROZEN pill — subtle, never modal. The
                // path went dark; it clears by itself when host
                // traffic returns.
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
            .overlay(alignment: .topLeading) {
                if model.statsVisible {
                    StatsOverlay(model: model)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if stripVisible {
                    ControlStrip(model: model)
                        .padding(.bottom, 16)
                        .onHover { hovering in
                            stripHovered = hovering
                            // Hover exit restamps the clock so the
                            // fade lands ~2 s after the pointer
                            // leaves, matching mouse activity.
                            if !hovering { fade.lastActivity = .now }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // Backup reveal path: hover tracking catches pointer entry
            // when the window is not key (the NSEvent monitor only
            // sees key-window events) — onMouseActivity is the primary
            // clock because the capture consumes moves over the video.
            .onContinuousHover { phase in
                if case .active = phase { reveal() }
            }
            .onDisappear {
                fade.task?.cancel()
                fade.task = nil
            }
            .animation(.easeInOut(duration: 0.3), value: model.lyteFrozen)
            .animation(.easeInOut(duration: 0.25), value: stripVisible)
            .animation(.easeInOut(duration: 0.2), value: model.statsVisible)
    }

    /// Reveal on activity; fade ~2 s after the LAST activity, never
    /// while hovered (the CL-13 behavior, kept). One STANDING task
    /// owns the countdown: it sleeps to the current deadline and, on
    /// waking early (activity moved it), just sleeps again — activity
    /// itself only writes a timestamp.
    private func reveal() {
        fade.lastActivity = .now
        if !stripVisible { stripVisible = true }
        guard fade.task == nil else { return }
        fade.task = Task { @MainActor in
            defer { fade.task = nil }
            while !Task.isCancelled {
                let deadline = fade.lastActivity
                    + .seconds(Self.idleFadeSeconds)
                if ContinuousClock.now < deadline {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    continue
                }
                // Deadline reached. Hover pins the strip: idle a fade
                // interval and look again (hover exit restamps the
                // clock, so the fade still lands ~2 s after it).
                if stripHovered {
                    try? await Task.sleep(for: .seconds(Self.idleFadeSeconds))
                    continue
                }
                stripVisible = false
                return
            }
        }
    }
}

/// StreamContainer's fade books — deliberately a plain class (not
/// Observable): mutations must be invisible to SwiftUI. Main-actor
/// confined by its only owner.
private final class StripFadeBooks {
    var lastActivity: ContinuousClock.Instant = .now
    var task: Task<Void, Never>?
}

/// The strip itself: one translucent capsule of session verbs. Order:
/// audio controls, stats, then the window/session verbs — Disconnect
/// last and visually apart. Every command here is the SAME model verb
/// the Actions menu drives, so menu and strip can never disagree.
struct ControlStrip: View {
    @Bindable var model: ConnectionModel

    var body: some View {
        HStack(spacing: 14) {
            // Mute Host Audio — EXISTS only when capability key 9
            // survived intersection (against a legacy host there is
            // nothing to show). Renders the 0x19-confirmed posture,
            // never the ask: the icon flips when the host says it did.
            if model.hostAudioNegotiated {
                stripButton(
                    systemImage: model.hostMuted
                        ? "speaker.slash.circle.fill" : "speaker.circle",
                    active: model.hostMuted,
                    help: model.hostAudioPosture == nil
                        ? "Host audio — waiting for the host's posture"
                        : (model.hostMuted
                            ? "Host speakers muted — click to unmute the host"
                            : "Mute the host's speakers (audio keeps streaming here)")
                ) {
                    model.setHostMuted(!model.hostMuted)
                }
                .disabled(model.hostAudioPosture == nil)
            }

            // Share Clipboard — EXISTS only when capability key 10
            // survived intersection (CL-15). Renders the live consent
            // state; while off, nothing leaves and nothing lands.
            if model.clipboardNegotiated {
                stripButton(
                    systemImage: model.clipboardSharing
                        ? "doc.on.clipboard.fill" : "doc.on.clipboard",
                    active: model.clipboardSharing,
                    help: model.clipboardSharing
                        ? "Stop sharing the clipboard with the host"
                        : "Share the clipboard with the host (text, both ways)"
                ) {
                    model.setClipboardSharing(!model.clipboardSharing)
                }
            }

            // Client-side mute — the local pipeline's mixer (CL-11);
            // always available while the session runs.
            stripButton(
                systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                active: model.muted,
                help: model.muted ? "Unmute audio on this Mac"
                                  : "Mute audio on this Mac"
            ) {
                model.muted.toggle()
            }

            // The stats readout: the session's existing books, as a
            // compact overlay toggle.
            stripButton(
                systemImage: "chart.bar",
                active: model.statsVisible,
                help: model.statsVisible ? "Hide session stats"
                                         : "Show session stats"
            ) {
                model.statsVisible.toggle()
            }

            Divider().frame(height: 18)

            stripButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                active: false,
                help: "Toggle full screen"
            ) {
                model.toggleFullscreen()
            }

            stripButton(
                systemImage: "xmark.circle.fill",
                active: false,
                help: "Disconnect (sends the typed teardown)",
                role: .destructive
            ) {
                model.disconnect()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder
    private func stripButton(
        systemImage: String,
        active: Bool,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(
                    role == .destructive ? AnyShapeStyle(.red.opacity(0.85))
                        : active ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.primary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The compact stats overlay (CL-13): the session's existing books —
/// datagram health, mode + host-audio posture, input latency when
/// flowing, audio depth/PLC — re-read once a second while visible.
struct StatsOverlay: View {
    let model: ConnectionModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.statsLines(), id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.white.opacity(0.9))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.55)))
        }
        .allowsHitTesting(false)
    }
}
