/// The app-launch decision for the root helper's `SMAppService`
/// registration, over injected seams so it runs without launchd.
///
/// Invariants:
/// - Registration records whatever helper binary is on disk as trusted to
///   run as root, so it happens only when needed: the service is not
///   registered, or it is enabled but the registered helper does not answer
///   the current version (a rebuild stales the stored launch requirement,
///   and launchd then refuses the spawn).
/// - Nothing is ever registered until the embedded helper validates
///   against the app's own designated requirement with the helper's
///   identifier. A helper signed by anyone else is refused, and an existing
///   registration is left alone.
/// - A registration awaiting the user's approval is never re-registered;
///   the approval prompt is the user's decision.
struct HelperRegistration {
    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
    }

    enum Outcome: Equatable {
        /// The registered helper answered the current version.
        case current
        case awaitingApproval
        case registered
        /// The embedded helper failed validation; nothing was registered.
        case refused(String)
        case failed(String)
    }

    var expectedVersion: String
    var status: () -> Status
    /// The registered helper's `version` answer; nil when it never answered.
    var probeVersion: () -> String?
    var validateEmbeddedHelper: () throws -> Void
    var unregister: () throws -> Void
    var register: () throws -> Void

    func run() -> Outcome {
        let replacing: Bool
        switch status() {
        case .requiresApproval:
            return .awaitingApproval
        case .enabled:
            guard probeVersion() != expectedVersion else { return .current }
            replacing = true
        case .notRegistered, .notFound:
            replacing = false
        }
        do {
            try validateEmbeddedHelper()
        } catch {
            return .refused(String(describing: error))
        }
        if replacing { try? unregister() }
        do {
            try register()
        } catch {
            return .failed(String(describing: error))
        }
        return .registered
    }
}
