import Foundation
import LyteHelperProtocol
import LyteHelperSecurity

/// Lyte's privileged helper: a launchd daemon (root, registered via
/// SMAppService from Lyte.app's Contents/Library/LaunchDaemons) that holds
/// awdl0 down while streams are active and restores it when the last one
/// ends, when a client connection dies, or when launchd stops the daemon.
///
/// Security surface: one Mach service exporting three argument-free calls
/// (`streamBegan`, `streamEnded`, `version`). A peer must satisfy the code
/// requirement derived from this binary's own designated requirement with
/// the app's identifier; XPC rejects every other signer before the delegate
/// runs. The only privileged effect is awdl0's IFF_UP flag.

/// One per XPC connection; its holds are released exactly once.
final class ConnectionHandler: NSObject, LyteHelperCommands, @unchecked Sendable {
    let owner = AwdlHoldController.shared.makeOwner()

    func streamBegan() { AwdlHoldController.shared.streamBegan(owner) }
    func streamEnded() { AwdlHoldController.shared.streamEnded(owner) }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(LyteHelper.version)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = ConnectionHandler()
        let owner = handler.owner
        connection.exportedInterface = NSXPCInterface(with: LyteHelperCommands.self)
        connection.exportedObject = handler
        connection.invalidationHandler = {
            AwdlHoldController.shared.ownerVanished(owner)
        }
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

// launchd stop, SMAppService re-registration and shutdown all arrive as
// SIGTERM: restore awdl0 first.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    AwdlHoldController.shared.restoreForShutdown()
    exit(0)
}
termination.resume()

NSLog("lyte-helperd: starting (v\(LyteHelper.version))")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
