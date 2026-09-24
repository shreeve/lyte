import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/input-coordinates-v1.json byte-exact:
// InputEvent coordinates are finite f64, so NaN and ±Inf reject in every
// f64-carrying kind while the finite extremes roundtrip.

final class InputCoordinateVectorFileTests: XCTestCase {

    private func loadFile() throws -> InputCoordinateVectorFile {
        try InputCoordinateVectorFile.loadCommitted()
    }

    /// Every f64-carrying kind is pinned on both sides of the domain
    /// edge, and every reject names the non-finite case.
    func testDomainEdgeCovered() throws {
        let file = try loadFile()
        let f64Kinds: Set<ControlVector.BodyKind> = [
            .pointerMotionAbsolute, .pointerMotionRelative, .pointerAxis,
        ]
        for kind in [ControlVector.Kind.roundtrip, .decodeReject] {
            let kinds = try Set(file.vectors.filter { $0.kind == kind }.map {
                try XCTUnwrap(
                    InputEvent.decodeBodyKind(Hex.bytes($0.messageHex) ?? [])
                )
            })
            XCTAssertEqual(kinds, f64Kinds, "\(kind)")
        }
        XCTAssertEqual(
            Set(file.vectors.filter { $0.kind == .decodeReject }
                .compactMap(\.error)),
            ["nonFiniteCoordinate"]
        )
    }

    func testAllInputCoordinateVectors() throws {
        for vector in try loadFile().vectors {
            XCTAssertEqual(vector.codec, .inputEvent, vector.name)
            let message = try XCTUnwrap(
                Hex.bytes(vector.messageHex), "\(vector.name): messageHex"
            )
            try checkInputEventVector(vector, message: message)
        }
    }
}

private extension InputEvent {
    /// The body kind named by a message's kind byte (offset 13).
    static func decodeBodyKind(_ message: [UInt8]) -> ControlVector.BodyKind? {
        guard message.count > 13 else { return nil }
        switch message[13] {
        case 0x02: return .pointerMotionAbsolute
        case 0x03: return .pointerMotionRelative
        case 0x05: return .pointerAxis
        default: return nil
        }
    }
}
