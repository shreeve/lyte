import Foundation
import LyteHelperProtocol
import LyteHelperSecurity

/// Lyte's privileged helper: a launchd daemon (root) that holds awdl0 down
/// while streams are active. AWDL re-raises itself whenever Continuity
/// services stir, so "down" is a held state (re-applied every second), not
/// a one-shot. Restores awdl0 when the last stream ends — or when a client
/// connection dies, so a crashed app can never leave AirDrop broken.
///
/// Registered via SMAppService from Lyte.app (Contents/Library/LaunchDaemons).

final class AwdlController: @unchecked Sendable {
    static let shared = AwdlController()
    private let queue = DispatchQueue(label: "dev.shreeve.lyte.helper.awdl")
    private var holds = 0
    private var timer: DispatchSourceTimer?

    func retain() {
        queue.async {
            self.idleExit?.cancel(); self.idleExit = nil
            self.holds += 1
            if self.holds == 1 { self.startHolding() }
        }
    }

    func release(_ n: Int = 1) {
        queue.async {
            self.holds = max(0, self.holds - n)
            if self.holds == 0 {
                self.stopHolding()
                self.scheduleIdleExit()
            }
        }
    }

    private var idleExit: DispatchSourceTimer?

    /// A root daemon shouldn't loiter. When no stream has needed us for a
    /// few seconds, exit — launchd relaunches on the next XPC connection.
    private func scheduleIdleExit() {
        idleExit?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5)
        t.setEventHandler {
            guard self.holds == 0 else { return }
            NSLog("lyte-helperd: idle — exiting (launchd will relaunch on demand)")
            exit(0)
        }
        t.resume()
        idleExit = t
    }

    func cancelIdleExit() {
        queue.async { self.idleExit?.cancel(); self.idleExit = nil }
    }

    private func startHolding() {
        NSLog("lyte-helperd: holding awdl0 down")
        setInterface("down")
        // Event-driven counter-punch: watch kernel route messages and re-down
        // awdl0 the moment the system re-raises it — before its channel scan
        // starts. (A polling watchdog eats a latency spike on every re-raise.)
        startRouteWatcher()
        // Slow backstop in case a route message is ever missed
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.setInterface("down") }
        t.resume()
        timer = t
    }

    private var routeSocket: Int32 = -1
    private var routeSource: DispatchSourceRead?

    private func startRouteWatcher() {
        guard routeSocket < 0 else { return }
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return }
        routeSocket = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            _ = read(fd, &buf, buf.count)   // drain; content irrelevant —
            if self.holds > 0 {             // any interface event re-asserts
                self.setInterface("down")
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        routeSource = src
    }

    private func stopHolding() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        routeSource?.cancel()
        routeSource = nil
        routeSocket = -1
        setInterface("up")
        NSLog("lyte-helperd: awdl0 restored")
    }

    private func setInterface(_ state: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["awdl0", state]
        try? p.run()
        p.waitUntilExit()
    }
}

/// One per XPC connection; tracks this client's holds so invalidation
/// (app quit or crash) releases exactly what it contributed.
final class ConnectionHandler: NSObject, LyteHelperCommands, @unchecked Sendable {
    private let lock = NSLock()
    private var contributed = 0

    func streamBegan() {
        lock.lock(); contributed += 1; lock.unlock()
        AwdlController.shared.retain()
    }

    func streamEnded() {
        lock.lock()
        let had = contributed > 0
        if had { contributed -= 1 }
        lock.unlock()
        if had { AwdlController.shared.release() }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(LyteHelper.version)
    }

    func connectionInvalidated() {
        lock.lock()
        let n = contributed
        contributed = 0
        lock.unlock()
        if n > 0 {
            NSLog("lyte-helperd: client vanished with \(n) hold(s) — releasing")
            AwdlController.shared.release(n)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = ConnectionHandler()
        connection.exportedInterface = NSXPCInterface(with: LyteHelperCommands.self)
        connection.exportedObject = handler
        connection.invalidationHandler = { handler.connectionInvalidated() }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: LyteHelper.machServiceName)
do {
    let requirement = try HelperClientRequirement.forCurrentProcess()
    if CommandLine.arguments.contains("--print-client-requirement") {
        print(requirement)
        exit(0)
    }
    // Foundation asks XPC to reject a foreign peer before the delegate sees
    // it. The exported root operations are never reachable without this DR.
    listener.setConnectionCodeSigningRequirement(requirement)
} catch {
    NSLog("lyte-helperd: client requirement unavailable — refusing to start: \(error)")
    exit(EX_CONFIG)
}

NSLog("lyte-helperd: starting (v\(LyteHelper.version))")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
