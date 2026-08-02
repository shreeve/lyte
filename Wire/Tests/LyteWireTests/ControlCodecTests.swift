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
        XCTAssertThrowsError(try IdleFrame.decode([0x16] + good.dropFirst())) {
            XCTAssertEqual($0 as? IdleFrameError, .unexpectedType(0x16))
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
        XCTAssertEqual(key.encode(), [
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
        XCTAssertEqual(move.encode(), expected)
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

    func testHostileInputBytesRejectAndNeverTrap() {
        let good = InputEvent(
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
        var axis = InputEvent(
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

    // MARK: Capability key 9 on the forward-compat spine

    func testCapabilityKeyRidesTheSpineWithoutMovingFrozenBytes() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        // wireDefault is an 8-entry map — the frozen v1 shape.
        XCTAssertEqual(base.first, 0xA8)

        // The declaration is EXACTLY the frozen bytes plus one appended
        // entry: map(9) head + trailing `09 F5` (key 9 sorts last in
        // RFC 8949 bytewise order among keys 1–9). Nothing between
        // moves — the "no frozen bytes" claim as data.
        var expected = base
        expected[0] = 0xA9
        expected += [0x09, 0xF5]
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        // Reads back as itself through the v1 decoder: key 9 lands in
        // unknownEntries (a v1 build "ignores and preserves"), and the
        // typed accessor sees it.
        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.hostAudioRouting)
        XCTAssertEqual(decoded, declared)
        XCTAssertEqual(decoded.unknownEntries.count, 1)
        XCTAssertFalse(Capabilities.wireDefault.hostAudioRouting)

        // Idempotent declaration; encode stays canonical through the
        // full 0x0F message codec.
        XCTAssertEqual(declared.declaringHostAudioRouting(), declared)
        let message = try CapabilityDeclaration(capabilities: declared).encode()
        XCTAssertEqual(
            try CapabilityDeclaration.decode(message).capabilities, declared
        )
    }

    func testIntersectionEnablesOnlyOnMutualDeclaration() throws {
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()

        // Both declare → survives (both argument orders — the W-G8
        // algebra's commutativity applied to key 9).
        XCTAssertTrue(declared.intersecting(declared).hostAudioRouting)

        // One-sided → dropped, both orders.
        XCTAssertFalse(
            declared.intersecting(.wireDefault).hostAudioRouting
        )
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).hostAudioRouting
        )

        // A peer declaring key 9 FALSE is not byte-equal to true:
        // absence and refusal are the same posture (the accessor's
        // documented rule) and the intersection drops the entry.
        var refusing = Capabilities.wireDefault
        refusing.unknownEntries.append(CborMapEntry(
            key: .unsigned(CapabilityKey.hostAudioRouting),
            value: .bool(false)
        ))
        XCTAssertFalse(refusing.hostAudioRouting)
        XCTAssertFalse(declared.intersecting(refusing).hostAudioRouting)
    }

    func testAudioStreamOffRidesTheSpineLikeKeyNine() throws {
        // Key 14 (mute-at-source): declaration appends exactly one
        // canonical entry, reads back through the v1 decoder, and
        // survives intersection only on mutual declaration — the
        // key-9 laws, fourteenth verse.
        let declared = Capabilities.wireDefault.declaringAudioStreamOff()
        XCTAssertTrue(declared.audioStreamOff)
        XCTAssertFalse(Capabilities.wireDefault.audioStreamOff)
        XCTAssertEqual(declared.declaringAudioStreamOff(), declared)

        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.audioStreamOff)
        XCTAssertEqual(decoded, declared)

        XCTAssertTrue(declared.intersecting(declared).audioStreamOff)
        XCTAssertFalse(declared.intersecting(.wireDefault).audioStreamOff)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).audioStreamOff
        )

        // The wire byte: streamOff is 0x04 — 0x03 is the tombstone
        // the frozen routing-mode-unknown vector pinned.
        XCTAssertEqual(HostAudioRoutingMode.streamOff.rawValue, 0x04)
        XCTAssertEqual(
            AudioRoutingRequest(mode: .streamOff).encode(), [0x18, 0x04]
        )
        XCTAssertEqual(
            try AudioRoutingStatus.decode([0x19, 0x04]).mode, .streamOff
        )
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
        XCTAssertEqual(CapabilityKey.hostAudioRouting, 9)
    }
}
