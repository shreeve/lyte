// NetworkPathWatcher: the NWPathMonitor shim behind roaming's
// `pathChanged` input. It reduces each NWPath to a signature and fires only
// on a change after the baseline.

import Foundation
import Network

public final class NetworkPathWatcher: @unchecked Sendable {
    /// The interface names and satisfiability (NWPath exposes no
    /// addresses; a same-interface re-lease is caught by the silence
    /// ladder).
    public struct Signature: Equatable, Sendable {
        public var isSatisfied: Bool
        public var interfaceNames: [String]

        public init(isSatisfied: Bool, interfaceNames: [String]) {
            self.isSatisfied = isSatisfied
            self.interfaceNames = interfaceNames.sorted()
        }
    }

    /// The first observation is the baseline; afterwards any difference
    /// notifies.
    public static func shouldNotify(
        previous: Signature?, current: Signature
    ) -> Bool {
        guard let previous else { return false }
        return previous != current
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var last: Signature?
    private var started = false

    public init() {}

    /// Starts monitoring; `onChange` fires (on an arbitrary queue) for
    /// every post-baseline signature change.
    public func start(onChange: @escaping @Sendable (Signature) -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Signature(
                isSatisfied: path.status == .satisfied,
                interfaceNames: path.availableInterfaces.map(\.name))
            self.lock.lock()
            let previous = self.last
            self.last = signature
            self.lock.unlock()
            if Self.shouldNotify(previous: previous, current: signature) {
                onChange(signature)
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    public func stop() {
        monitor.cancel()
    }
}
