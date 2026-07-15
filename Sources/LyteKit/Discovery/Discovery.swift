import Foundation
import Network

/// Bonjour discovery of GameStream/Sunshine hosts (_nvstream._tcp).
public enum Discovery {
    public struct FoundHost: Sendable {
        public let name: String
        public let endpoint: String
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: FoundHost] = [:]
        private var finished = false

        func add(_ host: FoundHost) {
            lock.lock(); defer { lock.unlock() }
            results[host.name] = host
        }

        /// Returns the results exactly once; nil on subsequent calls.
        func finish() -> [FoundHost]? {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            return Array(results.values).sorted { $0.name < $1.name }
        }
    }

    /// Browse for `duration` seconds and return unique hosts found.
    public static func browse(duration: TimeInterval = 3.0) async -> [FoundHost] {
        let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil),
                                using: NWParameters())
        let collector = Collector()
        return await withCheckedContinuation { (cont: CheckedContinuation<[FoundHost], Never>) in
            browser.browseResultsChangedHandler = { browseResults, _ in
                for result in browseResults {
                    if case .service(let name, _, _, _) = result.endpoint {
                        collector.add(FoundHost(name: name, endpoint: "\(result.endpoint)"))
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
}
