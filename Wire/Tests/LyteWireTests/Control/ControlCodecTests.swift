import XCTest
import LyteWire

// The promoted control-plane codecs (the second codec-promotion slice:
// IdleFrame 0x15, InputEvent 0x16, InputEcho 0x17, the lastInputSeq
// TLV 0x03, AudioRoutingRequest/Status 0x18/0x19, capability key 9),
// pinned against HAND-BUILT byte layouts — the same arrays the Host/
// and root gate tests pinned while the codecs lived as end-side
// mirrors, now the canonical anchor that keeps control-v1.json from
// grading its own homework.

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

    func testHostileIdleFrameBytesRejectAndNeverTrap() {
        let good = IdleFrame(
            frame: FrameNumber(rawValue: 7),
            captureTimestampMicroseconds: 1,
            annexB: [0xAA]
        ).encode()
        // Truncation at every length through the bare header (an empty
        // frame body is a construction bug, not a message).
        for length in 0...IdleFrame.headerByteCount {
            XCTAssertThrowsError(
                try IdleFrame.decode(Array(good.prefix(length))),
                "truncation to \(length) bytes must reject"
            )
        }
        // Foreign type byte rejects with what it found.
        assertThrows(IdleFrameError.unexpectedType(0x16)) {
            try IdleFrame.decode([0x16] + good.dropFirst())
        }
    }

    // MARK: InputEvent (0x16) / InputEcho (0x17) / TLV 0x03

    func testInputEventCodecPinsBytes() throws {
        // keyKeycode: KEY_A (30) pressed, seq 7, client µs 0x1122334455
        // — the InputGateTests hand-built array, verbatim.
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

        // The remaining kinds round-trip.
        for body: InputEvent.Body in [
            .pointerMotionRelative(dx: -3.5, dy: 12.0),
            .pointerButton(button: 0x110, pressed: false),
            .pointerAxis(dx: 0, dy: -45.0, finish: true),
        ] {
            let event = InputEvent(seq: 99, clientMicroseconds: 1_000, body: body)
            XCTAssertEqual(try InputEvent.decode(event.encode()), event)
        }
    }

    func testInputEchoCodecPinsBytes() throws {
        // Two tuples, hand-built layout — the InputGateTests array.
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

    func testHostileInputBytesRejectAndNeverTrap() throws {
        let good = try InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .keyKeycode(keycode: 30, pressed: true)
        ).encode()

        // Truncations at every length below the minimum.
        for length in 0..<good.count {
            XCTAssertThrowsError(
                try InputEvent.decode(Array(good.prefix(length))),
                "truncation to \(length) bytes must reject"
            )
        }
        // Foreign type byte.
        XCTAssertThrowsError(try InputEvent.decode([0x15] + good.dropFirst()))
        // Unknown kind.
        var badKind = good
        badKind[13] = 0x77
        XCTAssertThrowsError(try InputEvent.decode(badKind))
        // Trailing junk (body length disagrees with the kind).
        XCTAssertThrowsError(try InputEvent.decode(good + [0x00]))
        // A flag byte that is neither 0 nor 1.
        var badFlag = good
        badFlag[18] = 2
        XCTAssertThrowsError(try InputEvent.decode(badFlag))
        // Reserved axis-flag bits.
        var axis = try InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .pointerAxis(dx: 1, dy: 2, finish: false)
        ).encode()
        axis[axis.count - 1] = 0x82
        XCTAssertThrowsError(try InputEvent.decode(axis))

        // Echo: count 0, count/length mismatch, over-limit count.
        XCTAssertThrowsError(try InputEcho.decode([0x17, 0]))
        XCTAssertThrowsError(try InputEcho.decode([0x17, 1, 1, 2, 3]))
        XCTAssertThrowsError(try InputEcho.decode(
            [0x17, 33] + [UInt8](repeating: 0, count: 33 * 20)
        ))

        // The TLV: duplicate and malformed value.
        let tlv = LastInputSeqTlv.wireExtension(seq: 5)
        XCTAssertEqual(try LastInputSeqTlv.decode(extensions: [tlv]), 5)
        XCTAssertThrowsError(
            try LastInputSeqTlv.decode(extensions: [tlv, tlv])
        )
        XCTAssertThrowsError(try LastInputSeqTlv.decode(
            extensions: [try WireExtension(
                type: WireExtension.ReservedType.lastInputSeq, value: [1, 2]
            )]
        ))
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

    // MARK: AudioRoutingRequest/Status (0x18/0x19)

    func testRoutingCodecsPinBytes() throws {
        // The AudioRoutingGateTests hand-built pins, verbatim.
        XCTAssertEqual(
            AudioRoutingRequest(mode: .hostAudible).encode(), [0x18, 0x01]
        )
        XCTAssertEqual(
            AudioRoutingRequest(mode: .hostMuted).encode(), [0x18, 0x02]
        )
        XCTAssertEqual(
            AudioRoutingStatus(mode: .hostAudible).encode(), [0x19, 0x01]
        )
        XCTAssertEqual(
            AudioRoutingStatus(mode: .hostMuted).encode(), [0x19, 0x02]
        )
        for mode in HostAudioRoutingMode.allCases {
            XCTAssertEqual(
                try AudioRoutingRequest.decode(
                    AudioRoutingRequest(mode: mode).encode()
                ).mode, mode
            )
            XCTAssertEqual(
                try AudioRoutingStatus.decode(
                    AudioRoutingStatus(mode: mode).encode()
                ).mode, mode
            )
        }
    }

    func testHostileRoutingBytesRejectAndNeverTrap() {
        // Truncation.
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19]))
        XCTAssertThrowsError(try AudioRoutingRequest.decode([]))
        // Foreign type byte (each other's, and a stranger's).
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x19, 0x01]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x18, 0x01]))
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x7F, 0x01]))
        // Unknown modes: 0, 3, 255.
        for mode: UInt8 in [0x00, 0x03, 0xFF] {
            XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18, mode]))
            XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19, mode]))
        }
        // Trailing bytes.
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18, 0x01, 0]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19, 0x02, 0]))
    }

    // MARK: AudioTrackState (0x25) / VideoPostureState (0x26)

    func testAudioTrackStateCodecPinsBytesAndRejectsHostiles() throws {
        // The pinned images.
        XCTAssertEqual(
            AudioTrackState(state: .active).encode(), [0x25, 0x01]
        )
        XCTAssertEqual(
            AudioTrackState(state: .quiet).encode(), [0x25, 0x02]
        )
        for state in AudioTrackState.State.allCases {
            XCTAssertEqual(
                try AudioTrackState.decode(
                    AudioTrackState(state: state).encode()
                ).state, state
            )
        }
        // Truncation, foreign types, unknown states, trailing bytes.
        XCTAssertThrowsError(try AudioTrackState.decode([]))
        XCTAssertThrowsError(try AudioTrackState.decode([0x25]))
        XCTAssertThrowsError(try AudioTrackState.decode([0x24, 0x01]))
        XCTAssertThrowsError(try AudioTrackState.decode([0x7F, 0x01]))
        for state: UInt8 in [0x00, 0x03, 0xFF] {
            XCTAssertThrowsError(try AudioTrackState.decode([0x25, state]))
        }
        XCTAssertThrowsError(try AudioTrackState.decode([0x25, 0x01, 0]))
    }

    func testVideoPostureCodecPinsBytesAndRejectsHostiles() throws {
        XCTAssertEqual(
            VideoPostureState(posture: .active, keepaliveSeconds: 1).encode(),
            [0x26, 0x01, 0x01]
        )
        XCTAssertEqual(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            [0x26, 0x02, 0x1E]
        )
        for posture in VideoPostureState.Posture.allCases {
            for interval: UInt8 in [1, 2, 4, 8, 16, 30, 255] {
                let decoded = try VideoPostureState.decode(
                    VideoPostureState(
                        posture: posture, keepaliveSeconds: interval
                    ).encode())
                XCTAssertEqual(decoded.posture, posture)
                XCTAssertEqual(decoded.keepaliveSeconds, interval)
            }
        }
        // A zero interval never travels (the init clamps) and never
        // decodes (a hostile zero rejects).
        XCTAssertEqual(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 0)
                .keepaliveSeconds, 1)
        XCTAssertThrowsError(try VideoPostureState.decode([0x26, 0x02, 0x00]))
        // Truncation, foreign types, unknown postures, trailing bytes.
        XCTAssertThrowsError(try VideoPostureState.decode([]))
        XCTAssertThrowsError(try VideoPostureState.decode([0x26]))
        XCTAssertThrowsError(try VideoPostureState.decode([0x26, 0x02]))
        XCTAssertThrowsError(try VideoPostureState.decode([0x25, 0x01, 0x01]))
        for posture: UInt8 in [0x00, 0x03, 0xFF] {
            XCTAssertThrowsError(
                try VideoPostureState.decode([0x26, posture, 0x01]))
        }
        XCTAssertThrowsError(
            try VideoPostureState.decode([0x26, 0x01, 0x01, 0]))
    }

    // MARK: The registry itself

    func testPromotedRegistryNumbersAreThePinnedOnes() {
        // The end-side pins carried verbatim — a registry typo here
        // would be a silent wire break on both ends at once.
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
