import XCTest
import LyteWire

// The control-plane codecs (IdleFrame 0x15, InputEvent 0x16, InputEcho
// 0x17, the lastInputSeq TLV 0x03, the audio-routing pair 0x18/0x19,
// AudioTrackState 0x25, VideoPostureState 0x26) pinned against
// hand-built byte layouts — the anchors that keep control-v1.json and
// postures-v1.json from grading their own homework. Round trips and
// decode rejects live in those vector files.

final class ControlCodecTests: XCTestCase {

    // MARK: IdleFrame (0x15)

    func testIdleFrameCodecPinsBytes() throws {
        // frame 7, capture µs 0x1122334455, a 6-byte Annex-B stub —
        // the 13-byte header hand-assembled, all fields LE.
        let frame = IdleFrame(
            frame: FrameNumber(rawValue: 7),
            captureTimestampMicroseconds: 0x11_2233_4455,
            annexB: [0, 0, 0, 1, 0x26, 0x01]
        )
        XCTAssertEqual(frame.encode(), [
            0x15,                                   // type
            7, 0, 0, 0,                             // frame u32 LE
            0x55, 0x44, 0x33, 0x22, 0x11, 0, 0, 0,  // timestamp u64 LE
            0, 0, 0, 1, 0x26, 0x01,                 // annexB verbatim
        ])
        XCTAssertEqual(try IdleFrame.decode(frame.encode()), frame)
    }

    // MARK: InputEvent (0x16) / InputEcho (0x17) / TLV 0x03

