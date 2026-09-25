import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// CPace's confirmation tags over the draft-irtf-cfrg-cpace-21 B.1 exchange
// values. The draft's own vectors (appendix A utilities, B.1 generator,
// shares, K and ISK, and the B.1.10 low-order table) are transcribed into
// Vectors/pairing-v1.json and checked by PairingVectorFileTests.

final class CPaceCoreTests: XCTestCase {

    private static let sid = Hex.bytes("7e4b4791d6a8ef019b936c79fb7f2c57")!
    private static let yaShare = Hex.bytes(
        "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"
    )!
    private static let ybShare = Hex.bytes(
        "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623"
    )!
    private static let k = Hex.bytes(
        "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b"
    )!

    // MARK: Confirmation-tag construction (draft §10.4)

    func testConfirmationTagsDifferPerShare() {
        let isk = CPace.intermediateSessionKey(
            sid: Self.sid, k: Self.k,
            transcript: CPace.transcript(
                ya: Self.yaShare, ada: [], yb: Self.ybShare, adb: []
            )
        )
        let key = CPace.confirmationKey(sid: Self.sid, isk: isk)
        let ta = CPace.confirmationTag(
            confirmationKey: key, share: Self.yaShare, associatedData: []
        )
        let tb = CPace.confirmationTag(
            confirmationKey: key, share: Self.ybShare, associatedData: []
        )
        XCTAssertEqual(ta.count, CPace.tagByteCount)
        XCTAssertNotEqual(ta, tb, "the two directions' tags must differ")
        XCTAssertTrue(CPace.constantTimeEquals(ta, ta))
        XCTAssertFalse(CPace.constantTimeEquals(ta, tb))
        XCTAssertFalse(
            CPace.constantTimeEquals(ta, Array(ta.dropLast())),
            "length mismatch must compare unequal"
        )
    }
}
