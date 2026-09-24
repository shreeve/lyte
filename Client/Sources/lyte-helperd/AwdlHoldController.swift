import Foundation
import Synchronization

/// Holds awdl0 down while any client stream is active. AWDL re-raises
/// itself whenever Continuity services stir, so "down" is a held state —
/// re-asserted on every awdl0 up-edge the routing socket reports, plus a
/// slow backstop timer — not a one-shot.
///
/// Accounting is per XPC connection and lives entirely on `queue`: each
/// connection's holds are released exactly once, when it ends a stream or
/// vanishes (app quit or crash), and a connection that vanished can never
/// take a hold again — even if one of its calls is delivered after its
/// invalidation — so a crashed client can never strand AirDrop broken.
final class AwdlHoldController: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Brings awdl0 up (true) or down (false).
        var setAwdlUp: @Sendable (Bool) -> Void
        /// Re-asserts on routing-socket up-edges while holding.
        var watchRoutes = true
        var backstopInterval: DispatchTimeInterval = .seconds(5)
        /// Idle linger before `onIdle`; launchd relaunches on demand.
        var idleExitDelay: DispatchTimeInterval = .seconds(5)
        var onIdle: @Sendable () -> Void = {
            NSLog("lyte-helperd: idle — exiting (launchd will relaunch on demand)")
            exit(0)
        }
    }

    /// One XPC connection's identity. Tokens are never reused, so a
    /// retired token stays retired.
    struct Owner: Hashable, Sendable {
        fileprivate let token: UInt64
    }

    private let queue = DispatchQueue(label: "dev.shreeve.lyte.helper.awdl")
    private let configuration: Configuration
    private let nextToken = Atomic<UInt64>(0)
    private var holds: [Owner: Int] = [:]
    private var retired: Set<Owner> = []
    private var holding = false
    private var backstop: DispatchSourceTimer?
    private var routeWatcher: DispatchSourceRead?
    private var idleExit: DispatchSourceTimer?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The daemon's controller, switching the real awdl0.
    static let shared = AwdlHoldController(configuration: .init(
        setAwdlUp: { up in
            if !InterfaceControl.setUp(InterfaceControl.awdl, up: up) {
                NSLog("lyte-helperd: awdl0 \(up ? "up" : "down") refused")
            }
        }))

    func makeOwner() -> Owner {
        Owner(token: nextToken.add(1, ordering: .relaxed).newValue)
    }

    func streamBegan(_ owner: Owner) {
        queue.async { [self] in
            guard !retired.contains(owner) else { return }
            holds[owner, default: 0] += 1
            idleExit?.cancel()
            idleExit = nil
            if !holding { startHolding() }
        }
    }

    func streamEnded(_ owner: Owner) {
        queue.async { [self] in
            guard let count = holds[owner] else { return }
            holds[owner] = count > 1 ? count - 1 : nil
            releaseIfIdle()
        }
    }

    /// The connection is gone: release everything it held, and refuse
    /// anything it says later.
    func ownerVanished(_ owner: Owner) {
        queue.async { [self] in
            retired.insert(owner)
            guard let count = holds.removeValue(forKey: owner) else { return }
            NSLog("lyte-helperd: client vanished with \(count) hold(s) — releasing")
            releaseIfIdle()
        }
    }

    /// SIGTERM (launchd stop, unregister, shutdown): restore awdl0 before
    /// the process goes. Blocks until restored.
    func restoreForShutdown() {
        queue.sync {
            holds.removeAll()
            if holding { stopHolding() }
        }
    }

    /// Total outstanding holds; test observation.
    var outstandingHolds: Int {
        queue.sync { holds.values.reduce(0, +) }
    }

    // MARK: - Queue-confined

    private func releaseIfIdle() {
        guard holds.isEmpty, holding else { return }
        stopHolding()
        scheduleIdleExit()
    }

    private func startHolding() {
        holding = true
        NSLog("lyte-helperd: holding awdl0 down")
        configuration.setAwdlUp(false)
        if configuration.watchRoutes { startRouteWatcher() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + configuration.backstopInterval,
            repeating: configuration.backstopInterval)
        timer.setEventHandler { [configuration] in configuration.setAwdlUp(false) }
        timer.resume()
        backstop = timer
    }

    private func stopHolding() {
        holding = false
        backstop?.cancel()
        backstop = nil
        routeWatcher?.cancel()
        routeWatcher = nil
        configuration.setAwdlUp(true)
        NSLog("lyte-helperd: awdl0 restored")
    }

    private func scheduleIdleExit() {
        idleExit?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.idleExitDelay)
        timer.setEventHandler { [self] in
            guard holds.isEmpty else { return }
            configuration.onIdle()
        }
        timer.resume()
        idleExit = timer
    }

    /// Event-driven counter-punch: re-down awdl0 the moment the kernel
    /// reports it up again, before its channel scan starts (a polling
    /// watchdog eats a latency spike on every re-raise). Only awdl0's own
    /// up-edges act — our own down-edge and every other interface's
    /// traffic are ignored.
    private func startRouteWatcher() {
        guard routeWatcher == nil else { return }
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0, holding,
                  let index = InterfaceControl.index(of: InterfaceControl.awdl),
                  InterfaceControl.isUpEdge(
                    routingMessage: buffer[..<count], interfaceIndex: index)
            else { return }
            configuration.setAwdlUp(false)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        routeWatcher = source
    }
}
