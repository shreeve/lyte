public enum KernelPressureState: Equatable, Sendable {
    case calm
    case constrained
    case latencyOnly
}

public struct KernelPressureSample: Equatable, Sendable {
    public var nowNS: UInt64
    public var userspaceVideoBytes: Int
    public var videoKernelBytes: Int
    public var latencyKernelBytes: Int
    public var videoSendBufferBytes: Int
    public var latencySendBufferBytes: Int
    public var videoWouldBlockCount: Int
    public var latencyWouldBlockCount: Int
    public var videoENOBUFSCount: Int
    public var latencyENOBUFSCount: Int
    public var pacerRateBitsPerSecond: Int
    public var videoQueueBudgetNS: UInt64
    public var frameBudgetBytes: Int

    public init(
        nowNS: UInt64,
        userspaceVideoBytes: Int,
        videoKernelBytes: Int,
        latencyKernelBytes: Int,
        videoSendBufferBytes: Int,
        latencySendBufferBytes: Int,
        videoWouldBlockCount: Int,
        latencyWouldBlockCount: Int,
        videoENOBUFSCount: Int,
        latencyENOBUFSCount: Int,
        pacerRateBitsPerSecond: Int,
        videoQueueBudgetNS: UInt64,
        frameBudgetBytes: Int
    ) {
        self.nowNS = nowNS
        self.userspaceVideoBytes = userspaceVideoBytes
        self.videoKernelBytes = videoKernelBytes
        self.latencyKernelBytes = latencyKernelBytes
        self.videoSendBufferBytes = videoSendBufferBytes
        self.latencySendBufferBytes = latencySendBufferBytes
        self.videoWouldBlockCount = videoWouldBlockCount
        self.latencyWouldBlockCount = latencyWouldBlockCount
        self.videoENOBUFSCount = videoENOBUFSCount
        self.latencyENOBUFSCount = latencyENOBUFSCount
        self.pacerRateBitsPerSecond = pacerRateBitsPerSecond
        self.videoQueueBudgetNS = videoQueueBudgetNS
        self.frameBudgetBytes = frameBudgetBytes
    }
}

public struct KernelPressureDecision: Equatable, Sendable {
    public var state: KernelPressureState
    public var totalVideoServiceDebtNS: UInt64
    public var admissionBudgetNS: UInt64
    public var allowVideoPump: Bool
}

/// Pure state machine for Linux socket/qdisc pressure. It consumes measured
/// queue state and cumulative error books; it never estimates path capacity.
public struct KernelPressureGovernor: Sendable {
    public private(set) var state: KernelPressureState = .calm
    private var previous: KernelPressureSample?
    private var pressureSinceNS: UInt64?
    private var calmSinceNS: UInt64?
    private var measuredDrainNS: UInt64?

    public init() {}

