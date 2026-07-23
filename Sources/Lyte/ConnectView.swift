import SwiftUI
import LyteTransport

/// The window's empty state (D6): discovered Lyte hosts and pairing.
/// Melts away when the stream starts.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @State private var lyteHosts: [DiscoveredLyteHost] = []
    @State private var browsing = false
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
                } else if lyteHosts.isEmpty {
                    Text("No hosts found on this network")
                        .foregroundStyle(.secondary)
                }
                ForEach(lyteHosts, id: \.address) { host in
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

    private func browse() async {
        browsing = true
        lyteHosts = await LyteDiscovery.browse(duration: 3.0)
        browsing = false
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
                Toggle("Start with Host Muted", isOn: Binding(
                    get: {
                        pinnedStore.host(publicKeyHash: host.publicKeyHash)?
                            .startHostAudioMuted == true
                    },
                    set: { muted in
                        guard let pkh = host.publicKeyHash else { return }
                        var store = PinnedHostStore.load()
                        store.setStartHostAudioMuted(
                            publicKeyHash: pkh, muted: muted ? true : nil)
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

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Start Over") { model.phase = .pickHost }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(32)
    }
}

/// Bridges the shared NSImage icon into SwiftUI without exposing LyteUI here.
enum LyteUIIconBridge {
    @MainActor static var icon: NSImage { LyteUI.AppIcon.shared }
}

import LyteUI
