import Foundation
import LyteHelperProtocol
import XCTest
@testable import LyteHelperSecurity
@testable import lyte_helperd

/// A helper answers `version` with its build, not a constant: a daemon
/// still running from an earlier build must read as stale to the app that
/// embeds a newer one, or re-registration is skipped and launchd later
/// refuses the stale launch requirement.
final class HelperCodeIdentityTests: XCTestCase {
    func testDifferentCodeHasADifferentHash() throws {
        let ls = try HelperCodeIdentity.codeHash(
            ofCodeAt: URL(fileURLWithPath: "/bin/ls"))
        let cat = try HelperCodeIdentity.codeHash(
            ofCodeAt: URL(fileURLWithPath: "/bin/cat"))
        XCTAssertNotEqual(ls, cat)
        XCTAssertEqual(ls, try HelperCodeIdentity.codeHash(
            ofCodeAt: URL(fileURLWithPath: "/bin/ls")))
        XCTAssertTrue(ls.allSatisfy(\.isHexDigit) && ls.count >= 40, ls)
        XCTAssertNotEqual(
            HelperCodeIdentity.versionAnswer(protocolVersion: "2", codeHash: ls),
            HelperCodeIdentity.versionAnswer(protocolVersion: "2", codeHash: cat))
    }

    /// What the running helper answers matches what the app computes from
    /// the same binary on disk — the "current" verdict needs exactly that.
    func testTheRunningHelpersAnswerIsItsOnDiskBuild() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let onDisk = try HelperCodeIdentity.codeHash(ofCodeAt: executable)
        XCTAssertEqual(try HelperCodeIdentity.currentProcessCodeHash(), onDisk)

        let answered = expectation(description: "version")
        let answer = Answer()
        ConnectionHandler().version { answer.value = $0; answered.fulfill() }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(answer.value, HelperCodeIdentity.versionAnswer(
            protocolVersion: LyteHelper.version, codeHash: onDisk))
    }

    func testUnsignedCodeHasNoHash() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-unsigned-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try HelperCodeIdentity.codeHash(ofCodeAt: file))
    }
}

private final class Answer: @unchecked Sendable {
    var value: String?
}
