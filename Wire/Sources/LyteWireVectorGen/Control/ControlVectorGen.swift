// Authors Vectors/control-v1.json: IdleFrame 0x15, the input pair
// 0x16/0x17 with the lastInputSeq TLV 0x03, and the audio-routing pair
// 0x18/0x19 with capability key 9. Anchored by ControlCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeControlVectorFile() throws -> ControlVectorFile {
    var vectors: [ControlVector] = []

    func reject(
        _ name: String, _ codec: ControlVector.ControlCodec,
        _ description: String, _ hex: String, _ error: String
    ) {
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: hex, error: error
        ))
    }

    // MARK: IdleFrame (0x15)

    let idle = IdleFrame(
        frame: FrameNumber(rawValue: 7),
        captureTimestampMicroseconds: 0x11_2233_4455,
        annexB: [0, 0, 0, 1, 0x26, 0x01]
    )
    let idleBytes = idle.encode()
    vectors.append(ControlVector(
        name: "idle-frame-nominal",
        description: "13-byte header + a 6-byte Annex-B stub: type 0x15, "
            + "frame u32 LE, capture µs u64 LE, frame bytes verbatim — "
            + "the hand-computed anchor.",
        kind: .roundtrip, codec: .idleFrame,
        messageHex: Hex.string(idleBytes),
        frame: idle.frame.rawValue,
        timestampHex: Hex.uint64String(idle.captureTimestampMicroseconds),
        annexBHex: Hex.string(idle.annexB)
    ))
    reject("idle-frame-empty-body", .idleFrame,
           "The bare 13-byte header rejects — a frameless idle frame is a "
            + "construction bug, not a message.",
           Hex.string(idleBytes.prefix(13)), "truncatedMessage")
    reject("idle-frame-truncated", .idleFrame, "12 bytes reject.",
           Hex.string(idleBytes.prefix(12)), "truncatedMessage")
    reject("idle-frame-foreign-type", .idleFrame,
           "An input-event type byte at idle-frame shape rejects with what "
            + "it found.",
           Hex.string([CtrlMessageType.inputEvent] + idleBytes.dropFirst()),
           "unexpectedType")

    // MARK: InputEvent (0x16) — one roundtrip per kind (the codec's
    // whole kind space, the lifecycle whole-value-space discipline)

    let inputRoundtrips: [(String, String, InputEvent)] = [
        ("input-key-nominal",
         "keyKeycode KEY_A(30) pressed, seq 7, client µs 0x1122334455 — "
             + "the hand-computed anchor.",
         InputEvent(seq: 7, clientMicroseconds: 0x11_2233_4455,
                    body: .keyKeycode(keycode: 30, pressed: true))),
        ("input-motion-absolute",
         "pointerMotionAbsolute (512.0, 320.25): f64 IEEE-754 bit "
             + "patterns, LE — the second hand-computed anchor.",
         InputEvent(seq: 8, clientMicroseconds: 2,
                    body: .pointerMotionAbsolute(x: 512.0, y: 320.25))),
        ("input-motion-relative",
         "pointerMotionRelative (−3.5, 12.0).",
         InputEvent(seq: 99, clientMicroseconds: 1_000,
                    body: .pointerMotionRelative(dx: -3.5, dy: 12.0))),
        ("input-button",
         "pointerButton BTN_LEFT(0x110) released.",
         InputEvent(seq: 99, clientMicroseconds: 1_000,
                    body: .pointerButton(button: 0x110, pressed: false))),
        ("input-axis-finish",
         "pointerAxis (0, −45.0) with the finish flag — bit0 of the "
             + "flags byte, all others reserved-zero.",
         InputEvent(seq: 99, clientMicroseconds: 1_000,
                    body: .pointerAxis(dx: 0, dy: -45.0, finish: true))),
    ]
    for (name, description, event) in inputRoundtrips {
        let fields = controlVectorBodyFields(event.body)
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .roundtrip, codec: .inputEvent,
            messageHex: Hex.string(try event.encode()),
            seq: event.seq,
            clientMicrosHex: Hex.uint64String(event.clientMicroseconds),
            bodyKind: fields.kind,
            keycode: fields.keycode,
            button: fields.button,
            pressed: fields.pressed,
            xBitsHex: fields.xBitsHex,
            yBitsHex: fields.yBitsHex,
            finish: fields.finish
        ))
    }

    let keyAnchor = try inputRoundtrips[0].2.encode()
    var unknownKind = keyAnchor
    unknownKind[13] = 0x77
    var badFlag = keyAnchor
    badFlag[18] = 2
    var reservedAxis = try InputEvent(
        seq: 1, clientMicroseconds: 2,
        body: .pointerAxis(dx: 1, dy: 2, finish: false)
    ).encode()
    reservedAxis[reservedAxis.count - 1] = 0x82
    for (name, description, bytes, error) in [
        ("input-truncated", "14 bytes (header, no kind byte's body) reject.",
         Array(keyAnchor.prefix(14)), "truncatedMessage"),
        ("input-unknown-kind",
         "Kind 0x77 rejects — a foreign kind between capability-negotiated "
            + "peers is a protocol break to surface, not weather to skip.",
         unknownKind, "unknownKind"),
        ("input-body-length-mismatch",
         "A trailing byte after an exact-length body rejects (the W2 rule).",
         keyAnchor + [0x00], "bodyLengthMismatch"),
        ("input-malformed-flag",
         "A pressed byte that is neither 0 nor 1 rejects.",
         badFlag, "malformedFlag"),
        ("input-axis-reserved-bits",
         "Nonzero reserved bits in the axis flags byte reject.",
         reservedAxis, "reservedBitsSet"),
        ("input-foreign-type",
         "An idle-frame type byte at input-event shape rejects with what it "
            + "found.",
         [CtrlMessageType.idleFrame] + keyAnchor.dropFirst(), "unexpectedType"),
    ] {
        reject(name, .inputEvent, description, Hex.string(bytes), error)
    }

    // MARK: InputEcho (0x17)

    for (name, description, tuples) in [
        ("echo-two-tuples",
         "Two 20-byte (seq u32 ‖ rx µs u64 ‖ inject µs u64) tuples behind "
            + "the count byte — the hand-computed anchor.",
         [InputEchoTuple(seq: 1, receivedMicroseconds: 0x0A,
                         injectedMicroseconds: 0x0B),
          InputEchoTuple(seq: 2, receivedMicroseconds: 0x0C,
                         injectedMicroseconds: 0x0D)]),
        ("echo-single-tuple",
         "One tuple at the u32/u64 byte-order extremes.",
         [InputEchoTuple(seq: 0xDEAD_BEEF,
                         receivedMicroseconds: 0x0102_0304_0506_0708,
                         injectedMicroseconds: 0x1112_1314_1516_1718)]),
    ] {
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .roundtrip, codec: .inputEcho,
            messageHex: Hex.string(InputEcho(tuples: tuples).encode()),
            tuples: tuples.map {
                ControlEchoTuple(
                    seq: $0.seq,
                    receivedHex: Hex.uint64String($0.receivedMicroseconds),
                    injectedHex: Hex.uint64String($0.injectedMicroseconds)
                )
            }
        ))
    }
    reject("echo-zero-count", .inputEcho,
           "Count 0 rejects — the zero-fill rule.", "1700",
           "malformedTupleCount")
    reject("echo-over-limit-count", .inputEcho,
           "Count 33 rejects even with the bytes present — one message stays "
            + "inside the clamped ARQ segment body.",
           Hex.string([0x17, 33] + [UInt8](repeating: 0, count: 33 * 20)),
           "malformedTupleCount")
    reject("echo-length-disagrees", .inputEcho,
           "A count of 1 over 3 tuple bytes rejects.", "1701010203",
           "bodyLengthMismatch")

    // MARK: lastInputSeq TLV (0x03, whole-datagram vectors)

    vectors.append(ControlVector(
        name: "lastinputseq-tagged-datagram",
        description: "A video datagram carrying TLV 0x03 with the u32 LE "
            + "seq; LastInputSeqTlv.decode over the decoded extensions "
            + "must yield exactly lastInputSeq.",
        kind: .roundtrip, codec: .lastInputSeqTlv,
        messageHex: try tlvCarrierDatagram(
            [LastInputSeqTlv.wireExtension(seq: 0x0102_0304)]
        ),
        lastInputSeq: 0x0102_0304
    ))
    reject("lastinputseq-wrong-width", .lastInputSeqTlv,
           "TLV 0x03 with a 2-byte value: the envelope decodes, the seq "
            + "codec rejects loudly.",
           try tlvCarrierDatagram([try WireExtension(
               type: WireExtension.ReservedType.lastInputSeq, value: [1, 2]
           )]),
           "malformedLastInputSeqTlv")
    reject("lastinputseq-duplicate", .lastInputSeqTlv,
           "Two lastInputSeq claims in one envelope is ambiguity, not a tie.",
           try tlvCarrierDatagram([
               LastInputSeqTlv.wireExtension(seq: 5),
               LastInputSeqTlv.wireExtension(seq: 6),
           ]),
           "duplicateLastInputSeqTlv")

    // MARK: Audio routing (0x18/0x19 — the complete value spaces,
    // the lifecycle discipline)

    let routings: [(String, String, ControlVector.ControlCodec, ControlVector.RoutingMode)] = [
        ("routing-request-audible", "type ‖ mode: [0x18, 0x01].",
         .audioRoutingRequest, .hostAudible),
        ("routing-request-muted", "type ‖ mode: [0x18, 0x02].",
         .audioRoutingRequest, .hostMuted),
        ("routing-status-audible", "type ‖ mode: [0x19, 0x01].",
         .audioRoutingStatus, .hostAudible),
        ("routing-status-muted", "type ‖ mode: [0x19, 0x02].",
         .audioRoutingStatus, .hostMuted),
        ("routing-request-streamoff",
         "type ‖ mode: [0x18, 0x04] — streamOff (key-14 mute-at-source; "
            + "0x03 stays the pinned tombstone).",
         .audioRoutingRequest, .streamOff),
        ("routing-status-streamoff",
         "type ‖ mode: [0x19, 0x04] — streamOff applied.",
         .audioRoutingStatus, .streamOff),
    ]
    for (name, description, codec, mode) in routings {
        let wireMode = controlVectorMode(mode)
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .roundtrip, codec: codec,
            messageHex: Hex.string(codec == .audioRoutingRequest
                ? AudioRoutingRequest(mode: wireMode).encode()
                : AudioRoutingStatus(mode: wireMode).encode()),
            mode: mode
        ))
    }
    reject("routing-request-truncated", .audioRoutingRequest,
           "The bare type byte rejects.", "18", "truncatedMessage")
    reject("routing-request-cross-type", .audioRoutingRequest,
           "A status fed to the request decoder rejects with what it found "
            + "— they never cross-decode.",
           "1901", "unexpectedType")
    reject("routing-mode-zero", .audioRoutingStatus,
           "Mode 0x00 rejects — the loud zero-fill bug.", "1900",
           "unknownMode")
    reject("routing-mode-unknown", .audioRoutingRequest,
           "Mode 0x03 rejects — a foreign mode between capability-negotiated "
            + "peers is a protocol break.",
           "1803", "unknownMode")
    reject("routing-trailing-byte", .audioRoutingStatus,
           "3 bytes reject — the message is exactly its layout.", "190200",
           "trailingBytes")

    // MARK: Capability key 9 (the forward-compat spine as data)

    for (name, description, set) in [
        ("capability-key9-declared",
         "wireDefault's frozen encoding plus exactly the appended `09 F5` "
            + "entry (map head 0xA8 → 0xA9): the hostAudioRouting accessor "
            + "must read true and the set must re-encode byte-exactly — the "
            + "\"no frozen bytes moved\" claim as data.",
         Capabilities.wireDefault.declaringHostAudioRouting()),
        ("capability-key9-absent",
         "wireDefault's frozen encoding unchanged: absence reads false — "
            + "\"not supported\", never an error.",
         Capabilities.wireDefault),
    ] {
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .roundtrip, codec: .capabilitySet,
            messageHex: Hex.string(try set.encodeCbor()),
            hostAudioRouting: set.hostAudioRouting
        ))
    }

    return ControlVectorFile(vectors: vectors)
}
