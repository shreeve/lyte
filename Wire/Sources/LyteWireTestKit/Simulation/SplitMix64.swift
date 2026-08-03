// SplitMix64: the seeded RNG every LyteWire property test uses, so a
// failure reproduces from its seed on any platform. Reference constants
// from Steele/Lea/Flood (Vigna's splitmix64.c).

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
}
