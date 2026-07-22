// Pairing vector authoring (W6): draft-irtf-cfrg-cpace-21's external
// vectors transcribed as constants, the pinned PairingPake exchange
// runs, and the 0x0B–0x0E codec layouts. Run once, commit, freeze. The
// circularity is broken twice over: the draft section is transcription
// (not generation), and the codec/exchange sections are anchored by the
// hand-built bytes in PairingCodecTests and the draft-pinned math in
// CPaceCoreTests.

import LyteWire
import LyteWireTestKit

private let draftSource =
    "https://www.ietf.org/archive/id/draft-irtf-cfrg-cpace-21.txt"
private let draftSha256 =
    "ed2772c26c21d43a199d490c1ebe5c5d2431a7dbce50d2124d4fa40957fbf58f"

func makePairingVectorFile() throws -> PairingVectorFile {
    PairingVectorFile(
        format: PairingVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        draftVectors: makeDraftVectors(),
        exchangeVectors: try makeExchangeVectors(),
        messageVectors: try makeMessageVectors()
    )
}

// MARK: - External draft vectors (transcribed, not generated)

private func makeDraftVectors() -> PairingDraftVectors {
    let bytes127 = Hex.string((0..<127).map { UInt8($0) })
    let bytes128 = Hex.string((0..<128).map { UInt8($0) })
    return PairingDraftVectors(
        source: draftSource,
        sourceSha256: draftSha256,
        utilities: .init(
            prependLen: [
                // A.1.2, including both sides of the LEB128 boundary.
                .init(inputHex: "", outputHex: "00"),
                .init(inputHex: "31323334", outputHex: "0431323334"),
                .init(inputHex: bytes127, outputHex: "7f" + bytes127),
                .init(inputHex: bytes128, outputHex: "8001" + bytes128),
            ],
            lvCat: .init(
                // A.1.4: lv_cat(b"1234", b"5", b"", b"678").
                partsHex: ["31323334", "35", "", "363738"],
                outputHex: "043132333401350003363738"
            ),
            transcriptIr: [
                // A.3.5.
                .init(
                    yaHex: "313233", adaHex: "506172747941",
                    ybHex: "323334", adbHex: "506172747942",
                    outputHex:
                        "03313233065061727479410332333406506172747942"
                ),
                .init(
                    yaHex: "33343536", adaHex: "506172747941",
                    ybHex: "32333435", adbHex: "506172747942",
                    outputHex:
                        "043334353606506172747941043233343506506172747942"
                ),
            ]
        ),
        generator: .init(
            // B.1.1: PRS = b"Password", the draft's CI and sid.
            prsHex: "50617373776f7264",
            ciHex: "0b415f696e69746961746f720b425f726573706f6e646572",
            sidHex: "7e4b4791d6a8ef019b936c79fb7f2c57",
            generatorStringHex:
                "0843506163653235350850617373776f72646d000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000000000000000000000000000"
                + "00000000000000000000000000000000180b415f696e69746961746f"
                + "720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f"
                + "2c57",
            generatorHex:
                "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b6"
                + "2f05a73f"
        ),
        exchange: .init(
            // B.1.2–B.1.5, initiator-responder setting.
            yaHex:
                "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b3190971"
                + "53044080",
            adaHex: "414461",
            yaShareHex:
                "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989"
                + "ce0c9f32",
            ybHex:
                "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19"
                + "c51ac40a",
            adbHex: "414462",
            ybShareHex:
                "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea"
                + "32185623",
            kHex:
                "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee"
                + "71322c6b",
            iskIrHex:
                "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4"
                + "d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270ad"
                + "fa8bf413285f2263"
        ),
        lowOrder: .init(
            // B.1.10: u0…u5 and u7 MUST yield the neutral element (and
            // abort a pairing run); u6, u8…ub are non-canonical
            // encodings that MUST produce the listed points.
            scalarHex:
                "af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244"
                + "ba449aff",
            cases: [
                .init(
                    uHex: "00000000000000000000000000000000000000000000"
                        + "00000000000000000000",
                    resultHex: nil
                ),
                .init(
                    uHex: "01000000000000000000000000000000000000000000"
                        + "00000000000000000000",
                    resultHex: nil
                ),
                .init(
                    uHex: "ecffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffff7f",
                    resultHex: nil
                ),
                .init(
                    uHex: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32"
                        + "b1fd866205165f49b800",
                    resultHex: nil
                ),
                .init(
                    uHex: "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c"
                        + "8e86d8224eddd09f1157",
                    resultHex: nil
                ),
                .init(
                    uHex: "edffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffff7f",
                    resultHex: nil
                ),
                .init(
                    uHex: "daffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffffff",
                    resultHex: "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9a"
                        + "dfba3b6e040e8d3b71b21806"
                ),
                .init(
                    uHex: "eeffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffff7f",
                    resultHex: nil
                ),
                .init(
                    uHex: "dbffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffffff",
                    resultHex: "c85c655ebe8be44ba9c0ffde69f2fe10194458d1"
                        + "37f09bbff725ce58803cdb38"
                ),
                .init(
                    uHex: "d9ffffffffffffffffffffffffffffffffffffffffff"
                        + "ffffffffffffffffffff",
                    resultHex: "db64dafa9b8fdd136914e61461935fe92aa372cb"
                        + "056314e1231bc4ec12417456"
                ),
                .init(
                    uHex: "cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32"
                        + "b1fd866205165f49b880",
                    resultHex: "e062dcd5376d58297be2618c7498f55baa07d7e0"
                        + "3184e8aada20bca28888bf7a"
                ),
                .init(
                    uHex: "4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c"
                        + "8e86d8224eddd09f11d7",
                    resultHex: "993c6ad11c4c29da9a56f7691fd0ff8d732e49de"
                        + "6250b6c2e80003ff4629a175"
                ),
            ]
        )
    )
}

