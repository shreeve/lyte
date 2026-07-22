// CL-5: Lyte-UDP host discovery — browse `_lyte._udp` (the HS-10 Avahi
// advertisement) via NWBrowser, resolve each instance to a numeric
// address + SRV port, and parse the TXT identity records:
//
//   v=<wire major>      checked against WireVersion.major before any
//                       handshake is attempted
//   pkh=<64 hex>        sha256 of the host's raw 32-byte Noise static
//                       PUBLIC key — a client that has pinned a host key
//                       recognizes it in the browse list (and detects a
//                       re-key) without touching the network; the key
//                       itself never rides the advertisement.
//
// This is the Lyte-UDP path's discovery, deliberately separate from the
// frozen GameStream `_nvstream._tcp` browse in LyteKit (deleted at H2
// demolition, checklist item 4). Discovery is a convenience layer only:
// manual host:port stays the always-working fallback everywhere a host
// is named (wire-view's --host, the risk-register rule).
//
// Resolution craft carried from the frozen Discovery (lessons, not the
// file): Bonjour service names are useless as connect targets, so each
// result resolves through an NWConnection — UDP here, which reaches
// `.ready` on path resolution alone, sending nothing — and the numeric
// address + port are read off the established path's remote endpoint.

import Foundation
import Network
import Crypto
import LyteWire

/// One advertised Lyte host, resolved and parsed. `wireVersion` and
/// `publicKeyHash` are nil when the advertisement omitted or mangled
/// them — an old or foreign record, still listed so the operator sees it.
public struct DiscoveredLyteHost: Sendable, Equatable {
    /// Bonjour instance name — the host's short hostname (e.g. "pup"),
    /// possibly daemon-uniqued ("pup #2") on collision.
    public let name: String
    /// Resolved numeric address, e.g. "10.0.0.249".
    public let address: String
    /// The Lyte-UDP port, from the SRV record.
    public let port: UInt16
    /// TXT `v=` — the host's wire major version.
    public let wireVersion: UInt8?
    /// TXT `pkh=` — lowercased 64-hex sha256 of the host's Noise static
    /// public key; nil when absent or not exactly 64 hex digits.
    public let publicKeyHash: String?

    public init(name: String, address: String, port: UInt16,
                wireVersion: UInt8?, publicKeyHash: String?) {
        self.name = name
        self.address = address
        self.port = port
        self.wireVersion = wireVersion
        self.publicKeyHash = publicKeyHash
    }

    /// Whether this host advertises the wire major this build speaks.
    public var speaksOurWireVersion: Bool { wireVersion == WireVersion.major }

    /// Whether the advertised identity hash matches a pinned host static
    /// public key (the raw 32 bytes handed over at pairing or via
    /// lyte-host's printed banner). Recognition only — trust still comes
    /// from the Noise IK handshake against the pinned key itself.
    public func matches(pinnedStaticPublicKey key: [UInt8]) -> Bool {
        publicKeyHash == LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
    }
}

public enum LyteDiscovery {
    public static let serviceType = "_lyte._udp"

    /// The TXT `pkh` value for a raw 32-byte Noise static public key —
    /// the client-side mirror of the host's IdentityHash, for matching
    /// pinned keys against browse results.
    public static func publicKeyHash(ofStaticPublicKey key: [UInt8]) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses the advertisement's TXT dictionary. Tolerant by design —
    /// a missing or malformed record yields nil for that field, never a
    /// dropped host: the operator should still SEE a stale advertiser.
    public static func parseTxt(_ txt: [String: String])
        -> (wireVersion: UInt8?, publicKeyHash: String?)
    {
        let version = txt["v"].flatMap { UInt8($0) }
        let pkh: String? = txt["pkh"].flatMap {
            let lowered = $0.lowercased()
            let isHex = lowered.allSatisfy { $0.isHexDigit }
            return (lowered.count == 64 && isHex) ? lowered : nil
        }
        return (version, pkh)
    }

