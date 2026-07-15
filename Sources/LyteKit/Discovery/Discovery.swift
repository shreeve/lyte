import Foundation
import Network

/// Bonjour discovery of GameStream/Sunshine hosts (_nvstream._tcp).
/// Results are RESOLVED to numeric addresses — service names like
/// "pop._nvstream._tcp.local." are useless as connect targets and don't
/// match stored pairings.
public enum Discovery {
    public struct FoundHost: Sendable {
        public let name: String        // Bonjour service name, e.g. "pop"
        public let endpoint: String    // resolved address, e.g. "10.0.0.249"
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String: NWEndpoint] = [:]
        private var finished = false

        func add(name: String, endpoint: NWEndpoint) {
            lock.lock(); defer { lock.unlock() }
            services[name] = endpoint
        }

        /// Returns the results exactly once; nil on subsequent calls.
        func finish() -> [(String, NWEndpoint)]? {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            return services.map { ($0.key, $0.value) }
        }
    }

    /// Browse for `duration` seconds, then resolve each service to an address.
    public static func browse(duration: TimeInterval = 3.0) async -> [FoundHost] {
        let services = await browseServices(duration: duration)
        var hosts: [FoundHost] = []
        await withTaskGroup(of: FoundHost?.self) { group in
            for (name, endpoint) in services {
                group.addTask {
                    guard let address = await resolve(endpoint) else { return nil }
                    return FoundHost(name: name, endpoint: address)
                }
            }
            for await host in group {
                if let host { hosts.append(host) }
            }
        }
        return hosts.sorted { $0.name < $1.name }
    }

    private static func browseServices(duration: TimeInterval) async -> [(String, NWEndpoint)] {
        let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil),
                                using: NWParameters())
        let collector = Collector()
        return await withCheckedContinuation { cont in
            browser.browseResultsChangedHandler = { browseResults, _ in
                for result in browseResults {
                    if case .service(let name, _, _, _) = result.endpoint {
                        collector.add(name: name, endpoint: result.endpoint)
                    }
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

    /// Resolve a Bonjour service endpoint by opening a TCP connection to it
    /// and reading the remote address off the established path.
    private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 2.0) async -> String? {
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
            let connection = NWConnection(to: endpoint, using: .tcp)
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: String?
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = remote {
                        switch host {
                        case .ipv4(let v4): address = "\(v4)"
                        case .ipv6(let v6): address = "\(v6)"
                        case .name(let name, _): address = name
                        @unknown default: break
                        }
                    }
                    connection.cancel()
                    // Strip any interface scope ("%en0") — not part of the address
                    if let a = address, let bare = a.split(separator: "%").first {
                        address = String(bare)
                    }
                    if once.first() { cont.resume(returning: address) }
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
