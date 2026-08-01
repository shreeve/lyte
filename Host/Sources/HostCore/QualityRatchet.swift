/// Pure convergence policy for the static-quality ratchet.
///
/// NVENC can emit a transient all-skip packet while its capped-CQ walk is
/// still far above qmin. The next resend can carry a large refinement frame;
/// packet size alone therefore cannot prove convergence. Silence is earned
/// only after byte stability while the reported frame-average QP is at the
/// configured floor.
public struct QualityRatchetConvergence: Equatable, Sendable {
    public let floorQP: Int
    public let stableRatio: Double
    public let requiredStablePasses: Int

    public private(set) var previousBytes = 0
    public private(set) var stablePasses = 0

    public init(
        floorQP: Int,
        stableRatio: Double = 0.01,
        requiredStablePasses: Int = 3
    ) {
        precondition(floorQP >= 0)
        precondition(stableRatio >= 0)
        precondition(requiredStablePasses > 0)
        self.floorQP = floorQP
        self.stableRatio = stableRatio
        self.requiredStablePasses = requiredStablePasses
    }

    /// Records one encoded refinement pass. Returns true only once the walk
    /// is byte-stable at qmin; an above-floor all-skip packet resets stability.
    @discardableResult
    public mutating func note(bytes: Int, averageQP: Int) -> Bool {
        let atFloor = averageQP >= 0 && averageQP <= floorQP
        let stable = atFloor && previousBytes > 0
            && abs(bytes - previousBytes)
                <= Int(Double(previousBytes) * stableRatio)
        stablePasses = stable ? stablePasses + 1 : 0
        previousBytes = bytes
        return stablePasses >= requiredStablePasses
    }

    public mutating func reset() {
        previousBytes = 0
        stablePasses = 0
    }
}
