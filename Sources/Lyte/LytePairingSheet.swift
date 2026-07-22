import SwiftUI
import LyteTransport
import LyteWire

/// CL-6: the pairing sheet, off a discovered Lyte host row — pure
/// SwiftUI per the plan's cross-cutting rule. The flow mirrors
/// `wire-pair`: the host's console shows a static-key banner and a
/// 6-digit PIN (`lyte-host --wire-listen PORT --pair`); the operator
/// pastes the key (validated live against the TXT `pkh` this host
/// advertises — the typo firewall) and types the PIN; CPace does the
/// rest. On success the host static is pinned and reconnects are
/// zero-UI Noise IK.
///
/// The key paste is a bootstrap-era surface: the advertisement carries
/// only the identity HASH on purpose (HS-10), so first contact needs the
/// key itself hand-carried once. A host already pinned under the same
/// identity skips the paste (re-pair path).
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
    /// Progress lines stream from worker threads; latest one shows.
    @State private var paired = false

    /// A pinned key matching this host's advertised identity — the
    /// re-pair path needs no paste.
    private var alreadyPinnedKey: [UInt8]? {
        PinnedHostStore.load().host(publicKeyHash: host.publicKeyHash)?
            .staticPublicKey
    }

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
        effectiveHostKey != nil && pin.count == 6
            && pin.allSatisfy(\.isNumber)
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
                    Button("Cancel") { onDone(paired) }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 460)
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
                Button("Cancel") { onDone(paired) }
                Button("Pair") { startPairing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPair)
            }
        }
    }

    private func startPairing() {
        guard let hostKey = effectiveHostKey else { return }
        let identity: NoiseKeyPair
        do {
            identity = try ClientNoiseIdentity.loadOrCreate()
        } catch {
            phase = .failed("Keychain refused the client identity (\(error)) "
                + "— the app must be built via Scripts/make-app.sh so its "
                + "signature is stable")
            return
        }
        phase = .running("Connecting…")
        let config = LytePairing.Config(
            hostAddress: host.address,
            hostPort: host.port,
            hostStaticPublicKey: hostKey,
            pin: pin,
            clientStaticKeys: identity,
            onProgress: { line in
                Task { @MainActor in
                    if case .running = phase { phase = .running(line) }
                }
            })
        let target = host
        Task.detached {
            let outcome = LytePairing.run(config)
            await MainActor.run {
                switch outcome {
                case .paired(let key):
                    var store = PinnedHostStore.load()
                    store.pin(
                        staticPublicKey: key,
                        name: target.name,
                        address: target.address,
                        port: target.port,
                        pairedAt: ISO8601DateFormatter().string(from: Date()))
                    do {
                        try store.save()
                        paired = true
                        phase = .paired
                    } catch {
                        phase = .failed("Paired, but saving the pin failed: \(error)")
                    }
                case .pinMismatch:
                    phase = .failed("Wrong PIN — the host disagreed with this "
                        + "entry. Three wrong guesses burn the PIN; restart "
                        + "pairing on the host for a fresh one.")
                case .hostRejected(let reason):
                    phase = .failed("The host rejected the pairing (\(reason)).")
                case .invalidShare:
                    phase = .failed("The host's cryptographic share was invalid.")
                case .timedOut:
                    phase = .failed("No answer — is the host running with "
                        + "--pair? (A burned PIN also answers nothing.)")
                case .failed(let message):
                    phase = .failed(message)
                }
            }
        }
    }
}