    public mutating func observe(
        _ sample: KernelPressureSample
    ) -> KernelPressureDecision {
        let rate = max(sample.pacerRateBitsPerSecond, 1)
        let budget = sample.videoQueueBudgetNS
        let totalBytes = max(sample.userspaceVideoBytes, 0)
            + max(sample.videoKernelBytes, 0)
        let debt = Self.serviceTimeNS(bytes: totalBytes, rate: rate)
        let frameServiceNS = max(
            Self.serviceTimeNS(
                bytes: max(sample.frameBudgetBytes, 1), rate: rate),
            1)

        // Reserve one measured frame budget, capped at half SO_SNDBUF: a
        // frame may be larger than half the socket, but admission must still
        // leave a usable video half rather than permanently closing.
        let sendBuffer = max(sample.videoSendBufferBytes, 1)
        let frameReserve = min(
            max(sample.frameBudgetBytes, 1), sendBuffer / 2)
        let queueBudgetBytes = Self.bytes(for: budget, rate: rate)
        let highWater = min(
            max(sendBuffer - frameReserve, 0), queueBudgetBytes)
        let lowWater = highWater / 2

        /// Growth of a cumulative error book since the previous sample.
        func delta(_ book: (KernelPressureSample) -> Int) -> Int {
            max(book(sample) - (previous.map(book) ?? book(sample)), 0)
        }
        let eagainDelta = delta {
            $0.videoWouldBlockCount + $0.latencyWouldBlockCount
        }
        let enobufsDelta = delta {
            $0.videoENOBUFSCount + $0.latencyENOBUFSCount
        }

        if let prior = previous,
           sample.nowNS > prior.nowNS,
           sample.videoKernelBytes < prior.videoKernelBytes {
            let drained = prior.videoKernelBytes - sample.videoKernelBytes
            let elapsed = sample.nowNS - prior.nowNS
            // Clamped in Double: days between samples overflow UInt64.
            let fullDrain = Double(max(sample.videoKernelBytes, 1))
                * Double(elapsed) / Double(max(drained, 1))
            measuredDrainNS = fullDrain >= Double(budget)
                ? budget : min(max(UInt64(fullDrain), elapsed), budget)
        }

        let overHighWater = sample.videoKernelBytes >= highWater
            && highWater > 0
        let overBudget = debt >= budget
        let kernelPressure = overHighWater
            || eagainDelta > 0 || enobufsDelta > 0

        if kernelPressure {
            calmSinceNS = nil
            if pressureSinceNS == nil {
                pressureSinceNS = sample.nowNS
            }
            let sustainedFor = sample.nowNS
                &- (pressureSinceNS ?? sample.nowNS)
            if enobufsDelta > 0
                || sustainedFor >= min(frameServiceNS, budget) {
                state = .latencyOnly
            } else if state == .calm {
                state = .constrained
            }
        } else if overBudget {
            // Userspace debt closes pre-encode admission, but it must not
            // sustain latency-only mode after the kernel has drained: video
            // pumping is the only operation that can repay this debt.
            pressureSinceNS = nil
            calmSinceNS = nil
            state = .constrained
        } else {
            pressureSinceNS = nil
            let recovered = sample.videoKernelBytes <= lowWater
                && debt <= budget / 2
                && sample.latencyKernelBytes
                    <= max(sample.latencySendBufferBytes, 1) / 2
            if recovered {
                if calmSinceNS == nil { calmSinceNS = sample.nowNS }
                let recoveryNS = max(
                    frameServiceNS, measuredDrainNS ?? frameServiceNS)
                if sample.nowNS &- (calmSinceNS ?? sample.nowNS)
                    >= recoveryNS {
                    switch state {
                    case .latencyOnly:
                        state = .constrained
                        calmSinceNS = sample.nowNS
                    case .constrained:
                        state = .calm
                    case .calm:
                        break
                    }
                }
            } else {
                calmSinceNS = nil
            }
        }
        previous = sample

        let admissionBudget: UInt64
        switch state {
        case .calm: admissionBudget = budget
        case .constrained:
            admissionBudget = min(
                budget / 2,
                Self.serviceTimeNS(bytes: highWater, rate: rate))
        case .latencyOnly: admissionBudget = 0
        }
        return KernelPressureDecision(
            state: state,
            totalVideoServiceDebtNS: debt,
            admissionBudgetNS: admissionBudget,
            allowVideoPump: state != .latencyOnly)
    }

    public static func shouldShedAtSocket(
        priorityClass: PacerClass,
        releasedAtNS: UInt64,
        nowNS: UInt64,
        videoQueueBudgetNS: UInt64
    ) -> Bool {
        priorityClass == .freshVideo
            && nowNS >= releasedAtNS
            && nowNS - releasedAtNS >= videoQueueBudgetNS
    }

    private static func serviceTimeNS(bytes: Int, rate: Int) -> UInt64 {
        guard bytes > 0 else { return 0 }
        return UInt64(
            (Double(bytes) * 8_000_000_000 / Double(rate)).rounded(.up))
    }

    private static func bytes(for durationNS: UInt64, rate: Int) -> Int {
        Int(
            (Double(durationNS) * Double(rate) / 8_000_000_000)
                .rounded(.down))
    }
}
