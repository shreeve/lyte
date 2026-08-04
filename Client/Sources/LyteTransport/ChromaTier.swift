// ChromaTier (H4 V-5): owner decision 1's client half — mode selection
// is declaration-as-choice surfaced as a three-tier "Chroma" control:
// Good = 4:2:0 / Better = 4:2:2 / Best = 4:4:4. The client declares
// exactly ONE chroma mode per the chosen tier (the agreed intersection
// is a singleton and the singleton IS the choice — ChromaPosture's
// mirror on the host). The Better tier is DORMANT from day one: no
// yuv422 wire id exists yet (that append is a Wire/ slice) and no host
// silicon offers it (Ada NVENC has no 4:2:2 encode — Blackwell
// 9th-gen only), so the control renders it visible but disabled. An
// empty intersection (Best against a 4:2:0-only host) is the typed
// `noCommonChromaMode` failure; `ChromaFallbackPolicy` below is the
// auto-re-dial-at-Good verdict the app executes, never silently.

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
    /// nil for the dormant Better tier — no yuv422 id exists in wire
    /// v1, so Better cannot be declared at all yet.
    public var declaredChromaModes: [UInt64]? {
        switch self {
        case .good: return [CapabilityChroma.yuv420]
        case .better: return nil
        case .best:
            return ChromaPairing.bestSingleton(CapabilityChroma.yuv444)
        }
    }

    /// Whether the control can select this tier today. Better renders
    /// visible but disabled ("Not offered by this host") until the
    /// yuv422 wire append lands AND a host declares it.
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
    /// A copy of this set declaring exactly the tier's chroma
    /// singleton (declaration-as-choice: the host maps the agreed
    /// singleton straight to an encoder posture, so a multi-mode list
    /// is never sent). The dormant Better tier has nothing to declare
    /// and returns the set unchanged — the control never lets it
    /// through; this is belt-and-suspenders, not policy.
    public func declaringChroma(tier: ChromaTier) -> Capabilities {
        guard let modes = tier.declaredChromaModes else { return self }
        var declared = self
        declared.chromaModes = modes
        return declared
    }
}

// MARK: - The fallback verdict (the pillar's named degradation)

/// What the app does when the capability exchange fails: a Best (or
/// any non-Good) declaration meeting a host without that tier draws
/// the typed `noCommonChromaMode` — the verdict is re-dial at Good
/// with a banner, never a silent failure and never a hang (V-4's host
/// holds frames ≤2 s awaiting agreement, so the failure is prompt).
/// Every other negotiation failure stays a failure: there is no lower
/// tier to fall back to below Good, and a codec mismatch is not a
/// chroma problem.
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

// MARK: - The stream audit (plan V-5: assert stream chroma == posture)

/// The negotiated-posture audit: the client asserts what the wire
/// actually carries against what the capability exchange agreed —
/// SPS `chroma_format_idc` parsed off every IDR (the parameter sets
/// ride in-band on IDRs) against the agreed chroma singleton. One
/// confirmation line on the first sighting, a DOCTOR line on any
/// mismatch edge — never spam, never silent. Sans-IO by construction;
/// the session core owns an instance behind its lock.
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
            // No agreed singleton (pre-agreement IDR, or a
            // never-declaring peer): report the sighting, judge
            // nothing.
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
