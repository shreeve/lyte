import LyteCore
import LyteWire

/// The sans-IO owner of the Host session's injected-input evidence.
///
/// The latest injected sequence stamps subsequent video shards. Echo tuples
/// remain queued until `Session` successfully admits their message to the
/// reliable CTRL stream and commits that exact prefix. Peeking is deliberately
/// nonmutating so a refused send cannot discard input-to-photon evidence.
/// The book holds at most `capacity` tuples, oldest dropped first: while
/// reliable CTRL stays backpressured (a peer that sends input but never
/// acknowledges) the echo evidence, lossy by nature, cannot grow without
/// bound.
public struct SessionInputEchoBook: Equatable, Sendable {
    public static let capacity = 16 * InputEcho.maxTupleCount

    public private(set) var lastInjectedSequence: UInt32?
    public var pendingTupleCount: Int { pendingTuples.count }

    private var pendingTuples = Deque<InputEchoTuple>()

    public init() {}

    public mutating func noteInjected(
        seq: UInt32,
        receivedAtMicroseconds: UInt64,
        injectedAtMicroseconds: UInt64
    ) {
        lastInjectedSequence = seq
        if pendingTuples.count == Self.capacity {
            pendingTuples.removeFirst()
        }
        pendingTuples.append(InputEchoTuple(
            seq: seq,
            receivedMicroseconds: receivedAtMicroseconds,
            injectedMicroseconds: injectedAtMicroseconds
        ))
    }

    /// Peeks at the next wire-sized message without removing its tuples.
    public func nextMessage() -> InputEcho? {
        guard !pendingTuples.isEmpty else { return nil }
        return InputEcho(tuples: Array(
            pendingTuples.prefix(InputEcho.maxTupleCount)
        ))
    }

    /// Removes the exact prefix already admitted to reliable CTRL.
    /// Passing anything else is an owner bug, not hostile input.
    @discardableResult
    public mutating func commitSent(_ message: InputEcho) -> Int {
        precondition(
            message.tuples == Array(pendingTuples.prefix(message.tuples.count)),
            "only the pending input-echo prefix may be committed"
        )
        pendingTuples.removeFirst(message.tuples.count)
        return message.tuples.count
    }
}
