import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/lifecycle-v1.json byte-exact — the
// lifecycle messages (mode transition 0x09, session teardown 0x0A)
// both ends code against, on both platforms.

final class LifecycleVectorFileTests: XCTestCase {

    private func loadFile() throws -> LifecycleVectorFile {
        try LifecycleVectorFile.loadCommitted()
    }

    func testEveryLegalValueIsPinned() throws {
        // The codecs' whole value spaces are tiny; the file must pin
        // all of them so an enum addition can never slip in silently.
        let file = try loadFile()
        let modeValues = Set(file.vectors
            .filter { $0.kind == .roundtrip && $0.codec == .modeTransition }
            .compactMap(\.value))
        XCTAssertEqual(
            modeValues, Set(SessionWireMode.allCases.map(\.rawValue))
        )
        let reasonValues = Set(file.vectors
            .filter { $0.kind == .roundtrip && $0.codec == .sessionTeardown }
            .compactMap(\.value))
        XCTAssertEqual(
            reasonValues,
            Set(SessionTeardownReason.allCases.map(\.rawValue))
        )
    }

    func testAllLifecycleVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                XCTFail("\(vector.name): malformed messageHex")
                continue
            }
            switch (vector.kind, vector.codec) {
            case (.roundtrip, .modeTransition):
                let value = try XCTUnwrap(vector.value, vector.name)
                let mode = try XCTUnwrap(
                    SessionWireMode(rawValue: value), vector.name
                )
                XCTAssertEqual(
                    ModeTransition(mode: mode).encode(), message,
                    vector.name
                )
                XCTAssertEqual(
                    try ModeTransition.decode(message).mode, mode,
                    vector.name
                )
            case (.roundtrip, .sessionTeardown):
                let value = try XCTUnwrap(vector.value, vector.name)
                let reason = try XCTUnwrap(
                    SessionTeardownReason(rawValue: value), vector.name
                )
                XCTAssertEqual(
                    SessionTeardown(reason: reason).encode(), message,
                    vector.name
                )
                XCTAssertEqual(
                    try SessionTeardown.decode(message).reason, reason,
                    vector.name
                )
            case (.decodeReject, .modeTransition):
                assertVectorReject(
                    LifecycleMessageError.self, vector.error, vector.name
                ) {
                    try ModeTransition.decode(message)
                }
            case (.decodeReject, .sessionTeardown):
                assertVectorReject(
                    LifecycleMessageError.self, vector.error, vector.name
                ) {
                    try SessionTeardown.decode(message)
                }
            }
        }
    }
}
