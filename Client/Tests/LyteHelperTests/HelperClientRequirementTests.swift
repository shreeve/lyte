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
