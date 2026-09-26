// A dictionary that holds at most `capacity` keys and forgets the
// oldest-inserted one first; updating a known key keeps its age. The
// responder's bounded memories of hostile-sized key spaces (answered
// message 1s, admitted cookies, per-address budgets) all sit on it.
// Sans-IO value state, O(1) per operation.

import LyteCore

struct BoundedFifoMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var values: [Key: Value] = [:]
    private var order: BoundedRing<Key>

    init(capacity: Int) {
        order = BoundedRing(capacity: capacity)
    }

    var capacity: Int { order.capacity }
    var count: Int { values.count }

    subscript(key: Key) -> Value? { values[key] }

    /// Stores `value` under `key`. A new key past capacity evicts the
    /// oldest-inserted key.
    mutating func set(_ value: Value, for key: Key) {
        guard values.updateValue(value, forKey: key) == nil else { return }
        if let evicted = order.append(key) {
            values.removeValue(forKey: evicted)
        }
    }
}
