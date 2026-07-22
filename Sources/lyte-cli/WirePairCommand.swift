import ArgumentParser
import Foundation
import LyteTransport
import LyteWire

/// CL-6: PIN pairing against a Lyte-UDP host. The host side runs
/// `lyte-host --wire-listen PORT --pair`, which prints its static public
/// key and a 6-digit PIN on ITS console; this command dials that key
/// trust-on-first-use, runs the W6 CPace exchange bound to the Noise
/// session (sid = handshake hash, CI = both statics), and on a verified
/// confirmation pins the host static locally — the host pins ours in the
/// same exchange. Every later connect is plain Noise IK against the
/// pinned keys, no PIN, no UI (`wire-view` without --host-key).
///
/// The client identity lives in the login Keychain
/// (ClientNoiseIdentity): build this binary via Scripts/build-cli.sh so
/// the stable "Lyte Dev" signature keeps the Keychain grant across
/// rebuilds (docs/MACOS-SIGNING.md).
struct WirePair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-pair",
        abstract: "Pair with a Lyte-UDP host: PIN → CPace → pinned Noise statics.")

    @Argument(help: "Host: discovered Lyte host name, or an IP address")
    var host: String

    @Option(name: .long, help: "The host's --wire-listen port (default: from discovery)")
    var port: UInt16 = 0

    @Option(name: .long, help: "The 6-digit PIN printed on the host's console")
    var pin: String

    @Option(name: .long, help: "The host's static public key, 64 hex digits (from lyte-host's banner; optional when the host is discoverable and already pinned)")
    var hostKey: String?

    @Option(name: .long, help: "Seconds to wait for the pairing verdict")
    var timeout: Double = 20

    func validate() throws {
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else {
            throw ValidationError("--pin must be the host's 6 digits, got \"\(pin)\"")
        }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)

        // ── Resolve the dial target: discovery by name/address, manual
        // host:port as the always-working fallback. ──
        var address = host
        var dialPort = port
        var advertisedPkh: String?
        let isLiteralAddress = host.allSatisfy { $0.isNumber || $0 == "." }
        if !isLiteralAddress || dialPort == 0 {
            print("wire-pair: browsing \(LyteDiscovery.serviceType) …")
            let found = await LyteDiscovery.browse(duration: 3.0)
            if let match = found.first(where: {
                $0.name.caseInsensitiveCompare(host) == .orderedSame
                    || $0.address == host
            }) {
                address = match.address
                if dialPort == 0 { dialPort = match.port }
                advertisedPkh = match.publicKeyHash
                print("wire-pair: found \(match.name) at "
                    + "\(match.address):\(match.port)"
                    + (match.publicKeyHash.map { ", identity \($0.prefix(8))…" } ?? ""))
            }
        }
        guard dialPort != 0 else {
            throw ValidationError(
                "no port: \(host) was not discovered — pass --port (the host's --wire-listen port)")
        }

        // ── The host static: the banner's hex, checked against the
        // advertisement's hash when both are in hand (typo firewall). ──
        let hostStatic: [UInt8]
        if let hostKey {
            hostStatic = try NoiseTransportCrypto.parseKeyHex(hostKey)
            if let pkh = advertisedPkh,
               LyteDiscovery.publicKeyHash(ofStaticPublicKey: hostStatic) != pkh {
                throw ValidationError(
                    "--host-key does not match the identity this host advertises (pkh \(pkh.prefix(16))…) — check the banner")
            }
        } else if let pinned = PinnedHostStore.load().host(publicKeyHash: advertisedPkh),
                  let key = pinned.staticPublicKey {
            // Re-pairing a known host: the pinned key IS the advertised
            // identity (hash-matched), so no banner hand-carry needed.
            hostStatic = key
            print("wire-pair: using the already-pinned static for this identity")
        } else {
            throw ValidationError(
                "no host key: pass --host-key <64 hex> from lyte-host's \"noise: host static public key …\" banner")
        }

        // ── Our persistent identity (Keychain; minted on first pairing). ──
        let identity: NoiseKeyPair
        do {
            identity = try ClientNoiseIdentity.loadOrCreate()
        } catch ClientNoiseIdentityError.keychain(let status) {
            throw ValidationError(
                "Keychain refused the client identity (OSStatus \(status)) — build via Scripts/build-cli.sh so the binary is signed (docs/MACOS-SIGNING.md)")
        }
        let identityHex = identity.publicKey.map { String(format: "%02x", $0) }.joined()
        print("wire-pair: client static \(identityHex)")

        // ── The run. ──
        let outcome = LytePairing.run(LytePairing.Config(
            hostAddress: address,
            hostPort: dialPort,
            hostStaticPublicKey: hostStatic,
            pin: pin,
            clientStaticKeys: identity,
            timeoutSeconds: timeout,
            onProgress: { print("wire-pair: \($0)") }))

        switch outcome {
        case .paired(let key):
            var store = PinnedHostStore.load()
            let fresh = store.pin(
                staticPublicKey: key,
                name: isLiteralAddress ? address : host,
                address: address,
                port: dialPort,
                pairedAt: ISO8601DateFormatter().string(from: Date()))
            try store.save()
            let hex = key.map { String(format: "%02x", $0) }.joined()
            print("wire-pair: PAIRED — host static \(hex) "
                + (fresh ? "pinned" : "re-pinned") + " → \(PinnedHostStore.url.path)")
            print("wire-pair: reconnects are now 1-RTT Noise IK with zero UI: "
                + "lyte-cli wire-view \(dialPort) --host \(address)")
        case .pinMismatch:
            print("wire-pair: WRONG PIN — the host's tag disagreed with this "
                + "entry (each displayed PIN survives 3 wrong guesses; a "
                + "burned PIN answers nothing until --pair reruns)")
            throw ExitCode(1)
        case .hostRejected(let reason):
            print("wire-pair: host rejected the run (\(reason))")
            throw ExitCode(1)
        case .invalidShare:
            print("wire-pair: the host's share was cryptographically invalid")
            throw ExitCode(1)
        case .timedOut:
            print("wire-pair: no verdict in \(Int(timeout))s — wrong port, "
                + "host not in --pair mode, or a burned PIN's silence")
            throw ExitCode(1)
        case .failed(let message):
            print("wire-pair: FAILED — \(message)")
            throw ExitCode(1)
        }
    }
}