    /// Browse for `duration` seconds, then resolve each instance to a
    /// numeric address + port. Hosts that fail to resolve within the
    /// timeout are dropped — an unresolvable record is not a connect
    /// target, and manual host:port remains the fallback.
    public static func browse(duration: TimeInterval = 3.0) async -> [DiscoveredLyteHost] {
        let services = await browseServices(duration: duration)
        var hosts: [DiscoveredLyteHost] = []
        await withTaskGroup(of: DiscoveredLyteHost?.self) { group in
            for service in services {
                group.addTask {
                    guard let (address, port) = await resolve(service.endpoint)
                    else { return nil }
                    let parsed = parseTxt(service.txt)
                    return DiscoveredLyteHost(
                        name: service.name, address: address, port: port,
                        wireVersion: parsed.wireVersion,
                        publicKeyHash: parsed.publicKeyHash)
                }
            }
            for await host in group {
                if let host { hosts.append(host) }
            }
        }
        return hosts.sorted { $0.name < $1.name }
    }

    // MARK: - Browse

    private struct FoundService {
        let name: String
        let endpoint: NWEndpoint
        let txt: [String: String]
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String: FoundService] = [:]
        private var finished = false

        func add(_ service: FoundService) {
            lock.lock(); defer { lock.unlock() }
            services[service.name] = service
        }

        /// Returns the results exactly once; nil on subsequent calls.
        func finish() -> [FoundService]? {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            return Array(services.values)
        }
    }

    private static func browseServices(duration: TimeInterval) async -> [FoundService] {
        // bonjourWithTXTRecord delivers the TXT alongside each browse
        // result — no second resolve round-trip for v/pkh.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: NWParameters())
        let collector = Collector()
        return await withCheckedContinuation { cont in
            browser.browseResultsChangedHandler = { browseResults, _ in
                for result in browseResults {
                    guard case .service(let name, _, _, _) = result.endpoint
                    else { continue }
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata {
                        txt = record.dictionary
                    }
                    collector.add(FoundService(
                        name: name, endpoint: result.endpoint, txt: txt))
                }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                guard let results = collector.finish() else { return }
                browser.cancel()
                cont.resume(returning: results)
            }
        }
    }

    // MARK: - Resolve

    /// IPv4 preferred: the transport underneath (UdpReceiveEndpoint,
    /// sockaddr_in) is IPv4-today, and Avahi advertises on both protocols
    /// — an IPv6-resolved result would name a host the session path can't
    /// dial yet. Fall back to whatever resolves on v6-only networks; the
    /// row is still informative even before the transport can use it.
    private static func resolve(
        _ endpoint: NWEndpoint, timeout: TimeInterval = 2.0
    ) async -> (String, UInt16)? {
        let v4 = NWParameters.udp
        if let ip = v4.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        if let resolved = await resolve(endpoint, using: v4, timeout: timeout) {
            return resolved
        }
        return await resolve(endpoint, using: .udp, timeout: timeout)
    }

    /// Resolve a Bonjour service endpoint to (numeric address, port) by
    /// opening a UDP flow to it and reading the remote tuple off the
    /// established path. UDP `.ready` is path resolution, not traffic —
    /// no datagram leaves the machine.
    private static func resolve(
        _ endpoint: NWEndpoint, using parameters: NWParameters,
        timeout: TimeInterval
    ) async -> (String, UInt16)? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var used = false
            func first() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if used { return false }
                used = true
                return true
            }
        }

        return await withCheckedContinuation { cont in
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, UInt16)?
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = remote {
                        var address: String?
                        switch host {
                        case .ipv4(let v4): address = "\(v4)"
                        case .ipv6(let v6): address = "\(v6)"
                        case .name(let name, _): address = name
                        @unknown default: break
                        }
                        // Strip any interface scope ("%en0") — not part
                        // of the address.
                        if let a = address, let bare = a.split(separator: "%").first {
                            address = String(bare)
                        }
                        if let a = address {
                            resolved = (a, port.rawValue)
                        }
                    }
                    connection.cancel()
                    if once.first() { cont.resume(returning: resolved) }
                case .failed, .cancelled:
                    if once.first() { cont.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.first() {
                    connection.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
