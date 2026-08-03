import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/lifecycle-v1.json byte-exact — the
// W4b lifecycle messages (mode transition 0x09, session teardown 0x0A)
// both ends code against, on both platforms.

final class LifecycleVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/lifecycle-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> LifecycleVectorFile {
        try LifecycleVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, LifecycleVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(
            Set(names).count, names.count, "vector names must be unique"
        )
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
                XCTAssertThrowsError(
                    try ModeTransition.decode(message), vector.name
                ) { error in
                    guard let error = error as? LifecycleMessageError else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        lifecycleMessageErrorName(error), vector.error,
                        vector.name
                    )
                }
            case (.decodeReject, .sessionTeardown):
                XCTAssertThrowsError(
                    try SessionTeardown.decode(message), vector.name
                ) { error in
                    guard let error = error as? LifecycleMessageError else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        lifecycleMessageErrorName(error), vector.error,
                        vector.name
                    )
                }
            }
        }
    }
}
