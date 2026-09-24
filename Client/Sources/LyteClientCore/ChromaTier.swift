// ChromaTier: the three-tier "Chroma" control — Good 4:2:0 / Better
// 4:2:2 / Best 4:4:4. The client declares exactly one chroma mode per
// tier; the agreed singleton is the choice. Better is dormant (no yuv422
// wire id, no host encoder), so it renders visible but disabled. An
// empty intersection is the typed `noCommonChromaMode` failure, which
// `ChromaFallbackPolicy` turns into a re-dial at Good.

import LyteCore
import LyteWire

/// The three-tier Chroma control's vocabulary. Raw values are the
/// per-host persistence tokens (PinnedHost.chromaTier) — never wire
/// bytes; the wire speaks CapabilityChroma ids only.
public enum ChromaTier: String, CaseIterable, Hashable, Sendable {
    case good
    case better
    case best

    /// The chroma singleton this tier declares (capability key 3), or
    /// nil for the dormant Better tier.
    public var declaredChromaModes: [UInt64]? {
        switch self {
        case .good: return [CapabilityChroma.yuv420]
        case .better: return nil
        case .best:
            return ChromaPairing.bestSingleton(CapabilityChroma.yuv444)
        }
    }

    /// Whether the control can select this tier today (Better cannot).
    public var isSelectable: Bool { declaredChromaModes != nil }

    /// The control's row title.
    public var displayName: String {
        switch self {
        case .good: return "Good"
        case .better: return "Better"
        case .best: return "Best"
        }
    }

    /// The factual sampling label (the strip caption / row detail).
    public var samplingLabel: String {
        switch self {
        case .good: return "4:2:0"
        case .better: return "4:2:2"
        case .best: return "4:4:4"
        }
    }
}

extension Capabilities {
    /// A copy of this set declaring exactly the tier's chroma singleton.
    /// The dormant Better tier returns the set unchanged.
    public func declaringChroma(tier: ChromaTier) -> Capabilities {
        guard let modes = tier.declaredChromaModes else { return self }
        var declared = self
        declared.chromaModes = modes
        return declared
    }
}

// MARK: - The fallback verdict

/// What the app does when the capability exchange fails: a non-Good
/// declaration drawing `noCommonChromaMode` re-dials at Good with a
/// banner. Every other failure stays a failure — there is no tier below
/// Good, and a codec mismatch is not a chroma problem.
public enum ChromaFallbackVerdict: Equatable, Sendable {
    /// Tear down cleanly, re-dial declaring Good (4:2:0), and say so
    /// in a non-modal banner.
    case redialAtGood
    /// Surface the failure as-is.
    case fail
}

public enum ChromaFallbackPolicy {
    public static func verdict(
        declaredTier: ChromaTier,
        failure: CapabilityNegotiationError
    ) -> ChromaFallbackVerdict {
        failure == .noCommonChromaMode && declaredTier != .good
            ? .redialAtGood : .fail
    }
}

// MARK: - The stream audit

/// Asserts what the wire carries against what the capability exchange
/// agreed: SPS `chroma_format_idc` off every IDR against the agreed
/// singleton. One confirmation line on the first sighting, a DOCTOR line
/// on each mismatch edge. Sans-IO; the session core owns an instance
/// behind its lock.
public struct ChromaStreamAudit: Sendable {
    /// idc → agreed CapabilityChroma id (idc 1 = 4:2:0 ↔ yuv420,
    /// idc 3 = 4:4:4 ↔ yuv444; idc 0/2 have no wire id and are
    /// always a mismatch against any agreed singleton).
    private static func chromaId(forIdc idc: UInt32) -> UInt64? {
        switch idc {
        case 1: return CapabilityChroma.yuv420
        case 3: return CapabilityChroma.yuv444
        default: return nil
        }
    }

    private static func describe(idc: UInt32) -> String {
        switch idc {
        case 0: return "4:0:0"
        case 1: return "4:2:0"
        case 2: return "4:2:2"
        case 3: return "4:4:4"
        default: return "chroma_format_idc \(idc)"
        }
    }

    /// The last observed `chroma_format_idc`, nil before the first
    /// IDR with a parseable SPS.
    public private(set) var observedIdc: UInt32?

    public init() {}

    /// The observed stream chroma as a human label ("4:4:4"), for
    /// stats lines.
    public var observedDescription: String? {
        observedIdc.map(Self.describe(idc:))
    }

    /// Feeds one IDR's parsed SPS. Returns a line to surface (the
    /// first-sighting confirmation, or the doctor line on a mismatch
    /// edge), nil when there is nothing new to say.
    public mutating func observe(
        chromaFormatIdc idc: UInt32, agreedChromaModes: [UInt64]?
    ) -> String? {
        guard observedIdc != idc else { return nil }
        observedIdc = idc
        let streamLabel = Self.describe(idc: idc)
        guard let agreed = agreedChromaModes, agreed.count == 1,
              let first = agreed.first else {
            // No agreed singleton yet: report the sighting, judge nothing.
            return "stream chroma \(streamLabel) (no agreed singleton)"
        }
        if Self.chromaId(forIdc: idc) == first {
            return "stream chroma \(streamLabel) — matches the "
                + "negotiated posture"
        }
        let agreedLabel = first == CapabilityChroma.yuv444
            ? "4:4:4" : (first == CapabilityChroma.yuv420
                ? "4:2:0" : "chroma id \(first)")
        return "DOCTOR: stream chroma \(streamLabel) but the "
            + "negotiated posture is \(agreedLabel) — the host is not "
            + "serving what it agreed"
    }
}
