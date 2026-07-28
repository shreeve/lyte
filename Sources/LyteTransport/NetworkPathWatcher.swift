// NetworkPathWatcher (F-5): the thin NWPathMonitor shim behind the
// roaming policy's `pathChanged` input — the Mac hopping Wi-Fi
// networks mid-session changes the socket's source address, and
// waiting for the silence ladder wastes seconds the path monitor
// already knows about. The shim is deliberately dumb: it reduces each
// NWPath to a small signature and fires ONLY on a signature change
// after the baseline (the initial callback is the current state, not
// a change — never a trigger). Everything decidable is a pure
// function (`shouldNotify`) so the trigger rule pins in tests without
// a live network.

import Foundation
import Network

public final class NetworkPathWatcher: @unchecked Sendable {
    /// What "the path changed" means: the interface set or
    /// satisfiability moved. Interface NAMES (en0, en1, utun3…)
    /// rather than addresses — NWPath doesn't expose addresses, and a
    /// same-interface DHCP re-lease shows up as the session going
    /// silent anyway (the ladder covers it).
    public struct Signature: Equatable, Sendable {
        public var isSatisfied: Bool
        public var interfaceNames: [String]

        public init(isSatisfied: Bool, interfaceNames: [String]) {
            self.isSatisfied = isSatisfied
            self.interfaceNames = interfaceNames.sorted()
        }
    }

    /// The trigger rule, pure: the FIRST observation is the baseline
    /// (no notification — the session was dialed on that path);
    /// afterwards any signature difference notifies.
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
