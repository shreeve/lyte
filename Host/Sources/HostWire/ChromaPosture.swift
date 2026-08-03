// ChromaPosture (H4 V-4): the one place the agreed chroma capability
// list becomes an encoder posture. Owner decision 1's mechanics are
// declaration-as-choice — the client declares exactly the ONE chroma it
// wants this session, so the agreed intersection is a singleton and the
// singleton IS the choice. The host never infers a preference from a
// multi-mode list: only the unambiguous [yuv444] singleton opens the
// Best-tier (Rext 4:4:4) encoder; everything else — [yuv420], a
// both-declaring nonconforming peer, or no agreement at all (the
// grandfathered pre-W7 client that never sends a declaration) — rides
// the shipped 4:2:0 path. An EMPTY intersection never reaches this
// function: the negotiator raises `noCommonChromaMode` and the typed
// teardown follows (the client's auto-re-dial-at-420 handles it, V-5).

import LyteCore
import LyteWire

/// The encoder posture a session opens with, derived from the agreed
/// capability set (the three-tier Chroma control's host half: Good =
/// 4:2:0, Best = 4:4:4; Better = 4:2:2 is dormant on Ada silicon and
/// has no wire id yet).
public enum ChromaPosture: String, Equatable, Sendable {
    case yuv420
    case yuv444

    /// nil = no agreement (yet, or ever — the grandfathered posture).
    public static func from(agreedChromaModes: [UInt64]?) -> ChromaPosture {
        agreedChromaModes
            == ChromaPairing.bestSingleton(CapabilityChroma.yuv444)
            ? .yuv444 : .yuv420
    }
}
