// AnsweredHandshakeMemory: the listening service's memory of the Noise
// message 1s it has already answered, kept for the life of the process
// (across sessions). Noise IK message 1 carries no freshness, so without
// it a message 1 captured once — or a stale retransmit still queued on
// the listening socket after its session ended — would complete a new
// handshake to a client that is not there.
//
// A message 1 is known by its ephemeral public key (its first 32 bytes):
// an honest initiator draws a fresh ephemeral per dial and resends the
// same bytes only as retransmits of that dial, which the session that
// answered it handles itself.
//
// Sans-IO; bounded: the oldest entries age out past `capacity`.

public struct AnsweredHandshakeMemory: Sendable {
    public static let ephemeralByteCount = 32

    private var known: BoundedFifoMap<[UInt8], Void>

    public init(capacity: Int = 1_024) {
        known = BoundedFifoMap(capacity: capacity)
    }

    public var capacity: Int { known.capacity }
    public var count: Int { known.count }

    /// Remembers an answered message 1.
    public mutating func record(message1: some Collection<UInt8>) {
        guard let key = Self.key(message1) else { return }
        known.set((), for: key)
    }

    /// Whether this message 1 was answered before.
    public func contains(message1: some Collection<UInt8>) -> Bool {
        Self.key(message1).map { known[$0] != nil } ?? false
    }

    private static func key(_ message1: some Collection<UInt8>) -> [UInt8]? {
        guard message1.count >= ephemeralByteCount else { return nil }
        return Array(message1.prefix(ephemeralByteCount))
    }
}
