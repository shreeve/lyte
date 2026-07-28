import SwiftUI
import LyteTransport
import LyteUI
import UniformTypeIdentifiers

/// The streaming state's whole surface (CL-13): the stream view plus
/// its overlays — the FROZEN pill (CL-8), the stats readout, and the
/// auto-hiding control strip. CL-18 reworked the strip's ergonomics
/// after the owner's first hand-test:
///
/// - The strip lives on a PREFERRED edge (bottom, as shipped, or top —
///   `StripPreferences`, app-wide, togglable from the strip itself and
///   the Actions menu), and the reveal zone follows it.
/// - Reveal is a DWELL verdict, not a motion ping: `StripRevealPolicy`
///   (LyteUI, sans-IO, virtual-time gated) reveals only after ~200 ms
///   of pointer presence in the edge zone, ignores the fullscreen
///   system-edge sliver (the Dock/menu-bar summons stay macOS's),
///   hides instantly when the pointer leaves the window, and keeps
///   CL-16's fade discipline (~2 s after the last zone activity,
///   never while hovered). Aiming at the Dock no longer traps you.
/// - Hidden mode ("Hide Control Strip" in the Actions menu) disables
///   reveal entirely; the menu + shortcuts remain the full surface.
///
/// Buttons stay CAPABILITY-GATED: the strip shows what this session
/// actually supports (the negotiated set decides), not per-button
/// preferences.
struct StreamContainer: View {
    let model: ConnectionModel

    @AppStorage(StripPreferences.edgeKey)
    private var stripEdgeRaw = StripEdge.bottom.rawValue
    @AppStorage(StripPreferences.hiddenKey)
    private var stripHidden = false

    @State private var stripVisible = false
    /// The reveal machinery's mutable interior — a REFERENCE type (the
    /// CL-16 lesson, kept): pointer-rate events mutate the policy
    /// inside the box without invalidating any view; only actual
    /// visibility flips touch @State.
    @State private var reveal = StripRevealBooks()
    /// F-4: a file drag is over the window (SwiftUI's isTargeted) —
    /// the drop hint renders while true.
    @State private var dropTargeted = false

    private var stripEdge: StripEdge {
        StripEdge(rawValue: stripEdgeRaw) ?? .bottom
    }

