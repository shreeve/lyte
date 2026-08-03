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
        XCTAssertThrowsError(try ModeTransition.decode([0x09])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .truncatedMessage
            )
        }
        XCTAssertThrowsError(
            try ModeTransition.decode([0x09, 0x01, 0x00])
        ) {
            XCTAssertEqual($0 as? LifecycleMessageError, .trailingBytes)
        }
        XCTAssertThrowsError(try ModeTransition.decode([0x0A, 0x01])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .unexpectedType(0x0A)
            )
        }
        // 0x00 is the zero-fill bug; 0x03+ would be FROZEN/RECOVERY
        // leaking onto the wire — both must stay loud.
        XCTAssertThrowsError(try ModeTransition.decode([0x09, 0x00])) {
            XCTAssertEqual($0 as? LifecycleMessageError, .unknownMode(0))
        }
        XCTAssertThrowsError(try ModeTransition.decode([0x09, 0x03])) {
            XCTAssertEqual($0 as? LifecycleMessageError, .unknownMode(3))
        }
    }

    func testTeardownRejects() {
        XCTAssertThrowsError(try SessionTeardown.decode([0x0A])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .truncatedMessage
            )
        }
        XCTAssertThrowsError(
            try SessionTeardown.decode([0x0A, 0x02, 0x00])
        ) {
            XCTAssertEqual($0 as? LifecycleMessageError, .trailingBytes)
        }
        XCTAssertThrowsError(try SessionTeardown.decode([0x09, 0x01])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .unexpectedType(0x09)
            )
        }
        XCTAssertThrowsError(try SessionTeardown.decode([0x0A, 0x00])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .unknownReason(0)
            )
        }
        XCTAssertThrowsError(try SessionTeardown.decode([0x0A, 0x7F])) {
            XCTAssertEqual(
                $0 as? LifecycleMessageError, .unknownReason(0x7F)
            )
        }
    }

    // MARK: Fuzz — hostile bytes throw, never trap

    func testDecodersNeverTrapOnHostileBytes() {
        var rng = SplitMix64(seed: 0x4B_57_34_62)
        for _ in 0..<20_000 {
            let count = Int.random(in: 0...8, using: &rng)
            let bytes = (0..<count).map { _ in
                UInt8.random(in: .min ... .max, using: &rng)
            }
            _ = try? ModeTransition.decode(bytes)
            _ = try? SessionTeardown.decode(bytes)
        }
    }
}
