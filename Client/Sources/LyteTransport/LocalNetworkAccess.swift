import Network
import Darwin

/// The two user-actionable Local Network states Lyte can actually prove.
/// macOS exposes no general permission-status API: Bonjour policy denial is
/// definitive, while a BSD route failure can only support qualified advice.
public enum LocalNetworkAccessProblem: Sendable, Equatable {
    case permissionRequired
    case routeOrPermissionUnavailable

    /// DNSServiceErrorType.policyDenied. Keeping the wire value here makes
    /// this classifier directly constructible in tests without importing a
    /// second C module solely for one DNS-SD constant.
    private static let dnsServicePolicyDenied: Int32 = -65_570

    public static func browserError(_ error: NWError) -> Self? {
        guard case .dns(let code) = error,
              Int32(code) == dnsServicePolicyDenied else { return nil }
        return .permissionRequired
    }

    /// Network.framework exposes the exact Local Network verdict on a
    /// connection path even when the surfaced POSIX error is only the
    /// ambiguous EHOSTUNREACH. Prefer this proof whenever it exists.
    static func pathReason(_ reason: NWPath.UnsatisfiedReason?) -> Self? {
        reason == .localNetworkDenied ? .permissionRequired : nil
    }

    static func connectionError(
        _ error: NWError,
        pathReason: NWPath.UnsatisfiedReason?
    ) -> Self? {
        if let exact = Self.pathReason(pathReason) ?? browserError(error) {
            return exact
        }
        if case .posix(let code) = error,
           code == .EHOSTUNREACH || code == .ENETUNREACH {
            return .routeOrPermissionUnavailable
        }
        return nil
    }

    public static func endpointError(
        _ error: TransportEndpointError
    ) -> Self? {
        guard case .socketFailed(let code) = error,
              code == EHOSTUNREACH || code == EACCES || code == EPERM
        else { return nil }
        return .routeOrPermissionUnavailable
    }
}

/// Ordered evidence owned by one serial browser queue. Kept separate from
/// the browser shell so denial followed by readiness is a pinned transition,
/// not an incidental callback implementation detail.
struct LocalNetworkAccessEvidence {
    private(set) var problem: LocalNetworkAccessProblem?

    mutating func observe(browserError error: NWError) {
        guard let observed = LocalNetworkAccessProblem.browserError(error)
        else { return }
        problem = observed
    }

    mutating func browserReady() {
        problem = nil
    }
}
