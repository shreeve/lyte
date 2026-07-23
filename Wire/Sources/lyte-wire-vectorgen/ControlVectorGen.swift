// Control-codec vector authoring (the second codec-promotion slice):
// the CTRL/TLV/capability codecs that were pinned end-side under
// mirror-and-flag during H2 — IdleFrame 0x15 (HS-11), the input pair
// 0x16/0x17 + lastInputSeq TLV 0x03 (HS-13/CL-9), the audio-routing
// pair 0x18/0x19 + capability key 9 (HS-18/CL-13). Run once, commit,
// freeze. The circularity is broken by the hand-computed anchor bytes
// in ControlCodecTests, which pin the same nominal messages.

import LyteWire
import LyteWireTestKit

func makeControlVectorFile() throws -> ControlVectorFile {
    var vectors: [ControlVector] = []

    // MARK: IdleFrame (0x15)

    let idle = IdleFrame(
        frame: FrameNumber(rawValue: 7),
        captureTimestampMicroseconds: 0x11_2233_4455,
        annexB: [0, 0, 0, 1, 0x26, 0x01]
    )
    vectors.append(ControlVector(
        name: "idle-frame-nominal",
        description: "13-byte header + a 6-byte Annex-B stub: type 0x15, "
            + "frame u32 LE, capture µs u64 LE, frame bytes verbatim — "
            + "the hand-computed anchor.",
        kind: .roundtrip, codec: .idleFrame,
        messageHex: Hex.string(idle.encode()),
        frame: idle.frame.rawValue,
        timestampHex: Hex.uint64String(idle.captureTimestampMicroseconds),
        annexBHex: Hex.string(idle.annexB)
    ))
    vectors.append(ControlVector(
        name: "idle-frame-empty-body",
        description: "The bare 13-byte header rejects — a frameless idle "
            + "frame is a construction bug, not a message.",
        kind: .decodeReject, codec: .idleFrame,
        messageHex: Hex.string(idle.encode().prefix(13)),
        error: "truncatedMessage"
    ))
    vectors.append(ControlVector(
        name: "idle-frame-truncated",
        description: "12 bytes reject.",
        kind: .decodeReject, codec: .idleFrame,
        messageHex: Hex.string(idle.encode().prefix(12)),
        error: "truncatedMessage"
    ))
    vectors.append(ControlVector(
        name: "idle-frame-foreign-type",
        description: "An input-event type byte at idle-frame shape rejects "
            + "with what it found.",
        kind: .decodeReject, codec: .idleFrame,
        messageHex: Hex.string(
            [CtrlMessageType.inputEvent] + idle.encode().dropFirst()
        ),
        error: "unexpectedType"
    ))

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
            messageHex: Hex.string(event.encode()),
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

    let keyAnchor = InputEvent(
        seq: 7, clientMicroseconds: 0x11_2233_4455,
        body: .keyKeycode(keycode: 30, pressed: true)
    ).encode()
    vectors.append(ControlVector(
        name: "input-truncated",
        description: "14 bytes (header, no kind byte's body) reject.",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(keyAnchor.prefix(14)),
        error: "truncatedMessage"
    ))
    var unknownKind = keyAnchor
    unknownKind[13] = 0x77
    vectors.append(ControlVector(
        name: "input-unknown-kind",
        description: "Kind 0x77 rejects — a foreign kind between "
            + "capability-negotiated peers is a protocol break to "
            + "surface, not weather to skip.",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(unknownKind),
        error: "unknownKind"
    ))
    vectors.append(ControlVector(
        name: "input-body-length-mismatch",
        description: "A trailing byte after an exact-length body rejects "
            + "(the W2 rule).",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(keyAnchor + [0x00]),
        error: "bodyLengthMismatch"
    ))
    var badFlag = keyAnchor
    badFlag[18] = 2
    vectors.append(ControlVector(
        name: "input-malformed-flag",
        description: "A pressed byte that is neither 0 nor 1 rejects.",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(badFlag),
        error: "malformedFlag"
    ))
    var reservedAxis = InputEvent(
        seq: 1, clientMicroseconds: 2,
        body: .pointerAxis(dx: 1, dy: 2, finish: false)
    ).encode()
    reservedAxis[reservedAxis.count - 1] = 0x82
    vectors.append(ControlVector(
        name: "input-axis-reserved-bits",
        description: "Nonzero reserved bits in the axis flags byte reject.",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(reservedAxis),
        error: "reservedBitsSet"
    ))
    vectors.append(ControlVector(
        name: "input-foreign-type",
        description: "An idle-frame type byte at input-event shape rejects "
            + "with what it found.",
        kind: .decodeReject, codec: .inputEvent,
        messageHex: Hex.string(
            [CtrlMessageType.idleFrame] + keyAnchor.dropFirst()
        ),
        error: "unexpectedType"
    ))

    // MARK: InputEcho (0x17)

    let echo = InputEcho(tuples: [
        InputEchoTuple(seq: 1, receivedMicroseconds: 0x0A,
                       injectedMicroseconds: 0x0B),
        InputEchoTuple(seq: 2, receivedMicroseconds: 0x0C,
                       injectedMicroseconds: 0x0D),
    ])
    vectors.append(ControlVector(
        name: "echo-two-tuples",
        description: "Two 20-byte (seq u32 ‖ rx µs u64 ‖ inject µs u64) "
            + "tuples behind the count byte — the hand-computed anchor.",
        kind: .roundtrip, codec: .inputEcho,
        messageHex: Hex.string(echo.encode()),
        tuples: echo.tuples.map {
            ControlEchoTuple(
                seq: $0.seq,
                receivedHex: Hex.uint64String($0.receivedMicroseconds),
                injectedHex: Hex.uint64String($0.injectedMicroseconds)
            )
        }
    ))
    let single = InputEcho(tuples: [
        InputEchoTuple(seq: 0xDEAD_BEEF,
                       receivedMicroseconds: 0x0102_0304_0506_0708,
                       injectedMicroseconds: 0x1112_1314_1516_1718),
    ])
    vectors.append(ControlVector(
        name: "echo-single-tuple",
        description: "One tuple at the u32/u64 byte-order extremes.",
        kind: .roundtrip, codec: .inputEcho,
        messageHex: Hex.string(single.encode()),
        tuples: single.tuples.map {
            ControlEchoTuple(
                seq: $0.seq,
                receivedHex: Hex.uint64String($0.receivedMicroseconds),
                injectedHex: Hex.uint64String($0.injectedMicroseconds)
            )
        }
    ))
    vectors.append(ControlVector(
        name: "echo-zero-count",
        description: "Count 0 rejects — the zero-fill rule.",
        kind: .decodeReject, codec: .inputEcho,
        messageHex: "1700",
        error: "malformedTupleCount"
    ))
    vectors.append(ControlVector(
        name: "echo-over-limit-count",
        description: "Count 33 rejects even with the bytes present — one "
            + "message stays inside the clamped ARQ segment body.",
        kind: .decodeReject, codec: .inputEcho,
        messageHex: Hex.string(
            [0x17, 33] + [UInt8](repeating: 0, count: 33 * 20)
        ),
        error: "malformedTupleCount"
    ))
    vectors.append(ControlVector(
        name: "echo-length-disagrees",
        description: "A count of 1 over 3 tuple bytes rejects.",
        kind: .decodeReject, codec: .inputEcho,
        messageHex: "1701010203",
        error: "bodyLengthMismatch"
    ))

    // MARK: lastInputSeq TLV (0x03, whole-datagram vectors — the
    // conn-id precedent)

    let tagged = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [LastInputSeqTlv.wireExtension(seq: 0x0102_0304)]
    )
    vectors.append(ControlVector(
        name: "lastinputseq-tagged-datagram",
        description: "A video datagram carrying TLV 0x03 with the u32 LE "
            + "seq; LastInputSeqTlv.decode over the decoded extensions "
            + "must yield exactly lastInputSeq.",
        kind: .roundtrip, codec: .lastInputSeqTlv,
        messageHex: Hex.string(try tagged.encode(plaintextShard: [1, 2, 3])),
        lastInputSeq: 0x0102_0304
    ))
    let wrongWidth = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [try WireExtension(
            type: WireExtension.ReservedType.lastInputSeq, value: [1, 2]
        )]
    )
    vectors.append(ControlVector(
        name: "lastinputseq-wrong-width",
        description: "TLV 0x03 with a 2-byte value: the envelope decodes, "
            + "the seq codec rejects loudly.",
        kind: .decodeReject, codec: .lastInputSeqTlv,
        messageHex: Hex.string(try wrongWidth.encode(plaintextShard: [1, 2, 3])),
        error: "malformedLastInputSeqTlv"
    ))
    let duplicate = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3),
        timestamp: 1_000_000,
        fec: 0,
        extensions: [
            LastInputSeqTlv.wireExtension(seq: 5),
            LastInputSeqTlv.wireExtension(seq: 6),
        ]
    )
    vectors.append(ControlVector(
        name: "lastinputseq-duplicate",
        description: "Two lastInputSeq claims in one envelope is "
            + "ambiguity, not a tie.",
        kind: .decodeReject, codec: .lastInputSeqTlv,
        messageHex: Hex.string(try duplicate.encode(plaintextShard: [1, 2, 3])),
        error: "duplicateLastInputSeqTlv"
    ))

    // MARK: Audio routing (0x18/0x19 — the complete value spaces,
    // the lifecycle discipline)

    vectors.append(ControlVector(
        name: "routing-request-audible",
        description: "type ‖ mode: [0x18, 0x01].",
        kind: .roundtrip, codec: .audioRoutingRequest,
        messageHex: Hex.string(
            AudioRoutingRequest(mode: .hostAudible).encode()
        ),
        mode: .hostAudible
    ))
    vectors.append(ControlVector(
        name: "routing-request-muted",
        description: "type ‖ mode: [0x18, 0x02].",
        kind: .roundtrip, codec: .audioRoutingRequest,
        messageHex: Hex.string(
            AudioRoutingRequest(mode: .hostMuted).encode()
        ),
        mode: .hostMuted
    ))
    vectors.append(ControlVector(
        name: "routing-status-audible",
        description: "type ‖ mode: [0x19, 0x01].",
        kind: .roundtrip, codec: .audioRoutingStatus,
        messageHex: Hex.string(
            AudioRoutingStatus(mode: .hostAudible).encode()
        ),
        mode: .hostAudible
    ))
    vectors.append(ControlVector(
        name: "routing-status-muted",
        description: "type ‖ mode: [0x19, 0x02].",
        kind: .roundtrip, codec: .audioRoutingStatus,
        messageHex: Hex.string(
            AudioRoutingStatus(mode: .hostMuted).encode()
        ),
        mode: .hostMuted
    ))
    vectors.append(ControlVector(
        name: "routing-request-truncated",
        description: "The bare type byte rejects.",
        kind: .decodeReject, codec: .audioRoutingRequest,
        messageHex: "18",
        error: "truncatedMessage"
    ))
    vectors.append(ControlVector(
        name: "routing-request-cross-type",
        description: "A status fed to the request decoder rejects with "
            + "what it found — they never cross-decode.",
        kind: .decodeReject, codec: .audioRoutingRequest,
        messageHex: "1901",
        error: "unexpectedType"
    ))
    vectors.append(ControlVector(
        name: "routing-mode-zero",
        description: "Mode 0x00 rejects — the loud zero-fill bug.",
        kind: .decodeReject, codec: .audioRoutingStatus,
        messageHex: "1900",
        error: "unknownMode"
    ))
    vectors.append(ControlVector(
        name: "routing-mode-unknown",
        description: "Mode 0x03 rejects — a foreign mode between "
            + "capability-negotiated peers is a protocol break.",
        kind: .decodeReject, codec: .audioRoutingRequest,
        messageHex: "1803",
        error: "unknownMode"
    ))
    vectors.append(ControlVector(
        name: "routing-trailing-byte",
        description: "3 bytes reject — the message is exactly its layout.",
        kind: .decodeReject, codec: .audioRoutingStatus,
        messageHex: "190200",
        error: "trailingBytes"
    ))

    // MARK: Capability key 9 (the forward-compat spine as data)

    vectors.append(ControlVector(
        name: "capability-key9-declared",
        description: "wireDefault's frozen encoding plus exactly the "
            + "appended `09 F5` entry (map head 0xA8 → 0xA9): the "
            + "hostAudioRouting accessor must read true and the set must "
            + "re-encode byte-exactly — the \"no frozen bytes moved\" "
            + "claim as data.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(
            try Capabilities.wireDefault.declaringHostAudioRouting()
                .encodeCbor()
        ),
        hostAudioRouting: true
    ))
    vectors.append(ControlVector(
        name: "capability-key9-absent",
        description: "wireDefault's frozen encoding unchanged: absence "
            + "reads false — \"not supported\", never an error.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(try Capabilities.wireDefault.encodeCbor()),
        hostAudioRouting: false
    ))

    return ControlVectorFile(
        format: ControlVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
