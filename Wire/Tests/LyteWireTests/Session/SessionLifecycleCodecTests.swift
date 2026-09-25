import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The W4b lifecycle codecs against hand-computed bytes — the anchor
// that keeps lifecycle-v1.json honest — plus reject coverage and a
// never-traps fuzz.

final class SessionLifecycleCodecTests: XCTestCase {

    // MARK: Hand-computed anchors

    func testHandComputedModeTransition() throws {
        // type 09 | mode 01 (ACTIVE)
        XCTAssertEqual(
            Hex.string(ModeTransition(mode: .active).encode()), "0901"
        )
        // type 09 | mode 02 (IDLE)
        XCTAssertEqual(
            Hex.string(ModeTransition(mode: .idle).encode()), "0902"
        )
        XCTAssertEqual(
            try ModeTransition.decode([0x09, 0x02]),
            ModeTransition(mode: .idle)
        )
    }

    func testHandComputedTeardown() throws {
        // type 0A | reason 01 (taken-over-by)
        XCTAssertEqual(
            Hex.string(SessionTeardown(reason: .takenOver).encode()), "0a01"
        )
        // type 0A | reason 02 (shutting-down)
        XCTAssertEqual(
            Hex.string(SessionTeardown(reason: .shuttingDown).encode()),
            "0a02"
        )
        XCTAssertEqual(
            try SessionTeardown.decode([0x0A, 0x01]),
            SessionTeardown(reason: .takenOver)
        )
    }

    func testTypeBytesMatchRegistry() {
        XCTAssertEqual(
            ModeTransition(mode: .active).encode().first,
            CtrlMessageType.modeTransition
        )
        XCTAssertEqual(
            SessionTeardown(reason: .shuttingDown).encode().first,
            CtrlMessageType.sessionTeardown
        )
        // The lifecycle types must never collide with the ARQ frame
        // bytes they share the reliable channel with.
        XCTAssertNotEqual(
            CtrlMessageType.modeTransition, CtrlMessageType.arqSegment
        )
        XCTAssertNotEqual(
            CtrlMessageType.sessionTeardown, CtrlMessageType.arqAck
        )
    }

    // MARK: Rejects

    func testModeTransitionRejects() {
        assertThrows(LifecycleMessageError.truncatedMessage) {
            try ModeTransition.decode([0x09])
        }
        assertThrows(LifecycleMessageError.trailingBytes) {
            try ModeTransition.decode([0x09, 0x01, 0x00])
        }
        assertThrows(LifecycleMessageError.unexpectedType(0x0A)) {
            try ModeTransition.decode([0x0A, 0x01])
        }
        // 0x00 is the zero-fill bug; 0x03+ would be FROZEN/RECOVERY
        // leaking onto the wire — both must stay loud.
        assertThrows(LifecycleMessageError.unknownMode(0)) {
            try ModeTransition.decode([0x09, 0x00])
        }
        assertThrows(LifecycleMessageError.unknownMode(3)) {
            try ModeTransition.decode([0x09, 0x03])
        }
    }

    func testTeardownRejects() {
        assertThrows(LifecycleMessageError.truncatedMessage) {
            try SessionTeardown.decode([0x0A])
        }
        assertThrows(LifecycleMessageError.trailingBytes) {
            try SessionTeardown.decode([0x0A, 0x02, 0x00])
        }
        assertThrows(LifecycleMessageError.unexpectedType(0x09)) {
            try SessionTeardown.decode([0x09, 0x01])
        }
        assertThrows(LifecycleMessageError.unknownReason(0)) {
            try SessionTeardown.decode([0x0A, 0x00])
        }
        assertThrows(LifecycleMessageError.unknownReason(0x7F)) {
            try SessionTeardown.decode([0x0A, 0x7F])
        }
    }

    // MARK: Fuzz — hostile bytes throw, never trap

    func testDecodersNeverTrapOnHostileBytes() {
        var rng = SplitMix64(seed: 0x4B_57_34_62)
        for _ in 0..<20_000 {
            let count = rng.int(in: 0...8)
            let bytes = (0..<count).map { _ in
                UInt8.random(in: .min ... .max, using: &rng)
            }
            _ = try? ModeTransition.decode(bytes)
            _ = try? SessionTeardown.decode(bytes)
        }
    }
}