    func testInputEventCodecPinsBytes() throws {
        // keyKeycode: KEY_A (30) pressed, seq 7, client µs 0x1122334455.
        let key = InputEvent(
            seq: 7, clientMicroseconds: 0x11_2233_4455,
            body: .keyKeycode(keycode: 30, pressed: true)
        )
        XCTAssertEqual(try key.encode(), [
            0x16,                                   // type
            7, 0, 0, 0,                             // seq u32 LE
            0x55, 0x44, 0x33, 0x22, 0x11, 0, 0, 0,  // clientMicros u64 LE
            0x01,                                   // kind keyKeycode
            30, 0, 0, 0,                            // keycode u32 LE
            1,                                      // pressed
        ])
        XCTAssertEqual(try InputEvent.decode(key.encode()), key)

        // pointerMotionAbsolute: f64 bit patterns, LE.
        let move = InputEvent(
            seq: 8, clientMicroseconds: 2,
            body: .pointerMotionAbsolute(x: 512.0, y: 320.25)
        )
        var expected: [UInt8] = [0x16, 8, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x02]
        for value in [512.0, 320.25] {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 64, by: 8) {
                expected.append(UInt8(truncatingIfNeeded: bits >> shift))
            }
        }
        XCTAssertEqual(try move.encode(), expected)
        XCTAssertEqual(try InputEvent.decode(move.encode()), move)
    }

    func testInputEchoCodecPinsBytes() throws {
        // Two tuples, hand-built layout.
        let echo = InputEcho(tuples: [
            InputEchoTuple(seq: 1, receivedMicroseconds: 0x0A,
                           injectedMicroseconds: 0x0B),
            InputEchoTuple(seq: 2, receivedMicroseconds: 0x0C,
                           injectedMicroseconds: 0x0D),
        ])
        XCTAssertEqual(echo.encode(), [
            0x17, 2,
            1, 0, 0, 0,
            0x0A, 0, 0, 0, 0, 0, 0, 0,
            0x0B, 0, 0, 0, 0, 0, 0, 0,
            2, 0, 0, 0,
            0x0C, 0, 0, 0, 0, 0, 0, 0,
            0x0D, 0, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(try InputEcho.decode(echo.encode()), echo)
    }

    /// No lastInputSeq TLV is "no claim", not an error.
    func testAbsentLastInputSeqTlvIsNil() throws {
        XCTAssertNil(try LastInputSeqTlv.decode(extensions: []))
    }

    /// Hosts turn coordinates into integers with trapping conversions,
    /// so a non-finite coordinate must never leave the decoder: every
    /// NaN/±Inf class in every f64 slot of every kind rejects, naming the
    /// offending bit pattern.
    private static let nonFiniteBits: [UInt64] = [
        0x7FF8_0000_0000_0000, 0xFFF8_0000_0000_0000,
        0x7FF0_0000_0000_0001, 0x7FFF_FFFF_FFFF_FFFF,
        Double.infinity.bitPattern, (-Double.infinity).bitPattern,
    ]

    /// Every f64 slot of every kind, holding `bad` in one slot.
    private static func coordinateBodies(_ bad: Double) -> [InputEvent.Body] {
        let bodies: [(Double, Double) -> InputEvent.Body] = [
            { .pointerMotionAbsolute(x: $0, y: $1) },
            { .pointerMotionRelative(dx: $0, dy: $1) },
            { .pointerAxis(dx: $0, dy: $1, finish: false) },
        ]
        return bodies.flatMap { [$0(bad, 1), $0(1, bad)] }
    }

    func testNonFiniteCoordinatesRejectInEverySlot() {
        for bits in Self.nonFiniteBits {
            for event in Self.coordinateBodies(Double(bitPattern: bits)) {
                let bytes = InputEvent(
                    seq: 1, clientMicroseconds: 2, body: event
                ).rawCoordinateBytes()
                assertThrows(
                    InputMessageError.nonFiniteCoordinate(bits), "\(event)"
                ) {
                    try InputEvent.decode(bytes)
                }
            }
        }
        let finite = InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .pointerMotionRelative(
                dx: .greatestFiniteMagnitude, dy: -.leastNonzeroMagnitude
            )
        )
        XCTAssertEqual(try InputEvent.decode(finite.encode()), finite)
    }

    /// The encoder refuses what the decoder rejects, with the same typed
    /// error, so a sender bug surfaces at the sender instead of breaking
    /// the peer's stream.
    func testEncodeRefusesNonFiniteCoordinatesInEverySlot() {
        for bits in Self.nonFiniteBits {
            for event in Self.coordinateBodies(Double(bitPattern: bits)) {
                assertThrows(
                    InputMessageError.nonFiniteCoordinate(bits), "\(event)"
                ) {
                    try InputEvent(
                        seq: 1, clientMicroseconds: 2, body: event
                    ).encode()
                }
            }
        }
    }

    // MARK: Two-byte status codecs (0x18, 0x19, 0x25) and 0x26

    func testShortCodecsPinBytes() throws {
        XCTAssertEqual(AudioRoutingRequest(mode: .hostMuted).encode(), [0x18, 0x02])
        XCTAssertEqual(AudioRoutingStatus(mode: .streamOff).encode(), [0x19, 0x04])
        XCTAssertEqual(AudioTrackState(state: .quiet).encode(), [0x25, 0x02])
        XCTAssertEqual(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            [0x26, 0x02, 0x1E]
        )
    }

    /// A zero keepalive never travels: the initializer clamps it to 1 s
    /// (the decoder rejects a hostile zero).
    func testZeroKeepaliveClampsAtConstruction() {
        XCTAssertEqual(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 0)
                .keepaliveSeconds, 1)
    }

    // MARK: The registry itself

    func testPromotedRegistryNumbersAreThePinnedOnes() {
        // A registry typo here would be a silent wire break on both ends
        // at once.
        XCTAssertEqual(CtrlMessageType.idleFrame, 0x15)
        XCTAssertEqual(CtrlMessageType.inputEvent, 0x16)
        XCTAssertEqual(CtrlMessageType.inputEcho, 0x17)
        XCTAssertEqual(CtrlMessageType.audioRoutingRequest, 0x18)
        XCTAssertEqual(CtrlMessageType.audioRoutingStatus, 0x19)
        XCTAssertEqual(WireExtension.ReservedType.lastInputSeq, 0x03)
        XCTAssertEqual(CtrlMessageType.audioTrackState, 0x25)
        XCTAssertEqual(CtrlMessageType.videoPostureState, 0x26)
    }
}
