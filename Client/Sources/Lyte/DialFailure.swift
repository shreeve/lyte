import LyteTransport

/// What one failed dial means for the connect loop.
enum DialFailure: Equatable {
    /// The handshake used up its attempts without a session: the host
    /// stayed silent, or everything that came back from its address failed
    /// to authenticate (stale or forged). A restarting host looks exactly
    /// like this, so it is retried.
    case unanswered
    /// macOS Local Network privacy refused the socket.
    case localNetwork(LocalNetworkAccessProblem)
    /// Retrying cannot help.
    case refused

    init(_ error: any Error) {
        if let endpointError = error as? TransportEndpointError,
           let problem = LocalNetworkAccessProblem.endpointError(endpointError) {
            self = .localNetwork(problem)
            return
        }
        // The transport reports exhaustion only as text. Both exhaustion
        // messages carry its counters; a typed exhaustion case in
        // TransportCryptoError should replace this reading.
        guard case TransportCryptoError.handshakeFailed(let why) = error,
              why.hasPrefix("no response") || why.contains("[kernel accepted ")
        else {
            self = .refused
            return
        }
        self = .unanswered
    }
}
