// Authors Vectors/input-coordinates-v1.json: InputEvent (0x16) pointer
// coordinates are finite f64. Every finite bit pattern roundtrips, the
// extremes included; NaN (any sign or payload) and ±Inf reject with
// `nonFiniteCoordinate` in each of the three f64-carrying kinds and in
// either coordinate slot. The encoder refuses non-finite coordinates, so
// reject bytes are the test kit's raw bit-pattern encoding
// (`rawCoordinateBytes`) and only the decoder's domain is under test.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeInputCoordinateVectorFile() throws -> InputCoordinateVectorFile {
    var vectors: [ControlVector] = []

    let roundtrips: [(String, String, InputEvent.Body)] = [
        ("coordinates-absolute-extremes",
         "pointerMotionAbsolute (−f64 max, +f64 max): the largest finite "
             + "magnitudes are in the domain; bounding them to the screen "
             + "is the injector's job.",
         .pointerMotionAbsolute(x: -.greatestFiniteMagnitude,
                                y: .greatestFiniteMagnitude)),
        ("coordinates-relative-signed-zero-subnormal",
         "pointerMotionRelative (−0.0, the least subnormal): the sign bit "
             + "and subnormal patterns survive byte-exactly.",
         .pointerMotionRelative(dx: -0.0, dy: .leastNonzeroMagnitude)),
        ("coordinates-axis-huge",
         "pointerAxis (1e300, −1e300) with finish: finite but absurd "
             + "deltas decode; policy bounds them, not the codec.",
         .pointerAxis(dx: 1e300, dy: -1e300, finish: true)),
    ]
    for (name, description, body) in roundtrips {
        let event = InputEvent(seq: 3, clientMicroseconds: 0x40, body: body)
        let fields = controlVectorBodyFields(body)
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .roundtrip, codec: .inputEvent,
            messageHex: Hex.string(try event.encode()),
            seq: event.seq,
            clientMicrosHex: Hex.uint64String(event.clientMicroseconds),
            bodyKind: fields.kind,
            xBitsHex: fields.xBitsHex,
            yBitsHex: fields.yBitsHex,
            finish: fields.finish
        ))
    }

    let quietNaN = Double(bitPattern: 0x7FF8_0000_0000_0000)
    let negativeNaN = Double(bitPattern: 0xFFF8_0000_0000_0000)
    let signalingNaN = Double(bitPattern: 0x7FF0_0000_0000_0001)
    let rejects: [(String, String, InputEvent.Body)] = [
        ("coordinates-absolute-x-nan",
         "Absolute x = quiet NaN 0x7ff8000000000000 rejects.",
         .pointerMotionAbsolute(x: quietNaN, y: 10)),
        ("coordinates-absolute-y-infinity",
         "Absolute y = +Inf rejects although x is finite.",
         .pointerMotionAbsolute(x: 10, y: .infinity)),
        ("coordinates-relative-dx-negative-infinity",
         "Relative dx = −Inf rejects.",
         .pointerMotionRelative(dx: -.infinity, dy: 0)),
        ("coordinates-relative-dy-signaling-nan",
         "Relative dy = signaling NaN 0x7ff0000000000001 rejects — every "
             + "NaN payload is outside the domain, not only the canonical one.",
         .pointerMotionRelative(dx: 0, dy: signalingNaN)),
        ("coordinates-axis-dx-negative-nan",
         "Axis dx = negative NaN 0xfff8000000000000 rejects.",
         .pointerAxis(dx: negativeNaN, dy: 0, finish: false)),
        ("coordinates-axis-dy-infinity",
         "Axis dy = +Inf with finish set rejects.",
         .pointerAxis(dx: 0, dy: .infinity, finish: true)),
    ]
    for (name, description, body) in rejects {
        vectors.append(ControlVector(
            name: name, description: description,
            kind: .decodeReject, codec: .inputEvent,
            messageHex: Hex.string(InputEvent(
                seq: 4, clientMicroseconds: 0x41, body: body
            ).rawCoordinateBytes()),
            error: "nonFiniteCoordinate"
        ))
    }

    return InputCoordinateVectorFile(vectors: vectors)
}
