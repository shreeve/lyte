import SwiftUI
import AppKit
import LyteTransport
import LyteUI

/// The window's empty state: discovered Lyte hosts and pairing. Melts
/// away when the stream starts.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var lyteHosts: [DiscoveredLyteHost] = []
    @State private var browsing = false
    @State private var accessProblem: LocalNetworkAccessProblem?
    @State private var rescanWhenActive = false
    // The pairing sheet's target, and a pinned-store snapshot for the
    // paired badges: read when the view appears and after every write,
    // never per render.
    @State private var pairingTarget: DiscoveredLyteHost?
    @State private var pinnedStore = PinnedHostStore()
    // The typed address, and the one awaiting "which paired host is
    // this?" when no pin knows it.
    @State private var typedAddress = ""
    @State private var typedTarget: TypedHostAddress?

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
                Button("Cancel") { model.disconnect() }
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
        .onAppear { pinnedStore = loadPinnedHosts() }
        .task { await browse() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, rescanWhenActive else { return }
            if case .failed = model.phase { model.phase = .pickHost }
            Task { await browse(afterSettings: true) }
        }
        .sheet(item: $pairingTarget) { host in
            LytePairingSheet(host: host) { pairedNow in
                if pairedNow { pinnedStore = loadPinnedHosts() }
                pairingTarget = nil
            }
        }
    }

    // MARK: - Hosts

    private var hostPicker: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
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
                // Paired hosts this scan did not see still dial their
                // last-known address.
                if !browsing {
                    ForEach(pinnedStore.unsighted(excluding: lyteHosts), id: \.publicKeyHash) { host in
                        lyteHostRow(host, lastSeen: true)
                    }
                }
                Button("Search Again") { Task { await browse() } }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .disabled(browsing)
            }
            typedAddressField
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Typed address

    /// Routed and mDNS-less networks: a host name or IPv4 address, with
    /// an optional port, dialed like any listed host.
    private var typedAddressField: some View {
        let parsed = TypedHostAddress.parse(typedAddress)
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField("Host address", text: $typedAddress,
                          prompt: Text("Host name or IPv4 address[:port]"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(connectTyped)
                Button("Connect", action: connectTyped)
                    .disabled((try? parsed.get()) == nil)
            }
            if case .failure(let problem) = parsed, problem != .empty {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Which host is at \(typedTarget?.host ?? "this address")?",
            isPresented: Binding(
                get: { typedTarget != nil },
                set: { if !$0 { typedTarget = nil } }),
            presenting: typedTarget
        ) { typed in
            ForEach(pinnedStore.hosts.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }, id: \.staticPublicKeyHex) { pinned in
                Button("Connect to \(pinned.name)") {
                    Task { await model.connectLyte(typed.dialing(pinned)) }
                }
            }
            Button("Pair a New Host…") { pairingTarget = typed.unpaired }
        } message: { _ in
            Text("A paired host is dialed under its pinned identity; a new one pairs with its key and PIN.")
        }
    }

    /// A paired host the text names (or was last seen at) dials at once;
    /// an address no pin knows asks which paired host lives there, or
    /// pairs a new one — never a dial without a pinned or pasted key.
    private func connectTyped() {
        guard case .success(let typed) = TypedHostAddress.parse(typedAddress)
        else { return }
        if let pinned = typed.pinned(in: pinnedStore) {
            Task { await model.connectLyte(typed.dialing(pinned)) }
        } else if pinnedStore.hosts.isEmpty {
            pairingTarget = typed.unpaired
        } else {
            typedTarget = typed
        }
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

/// One Lyte host row: unpaired opens the pairing sheet; paired dials the
/// pinned static with the Keychain identity and opens the stream.
    @ViewBuilder
    private func lyteHostRow(
        _ host: DiscoveredLyteHost, lastSeen: Bool = false
    ) -> some View {
        let pinned = pinnedStore.host(publicKeyHash: host.publicKeyHash)
        Group {
            if pinned != nil {
                Button {
                    Task { await model.connectLyte(host) }
                } label: {
                    lyteHostLabel(host, paired: true, lastSeen: lastSeen)
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
                // The per-host defaults, applied at connect.
                ForEach(HostPreference.allCases, id: \.self) { preference in
                    Toggle(preference.pickerTitle, isOn: Binding(
                        get: { preference.value(in: pinned) },
                        set: { on in
                            updatePins(host) { preference.set(on, in: &$0, publicKeyHash: $1) }
                        }
                    ))
                }
                Divider()
                Button("Unpair \(pinned.name)", role: .destructive) {
                    updatePins(host) { $0.unpin(publicKeyHash: $1) != nil }
                }
            } else {
                Button("Pair…") { pairingTarget = host }
            }
        }
    }

    /// Load–mutate–save for one host's pin; `mutate` returns false when
    /// nothing changed.
    private func updatePins(
        _ host: DiscoveredLyteHost,
        _ mutate: (inout PinnedHostStore, String) -> Bool
    ) {
        guard let pkh = host.publicKeyHash else { return }
        var store = model.services.loadPins()
        guard mutate(&store, pkh) else { return }
        try? model.services.savePins(store)
        pinnedStore = store
    }

    @ViewBuilder
    private func lyteHostLabel(
        _ host: DiscoveredLyteHost, paired: Bool, lastSeen: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.indigo).frame(width: 8, height: 8)
            Text(host.name).fontWeight(.medium)
            Text((lastSeen ? "last seen at " : "")
                + "\(host.address):\(String(host.port))")
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

extension HostPreference {
    var pickerTitle: String {
        switch self {
        case .startHostMuted: "Start with Host Muted"
        case .shareClipboard: "Share Clipboard"
        case .shareClipboardImages: "Share Clipboard Images"
        }
    }
}

extension PinnedHostStore {
    /// The paired hosts no sighting carries, by name, as rows that dial
    /// the pinned address and port.
    func unsighted(excluding sighted: [DiscoveredLyteHost]) -> [DiscoveredLyteHost] {
        let seen = Set(sighted.compactMap(\.publicKeyHash))
        return hosts.filter { !seen.contains($0.key) }
            .map {
                DiscoveredLyteHost(
                    name: $0.value.name, address: $0.value.address,
                    port: $0.value.port, wireVersion: nil, publicKeyHash: $0.key)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
