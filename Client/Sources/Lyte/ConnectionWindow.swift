import Foundation
import LyteTransport
import SwiftUI

/// One window = one connection (D6). Starts in the connect state; becomes a
/// pure stream when a session launches.
struct ConnectionWindow: View {
    var autoconnect: String?
    @State private var model = ConnectionModel()
    @State private var didAutoconnect = false

    init(autoconnect: String? = nil) {
        self.autoconnect = autoconnect
    }

    var body: some View {
        Group {
            switch model.phase {
            case .pickHost, .connecting, .failed:
                ConnectView(model: model)
            case .streaming:
                // CL-13: the stream + its overlays (FROZEN pill, stats
                // readout, the auto-hiding control strip) live in
                // StreamContainer.
                StreamContainer(model: model)
                    .task {
                        await DiagnosticBenchmark.run(model: model)
                    }
            }
        }
        .navigationTitle(model.windowTitle)
        .focusedSceneValue(\.connection, model)
        .frame(minWidth: 480, minHeight: 320)
        .overlay(alignment: .topLeading) {
            if let badge = ProcessInfo.processInfo.environment[
                "LYTE_DIAGNOSTIC_BUILD_BADGE"
            ] {
                Text(badge)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.78), in: RoundedRectangle(
                        cornerRadius: 4))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .task {
            // Repeatable real-app diagnostics without UI scripting. Normal
            // launches never enter this path; setting LYTE_AUTOCONNECT to a
            // pinned host's name exercises the exact production window,
            // renderer, input, helper, and session lifecycle.
            guard !didAutoconnect, let requested = autoconnect else { return }
            didAutoconnect = true
            // A LaunchServices start is the path macOS subjects to Local
            // Network privacy. Let Bonjour finish its authorization probe
            // before a diagnostic UDP send; otherwise autoconnect can race
            // the prompt and collapse a policy decision into errno 65.
            let preflight = await LyteDiscovery.scan(duration: 1.0)
            if let problem = preflight.accessProblem {
                model.phase = .failed(.localNetwork(
                    problem,
                    diagnosticDetail: "autoconnect preflight: \(problem)"))
                return
            }
            let store = PinnedHostStore.load()
            var probe = in_addr()
            let requestedIsAddress =
                inet_pton(AF_INET, requested, &probe) == 1
            let matched = store.hosts.values.first(where: {
                $0.name.localizedCaseInsensitiveContains(requested)
                    || $0.address == requested
            })
            // An IP-shaped request whose address no pin remembers is a
            // transport override — the host moved roads (Wi-Fi→wire)
            // while the pin kept the old one. With exactly one pin
            // there is no ambiguity about WHO we mean, and Noise still
            // enforces the identity at the requested address; only the
            // route differs.
            let fallback = (matched == nil && requestedIsAddress
                && store.hosts.count == 1) ? store.hosts.values.first : nil
            guard let pinned = matched ?? fallback,
                  let publicKeyHash = pinned.publicKeyHash else {
                NSLog(
                    "lyte diagnostic: no pinned host matches %@ (%d pins)",
                    requested, store.hosts.count)
                return
            }
            let dialAddress = requestedIsAddress ? requested : pinned.address
            NSLog(
                "lyte diagnostic: autoconnecting %@:%d",
                dialAddress, pinned.port)
            await model.connectLyte(DiscoveredLyteHost(
                name: pinned.name,
                address: dialAddress,
                port: pinned.port,
                wireVersion: nil,
                publicKeyHash: publicKeyHash))
        }
        .onDisappear {
            // The ⌘W seam (v1-final analysis, finding 1): closing the
            // window is the most natural macOS exit, and it was the one
            // verb with no teardown — the receive thread, 100 ms
            // machine beat, and feedback cadence outlived the window,
            // no typed 0x0A left, the host kept encoding full-rate
            // into the void, and awdl0 stayed held down until app
            // quit. One window = one connection (D6), so the window's
            // disappearance IS the disconnect. This modifier sits on
            // the whole body — phase flips inside the Group never
            // detach it, only the window going away does — and
            // endLyteSession's guard makes the already-disconnected
            // and app-quit paths harmless no-ops.
            model.disconnect()
        }
    }
}
