import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/pairing-v1.json byte-exact — the W6
// pairing layer's frozen artifact (gate W-G7), on both platforms: the
// external draft-irtf-cfrg-cpace-21 vectors drive CPace, the pinned
// exchange runs drive the real PairingPake machines, and the message
// vectors drive the 0x0B–0x0E codecs.

final class PairingVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/pairing-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> PairingVectorFile {
        try PairingVectorFile.load(from: Self.vectorsPath)
    }

    private func bytes(
        _ hex: String, _ context: String
    ) throws -> [UInt8] {
        try XCTUnwrap(Hex.bytes(hex), "\(context): malformed hex")
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, PairingVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.exchangeVectors.isEmpty)
        XCTAssertFalse(file.messageVectors.isEmpty)
        XCTAssertFalse(file.draftVectors.lowOrder.cases.isEmpty)
        XCTAssertFalse(file.draftVectors.source.isEmpty)
        XCTAssertEqual(file.draftVectors.sourceSha256.count, 64)
        let names = file.messageVectors.map(\.name)
            + file.exchangeVectors.map(\.name)
        XCTAssertEqual(
            Set(names).count, names.count, "vector names must be unique"
        )
    }

    // MARK: External draft vectors

    func testDraftUtilityVectors() throws {
        let utilities = try loadFile().draftVectors.utilities
        for vector in utilities.prependLen {
            XCTAssertEqual(
                CPace.prependLength(
                    try bytes(vector.inputHex, "prependLen input")
                ),
                try bytes(vector.outputHex, "prependLen output")
            )
        }
        let parts = try utilities.lvCat.partsHex.map {
            try bytes($0, "lvCat part")
        }
        XCTAssertEqual(
            CPace.lvCat(parts),
            try bytes(utilities.lvCat.outputHex, "lvCat output")
        )
        for vector in utilities.transcriptIr {
            XCTAssertEqual(
                CPace.transcript(
                    ya: try bytes(vector.yaHex, "transcript ya"),
                    ada: try bytes(vector.adaHex, "transcript ada"),
                    yb: try bytes(vector.ybHex, "transcript yb"),
                    adb: try bytes(vector.adbHex, "transcript adb")
                ),
                try bytes(vector.outputHex, "transcript output")
            )
        }
    }

    func testDraftGeneratorVector() throws {
        let generator = try loadFile().draftVectors.generator
        let prs = try bytes(generator.prsHex, "generator prs")
        let ci = try bytes(generator.ciHex, "generator ci")
        let sid = try bytes(generator.sidHex, "generator sid")
        XCTAssertEqual(
            CPace.generatorString(prs: prs, ci: ci, sid: sid),
            try bytes(generator.generatorStringHex, "generator string")
        )
        XCTAssertEqual(
            CPace.calculateGenerator(prs: prs, ci: ci, sid: sid),
            try bytes(generator.generatorHex, "generator point")
        )
    }

    func testDraftExchangeVector() throws {
        let draft = try loadFile().draftVectors
        let generator = CPace.calculateGenerator(
            prs: try bytes(draft.generator.prsHex, "prs"),
            ci: try bytes(draft.generator.ciHex, "ci"),
            sid: try bytes(draft.generator.sidHex, "sid")
        )
        let exchange = draft.exchange
        let ya = try bytes(exchange.yaHex, "ya")
        let yb = try bytes(exchange.ybHex, "yb")
        let yaShare = try bytes(exchange.yaShareHex, "Ya")
        let ybShare = try bytes(exchange.ybShareHex, "Yb")
        let k = try bytes(exchange.kHex, "K")
        XCTAssertEqual(
            CPace.scalarMult(scalar: ya, element: generator), yaShare
        )
        XCTAssertEqual(
            CPace.scalarMult(scalar: yb, element: generator), ybShare
        )
        XCTAssertEqual(
            CPace.scalarMultVfy(scalar: ya, element: ybShare), k
        )
        XCTAssertEqual(
            CPace.scalarMultVfy(scalar: yb, element: yaShare), k
        )
        XCTAssertEqual(
            CPace.intermediateSessionKey(
                sid: try bytes(draft.generator.sidHex, "sid"),
                k: k,
                transcript: CPace.transcript(
                    ya: yaShare,
                    ada: try bytes(exchange.adaHex, "ADa"),
                    yb: ybShare,
                    adb: try bytes(exchange.adbHex, "ADb")
                )
            ),
            try bytes(exchange.iskIrHex, "ISK")
        )
    }

    func testDraftLowOrderVectors() throws {
        let lowOrder = try loadFile().draftVectors.lowOrder
        let scalar = try bytes(lowOrder.scalarHex, "low-order scalar")
        for (index, testCase) in lowOrder.cases.enumerated() {
            let result = CPace.scalarMultVfy(
                scalar: scalar,
                element: try bytes(testCase.uHex, "u\(index)")
            )
            if let expected = testCase.resultHex {
                XCTAssertEqual(
                    result, try bytes(expected, "q\(index)"),
                    "u\(index) must produce the listed point"
                )
            } else {
                XCTAssertEqual(
                    result, CPace.neutralElement,
                    "u\(index) must map to the neutral element"
                )
            }
        }
    }

    // MARK: Pinned exchange vectors

    func testExchangeVectorsReplayThroughTheRealMachines() throws {
        for vector in try loadFile().exchangeVectors {
            var initiator = try PairingPakeInitiator(
                pin: try bytes(vector.pinHex, vector.name),
                clientStaticPublicKey: try bytes(
                    vector.clientStaticHex, vector.name
                ),
                hostStaticPublicKey: try bytes(
                    vector.hostStaticHex, vector.name
                ),
                noiseHandshakeHash: try bytes(
                    vector.handshakeHashHex, vector.name
                ),
                fixedScalar: try bytes(
                    vector.initiatorScalarHex, vector.name
                )
            )
            var responder = try PairingPakeResponder(
                pin: try bytes(vector.pinHex, vector.name),
                clientStaticPublicKey: try bytes(
                    vector.clientStaticHex, vector.name
                ),
                hostStaticPublicKey: try bytes(
                    vector.hostStaticHex, vector.name
                ),
                noiseHandshakeHash: try bytes(
                    vector.handshakeHashHex, vector.name
                ),
                fixedScalar: try bytes(
                    vector.responderScalarHex, vector.name
                )
            )
            let shareA = try initiator.makeShareA()
            XCTAssertEqual(
                try shareA.encode(),
                try bytes(vector.shareAMessageHex, vector.name),
                "\(vector.name): share A bytes"
            )
            let shareB = try responder.receiveShareA(shareA)
            XCTAssertEqual(
                try shareB.encode(),
                try bytes(vector.shareBMessageHex, vector.name),
                "\(vector.name): share B bytes"
            )
            let confirm = try initiator.receiveShareB(shareB)
            XCTAssertEqual(
                try confirm.encode(),
                try bytes(vector.confirmMessageHex, vector.name),
                "\(vector.name): confirm bytes"
            )
            try responder.receiveConfirm(confirm)
            let expectedIsk = try bytes(vector.iskHex, vector.name)
            XCTAssertEqual(
                try XCTUnwrap(initiator.result).intermediateSessionKey,
                expectedIsk, "\(vector.name): initiator ISK"
            )
            XCTAssertEqual(
                try XCTUnwrap(responder.result).intermediateSessionKey,
                expectedIsk, "\(vector.name): responder ISK"
            )
        }
    }

    // MARK: Codec vectors

    func testEveryRejectReasonIsPinned() throws {
        let reasons = Set(try loadFile().messageVectors
            .filter { $0.kind == .roundtrip && $0.codec == .reject }
            .compactMap(\.reason))
        XCTAssertEqual(
            reasons, Set(PairingRejectReason.allCases.map(\.rawValue)),
            "the reject codec's whole value space must be pinned"
        )
    }

    func testAllMessageVectors() throws {
        for vector in try loadFile().messageVectors {
            let message = try bytes(vector.messageHex, vector.name)
            switch vector.kind {
            case .roundtrip:
                try verifyRoundtrip(vector, message: message)
            case .decodeReject:
                try verifyDecodeReject(vector, message: message)
            }
        }
    }

    private func verifyRoundtrip(
        _ vector: PairingMessageVector, message: [UInt8]
    ) throws {
        switch vector.codec {
        case .shareA:
            let share = try bytes(
                try XCTUnwrap(vector.shareHex, vector.name), vector.name
            )
            XCTAssertEqual(
                try PairingShareA(share: share).encode(), message,
                vector.name
            )
            XCTAssertEqual(
                try PairingShareA.decode(message).share, share,
                vector.name
            )
        case .shareB:
            let share = try bytes(
                try XCTUnwrap(vector.shareHex, vector.name), vector.name
            )
            let tag = try bytes(
                try XCTUnwrap(vector.tagHex, vector.name), vector.name
            )
            XCTAssertEqual(
                try PairingShareB(
                    share: share, confirmationTag: tag
                ).encode(),
                message, vector.name
            )
            let decoded = try PairingShareB.decode(message)
            XCTAssertEqual(decoded.share, share, vector.name)
            XCTAssertEqual(decoded.confirmationTag, tag, vector.name)
        case .confirm:
            let tag = try bytes(
                try XCTUnwrap(vector.tagHex, vector.name), vector.name
            )
            XCTAssertEqual(
                try PairingConfirm(confirmationTag: tag).encode(),
                message, vector.name
            )
            XCTAssertEqual(
                try PairingConfirm.decode(message).confirmationTag, tag,
                vector.name
            )
        case .reject:
            let reason = try XCTUnwrap(
                PairingRejectReason(
                    rawValue: try XCTUnwrap(vector.reason, vector.name)
                ),
                vector.name
            )
            XCTAssertEqual(
                PairingReject(reason: reason).encode(), message,
                vector.name
            )
            XCTAssertEqual(
                try PairingReject.decode(message).reason, reason,
                vector.name
            )
        }
    }

    private func verifyDecodeReject(
        _ vector: PairingMessageVector, message: [UInt8]
    ) throws {
        let decode: () throws -> Void
        switch vector.codec {
        case .shareA: decode = { _ = try PairingShareA.decode(message) }
        case .shareB: decode = { _ = try PairingShareB.decode(message) }
        case .confirm: decode = { _ = try PairingConfirm.decode(message) }
        case .reject: decode = { _ = try PairingReject.decode(message) }
        }
        XCTAssertThrowsError(try decode(), vector.name) { error in
            guard let error = error as? PairingMessageError else {
                return XCTFail("\(vector.name): foreign error \(error)")
            }
            XCTAssertEqual(
                pairingMessageErrorName(error), vector.error, vector.name
            )
        }
    }
}