// MARK: - Pinned PairingPake exchanges

private func makeExchangeVectors() throws -> [PairingExchangeVector] {
    // Counting-byte inputs, auditable by eye (the noise-v1 convention).
    let pin = Array("482913".utf8)
    let clientStatic = (0..<32).map { UInt8(0x10 + $0) }
    let hostStatic = (0..<32).map { UInt8(0x30 + $0) }
    let handshakeHash = (0..<32).map { UInt8(0x50 + $0) }
    let initiatorScalar = (0..<32).map { UInt8(0x70 + $0) }
    let responderScalar = (0..<32).map { UInt8(0x90 + $0) }

    var initiator = try PairingPakeInitiator(
        pin: pin,
        clientStaticPublicKey: clientStatic,
        hostStaticPublicKey: hostStatic,
        noiseHandshakeHash: handshakeHash,
        fixedScalar: initiatorScalar
    )
    var responder = try PairingPakeResponder(
        pin: pin,
        clientStaticPublicKey: clientStatic,
        hostStaticPublicKey: hostStatic,
        noiseHandshakeHash: handshakeHash,
        fixedScalar: responderScalar
    )
    let shareA = try initiator.makeShareA()
    let shareB = try responder.receiveShareA(shareA)
    let confirm = try initiator.receiveShareB(shareB)
    try responder.receiveConfirm(confirm)
    guard
        let initiatorResult = initiator.result,
        let responderResult = responder.result,
        initiatorResult.intermediateSessionKey
            == responderResult.intermediateSessionKey
    else {
        die("pairing exchange vector generation disagreed on the ISK")
    }

    return [PairingExchangeVector(
        name: "pairing-nominal",
        description: "A full PIN-pairing run over counting-byte inputs:"
            + " PIN \"482913\", statics 0x10…/0x30…, Noise handshake"
            + " hash 0x50…, scalars 0x70…/0x90… — the exact 0x0B/0x0C/"
            + "0x0D message bytes and the shared ISK.",
        provenance: "pinned-self-consistent",
        pinHex: Hex.string(pin),
        clientStaticHex: Hex.string(clientStatic),
        hostStaticHex: Hex.string(hostStatic),
        handshakeHashHex: Hex.string(handshakeHash),
        initiatorScalarHex: Hex.string(initiatorScalar),
        responderScalarHex: Hex.string(responderScalar),
        shareAMessageHex: Hex.string(try shareA.encode()),
        shareBMessageHex: Hex.string(try shareB.encode()),
        confirmMessageHex: Hex.string(try confirm.encode()),
        iskHex: Hex.string(initiatorResult.intermediateSessionKey)
    )]
}

// MARK: - Codec vectors