    var body: some View {
        StreamView(model: model, onMouseActivity: { pointerActivity($0) })
            .overlay(alignment: stripEdge == .top ? .bottom : .top) {
                // The connection-health pill, tiered (F-5 over CL-8):
                // a short blip is the FROZEN pill; past the roaming
                // thresholds the banner SAYS what is happening
                // ("looking for pup…", "found at … — reconnecting…")
                // instead of a silent frozen frame. Subtle, never
                // modal; the edge OPPOSITE the strip so they never
                // stack.
                if let line = model.roamingStatusLine {
                    Label(line, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .foregroundStyle(.orange)
                        .padding(stripEdge == .top ? .bottom : .top, 10)
                        .transition(.opacity)
                } else if model.lyteFrozen {
                    Label("Connection interrupted…",
                          systemImage: "wifi.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .foregroundStyle(.orange)
                        .padding(stripEdge == .top ? .bottom : .top, 10)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: stripEdge == .top ? .bottomLeading : .topLeading) {
                // The stats readout keeps clear of the strip's edge too.
                if model.statsVisible {
                    StatsOverlay(model: model)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: stripEdge == .top ? .bottomTrailing : .topTrailing) {
                // F-4: the transfer pill (progress + cancel ×) and the
                // transient verdict line — the trailing corner of the
                // strip's OPPOSITE edge, clear of the FROZEN pill
                // (centered there) and the stats readout (leading).
                VStack(alignment: .trailing, spacing: 6) {
                    if model.bulkActive {
                        BulkProgressPill(model: model)
                    }
                    if let notice = model.bulkNotice {
                        Text(notice)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .transition(.opacity)
                    }
                }
                .padding(12)
            }
            .overlay {
                // F-4: the drop hint, while a file drag hovers. The
                // capability verdict shows DURING the drag, so nobody
                // has to complete a doomed drop to learn the host's
                // toggle is off (the drop itself answers with the
                // notice either way).
                if dropTargeted {
                    DropHintOverlay(
                        accepting: model.bulkNegotiated,
                        hostName: model.hostName ?? "the host")
                }
            }
            // F-4: the drop TARGET. Drag-and-drop never touches the
            // CL-16 input-capture path by construction: the capture's
            // NSEvent local monitors see only the mouse/key mask —
            // drag sessions ride NSDraggingDestination, a separate
            // pipeline — and this modifier lives on the SwiftUI
            // overlay layer, whose claimed points the capture already
            // returns to AppKit (the landsOnVideoSurface rule).
            .onDrop(
                of: [UTType.fileURL],
                isTargeted: $dropTargeted
            ) { providers in
                model.handleDrop(providers: providers)
            }
            .overlay(alignment: stripEdge == .top ? .top : .bottom) {
                if stripVisible {
                    ControlStrip(model: model, edge: stripEdge,
                                 onMoveEdge: { moveEdge(to: $0) })
                        .padding(stripEdge == .top ? .top : .bottom, 16)
                        .onHover { hovering in
                            reveal.policy.hoverChanged(hovering, now: .nowNS)
                            syncAndSchedule()
                        }
                        .transition(.opacity.combined(
                            with: .move(edge: stripEdge == .top ? .top : .bottom)))
                }
            }
            // Backup pointer path: hover tracking catches the pointer
            // when the window is not key (the NSEvent monitor only
            // sees key-window events) — and its `.ended` is the ONE
            // window-exit signal (mouseExited is not in the monitor's
            // mask, so it fires even while the capture eats moves).
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard reveal.viewSize.height > 0 else { return }
                    // SwiftUI's local space is top-left-origin. This
                    // path only matters for non-key windows, which are
                    // never the fullscreen front — the sliver rule
                    // rides the capture path.
                    pointerActivity(PointerActivity(
                        distanceFromBottom: reveal.viewSize.height - point.y,
                        distanceFromTop: point.y,
                        isFullscreen: false))
                case .ended:
                    reveal.policy.pointerExitedWindow(now: .nowNS)
                    syncAndSchedule()
                }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                reveal.viewSize = $0
            }
            .onChange(of: stripHidden, initial: true) { _, hidden in
                reveal.policy.hiddenMode = hidden
                syncAndSchedule()
            }
            .onDisappear {
                reveal.task?.cancel()
                reveal.task = nil
            }
            .animation(.easeInOut(duration: 0.3), value: model.lyteFrozen)
            .animation(.easeInOut(duration: 0.3),
                       value: model.roamingStatusLine)
            .animation(.easeInOut(duration: 0.25), value: stripVisible)
            .animation(.easeInOut(duration: 0.2), value: model.statsVisible)
            .animation(.easeInOut(duration: 0.15), value: dropTargeted)
            .animation(.easeInOut(duration: 0.2), value: model.bulkActive)
            .animation(.easeInOut(duration: 0.2), value: model.bulkNotice)
    }

    /// Every pointer event funnels here (capture primary, hover
    /// backup): pick the distance to the CONFIGURED edge, let the
    /// policy judge, and mirror its verdict.
    private func pointerActivity(_ activity: PointerActivity) {
        let distance = stripEdge == .top
            ? activity.distanceFromTop : activity.distanceFromBottom
        reveal.policy.pointerMoved(
            edgeDistance: distance,
            atSystemEdge: activity.isFullscreen,
            now: .nowNS)
        syncAndSchedule()
    }

    /// The strip's own position toggle: persist the new edge and keep
    /// the (teleported) strip alive a full idle interval so it doesn't
    /// vanish mid-move — the pointer is at the OLD edge now.
    private func moveEdge(to edge: StripEdge) {
        stripEdgeRaw = edge.rawValue
        reveal.policy.keepAlive(now: .nowNS)
        syncAndSchedule()
    }

    /// Mirrors the policy's visibility into @State and keeps ONE
    /// standing deadline task alive while the policy has work pending
    /// (dwell completion for a stationary pointer, the idle fade) —
    /// the CL-16 shape: activity writes state; the task just sleeps
    /// to the current deadline and looks again.
    private func syncAndSchedule() {
        if stripVisible != reveal.policy.isVisible {
            stripVisible = reveal.policy.isVisible
        }
        guard reveal.task == nil, reveal.policy.nextDeadline != nil else {
            return
        }
        let reveal = reveal
        reveal.task = Task { @MainActor in
            defer { reveal.task = nil }
            while !Task.isCancelled {
                guard let deadline = reveal.policy.nextDeadline else { return }
                let now = UInt64.nowNS
                if now < deadline {
                    try? await Task.sleep(nanoseconds: deadline - now)
                    continue
                }
                reveal.policy.tick(now: now)
                if stripVisible != reveal.policy.isVisible {
                    stripVisible = reveal.policy.isVisible
                }
            }
        }
    }
}

/// StreamContainer's reveal books — deliberately a plain class (not
/// Observable): pointer-rate mutations must be invisible to SwiftUI.
/// Main-actor confined by its only owner.
@MainActor
private final class StripRevealBooks {
    var policy = StripRevealPolicy()
    var task: Task<Void, Never>?
    /// The container's live size (onGeometryChange) — the hover
    /// backup path's coordinate flip needs the height.
    var viewSize: CGSize = .zero
}

private extension UInt64 {
    /// The policy's clock: monotonic uptime nanoseconds.
    static var nowNS: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// The strip itself: one translucent capsule of session verbs. Order:
/// audio controls, stats, then the window/session verbs — Disconnect
/// last and visually apart. Every command here is the SAME model verb
/// the Actions menu drives, so menu and strip can never disagree.
///
/// CL-18, the mute distinction (the owner muted the wrong end): the
/// two mute buttons stopped being speaker-glyph siblings. The HOST
/// button wears the hifispeaker cabinet — a physical loudspeaker in
/// the other room — and the LOCAL button wears headphones — what this
/// Mac plays; each carries a tiny HOST/MAC caption, and mute is the
/// same diagonal slash treatment on both. (SF Symbols ships no .slash
/// variant for either glyph, so the slash is composed — one visual
/// language for "silenced" across both.) Tooltips name the machine.
struct ControlStrip: View {
    @Bindable var model: ConnectionModel
    let edge: StripEdge
    let onMoveEdge: (StripEdge) -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Mute Host Speakers — EXISTS only when capability key 9
            // survived intersection (against a legacy host there is
            // nothing to show). Renders the 0x19-confirmed posture,
            // never the ask: the icon flips when the host says it did.
            if model.hostAudioNegotiated {
                let hostLabel = model.hostName ?? "the host"
                stripButton(
                    active: model.hostMuted,
                    help: model.hostAudioPosture == nil
                        ? "Host speakers — waiting for the host's posture"
                        : (model.hostMuted
                            ? "Host speakers are muted — click to let \(hostLabel) play out loud"
                            : "Mute host speakers (\(hostLabel)) — audio keeps streaming here"),
                    action: { model.setHostMuted(!model.hostMuted) },
                    label: {
                        mutableGlyph(base: "hifispeaker.fill",
                                     muted: model.hostMuted,
                                     caption: "HOST")
                    }
                )
                .disabled(model.hostAudioPosture == nil)
            }

            // Client-side mute — the local pipeline's mixer (CL-11);
            // always available while the session runs.
            stripButton(
                active: model.muted,
                help: model.muted
                    ? "Unmute playback on this Mac"
                    : "Mute playback on this Mac (the host's speakers are unaffected)",
                action: { model.muted.toggle() },
                label: {
                    mutableGlyph(base: "headphones",
                                 muted: model.muted,
                                 caption: "MAC")
                }
            )

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

            // CL-18: the strip's own home — flip it to the other edge
            // (persisted app-wide; the reveal zone follows).
            stripButton(
                systemImage: edge == .bottom
                    ? "arrow.up.to.line" : "arrow.down.to.line",
                active: false,
                help: edge == .bottom
                    ? "Move the control strip to the top edge"
                    : "Move the control strip to the bottom edge"
            ) {
                onMoveEdge(edge == .bottom ? .top : .bottom)
            }

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

    /// A muteable audio endpoint's glyph: the base symbol (distinct
    /// per machine), the shared diagonal-slash mute treatment, and a
    /// tiny caption naming whose sound this is.
    @ViewBuilder
    private func mutableGlyph(
        base: String, muted: Bool, caption: String
    ) -> some View {
        VStack(spacing: 1) {
            Image(systemName: base)
                .font(.system(size: 14, weight: .medium))
                .overlay {
                    if muted {
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 17, weight: .bold))
                            .rotationEffect(.degrees(90))
                    }
                }
                .frame(height: 17)
            Text(caption)
                .font(.system(size: 7, weight: .semibold))
                .kerning(0.5)
                .opacity(0.75)
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private func stripButton(
        systemImage: String,
        active: Bool,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        stripButton(active: active, help: help, role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private func stripButton<Content: View>(
        active: Bool,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(role: role, action: action) {
            label()
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

/// The transfer pill (F-4): file name, phase/progress, queue depth,
/// and a cancel × — small and non-intrusive (the CL-16/CL-18 overlay
/// discipline). Its SwiftUI content claims its own points, so clicks
/// here never reach the host cursor (the landsOnVideoSurface rule).
struct BulkProgressPill: View {
    let model: ConnectionModel

    var body: some View {
        let status = model.bulkStatus
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: 12, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.activeName ?? "File transfer")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                    if status.queuedCount > 0 {
                        Text("+\(status.queuedCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if status.phase == .transferring,
                       let progress = status.progress {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 110)
                        Text(String(format: "%.0f%%", progress.fraction * 100))
                            .font(.caption2.monospacedDigit())
                    } else {
                        Text(phaseLabel(status.phase))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                model.cancelBulkTransfers()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel the file transfer (and anything queued)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .transition(.opacity)
    }

    private func phaseLabel(_ phase: BulkSendSnapshot.Phase?) -> String {
        switch phase {
        case .preparing: return "Preparing…"
        case .offering: return "Waiting for the host…"
        case .transferring: return "Sending…"
        case .verifying: return "Verifying…"
        case .awaitingReconnect: return "Waiting to reconnect…"
        case nil: return "…"
        }
    }
}

/// The drag-over hint (F-4): tells the truth about the host's file
/// consent DURING the drag. Hit-test transparent — a hint must never
/// eat the drop it is hinting about.
struct DropHintOverlay: View {
    let accepting: Bool
    let hostName: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: accepting
                ? "arrow.down.doc" : "nosign")
                .font(.system(size: 28, weight: .medium))
            Text(accepting
                ? "Drop to send to \(hostName)"
                : "\(hostName) isn't accepting files")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(accepting ? AnyShapeStyle(.primary)
                                   : AnyShapeStyle(.orange))
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(accepting ? AnyShapeStyle(.secondary)
                                           : AnyShapeStyle(.orange)))
        .allowsHitTesting(false)
        .transition(.opacity)
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
