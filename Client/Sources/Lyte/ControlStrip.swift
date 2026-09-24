import LyteIO
import SwiftUI
import LyteClientCore
import LyteTransport
import LyteUI
import UniformTypeIdentifiers

/// The streaming state's whole surface: the stream view plus its
/// overlays — the FROZEN pill, the stats readout, and the auto-hiding
/// control strip.
///
/// - The strip lives on a preferred edge (`StripPreferences`, app-wide)
///   and the reveal zone follows it.
/// - Reveal is a dwell verdict (`StripRevealPolicy`): ~200 ms of pointer
///   presence in the edge zone, ignoring the fullscreen system-edge
///   sliver; hides when the pointer leaves the window and fades ~2 s
///   after the last zone activity, never while hovered.
/// - Hidden mode disables reveal; the menu and shortcuts remain.
///
/// Buttons are capability-gated: the negotiated set decides what shows.
struct StreamContainer: View {
    let model: ConnectionModel

    @AppStorage(StripPreferences.edgeKey)
    private var stripEdgeRaw = StripEdge.bottom.rawValue
    @AppStorage(StripPreferences.hiddenKey)
    private var stripHidden = false

    @State private var stripVisible = false
    /// A reference type: pointer-rate events mutate the policy inside
    /// the box without invalidating any view; only visibility flips
    /// touch @State.
    @State private var reveal = StripRevealBooks()
    /// A file drag is over the window; the drop hint renders while true.
    @State private var dropTargeted = false

    private var stripEdge: StripEdge {
        StripEdge(rawValue: stripEdgeRaw) ?? .bottom
    }

    /// "Video was delayed 5 times in the last minute, worst was 49 ms":
    /// every number in the warning describes the same live 60-second window.
    /// The pill is failure-only: disturbances absorbed by the Conductor stay
    /// in diagnostics and never become user-facing alarm copy.
    private func linkHealthLine(
        _ health: LinkHealthAssessment
    ) -> String {
        let recent = health.stallsLastMinute.formatted()
        let occurrence = health.stallsLastMinute == 1
            ? "1 time"
            : "\(recent) times"
        guard health.worstStallMilliseconds > 0 else {
            return "Video playback failed \(occurrence) in the last minute"
        }
        let worst = max(1, Int(ceil(health.worstStallMilliseconds)))
        return "Video was delayed \(occurrence) in the last minute, "
            + "worst was \(worst.formatted()) ms"
    }

