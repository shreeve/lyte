// SplitMix64: the seeded RNG every LyteWire property test uses, so a
// failure reproduces from its seed (Vigna's splitmix64.c constants).
// The stdlib's `Int.random(in:using:)`/`shuffle(using:)` draw at Int's
// width, so the same seed differs on wasm32; anything frozen or replayed
// across platforms draws through `int(in:)` / `shuffle(_:)`, which draw at
// 64 bits everywhere and match the stdlib on 64-bit hosts.

public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            var word = next()
            for _ in 0..<8 where out.count < count {
                out.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return out
    }

    /// A uniform Int in `range`, drawn at 64-bit width on every
    /// platform; equal to `Int.random(in: range, using: &self)` on
    /// 64-bit hosts.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let lower = Int64(range.lowerBound)
        let span = UInt64(bitPattern: Int64(range.upperBound) &- lower)
        // The stdlib returns a full-width range's raw word unoffset.
        guard span != .max else { return Int(truncatingIfNeeded: next()) }
        let draw = UInt64.random(in: 0...span, using: &self)
        return Int(truncatingIfNeeded: lower &+ Int64(bitPattern: draw))
    }

    /// A uniform Int in the non-empty `range`, drawn at 64-bit width;
    /// equal to `Int.random(in: range, using: &self)` on 64-bit hosts.
    public mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "empty range")
        return int(in: range.lowerBound...(range.upperBound - 1))
    }

    /// Fisher-Yates in place, drawn at 64-bit width; the same
    /// permutation as `collection.shuffle(using: &self)` on 64-bit hosts.
    public mutating func shuffle<C: MutableCollection & RandomAccessCollection>(
        _ collection: inout C
    ) {
        var amount = collection.count
        var current = collection.startIndex
        while amount > 1 {
            let offset = int(in: 0..<amount)
            amount -= 1
            collection.swapAt(
                current, collection.index(current, offsetBy: offset)
            )
            collection.formIndex(after: &current)
        }
    }
}
