import Foundation

extension LytePairing.Outcome {
    /// What an operator should read when the run did not pair; nil for
    /// `.paired`. One wording for the app's sheet and `lyte-cli wire-pair`.
    public var failureMessage: String? {
        switch self {
        case .paired:
            return nil
        case .pinMismatch:
            return "Wrong PIN — the host disagreed with this entry. Three wrong "
                + "guesses burn the PIN; restart pairing on the host for a fresh one."
        case .hostRejected(let reason):
            return "The host rejected the pairing (\(reason))."
        case .invalidShare:
            return "The host's cryptographic share was invalid."
        case .timedOut:
            return "No answer — is the host running with --pair? "
                + "(A burned PIN also answers nothing.)"
        case .failed(let message):
            return message
        }
    }
}

extension PinnedHostStore {
    /// Pins a host static that pairing just confirmed, stamped now.
    /// Returns true when the key is new (false: a re-pair refreshed it).
    @discardableResult
    public mutating func pinPaired(
        staticPublicKey: [UInt8], name: String, address: String, port: UInt16,
        at date: Date = Date()
    ) -> Bool {
        pin(staticPublicKey: staticPublicKey, name: name, address: address,
            port: port, pairedAt: ISO8601DateFormatter().string(from: date))
    }
}