    var body: some View {
        StreamView(model: model, onMouseActivity: { pointerActivity($0) })
            .overlay(alignment: stripEdge == .top ? .bottom : .top) {
                // The connection-health pill, tiered: a short blip is the
                // FROZEN pill; past the roaming thresholds the banner says
                // what is happening. Never modal; on the edge opposite
                // the strip so they never stack.
                VStack(spacing: 6) {
                    if let line = model.roamingStatusLine {
                        Label(line, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    } else if model.lyteFrozen {
                        Label("Connection interrupted…",
                              systemImage: "wifi.exclamationmark")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                    // The chroma fallback banner: the host lacked the
                    // declared tier and the session re-dialed at Good.
                    if let notice = model.chromaNotice {
                        Label(notice, systemImage: "camera.filters")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                    // The link-health pill: only terminal, uncorrectable
                    // presentation misses or renderer failures, folded to
                    // a verdict at 1 Hz. Filled with its color and bold
                    // text (black on amber) so it reads across the room.
                    if let health = model.linkHealth,
                       health.level != .good {
                        Label(linkHealthLine(health),
                              systemImage: "waveform.path.ecg")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(
                                health.level == .poor
                                    ? Color.red : Color.yellow))
                            .foregroundStyle(
                                health.level == .poor
                                    ? Color.white : Color.black)
                            .transition(.opacity)
                            .help("Frames Lyte could not preserve or the "
                                + "renderer failed during the last minute. "
                                + "Corrected delivery disturbances are not "
                                + "shown.")
                    }
                }
                .padding(stripEdge == .top ? .bottom : .top, 10)
                .task {
                    // The 1 Hz verdict tick; folds only new frames.
                    while !Task.isCancelled {
                        model.tickLinkHealth()
                        try? await Task.sleep(for: .seconds(1))
                    }
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
                // The transfer pill and verdict line, in the trailing
                // corner of the strip's opposite edge.
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
                // The drop hint shows the capability verdict during the
                // drag, so nobody completes a doomed drop to learn it.
                if dropTargeted {
                    DropHintOverlay(
                        accepting: model.negotiated.bulkTransfer,
                        hostName: model.hostName ?? "the host")
                }
            }
            // Drag sessions ride NSDraggingDestination, not the input
            // capture's NSEvent monitors, and this modifier lives on the
            // overlay layer whose points the capture returns to AppKit —
            // drag-and-drop never reaches the host.
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
                            reveal.policy.hoverChanged(hovering, now: SystemMonotonicClock.nowNanoseconds)
                            syncAndSchedule()
                        }
                        .transition(.opacity.combined(
                            with: .move(edge: stripEdge == .top ? .top : .bottom)))
                }
            }
            // Backup pointer path for a non-key window (the NSEvent
            // monitor sees only key-window events); its `.ended` is the
            // one window-exit signal.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard reveal.viewSize.height > 0 else { return }
                    // SwiftUI's local space is top-left-origin. Non-key
                    // windows are never the fullscreen front, so the
                    // sliver rule rides the capture path.
                    pointerActivity(PointerActivity(
                        distanceFromBottom: reveal.viewSize.height - point.y,
                        distanceFromTop: point.y,
                        isFullscreen: false))
                case .ended:
                    reveal.policy.pointerExitedWindow(now: SystemMonotonicClock.nowNanoseconds)
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
            .animation(.easeInOut(duration: 0.3), value: model.chromaNotice)
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
            now: SystemMonotonicClock.nowNanoseconds)
        syncAndSchedule()
    }

    /// The strip's own position toggle: persist the new edge and keep
    /// the (teleported) strip alive a full idle interval so it doesn't
    /// vanish mid-move — the pointer is at the OLD edge now.
    private func moveEdge(to edge: StripEdge) {
        stripEdgeRaw = edge.rawValue
        reveal.policy.keepAlive(now: SystemMonotonicClock.nowNanoseconds)
        syncAndSchedule()
    }

    /// Mirrors the policy's visibility into @State and keeps one standing
    /// deadline task alive while the policy has work pending (dwell,
    /// idle fade): it sleeps to the current deadline and looks again.
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
                let now = SystemMonotonicClock.nowNanoseconds
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

/// StreamContainer's reveal books — a plain class, not Observable:
/// pointer-rate mutations must be invisible to SwiftUI.
@MainActor
private final class StripRevealBooks {
    var policy = StripRevealPolicy()
    var task: Task<Void, Never>?
    /// The container's live size, for the hover path's coordinate flip.
    var viewSize: CGSize = .zero
}

