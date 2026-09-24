// ChromaPosture: the one place the agreed chroma capability list becomes
// an encoder posture. Declaration is choice: the client declares exactly
// the ONE chroma it wants, so the agreed intersection is a singleton. The
// host never infers a preference from a multi-mode list: only the
// [yuv444] singleton opens the Best-tier (Rext 4:4:4) encoder; everything
// else — [yuv420], a both-declaring peer, or no agreement at all — rides
// 4:2:0. An EMPTY intersection never reaches here: the negotiator raises
// `noCommonChromaMode` and a typed teardown follows.

import LyteCore
import LyteWire

/// The encoder posture a session opens with: Good = 4:2:0, Best = 4:4:4
/// (Better = 4:2:2 is dormant and has no wire id yet).
public enum ChromaPosture: String, Equatable, Sendable {
    case yuv420
    case yuv444

    /// nil = no agreement (yet, or ever).
    public static func from(agreedChromaModes: [UInt64]?) -> ChromaPosture {
        agreedChromaModes
            == ChromaPairing.bestSingleton(CapabilityChroma.yuv444)
            ? .yuv444 : .yuv420
    }

    /// How long the capture leg holds its first encode for the client's
    /// declaration. The declaration rides the reliable stream right after
    /// the handshake; a peer that never sends one gets 4:2:0 when the
    /// wait lapses.
    public static let openingAgreementWaitNS: UInt64 = 500_000_000

    /// The posture to open the encoder in, or nil to keep waiting. Chroma
    /// is a session posture, never a mid-stream encoder dial: opening in
    /// the agreed posture means no 4:2:0 frame precedes a Best agreement.
    public static func opening(
        agreedChromaModes: [UInt64]?, waitedNS: UInt64
    ) -> ChromaPosture? {
        if agreedChromaModes != nil || waitedNS >= openingAgreementWaitNS {
            return from(agreedChromaModes: agreedChromaModes)
        }
        return nil
    }
}
