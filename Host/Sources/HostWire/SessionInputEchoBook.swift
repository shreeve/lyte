import LyteWire

/// The sans-IO owner of the Host session's injected-input evidence.
///
/// The latest injected sequence stamps subsequent video shards. Echo tuples
/// remain queued until `Session` successfully admits their message to the
/// reliable CTRL stream and commits that exact prefix. Peeking is deliberately
/// nonmutating so a refused send cannot discard input-to-photon evidence.
public struct SessionInputEchoBook: Equatable, Sendable {
    public private(set) var lastInjectedSequence: UInt32?
    public var pendingTupleCount: Int { pendingTuples.count }

    private var pendingTuples: [InputEchoTuple] = []

    public init() {}

    public mutating func noteInjected(
        seq: UInt32,
        receivedAtMicroseconds: UInt64,
        injectedAtMicroseconds: UInt64
    ) {
        lastInjectedSequence = seq
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
