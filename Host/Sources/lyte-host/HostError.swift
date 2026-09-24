/// The host executable's one error type: a human-readable reason that
/// the composition root prints before exiting nonzero.
struct HostError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}
