import SwiftUI
import AppKit
import LyteTransport

/// The window's empty state (D6): discovered Lyte hosts and pairing.
/// Melts away when the stream starts.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var lyteHosts: [DiscoveredLyteHost] = []
    @State private var browsing = false
    @State private var accessProblem: LocalNetworkAccessProblem?
    @State private var rescanWhenActive = false
    // CL-6: the pairing sheet's target, and a pinned-store snapshot for
    // the paired badges (reloaded after every pair/unpair).
    @State private var pairingTarget: DiscoveredLyteHost?
    @State private var pinnedStore = PinnedHostStore.load()

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .pickHost:
                hostPicker
            case .connecting(let message):
                Spacer()
                ProgressView(message)
                // The respawn-gap hunt can run tens of seconds — the
                // human always has the exit.
                Button("Cancel") { model.cancelConnect() }
                    .padding(.top, 16)
                Spacer()
            case .failed(let message):
                failedView(message)
            case .streaming:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [Color.indigo.opacity(0.10), .clear],
                               center: .top, startRadius: 0, endRadius: 600)
            }
            .ignoresSafeArea()
        }
        .task { await browse() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, rescanWhenActive else { return }
            if case .failed = model.phase { model.phase = .pickHost }
            Task { await browse(afterSettings: true) }
        }
        .sheet(item: $pairingTarget) { host in
            LytePairingSheet(host: host) { pairedNow in
                if pairedNow { pinnedStore = PinnedHostStore.load() }
                pairingTarget = nil
            }
        }
    }

    // MARK: - Hosts

    private var hostPicker: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(nsImage: LyteUIIconBridge.icon)
                .resizable()
                .frame(width: 64, height: 64)

            // Hosts are the hero: an unpaired row opens the pairing
            // sheet; a paired one wears its badge and is a launch button.
            VStack(spacing: 10) {
                if lyteHosts.isEmpty && browsing {
                    ProgressView("Looking for hosts…")
                        .controlSize(.small)
                } else if lyteHosts.isEmpty, let accessProblem {
                    localNetworkAccessView(accessProblem)
                } else if lyteHosts.isEmpty {
                    Text("No hosts found on this network")
                        .foregroundStyle(.secondary)
                }
                ForEach(lyteHosts) { host in
                    lyteHostRow(host)
                }
                Button("Search Again") { Task { await browse() } }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .disabled(browsing)
            }
            Spacer()
        }
        .padding(32)
    }

    private func browse(afterSettings: Bool = false) async {
        if afterSettings { rescanWhenActive = true }
        guard !browsing else { return }
        while true {
            // Claim the Settings-return intent only when this scan is truly
            // about to start. An older scan leaves the flag queued and
            // consumes it immediately after completion.
            if rescanWhenActive, scenePhase == .active {
                rescanWhenActive = false
            }
            browsing = true
            let scan = await LyteDiscovery.scan(duration: 3.0)
            lyteHosts = scan.hosts
            accessProblem = scan.blockingAccessProblem
            browsing = false
            guard rescanWhenActive, scenePhase == .active else { return }
        }
    }

    private func localNetworkAccessView(
        _ problem: LocalNetworkAccessProblem
    ) -> some View {
        VStack(spacing: 8) {
            Text(problem == .permissionRequired
                ? "Local Network access is required"
                : "Lyte found a host but couldn’t reach it")
                .fontWeight(.medium)
            Text(localNetworkRecovery(problem))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Open System Settings") { openSystemSettings() }
                .buttonStyle(.bordered)
        }
    }

    private func openSystemSettings() {
        rescanWhenActive = true
        NSWorkspace.shared.open(URL(
            fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// One Lyte host row: unpaired opens the pairing sheet; paired is a
    /// launch button — clicking it dials the pinned static with the
    /// Keychain identity and opens the stream (CL-8's session slice).
    @ViewBuilder
    private func lyteHostRow(_ host: DiscoveredLyteHost) -> some View {
        let pinned = pinnedStore.host(publicKeyHash: host.publicKeyHash)
        Group {
            if pinned != nil {
                Button {
                    Task { await model.connectLyte(host) }
                } label: {
                    lyteHostLabel(host, paired: true)
                        .frame(maxWidth: 340)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            } else {
                lyteHostLabel(host, paired: false)
                    .frame(maxWidth: 340)
            }
        }
        .help(lyteHostTooltip(host, paired: pinned != nil))
        .contextMenu {
            if let pinned {
                // CL-13: the per-host session-start posture — applied
                // at connect; the strip's toggle overrides live.
                // CL-18: opt-out semantics — unset means muted (the
                // flipped default), so this reads `!= false` (checked
                // by default) and writes BOTH directions explicitly.
                Toggle("Start with Host Muted", isOn: Binding(
                    get: {
                        pinnedStore.host(publicKeyHash: host.publicKeyHash)?
                            .startHostAudioMuted != false
                    },
                    set: { muted in
                        guard let pkh = host.publicKeyHash else { return }
                        var store = PinnedHostStore.load()
                        store.setStartHostAudioMuted(
                            publicKeyHash: pkh, muted: muted)
                        try? store.save()
                        pinnedStore = store
                    }
                ))
                // CL-15: the per-host clipboard consent — applied at
                // connect; the strip's toggle overrides live. OFF by
                // default (clipboards carry passwords).
                Toggle("Share Clipboard", isOn: Binding(
                    get: {
                        pinnedStore.host(publicKeyHash: host.publicKeyHash)?
                            .shareClipboard == true
                    },
                    set: { share in
                        guard let pkh = host.publicKeyHash else { return }
                        var store = PinnedHostStore.load()
                        store.setShareClipboard(
                            publicKeyHash: pkh, share: share ? true : nil)
                        try? store.save()
                        pinnedStore = store
                    }
                ))
                // P-1: the images rung — meaningful only with text
                // consent on (the Off / Text only / Text + images
                // tier); OFF by default like text.
                Toggle("Share Clipboard Images", isOn: Binding(
                    get: {
                        pinnedStore.host(publicKeyHash: host.publicKeyHash)?
                            .shareClipboardImages == true
                    },
                    set: { share in
                        guard let pkh = host.publicKeyHash else { return }
                        var store = PinnedHostStore.load()
                        store.setShareClipboardImages(
                            publicKeyHash: pkh, share: share ? true : nil)
                        try? store.save()
                        pinnedStore = store
                    }
                ))
                Divider()
                Button("Unpair \(pinned.name)", role: .destructive) {
                    var store = PinnedHostStore.load()
                    if let pkh = host.publicKeyHash {
                        store.unpin(publicKeyHash: pkh)
                        try? store.save()
                        pinnedStore = store
                    }
                }
            } else {
                Button("Pair…") { pairingTarget = host }
            }
        }
    }

    @ViewBuilder
    private func lyteHostLabel(_ host: DiscoveredLyteHost, paired: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.indigo).frame(width: 8, height: 8)
            Text(host.name).fontWeight(.medium)
            Text("\(host.address):\(String(host.port))")
                .foregroundStyle(.secondary)
            Text("Lyte")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.indigo.opacity(0.18)))
                .foregroundStyle(.indigo)
            if paired {
                Label("Paired", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Pair…") { pairingTarget = host }
                    .controlSize(.small)
            }
        }
    }

    private func lyteHostTooltip(_ host: DiscoveredLyteHost, paired: Bool) -> String {
        var parts = ["Lyte-UDP host"]
        if let v = host.wireVersion { parts.append("wire v\(v)") }
        if let pkh = host.publicKeyHash {
            parts.append("identity \(pkh.prefix(8))…")
        }
        parts.append(paired
            ? "paired — click to stream (zero-UI Noise IK reconnect)"
            : "unpaired — Pair… runs the PIN flow")
        return parts.joined(separator: " — ")
    }

    // MARK: - Failure

    private func failedView(_ failure: ConnectionModel.Failure) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(failureTitle(failure))
                .multilineTextAlignment(.center)
            if case .localNetwork(let problem, _) = failure {
                Text(localNetworkRecovery(problem))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Button("Open System Settings") { openSystemSettings() }
                    .buttonStyle(.bordered)
            }
            Button("Start Over") {
                model.phase = .pickHost
                Task { await browse() }
            }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(32)
    }

    private func failureTitle(_ failure: ConnectionModel.Failure) -> String {
        switch failure {
        case .ordinary(let message):
            return message
        case .localNetwork:
            return "Lyte couldn’t reach this host on the local network."
        }
    }

    private func localNetworkRecovery(
        _ problem: LocalNetworkAccessProblem
    ) -> String {
        switch problem {
        case .permissionRequired:
            return "Lyte is waiting for Local Network access. Allow it in "
                + "the macOS prompt, or enable Lyte in System Settings → "
                + "Privacy & Security → Local Network. Then return here; "
                + "Lyte will search again."
        case .routeOrPermissionUnavailable:
            return "The route may be unavailable, or Local Network access "
                + "may be off. Check Lyte in System Settings → Privacy & "
                + "Security → Local Network, then return here to retry."
        }
    }
}

/// Bridges the shared NSImage icon into SwiftUI without exposing LyteUI here.
enum LyteUIIconBridge {
    @MainActor static var icon: NSImage { LyteUI.AppIcon.shared }
}

import LyteUI
