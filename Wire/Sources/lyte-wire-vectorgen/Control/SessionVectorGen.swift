// Session-codec vector authoring (the codec-unification slice): the
// promoted end-side codecs — path challenge/response (HS-12), the IDR
// request (CL-3/HS-7, reconciled), and the conn-id TLV value codec
// (HS-12) riding a whole envelope datagram. Run once, commit, freeze.
// The circularity is broken by the hand-computed anchor bytes in
// SessionCodecTests, which pin the same nominal messages.

import LyteCore
import LyteWire
import LyteWireTestKit

func makeSessionVectorFile() throws -> SessionVectorFile {
    var vectors: [SessionVector] = []

    // MARK: Path challenge/response

    let token: UInt64 = 0x0102_0304_0506_0708
    let challenge = PathChallenge(token: token)
    vectors.append(SessionVector(
        name: "path-challenge-nominal",
        description: "10-byte challenge: type 0x03, flags 0, token u64 LE — "
            + "the hand-computed anchor.",
        kind: .roundtrip, codec: .pathChallenge,
        messageHex: Hex.string(challenge.encode()),
        tokenHex: Hex.uint64String(token)
    ))
    let response = PathResponse(echoing: challenge)
    vectors.append(SessionVector(
        name: "path-response-nominal",
        description: "The well-formed echo: type 0x04, token verbatim.",
        kind: .roundtrip, codec: .pathResponse,
        messageHex: Hex.string(response.encode()),
        tokenHex: Hex.uint64String(token)
    ))
    vectors.append(SessionVector(
        name: "path-challenge-truncated",
        description: "9 bytes: the message is exactly its layout.",
        kind: .decodeReject, codec: .pathChallenge,
        messageHex: Hex.string(challenge.encode().dropLast()),
        error: "truncated"
    ))
    vectors.append(SessionVector(
        name: "path-response-cross-type",
        description: "A challenge fed to the response decoder rejects with "
            + "what it found — they never cross-decode.",
        kind: .decodeReject, codec: .pathResponse,
        messageHex: Hex.string(challenge.encode()),
        error: "unexpectedType"
    ))

    // MARK: IDR request

    let request = IdrRequest(
        requestSeq: 3, frame: FrameNumber(rawValue: 0x0001_E240),
        coalescedCount: 5
    )
    vectors.append(SessionVector(
        name: "idr-request-nominal",
        description: "10-byte IDR request: type 0x10, requestSeq 3, frame "
            + "123456, coalescedCount 5 — the reconciled CL-3/HS-7 codec's "
            + "hand-computed anchor.",
        kind: .roundtrip, codec: .idrRequest,
        messageHex: Hex.string(request.encode()),
        requestSeq: request.requestSeq,
        frame: request.frame.rawValue,
        coalescedCount: request.coalescedCount
    ))
    vectors.append(SessionVector(
        name: "idr-request-truncated",
        description: "9 bytes reject.",
        kind: .decodeReject, codec: .idrRequest,
        messageHex: Hex.string(request.encode().dropLast()),
        error: "truncatedMessage"
    ))
    vectors.append(SessionVector(
        name: "idr-request-trailing-byte",
        description: "11 bytes reject — exactly its fixed size.",
        kind: .decodeReject, codec: .idrRequest,
        messageHex: Hex.string(request.encode() + [0]),
        error: "trailingBytes"
    ))
    vectors.append(SessionVector(
        name: "idr-request-foreign-type",
        description: "A beacon-echo type byte at IDR-request length rejects "
            + "with what it found.",
        kind: .decodeReject, codec: .idrRequest,
        messageHex: Hex.string(
            [CtrlMessageType.beaconEcho] + request.encode().dropFirst()
        ),
        error: "unexpectedType"
    ))

    // MARK: Conn-id TLV value codec (whole-datagram vectors)

    let connIdBytes: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18]
    let connId = try ConnectionId(bytes: connIdBytes)
    let envelope = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [connId.wireExtension]
    )
    vectors.append(SessionVector(
        name: "connid-tagged-datagram",
        description: "A video datagram carrying TLV 0x01 with the 8 identity "
            + "bytes; ConnectionId.decode over the decoded extensions must "
            + "yield exactly connectionIdHex.",
        kind: .roundtrip, codec: .connectionIdTlv,
        messageHex: Hex.string(try envelope.encode(plaintextShard: [1, 2, 3])),
        connectionIdHex: Hex.string(connIdBytes)
    ))
    let shortValue = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [try WireExtension(
            type: WireExtension.ReservedType.connectionId, value: [0xAA]
        )]
    )
    vectors.append(SessionVector(
        name: "connid-wrong-width",
        description: "TLV 0x01 with a 1-byte value: the envelope decodes, "
            + "the identity codec rejects loudly.",
        kind: .decodeReject, codec: .connectionIdTlv,
        messageHex: Hex.string(try shortValue.encode(plaintextShard: [1, 2, 3])),
        error: "invalidValueLength"
    ))
    let duplicate = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [
            connId.wireExtension,
            try ConnectionId(bytes: Array(connIdBytes.reversed())).wireExtension,
        ]
    )
    vectors.append(SessionVector(
        name: "connid-duplicate-tlv",
        description: "Two identity claims in one envelope is ambiguity, "
            + "not a tie.",
        kind: .decodeReject, codec: .connectionIdTlv,
        messageHex: Hex.string(try duplicate.encode(plaintextShard: [1, 2, 3])),
        error: "duplicateTlv"
    ))

    return SessionVectorFile(
        format: SessionVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