/// The unpair affordance: drops the local pin. Trust stores are
/// per-end — the host keeps its `paired_clients` entry until pruned
/// there; without OUR pin this client simply refuses to dial that host
/// unauthenticated ever again (until a fresh pairing).
struct WireUnpair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-unpair",
        abstract: "Forget a pinned Lyte-UDP host (local trust removal).")

    @Argument(help: "Pinned host: name, address, or an identity-hash prefix")
    var host: String

    func run() async throws {
        var store = PinnedHostStore.load()
        let matches = store.hosts.filter { pkh, pinned in
            pinned.name.caseInsensitiveCompare(host) == .orderedSame
                || pinned.address.caseInsensitiveCompare(host) == .orderedSame
                || pkh.hasPrefix(host.lowercased())
        }
        guard !matches.isEmpty else {
            if store.hosts.isEmpty {
                print("wire-unpair: nothing is pinned")
            } else {
                print("wire-unpair: no pinned host matches \"\(host)\" — pinned:")
                for (pkh, pinned) in store.hosts.sorted(by: { $0.value.name < $1.value.name }) {
                    print("  \(pinned.name)  \(pinned.address):\(pinned.port)  "
                        + "identity \(pkh.prefix(16))…  (\(pinned.pairedAt))")
                }
            }
            throw ExitCode(1)
        }
        guard matches.count == 1, let (pkh, pinned) = matches.first else {
            print("wire-unpair: \"\(host)\" is ambiguous — matches:")
            for (pkh, candidate) in matches {
                print("  \(candidate.name)  \(candidate.address):\(candidate.port)  identity \(pkh.prefix(16))…")
            }
            throw ExitCode(1)
        }
        store.unpin(publicKeyHash: pkh)
        try store.save()
        print("wire-unpair: forgot \(pinned.name) (\(pinned.address):\(pinned.port), "
            + "identity \(pkh.prefix(16))…) — re-pair to reconnect; the host's "
            + "own keystore is untouched")
    }
}
