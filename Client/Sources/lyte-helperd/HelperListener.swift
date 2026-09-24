import Foundation

/// Arms the helper's listener in the only safe order: the peer code
/// requirement is installed before any delegate exists, so XPC refuses a
/// foreign peer before the delegate could export the root-only operations.
enum HelperListener {
    static func activate(
        _ listener: NSXPCListener,
        requiring requirement: String,
        delegate: any NSXPCListenerDelegate
    ) {
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
    }
}
