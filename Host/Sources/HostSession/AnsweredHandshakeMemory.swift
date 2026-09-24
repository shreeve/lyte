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

    public let capacity: Int
    private var order: [[UInt8]] = []
    private var next = 0
    private var known: Set<[UInt8]> = []

    public init(capacity: Int = 1_024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { known.count }

    /// Remembers an answered message 1.
    public mutating func record(message1: some Collection<UInt8>) {
        guard let key = Self.key(message1), known.insert(key).inserted
        else { return }
        if order.count < capacity {
            order.append(key)
        } else {
            known.remove(order[next])
            order[next] = key
            next = (next + 1) % capacity
        }
    }

    /// Whether this message 1 was answered before.
    public func contains(message1: some Collection<UInt8>) -> Bool {
        Self.key(message1).map(known.contains) ?? false
    }

    private static func key(_ message1: some Collection<UInt8>) -> [UInt8]? {
        guard message1.count >= ephemeralByteCount else { return nil }
        return Array(message1.prefix(ephemeralByteCount))
    }
}
