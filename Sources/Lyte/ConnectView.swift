import SwiftUI
import LyteKit
import LyteTransport

/// The window's empty state (D6): discovered hosts + recents; pairing PIN;
/// the chosen host's app list. Melts away when the stream starts.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @State private var discovered: [Discovery.FoundHost] = []
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
            case .pairing(let address, let pin):
                pairingView(address: address, pin: pin)
            case .apps(_, let hostName, let apps):
                appPicker(hostName: hostName, apps: apps)
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

            // Hosts are the hero: click one → the app-launch cards.
            VStack(spacing: 10) {
                if discovered.isEmpty && lyteHosts.isEmpty && browsing {
                    ProgressView("Looking for hosts…")
                        .controlSize(.small)
                } else if discovered.isEmpty && lyteHosts.isEmpty {
                    Text("No hosts found on this network")
                        .foregroundStyle(.secondary)
                }
                // CL-5 dual-browse: Lyte-UDP hosts (_lyte._udp) listed
                // beside the Sunshine ones until the H2 demolition retires
                // the latter. CL-6: an unpaired row opens the pairing
                // sheet; a paired one wears its badge and offers Unpair.
                // Session flow (launching a stream) is CL-7.
                ForEach(lyteHosts, id: \.address) { host in
                    lyteHostRow(host)
                }
                ForEach(discovered, id: \.endpoint) { host in
                    Button {
                        Task { await model.selectHost(host.endpoint, name: host.name) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(host.name).fontWeight(.medium)
                            Text(host.endpoint).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 300)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                Button("Search Again") { Task { await browse() } }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .disabled(browsing)
            }

            // Recents: quiet quick-launch chips, secondary to picking a host.
            let recents = RecentConnections.load()
            if !recents.isEmpty {
                VStack(spacing: 6) {
                    Text("Resume")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(recents.prefix(3).enumerated()), id: \.offset) { _, entry in
                        Button {
                            Task { await model.reconnect(address: entry.address, appTitle: entry.app) }
                        } label: {
                            Label(entry.app, systemImage: "clock.arrow.circlepath")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .padding(32)
    }

    private func browse() async {
        browsing = true
        async let sunshine = Discovery.browse(duration: 3.0)
        async let lyte = LyteDiscovery.browse(duration: 3.0)
        discovered = await sunshine
        lyteHosts = await lyte
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

    // MARK: - Pairing

    private func pairingView(address: String, pin: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Pair with \(model.hostName ?? address)")
                .font(.title2.weight(.semibold))
            Text(pin)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .kerning(8)
            Text("Enter this PIN in the Sunshine web UI on the host")
                .foregroundStyle(.secondary)
            Link("Open Sunshine Web UI",
                 destination: URL(string: "https://\(address):47990/pin")!)
                .buttonStyle(.borderedProminent)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Apps

    private func appPicker(hostName: String, apps: [NvApp]) -> some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 9, height: 9)
                    Text(hostName)
                        .font(.title.weight(.semibold))
                }
                Text("Choose what to stream")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                ForEach(apps, id: \.id) { app in
                    AppCard(title: app.title,
                            symbol: appSymbol(for: app.title),
                            colors: appColors(for: app.title)) {
                        Task { await model.connect(app: app) }
                    }
                }
            }
            Spacer()
        }
        .padding(32)
        .overlay(alignment: .topLeading) {
            Button {
                model.phase = .pickHost
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .padding(20)
            .help("Back to hosts")
        }
    }

    private func appSymbol(for title: String) -> String {
        if title.localizedCaseInsensitiveContains("low res") { return "rectangle.on.rectangle" }
        if title.localizedCaseInsensitiveContains("desktop") { return "desktopcomputer" }
        if title.localizedCaseInsensitiveContains("steam") || title.localizedCaseInsensitiveContains("game") {
            return "gamecontroller.fill"
        }
        return "app.fill"
    }

    private func appColors(for title: String) -> [Color] {
        if title.localizedCaseInsensitiveContains("low res") { return [.teal, .cyan] }
        if title.localizedCaseInsensitiveContains("desktop") { return [.indigo, .blue] }
        if title.localizedCaseInsensitiveContains("steam") || title.localizedCaseInsensitiveContains("game") {
            return [.purple, .indigo]
        }
        return [Color.gray, Color.gray.opacity(0.6)]
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

/// A launchable app as a big friendly card: gradient icon tile + title,
/// with a gentle lift on hover.
private struct AppCard: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: colors,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 108, height: 108)
                        .shadow(color: .black.opacity(hovering ? 0.28 : 0.12),
                                radius: hovering ? 16 : 8, y: hovering ? 10 : 4)
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(6)
            .scaleEffect(hovering ? 1.06 : 1.0)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Bridges the shared NSImage icon into SwiftUI without exposing LyteUI here.
enum LyteUIIconBridge {
    @MainActor static var icon: NSImage { LyteUI.AppIcon.shared }
}

import LyteUI
