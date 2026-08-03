import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The W-G7 external anchors: CPACE-X25519-SHA512 verified against the
// published test vectors in draft-irtf-cfrg-cpace-21, appendices A and
// B.1 — hand-transcribed here so the implementation never grades its
// own homework, and frozen again as data in Vectors/pairing-v1.json.
// Source: https://www.ietf.org/archive/id/draft-irtf-cfrg-cpace-21.txt
// (sha256 ed2772c26c21d43a199d490c1ebe5c5d2431a7dbce50d2124d4fa40957fbf58f).

final class CPaceCoreTests: XCTestCase {

    // MARK: Draft appendix A — string utilities

    func testPrependLenDraftVectors() {
        // A.1.2.
        XCTAssertEqual(Hex.string(CPace.prependLength([])), "00")
        XCTAssertEqual(
            Hex.string(CPace.prependLength(Array("1234".utf8))),
            "0431323334"
        )
        // The LEB128 boundary: 127 one-byte, 128 two-byte.
        let bytes127 = (0..<127).map { UInt8($0) }
        XCTAssertEqual(
            Hex.string(CPace.prependLength(bytes127)),
            "7f" + Hex.string(bytes127)
        )
        let bytes128 = (0..<128).map { UInt8($0) }
        XCTAssertEqual(
            Hex.string(CPace.prependLength(bytes128)),
            "8001" + Hex.string(bytes128)
        )
    }

    func testLvCatDraftVector() {
        // A.1.4: lv_cat(b"1234", b"5", b"", b"678").
        XCTAssertEqual(
            Hex.string(CPace.lvCat(
                Array("1234".utf8), Array("5".utf8), [], Array("678".utf8)
            )),
            "043132333401350003363738"
        )
    }

    func testTranscriptIrDraftVectors() {
        // A.3.5.
        XCTAssertEqual(
            Hex.string(CPace.transcript(
                ya: Array("123".utf8), ada: Array("PartyA".utf8),
                yb: Array("234".utf8), adb: Array("PartyB".utf8)
            )),
            "03313233065061727479410332333406506172747942"
        )
        XCTAssertEqual(
            Hex.string(CPace.transcript(
                ya: Array("3456".utf8), ada: Array("PartyA".utf8),
                yb: Array("2345".utf8), adb: Array("PartyB".utf8)
            )),
            "043334353606506172747941043233343506506172747942"
        )
    }

    // MARK: Draft B.1 — the full CPACE-X25519-SHA512 exchange

    private static let prs = Array("Password".utf8)
    private static let ci = Hex.bytes(
        "0b415f696e69746961746f720b425f726573706f6e646572"
    )!
    private static let sid = Hex.bytes("7e4b4791d6a8ef019b936c79fb7f2c57")!
    private static let ya = Hex.bytes(
        "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080"
    )!
    private static let yaShare = Hex.bytes(
        "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"
    )!
    private static let yb = Hex.bytes(
        "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a"
    )!
    private static let ybShare = Hex.bytes(
        "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623"
    )!
    private static let k = Hex.bytes(
        "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b"
    )!

    func testGeneratorStringDraftVector() {
        // B.1.1: DSI ‖ PRS ‖ 109-byte zero pad fills the first SHA-512
        // block, then CI and sid.
        let generatorString = CPace.generatorString(
            prs: Self.prs, ci: Self.ci, sid: Self.sid
        )
        XCTAssertEqual(generatorString.count, 170)
        XCTAssertEqual(
            Hex.string(generatorString),
            "0843506163653235350850617373776f72646d000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000180b415f696e69746961746f"
                + "720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f"
                + "2c57"
        )
    }

    func testCalculateGeneratorDraftVector() {
        // B.1.1's end-to-end pin: hash → decodeUCoordinate → Elligator 2.
        XCTAssertEqual(
            Hex.string(CPace.calculateGenerator(
                prs: Self.prs, ci: Self.ci, sid: Self.sid
            )),
            "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f"
        )
    }

    func testPublicSharesDraftVectors() {
        // B.1.2 / B.1.3: Ya = X25519(ya, g), Yb = X25519(yb, g).
        let generator = CPace.calculateGenerator(
            prs: Self.prs, ci: Self.ci, sid: Self.sid
        )
        XCTAssertEqual(
            CPace.scalarMult(scalar: Self.ya, element: generator),
            Self.yaShare
        )
        XCTAssertEqual(
            CPace.scalarMult(scalar: Self.yb, element: generator),
            Self.ybShare
        )
    }

    func testSharedSecretDraftVector() {
        // B.1.4: both orders agree on K.
        XCTAssertEqual(
            CPace.scalarMultVfy(scalar: Self.ya, element: Self.ybShare),
            Self.k
        )
        XCTAssertEqual(
            CPace.scalarMultVfy(scalar: Self.yb, element: Self.yaShare),
            Self.k
        )
    }

    func testIskDraftVector() {
        // B.1.5, initiator-responder setting with ADa = b"ADa",
        // ADb = b"ADb".
        let transcript = CPace.transcript(
            ya: Self.yaShare, ada: Array("ADa".utf8),
            yb: Self.ybShare, adb: Array("ADb".utf8)
        )
        XCTAssertEqual(
            Hex.string(CPace.intermediateSessionKey(
                sid: Self.sid, k: Self.k, transcript: transcript
            )),
            "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4"
                + "d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270ad"
                + "fa8bf413285f2263"
        )
    }

    // MARK: Draft B.1.10 — scalar_mult_vfy low-order / non-canonical table

    func testLowOrderPointsDraftVectors() {
        // The 12-row table: u0…u5 and u7 encode low-order points on the
        // curve or twist and MUST come back as G.I; u6 and u8…ub are
        // non-canonical encodings (bit #255 set) of valid points and
        // MUST produce the exact listed results — proving the RFC 7748
        // bit-clearing happens inside scalar_mult_vfy on BOTH platforms.
        let scalar = Hex.bytes(
            "af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff"
        )!
        let table: [(u: String, q: String?)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", nil),
            ("0100000000000000000000000000000000000000000000000000000000000000", nil),
            ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", nil),
            ("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", nil),
            ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
             "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
             "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
             "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
             "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
             "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
        ]
        for (index, row) in table.enumerated() {
            let result = CPace.scalarMultVfy(
                scalar: scalar, element: Hex.bytes(row.u)!
            )
            if let q = row.q {
                XCTAssertEqual(
                    Hex.string(result), q, "u\(index) must produce q\(index)"
                )
            } else {
                XCTAssertEqual(
                    result, CPace.neutralElement,
                    "u\(index) must map to the neutral element"
                )
            }
        }
    }

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
