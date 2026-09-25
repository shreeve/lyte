// Authors Vectors/session-v1.json: path challenge/response, the IDR
// request, and the conn-id TLV value codec riding a whole envelope
// datagram. Anchored by SessionCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeSessionVectorFile() throws -> SessionVectorFile {
    var vectors: [SessionVector] = []

    func reject(
        _ name: String, _ codec: SessionVector.SessionCodec,
        _ description: String, _ message: [UInt8], _ error: String
    ) {
        vectors.append(SessionVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: Hex.string(message), error: error
        ))
    }

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
    vectors.append(SessionVector(
        name: "path-response-nominal",
        description: "The well-formed echo: type 0x04, token verbatim.",
        kind: .roundtrip, codec: .pathResponse,
        messageHex: Hex.string(PathResponse(echoing: challenge).encode()),
        tokenHex: Hex.uint64String(token)
    ))
    reject("path-challenge-truncated", .pathChallenge,
           "9 bytes: the message is exactly its layout.",
           Array(challenge.encode().dropLast()), "truncated")
    reject("path-response-cross-type", .pathResponse,
           "A challenge fed to the response decoder rejects with what it "
            + "found — they never cross-decode.",
           challenge.encode(), "unexpectedType")

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
    reject("idr-request-truncated", .idrRequest, "9 bytes reject.",
           Array(request.encode().dropLast()), "truncatedMessage")
    reject("idr-request-trailing-byte", .idrRequest,
           "11 bytes reject — exactly its fixed size.",
           request.encode() + [0], "trailingBytes")
    reject("idr-request-foreign-type", .idrRequest,
           "A beacon-echo type byte at IDR-request length rejects with what "
            + "it found.",
           [CtrlMessageType.beaconEcho] + request.encode().dropFirst(),
           "unexpectedType")

    // MARK: Conn-id TLV value codec (whole-datagram vectors)

    let connIdBytes: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18]
    let connId = try ConnectionId(bytes: connIdBytes)
    vectors.append(SessionVector(
        name: "connid-tagged-datagram",
        description: "A video datagram carrying TLV 0x01 with the 8 identity "
            + "bytes; ConnectionId.decode over the decoded extensions must "
            + "yield exactly connectionIdHex.",
        kind: .roundtrip, codec: .connectionIdTlv,
        messageHex: try tlvCarrierDatagram([connId.wireExtension]),
        connectionIdHex: Hex.string(connIdBytes)
    ))
    for (name, description, extensions, error) in [
        ("connid-wrong-width",
         "TLV 0x01 with a 1-byte value: the envelope decodes, the identity "
            + "codec rejects loudly.",
         [try WireExtension(
            type: WireExtension.ReservedType.connectionId, value: [0xAA]
         )],
         "invalidValueLength"),
        ("connid-duplicate-tlv",
         "Two identity claims in one envelope is ambiguity, not a tie.",
         [connId.wireExtension,
          try ConnectionId(bytes: Array(connIdBytes.reversed())).wireExtension],
         "duplicateTlv"),
    ] {
        vectors.append(SessionVector(
            name: name, description: description,
            kind: .decodeReject, codec: .connectionIdTlv,
            messageHex: try tlvCarrierDatagram(extensions), error: error
        ))
    }

    return SessionVectorFile(vectors: vectors)
}
