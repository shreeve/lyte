import SwiftUI
import LyteTransport
import LyteWire

/// The pairing sheet, off a discovered Lyte host row; the flow mirrors
/// `wire-pair`. The operator pastes the host's static key (validated
/// live against the advertised TXT `pkh`) and types the PIN; CPace does
/// the rest. On success the host static is pinned and reconnects are
/// zero-UI Noise IK. The advertisement carries only the identity hash,
/// so first contact needs the key hand-carried once; a host already
/// pinned under the same identity skips the paste.
struct LytePairingSheet: View {
    let host: DiscoveredLyteHost
    /// Called on dismiss; true when a pairing landed (the caller
    /// refreshes its pinned-store snapshot).
    let onDone: (Bool) -> Void

    private enum Phase: Equatable {
        case form
        case running(String)
        case paired
        case failed(String)
    }

    @State private var hostKeyHex = ""
    @State private var pin = ""
    @State private var phase: Phase = .form
    /// A pinned key matching this host's advertised identity — the
    /// re-pair path needs no paste. Read once when the sheet appears.
    @State private var alreadyPinnedKey: [UInt8]?

    /// The pasted key parsed, nil while malformed.
    private var pastedKey: [UInt8]? {
        try? NoiseTransportCrypto.parseKeyHex(hostKeyHex)
    }

    /// Whether the pasted key matches the advertised identity hash.
    /// nil = no advertisement to check against (still allowed — manual
    /// hosts advertise nothing).
    private var pastedKeyMatchesAdvertisement: Bool? {
        guard let key = pastedKey, let pkh = host.publicKeyHash else {
            return nil
        }
        return LyteDiscovery.publicKeyHash(ofStaticPublicKey: key) == pkh
    }

    private var effectiveHostKey: [UInt8]? {
        if let pasted = pastedKey {
            guard pastedKeyMatchesAdvertisement != false else { return nil }
            return pasted
        }
        return alreadyPinnedKey
    }

    private var canPair: Bool {
        effectiveHostKey != nil && PairingPin.isValid(pin)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair with \(host.name)")
                .font(.title2.weight(.semibold))
            Text("\(host.address):\(String(host.port))")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            switch phase {
            case .form:
                form
            case .running(let line):
                ProgressView()
                    .controlSize(.small)
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.center)
            case .paired:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("Paired — reconnects are now automatic")
                    .font(.callout)
                Button("Done") { onDone(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Try Again") { phase = .form }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { onDone(false) }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 460)
        .onAppear {
            alreadyPinnedKey = loadPinnedHosts()
                .host(publicKeyHash: host.publicKeyHash)?.staticPublicKey
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if alreadyPinnedKey != nil && hostKeyHex.isEmpty {
                Label("Known identity — using the pinned key",
                      systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Host key (from the lyte-host console banner)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("64 hex digits — “noise: host static public key …”",
                              text: $hostKeyHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    if !hostKeyHex.isEmpty {
                        switch pastedKeyMatchesAdvertisement {
                        case .some(true):
                            Label("Matches this host's advertised identity",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .some(false):
                            Label("Does NOT match the advertised identity — check the banner",
                                  systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        case .none:
                            if pastedKey == nil {
                                Label("Not a 64-hex-digit key yet",
                                      systemImage: "circle.dotted")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PIN (shown on the host's console)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("6 digits", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .frame(width: 140)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(false) }
                Button("Pair") { startPairing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPair)
            }
        }
    }

    private func startPairing() {
        guard let hostKey = effectiveHostKey else { return }
        phase = .running("Unlocking client identity…")
        let target = host
        Task { @MainActor in
            let identity: NoiseKeyPair
            do {
                identity = try await ClientNoiseIdentityProvider.shared
                    .identity()
            } catch {
                phase = .failed(
                    "Keychain refused the client identity (\(error)) "
                        + "— the app must be built via Scripts/make-app.sh "
                        + "so its signature is stable")
                return
            }
            guard case .running = phase else { return }
            phase = .running("Connecting…")
            let config = LytePairing.Config(
                hostAddress: target.address,
                hostPort: target.port,
                hostStaticPublicKey: hostKey,
                pin: pin,
                clientStaticKeys: identity,
                onProgress: { line in
                    Task { @MainActor in
                        if case .running = phase { phase = .running(line) }
                    }
                })
            let outcome = await Task.detached {
                LytePairing.run(config)
            }.value
            guard case .paired(let key) = outcome else {
                phase = .failed(outcome.failureMessage ?? "Pairing failed.")
                return
            }
            var store = loadPinnedHosts()
            store.pinPaired(
                staticPublicKey: key, name: target.name,
                address: target.address, port: target.port)
            do {
                try store.save()
                phase = .paired
            } catch {
                phase = .failed("Paired, but saving the pin failed: \(error)")
            }
        }
    }
}
