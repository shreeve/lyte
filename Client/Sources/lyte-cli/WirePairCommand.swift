import ArgumentParser
import Foundation
import LyteCore
import LyteTransport
import LyteWire

/// PIN pairing against a Lyte-UDP host. `lyte-host --wire-listen PORT
/// --pair` prints its static public key and a 6-digit PIN on its
/// console; this command dials that key trust-on-first-use, runs the
/// CPace exchange bound to the Noise session, and on a verified
/// confirmation pins the host static locally (the host pins ours in the
/// same exchange). Later connects are plain Noise IK, no PIN.
///
/// The client identity lives in the login Keychain: build via
/// Scripts/build-cli.sh so the stable signature keeps the Keychain grant
/// across rebuilds (docs/MACOS-SIGNING.md).
struct WirePair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-pair",
        abstract: "Pair with a Lyte-UDP host: PIN → CPace → pinned Noise statics.")

    @Argument(help: "Host: discovered Lyte host name, or an IP address")
    var host: String

    @Option(name: .long, help: "The host's --wire-listen port (default: from discovery)")
    var port: UInt16 = 0

    @Option(name: .long, help: "The 6-digit PIN printed on the host's console; `-` reads it from standard input, keeping it out of the process list")
    var pin: String

    @Option(name: .long, help: "The host's static public key, 64 hex digits (from lyte-host's banner; optional when the host is discoverable and already pinned)")
    var hostKey: String?

    @Option(name: .long, help: "Seconds to wait for the pairing verdict")
    var timeout: Double = 20

    func validate() throws {
        guard pin == "-" || PairingPin.isValid(pin) else {
            throw ValidationError("--pin must be the host's 6 digits or -, got \"\(pin)\"")
        }
    }

    /// The PIN itself: `argument`, or one line read when it is `-`.
    static func resolvedPin(
        _ argument: String, readLine: () -> String?
    ) throws -> String {
        guard argument == "-" else { return argument }
        let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        guard PairingPin.isValid(line) else {
            throw ValidationError("standard input must carry the host's 6-digit PIN")
        }
        return line
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let pin = try Self.resolvedPin(self.pin) { Swift.readLine() }

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
            identity = try await ClientNoiseIdentityProvider.shared.identity()
        } catch ClientNoiseIdentityError.keychain(let status) {
            throw ValidationError(
                "Keychain refused the client identity (OSStatus \(status)) — build via Scripts/build-cli.sh so the binary is signed (docs/MACOS-SIGNING.md)")
        }
        let identityHex = Hex.string(identity.publicKey)
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

        guard case .paired(let key) = outcome else {
            print("wire-pair: FAILED — \(outcome.failureMessage ?? "\(outcome)")")
            throw ExitCode(1)
        }
        var store = PinnedHostStore.load()
        let fresh = store.pinPaired(
            staticPublicKey: key,
            name: isLiteralAddress ? address : host,
            address: address,
            port: dialPort)
        try store.save()
        print("wire-pair: PAIRED — host static \(Hex.string(key)) "
            + (fresh ? "pinned" : "re-pinned") + " → \(PinnedHostStore.url.path)")
        print("wire-pair: reconnects are now 1-RTT Noise IK with zero UI: "
            + "lyte-cli wire-view \(dialPort) --host \(address)")
    }
}
