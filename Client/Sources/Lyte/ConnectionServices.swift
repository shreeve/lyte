import Foundation
import LyteIO
import Synchronization
import LyteTransport
import LyteWire

/// Everything a connection window reaches outside the process: the pinned
/// store, the Keychain identity, discovery, the network path, the session's
/// blocking start and close, and the process-wide stream count behind the
/// AWDL helper. `live` is the production wiring; tests substitute closures
/// so the connect and roaming lifecycle runs in-process without sockets,
/// Keychain, or helper.
struct ConnectionServices: Sendable {
    /// How a wire session ends: `goodbye` sends the typed 0x0A and
    /// lingers for its ACK; `silent` stops without a word (the peer is
    /// gone or already closed).
    enum SessionEnd: Sendable {
        case goodbye
        case silent
    }

    var loadPins: @MainActor @Sendable () -> PinnedHostStore
    var savePins: @MainActor @Sendable (PinnedHostStore) throws -> Void
    var identity: @Sendable (
        ClientNoiseIdentityProvider.AuthenticationUI
    ) async throws -> NoiseKeyPair
    /// The process-cached identity; nil until an interactive lookup
    /// succeeded. Automatic paths (roaming) never summon Keychain UI.
    var cachedIdentity: @Sendable () -> NoiseKeyPair?
    var browse: @Sendable (TimeInterval) async -> [DiscoveredLyteHost]
    /// Bind + handshake. Blocking in production, so it runs off-main.
    var startSession: @Sendable (LyteUdpSession) async throws -> Void
    /// Fire-and-forget; the goodbye linger never blocks the caller.
    var endSession: @Sendable (LyteUdpSession, SessionEnd) -> Void
    /// Starts watching the Mac's network path; `onChange` fires on every
    /// post-baseline change. Returns the stop verb.
    var watchPath: @MainActor @Sendable (
        _ onChange: @escaping @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void
    var streamBegan: @MainActor @Sendable () -> Void
    var streamEnded: @MainActor @Sendable () -> Void
    /// Monotonic microseconds — the roaming policy's and connect
    /// budget's clock.
    var now: @Sendable () -> UInt64

    static let live = ConnectionServices(
        loadPins: { loadPinnedHosts() },
        savePins: { try $0.save() },
        identity: { authenticationUI in
            try await ClientNoiseIdentityProvider.shared.identity(
                authenticationUI: authenticationUI)
        },
        cachedIdentity: { ClientNoiseIdentityProvider.shared.cachedIdentity },
        browse: { await LyteDiscovery.browse(duration: $0) },
        startSession: { session in
            try await Task.detached { try session.start() }.value
        },
        endSession: { session, end in
            SessionCloses.shared.run {
                switch end {
                case .goodbye: session.close(reason: .shuttingDown)
                case .silent: session.stop()
                }
            }
        },
        watchPath: { onChange in
            let watcher = NetworkPathWatcher()
            watcher.start { _ in onChange() }
            return { watcher.stop() }
        },
        streamBegan: { AgentState.shared.streamBegan() },
        streamEnded: { AgentState.shared.streamEnded() },
        now: { SystemMonotonicClock.nowMicroseconds })
}

/// Session closes in flight. A close blocks for its goodbye's linger, so
/// it runs off the caller; app termination waits for the outstanding ones,
/// boundedly, so quitting still says goodbye to every host.
final class SessionCloses: Sendable {
    static let shared = SessionCloses()

    private let group = DispatchGroup()

    func run(_ close: @escaping @Sendable () -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [group] in
            close()
            group.leave()
        }
    }

    /// Calls `done` on the main queue once every close has finished or
    /// `timeout` has passed, whichever comes first — exactly once.
    func whenDrained(
        within timeout: DispatchTimeInterval,
        _ done: @escaping @MainActor @Sendable () -> Void
    ) {
        let once = FireOnce()
        let finish: @Sendable () -> Void = {
            guard once.claim() else { return }
            MainActor.assumeIsolated { done() }
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)
    }

    private final class FireOnce: Sendable {
        private let fired = Atomic(false)

        func claim() -> Bool {
            !fired.exchange(true, ordering: .relaxed)
        }
    }
}

/// The app's one read of the pinned-host store. An unreadable file is
/// moved aside by the store (so a later save cannot overwrite the only
/// copy); the log line says where, since the picker then shows no pins.
@MainActor
func loadPinnedHosts() -> PinnedHostStore {
    let loaded = PinnedHostStore.loadQuarantiningUnreadable()
    if let quarantined = loaded.quarantinedTo {
        NSLog("lyte: pinned hosts file was unreadable — moved aside to %@",
              quarantined.path)
    }
    return loaded.store
}
