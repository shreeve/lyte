import Foundation
import XCTest

final class HostSessionBoundaryTests: XCTestCase {
    private var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    func testPureSessionOrgansHaveOneOwner() throws {
        let manager = FileManager.default
        let sessionRoot = packageRoot + "/Sources/HostSession"
        XCTAssertEqual(
            try manager.contentsOfDirectory(atPath: sessionRoot).sorted(),
            ["HandshakeGate.swift", "SessionLifecycleLane.swift",
             "SessionPath.swift"]
        )
        for retired in ["HandshakeGate.swift", "SessionLifecycleLane.swift",
                        "SessionPath.swift"] {
            XCTAssertFalse(manager.fileExists(
                atPath: packageRoot + "/Sources/HostWire/" + retired
            ))
        }
    }

    func testRandomnessIsMandatoryAndTheWireShellOwnsItsSource() throws {
        let path = try String(
            contentsOfFile: packageRoot
                + "/Sources/HostSession/SessionPath.swift",
            encoding: .utf8
        )
        XCTAssertTrue(path.contains("rng: some RandomNumberGenerator"))
        XCTAssertFalse(path.contains("SystemRandomNumberGenerator"))

        let wire = try String(
            contentsOfFile: packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8
        )
        XCTAssertTrue(wire.contains("import HostSession"))
        XCTAssertTrue(wire.contains("rng: rng"))
        XCTAssertTrue(wire.contains(
            "private var lifecycleLane: SessionLifecycleLane"
        ))
        XCTAssertTrue(wire.contains(
            "public private(set) var validator: PathValidator"
        ))
    }
}