private func makeMessageVectors() throws -> [PairingMessageVector] {
    let share = (0..<32).map { UInt8(0xA0 + $0) }
    let tag = (0..<64).map { UInt8($0) }
    var vectors: [PairingMessageVector] = []

    // Round trips — the PairingCodecTests hand-computed anchors as data.
    vectors.append(PairingMessageVector(
        name: "share-a-nominal",
        description: "Client's CPace share Ya, counting bytes from 0xA0.",
        kind: .roundtrip, codec: .shareA,
        messageHex: Hex.string(try PairingShareA(share: share).encode()),
        shareHex: Hex.string(share)
    ))
    vectors.append(PairingMessageVector(
        name: "share-b-nominal",
        description: "Host's share Yb plus its confirmation tag Tb.",
        kind: .roundtrip, codec: .shareB,
        messageHex: Hex.string(
            try PairingShareB(share: share, confirmationTag: tag).encode()
        ),
        shareHex: Hex.string(share),
        tagHex: Hex.string(tag)
    ))
    vectors.append(PairingMessageVector(
        name: "confirm-nominal",
        description: "Client's confirmation tag Ta.",
        kind: .roundtrip, codec: .confirm,
        messageHex: Hex.string(
            try PairingConfirm(confirmationTag: tag).encode()
        ),
        tagHex: Hex.string(tag)
    ))
    for reason in PairingRejectReason.allCases {
        let slug = reason == .confirmationFailed
            ? "confirmation-failed" : "invalid-share"
        vectors.append(PairingMessageVector(
            name: "reject-\(slug)",
            description: reason == .confirmationFailed
                ? "Refusal after a bad tag — wrong PIN and tampered"
                    + " binding share one value on purpose (no oracle)."
                : "Refusal of a low-order share (the G.I abort).",
            kind: .roundtrip, codec: .reject,
            messageHex: Hex.string(PairingReject(reason: reason).encode()),
            reason: reason.rawValue
        ))
    }

    // Decode rejects — the fixed-frame discipline.
    vectors.append(PairingMessageVector(
        name: "share-a-truncated",
        description: "The type byte alone — share A is exactly 33 bytes.",
        kind: .decodeReject, codec: .shareA,
        messageHex: "0b", error: "truncatedMessage"
    ))
    vectors.append(PairingMessageVector(
        name: "share-a-trailing-byte",
        description: "34 bytes where the message is exactly its layout.",
        kind: .decodeReject, codec: .shareA,
        messageHex: Hex.string([0x0B] + share + [0x00]),
        error: "trailingBytes"
    ))
    vectors.append(PairingMessageVector(
        name: "share-a-bad-type",
        description: "A share-B type byte fed to the share-A decoder.",
        kind: .decodeReject, codec: .shareA,
        messageHex: Hex.string([0x0C] + share), error: "unexpectedType"
    ))
    vectors.append(PairingMessageVector(
        name: "share-b-truncated",
        description: "Share without the tag — share B is exactly"
            + " 97 bytes.",
        kind: .decodeReject, codec: .shareB,
        messageHex: Hex.string([0x0C] + share), error: "truncatedMessage"
    ))
    vectors.append(PairingMessageVector(
        name: "confirm-bad-type",
        description: "A share-A type byte fed to the confirm decoder.",
        kind: .decodeReject, codec: .confirm,
        messageHex: Hex.string([0x0B] + tag), error: "unexpectedType"
    ))
    vectors.append(PairingMessageVector(
        name: "confirm-trailing-byte",
        description: "66 bytes where the message is exactly its layout.",
        kind: .decodeReject, codec: .confirm,
        messageHex: Hex.string([0x0D] + tag + [0x00]),
        error: "trailingBytes"
    ))
    vectors.append(PairingMessageVector(
        name: "reject-truncated",
        description: "The type byte alone — a reject is exactly 2 bytes.",
        kind: .decodeReject, codec: .reject,
        messageHex: "0e", error: "truncatedMessage"
    ))
    vectors.append(PairingMessageVector(
        name: "reject-zero",
        description: "Reason 0x00 — the loud zero-fill bug, never a"
            + " value.",
        kind: .decodeReject, codec: .reject,
        messageHex: "0e00", error: "unknownReason"
    ))
    vectors.append(PairingMessageVector(
        name: "reject-unknown",
        description: "Reason 0x7f — unassigned reasons reject.",
        kind: .decodeReject, codec: .reject,
        messageHex: "0e7f", error: "unknownReason"
    ))

    return vectors
}
