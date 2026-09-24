import XCTest
@testable import LyteHelperSecurity

final class HelperClientRequirementTests: XCTestCase {
    func testAppleDevelopmentRequirementChangesOnlyTheIdentifier() throws {
        let helper = """
        identifier "dev.shreeve.lyte-helperd" and anchor apple generic and \
        certificate leaf[subject.CN] = "Apple Development: Lyte" and \
        certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
        """
        let app = try HelperClientRequirement.applicationRequirement(
            fromHelperDesignatedRequirement: helper)

        XCTAssertEqual(
            app,
            helper.replacingOccurrences(
                of: "identifier \"dev.shreeve.lyte-helperd\"",
                with: "identifier \"dev.shreeve.lyte\""))
        XCTAssertTrue(app.contains("anchor apple generic"))
        XCTAssertTrue(app.contains("certificate leaf[subject.CN]"))
    }

    func testLyteDevRequirementPreservesTheExactRootCertificate() throws {
        let helper = """
        identifier "dev.shreeve.lyte-helperd" and \
        certificate root = H"0123456789abcdef0123456789abcdef01234567"
        """
        let app = try HelperClientRequirement.applicationRequirement(
            fromHelperDesignatedRequirement: helper)

        XCTAssertEqual(app, """
        identifier "dev.shreeve.lyte" and \
        certificate root = H"0123456789abcdef0123456789abcdef01234567"
        """)
    }

    func testRequirementWithoutTheExactHelperIdentifierFailsClosed() {
        XCTAssertThrowsError(try HelperClientRequirement
            .applicationRequirement(
                fromHelperDesignatedRequirement:
                    "identifier \"com.example.foreign\" and anchor apple")) {
            XCTAssertEqual(
                $0 as? HelperClientRequirementError,
                .unexpectedDesignatedRequirement)
        }
    }

    func testAmbiguousHelperIdentifierFailsClosed() {
        let duplicate = "identifier \"dev.shreeve.lyte-helperd\" or "
            + "identifier \"dev.shreeve.lyte-helperd\""
        XCTAssertThrowsError(try HelperClientRequirement
            .applicationRequirement(
                fromHelperDesignatedRequirement: duplicate)) {
            XCTAssertEqual(
                $0 as? HelperClientRequirementError,
                .unexpectedDesignatedRequirement)
        }
    }
}

/// The app-side mirror (the requirement the app demands of the helper it
/// registers) and the shape checks both directions share.
final class HelperRequirementDerivationTests: XCTestCase {
    private let appleApp = """
        identifier "dev.shreeve.lyte" and anchor apple generic and \
        certificate leaf[subject.CN] = "Apple Development: Lyte" and \
        certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
        """

    func testAppRequirementDerivesTheHelperRequirementAndBack() throws {
        let helper = try HelperClientRequirement.helperRequirement(
            fromApplicationDesignatedRequirement: appleApp)
        XCTAssertEqual(helper, appleApp.replacingOccurrences(
            of: "identifier \"dev.shreeve.lyte\"",
            with: "identifier \"dev.shreeve.lyte-helperd\""))
        XCTAssertEqual(
            try HelperClientRequirement.applicationRequirement(
                fromHelperDesignatedRequirement: helper),
            appleApp)
    }

    /// An identifier-only requirement would admit an ad-hoc signature
    /// that merely claims the identifier.
    func testRequirementThatPinsNoSignerFailsClosed() {
        for unpinned in [
            "identifier \"dev.shreeve.lyte\"",
            "identifier \"dev.shreeve.lyte\" and "
                + "certificate leaf[subject.CN] = \"anchor apple generic\"",
        ] {
            XCTAssertThrowsError(try HelperClientRequirement.helperRequirement(
                fromApplicationDesignatedRequirement: unpinned), unpinned) {
                XCTAssertEqual(
                    $0 as? HelperClientRequirementError,
                    .unexpectedDesignatedRequirement)
            }
        }
    }

    func testRequirementWithAnAlternativeSignerFailsClosed() {
        let alternative = appleApp + " or identifier \"com.example.other\""
        XCTAssertThrowsError(try HelperClientRequirement.helperRequirement(
            fromApplicationDesignatedRequirement: alternative)) {
            XCTAssertEqual(
                $0 as? HelperClientRequirementError,
                .unexpectedDesignatedRequirement)
        }
    }

    func testSignerNamesContainingKeywordsStayData() {
        let app = """
            identifier "dev.shreeve.lyte" and anchor apple generic and \
            certificate leaf[subject.CN] = "Apple Development: Mo or Less"
            """
        XCTAssertNoThrow(try HelperClientRequirement.helperRequirement(
            fromApplicationDesignatedRequirement: app))
    }

    // MARK: - Static validation of code on disk

    func testCodeOnDiskIsCheckedAgainstTheRequirement() throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        XCTAssertNoThrow(try HelperClientRequirement.validateStaticCode(
            at: ls, satisfies: "identifier \"com.apple.ls\" and anchor apple"))
        let helper = try HelperClientRequirement.helperRequirement(
            fromApplicationDesignatedRequirement: appleApp)
        XCTAssertThrowsError(try HelperClientRequirement.validateStaticCode(
            at: ls, satisfies: helper),
            "a binary from another signer must never pass as the helper")
    }

    func testMissingCodeFailsValidation() {
        XCTAssertThrowsError(try HelperClientRequirement.validateStaticCode(
            at: URL(fileURLWithPath: "/nonexistent/lyte-helperd"),
            satisfies: "identifier \"com.apple.ls\" and anchor apple"))
    }
}
