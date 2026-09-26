// Lyte-UDP host discovery: browse `_lyte._udp`, resolve each instance to a
// numeric address + SRV port, and parse the TXT records `v=<wire major>`
// and `pkh=<sha256 of the host's Noise static public key>` (recognition of
// pinned hosts without touching the network; the key itself never rides
// the advertisement).

import Foundation
import Network
import LyteCore
import LyteWire

/// One advertised Lyte host. `wireVersion` and `publicKeyHash` are nil
/// when the advertisement omitted or mangled them; the host is still listed.
public struct DiscoveredLyteHost: Sendable, Equatable, Identifiable {
    /// Stable per dial target.
    public var id: String { "\(address):\(port)" }

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

    /// Recognition only: trust comes from the Noise IK handshake against
    /// the pinned key itself.
    public func matches(pinnedStaticPublicKey key: [UInt8]) -> Bool {
        publicKeyHash == LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
    }
}

/// One bounded Bonjour scan; hosts and access diagnosis are independent.
public struct LyteDiscoveryScan: Sendable, Equatable {
    public let hosts: [DiscoveredLyteHost]
    public let accessProblem: LocalNetworkAccessProblem?

    /// An access problem blocks only when no usable dial target was found.
    public var blockingAccessProblem: LocalNetworkAccessProblem? {
        hosts.isEmpty ? accessProblem : nil
    }

    public init(
        hosts: [DiscoveredLyteHost],
        accessProblem: LocalNetworkAccessProblem?
    ) {
        self.hosts = hosts
        self.accessProblem = accessProblem
    }
}

public enum LyteDiscovery {
    public static let serviceType = "_lyte._udp"

    /// The TXT `pkh` value for a raw 32-byte Noise static public key.
    public static func publicKeyHash(ofStaticPublicKey key: [UInt8]) -> String {
        Hex.string(Sha256.digest(key))
    }

    /// A missing or malformed record yields nil for that field, never a
    /// dropped host.
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

    /// Browse for `duration` seconds, then resolve each instance. Hosts that
    /// fail to resolve are not dial targets but count as route-or-permission
    /// evidence.
    public static func scan(duration: TimeInterval = 3.0) async
        -> LyteDiscoveryScan
    {
        let browse = await browseServices(duration: duration)
        var hosts: [DiscoveredLyteHost] = []
        var resolutionProblems: [LocalNetworkAccessProblem] = []
        var hadUnresolvedService = false
        await withTaskGroup(
            of: (FoundService, EndpointResolution).self
        ) { group in
            for service in browse.services {
                group.addTask { (service, await resolve(service.endpoint)) }
            }
            for await (service, result) in group {
                switch result {
                case .resolved(let address, let port):
                    let parsed = parseTxt(service.txt)
                    hosts.append(DiscoveredLyteHost(
                        name: service.name, address: address, port: port,
                        wireVersion: parsed.wireVersion,
                        publicKeyHash: parsed.publicKeyHash))
                case .accessProblem(let problem):
                    resolutionProblems.append(problem)
                case .failed:
                    hadUnresolvedService = true
                }
            }
        }
        return LyteDiscoveryScan(
            hosts: hosts.sorted { $0.name < $1.name },
            accessProblem: combinedAccessProblem(
                browserProblem: browse.accessProblem,
                resolutionProblems: resolutionProblems,
                hadUnresolvedService: hadUnresolvedService))
    }

    /// Reduces browser and resolver evidence to one diagnosis. An instance
    /// that cannot resolve proves a route problem or a Local Network denial,
    /// even without a classifiable NWError.
    static func combinedAccessProblem(
        browserProblem: LocalNetworkAccessProblem?,
        resolutionProblems: [LocalNetworkAccessProblem],
        hadUnresolvedService: Bool
    ) -> LocalNetworkAccessProblem? {
        if browserProblem == .permissionRequired
            || resolutionProblems.contains(.permissionRequired)
        {
            return .permissionRequired
        }
        if let browserProblem { return browserProblem }
        if let resolutionProblem = resolutionProblems.first {
            return resolutionProblem
        }
        return hadUnresolvedService ? .routeOrPermissionUnavailable : nil
    }

    /// Sightings only; the app's host picker uses `scan`.
    public static func browse(duration: TimeInterval = 3.0) async
        -> [DiscoveredLyteHost]
    {
        await scan(duration: duration).hosts
    }

    // MARK: - Browse

    private struct FoundService {
        let name: String
        let endpoint: NWEndpoint
        let txt: [String: String]
    }