/// The strip: one translucent capsule of session verbs, Disconnect last.
/// Every command is the same model verb the Actions menu drives. The
/// host mute wears a loudspeaker and the local mute headphones, each
/// with a HOST/MAC caption and the same composed diagonal slash.
struct ControlStrip: View {
    @Bindable var model: ConnectionModel
    let edge: StripEdge
    let onMoveEdge: (StripEdge) -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Mute Host Speakers — only with capability key 9. Renders
            // the 0x19-confirmed posture, never the ask.
            if model.negotiated.hostAudioRouting {
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

            // Mute-at-source (key 14): the audio track leaves the wire
            // while the host's own speakers keep playing.
            if model.negotiated.audioStreamOff {
                stripButton(
                    active: model.hostAudioOff,
                    help: model.hostAudioPosture == nil
                        ? "Audio stream — waiting for the host's posture"
                        : (model.hostAudioOff
                            ? "Audio stream is off (zero bandwidth) — click to stream sound again"
                            : "Turn the audio stream off — no sound crosses the network at all"),
                    action: { model.setHostAudioOff(!model.hostAudioOff) },
                    label: {
                        mutableGlyph(base: "waveform",
                                     muted: model.hostAudioOff,
                                     caption: "WIRE")
                    }
                )
                .disabled(model.hostAudioPosture == nil)
            }

            // Client-side mute — the local pipeline's mixer.
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

            // Share Clipboard — only with capability key 10. While off,
            // nothing leaves and nothing lands.
            if model.negotiated.clipboardText {
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

            // The images rung — only when keys 10 and 12 both agree. Its
            // consent rides on top of text sharing.
            if model.negotiated.clipboardImages {
                stripButton(
                    systemImage: model.clipboardImageSharing
                        ? "photo.fill.on.rectangle.fill"
                        : "photo.on.rectangle",
                    active: model.clipboardImageSharing
                        && model.clipboardSharing,
                    help: model.clipboardImageSharing
                        ? "Stop sharing clipboard images with the host"
                        : "Share clipboard images with the host too "
                            + "(PNG, both ways)"
                ) {
                    model.setClipboardImageSharing(
                        !model.clipboardImageSharing)
                }
            }

            // Chroma: Good 4:2:0 / Better 4:2:2 (no wire id — disabled) /
            // Best 4:4:4. Picking a tier is a clean reconnect; a host
            // without it answers typed and the session re-dials at Good.
            ChromaStripMenu(model: model)

            stripButton(
                systemImage: "chart.bar",
                active: model.statsVisible,
                help: model.statsVisible ? "Hide session stats"
                                         : "Show session stats"
            ) {
                model.statsVisible.toggle()
            }

            Divider().frame(height: 18)

            // Flip the strip to the other edge (persisted app-wide).
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

/// The strip's Chroma control: a tier menu with the glyph+caption shape,
/// the caption being the sampling ("4:2:0"/"4:4:4"). Non-Good renders
/// active-orange; the dormant Better row is visible but disabled.
struct ChromaStripMenu: View {
    @Bindable var model: ConnectionModel

    var body: some View {
        Menu {
            ForEach(ChromaTier.allCases, id: \.self) { tier in
                Button {
                    model.setChromaTier(tier)
                } label: {
                    if model.chromaTier == tier {
                        Label(rowTitle(tier), systemImage: "checkmark")
                    } else {
                        Text(rowTitle(tier))
                    }
                }
                .disabled(!tier.isSelectable)
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 17)
                Text(model.chromaTier.samplingLabel)
                    .font(.system(size: 7, weight: .semibold))
                    .kerning(0.5)
                    .opacity(0.75)
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(model.chromaTier != .good
                ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Chroma — Good 4:2:0 / Better 4:2:2 / Best 4:4:4 "
            + "(changing the tier reconnects)")
    }

    private func rowTitle(_ tier: ChromaTier) -> String {
        let base = "\(tier.displayName) (\(tier.samplingLabel))"
        return tier.isSelectable
            ? base : base + " — not yet available"
    }
}

/// The transfer pill: file name, phase/progress, queue depth, and a
/// cancel ×. Its SwiftUI content claims its own points, so clicks here
/// never reach the host cursor.
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

/// The drag-over hint: the host's file consent during the drag.
/// Hit-test transparent — a hint must never eat the drop.
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

/// The compact stats overlay, re-read once a second while visible.
struct StatsOverlay: View {
    let model: ConnectionModel
    @State private var rows: [SessionStatsRow] = []

    var body: some View {
        // Two-column ledger: labels right-aligned and dimmed, values
        // left-aligned. Lowercase is nominal; caps are alarms.
        Grid(alignment: .topLeading,
             horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(rows) { statsRow in
                GridRow {
                    Text(statsRow.label)
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(statsRow.value)
                }
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.9))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.55)))
        .task {
            while !Task.isCancelled {
                rows = model.statsRows()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .allowsHitTesting(false)
    }
}
