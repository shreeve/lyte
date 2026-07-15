import SwiftUI
import LyteKit

/// The window's empty state (D6): discovered hosts + recents; pairing PIN;
/// the chosen host's app list. Melts away when the stream starts.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @State private var discovered: [Discovery.FoundHost] = []
    @State private var browsing = false

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
    }

    // MARK: - Hosts

    private var hostPicker: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(nsImage: LyteUIIconBridge.icon)
                .resizable()
                .frame(width: 72, height: 72)

            let recents = RecentConnections.load()
            if !recents.isEmpty {
                VStack(spacing: 8) {
                    ForEach(recents.prefix(3), id: \.address) { entry in
                        Button {
                            Task {
                                await model.selectHost(entry.address, name: nil)
                            }
                        } label: {
                            Label("\(entry.app) on \(entry.address)", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: 320)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            VStack(spacing: 8) {
                if discovered.isEmpty && browsing {
                    ProgressView("Looking for hosts…")
                        .controlSize(.small)
                } else if discovered.isEmpty {
                    Text("No Sunshine hosts found on this network")
                        .foregroundStyle(.secondary)
                }
                ForEach(discovered, id: \.endpoint) { host in
                    Button {
                        Task { await model.selectHost(host.endpoint, name: host.name) }
                    } label: {
                        Label("\(host.name) — \(host.endpoint)", systemImage: "desktopcomputer")
                            .frame(maxWidth: 320)
                    }
                    .controlSize(.large)
                }
                Button("Search Again") { Task { await browse() } }
                    .controlSize(.small)
                    .disabled(browsing)
            }
            Spacer()
        }
        .padding(32)
    }

    private func browse() async {
        browsing = true
        discovered = await Discovery.browse(duration: 3.0)
        browsing = false
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