    private enum EndpointResolution: Sendable {
        case resolved(String, UInt16)
        case accessProblem(LocalNetworkAccessProblem)
        case failed
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String: FoundService] = [:]
        private var accessEvidence = LocalNetworkAccessEvidence()
        private var finished = false

        func add(_ service: FoundService) {
            lock.lock(); defer { lock.unlock() }
            services[service.name] = service
        }

        func observe(browserError error: NWError) {
            lock.lock(); defer { lock.unlock() }
            accessEvidence.observe(browserError: error)
        }

        func browserReady() {
            lock.lock(); defer { lock.unlock() }
            accessEvidence.browserReady()
        }

        /// Returns the results exactly once; nil on subsequent calls.
        func finish() -> (
            services: [FoundService],
            accessProblem: LocalNetworkAccessProblem?
        )? {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            return (Array(services.values), accessEvidence.problem)
        }
    }

    private static func browseServices(duration: TimeInterval) async -> (
        services: [FoundService],
        accessProblem: LocalNetworkAccessProblem?
    ) {
        // bonjourWithTXTRecord delivers the TXT alongside each browse
        // result — no second resolve round-trip for v/pkh.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: NWParameters())
        let collector = Collector()
        // A private serial queue orders every callback and the deadline.
        let queue = DispatchQueue(label: "dev.shreeve.lyte.discovery.scan")
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
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    collector.browserReady()
                case .waiting(let error), .failed(let error):
                    collector.observe(browserError: error)
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + duration) {
                guard let results = collector.finish() else { return }
                browser.cancel()
                cont.resume(returning: results)
            }
        }
    }

    // MARK: - Resolve

    /// IPv4 preferred (the transport is IPv4-only); falls back to whatever
    /// resolves on v6-only networks.
    private static func resolve(
        _ endpoint: NWEndpoint, timeout: TimeInterval = 2.0
    ) async -> EndpointResolution {
        let v4 = NWParameters.udp
        if let ip = v4.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let first = await resolve(endpoint, using: v4, timeout: timeout)
        switch first {
        case .resolved, .accessProblem(.permissionRequired):
            return first
        case .accessProblem(.routeOrPermissionUnavailable):
            let fallback = await resolve(
                endpoint, using: .udp, timeout: timeout)
            switch fallback {
            case .resolved, .accessProblem:
                return fallback
            case .failed:
                return first
            }
        case .failed:
            return await resolve(endpoint, using: .udp, timeout: timeout)
        }
    }

    /// Reads (numeric address, port) off a UDP flow's established path;
    /// UDP `.ready` sends nothing.
    private static func resolve(
        _ endpoint: NWEndpoint, using parameters: NWParameters,
        timeout: TimeInterval
    ) async -> EndpointResolution {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var used = false
            private var pendingProblem: LocalNetworkAccessProblem?

            func observe(_ problem: LocalNetworkAccessProblem?) {
                lock.lock(); defer { lock.unlock() }
                pendingProblem = problem ?? pendingProblem
            }

            func timeoutResult() -> EndpointResolution {
                lock.lock(); defer { lock.unlock() }
                return pendingProblem.map(EndpointResolution.accessProblem)
                    ?? .failed
            }

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
            let queue = DispatchQueue(
                label: "dev.shreeve.lyte.discovery.resolve")
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
                        // Strip any interface scope ("%en0").
                        if let a = address, let bare = a.split(separator: "%").first {
                            address = String(bare)
                        }
                        if let a = address {
                            resolved = (a, port.rawValue)
                        }
                    }
                    connection.cancel()
                    if once.first() {
                        if let resolved {
                            cont.resume(returning: .resolved(
                                resolved.0, resolved.1))
                        } else {
                            cont.resume(returning: .failed)
                        }
                    }
                case .waiting(let error):
                    once.observe(LocalNetworkAccessProblem.connectionError(
                        error,
                        pathReason: connection.currentPath?.unsatisfiedReason))
                case .failed(let error):
                    let problem = LocalNetworkAccessProblem.connectionError(
                        error,
                        pathReason: connection.currentPath?.unsatisfiedReason)
                    if once.first() {
                        cont.resume(returning: problem.map(
                            EndpointResolution.accessProblem) ?? .failed)
                    }
                case .cancelled:
                    if once.first() { cont.resume(returning: .failed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.first() {
                    let result = once.timeoutResult()
                    connection.cancel()
                    cont.resume(returning: result)
                }
            }
        }
    }
}
