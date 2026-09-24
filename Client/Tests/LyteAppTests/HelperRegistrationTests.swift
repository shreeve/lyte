import XCTest
@testable import Lyte

/// The app-launch registration decision: the root helper is registered
/// only when it must be, and never before the embedded binary validates.
final class HelperRegistrationTests: XCTestCase {
    private struct Refusal: Error {}

    private final class Books {
        var probes = 0
        var validations = 0
        var unregisters = 0
        var registers = 0
    }

    private func registration(
        status: HelperRegistration.Status,
        answers version: String? = nil,
        helperValid: Bool = true,
        registerFails: Bool = false,
        books: Books
    ) -> HelperRegistration {
        HelperRegistration(
            expectedVersion: "2",
            status: { status },
            probeVersion: { books.probes += 1; return version },
            validateEmbeddedHelper: {
                books.validations += 1
                if !helperValid { throw Refusal() }
            },
            unregister: { books.unregisters += 1 },
            register: {
                books.registers += 1
                if registerFails { throw Refusal() }
            })
    }

    func testCurrentHelperIsLeftRegisteredAsIs() {
        let books = Books()
        XCTAssertEqual(
            registration(status: .enabled, answers: "2", books: books).run(),
            .current)
        XCTAssertEqual(books.registers, 0, "a launch must not re-trust the disk")
        XCTAssertEqual(books.unregisters, 0)
        XCTAssertEqual(books.validations, 0)
    }

    func testSilentOrStaleHelperIsReplacedAfterValidation() {
        for answer in [nil, "1"] {
            let books = Books()
            XCTAssertEqual(
                registration(status: .enabled, answers: answer, books: books)
                    .run(),
                .registered)
            XCTAssertEqual(books.validations, 1)
            XCTAssertEqual(books.unregisters, 1)
            XCTAssertEqual(books.registers, 1)
        }
    }

    func testForeignHelperIsNeverRegistered() {
        for status in [HelperRegistration.Status.enabled, .notRegistered] {
            let books = Books()
            guard case .refused = registration(
                status: status, helperValid: false, books: books).run()
            else { return XCTFail("\(status): an invalid helper was not refused") }
            XCTAssertEqual(books.registers, 0)
            XCTAssertEqual(books.unregisters, 0,
                           "a refusal leaves the existing registration alone")
        }
    }

    func testMissingRegistrationRegistersWithoutUnregistering() {
        for status in [HelperRegistration.Status.notRegistered, .notFound] {
            let books = Books()
            XCTAssertEqual(
                registration(status: status, books: books).run(), .registered)
            XCTAssertEqual(books.probes, 0)
            XCTAssertEqual(books.unregisters, 0)
            XCTAssertEqual(books.registers, 1)
        }
    }

    func testPendingApprovalIsNeverReRegistered() {
        let books = Books()
        XCTAssertEqual(
            registration(status: .requiresApproval, books: books).run(),
            .awaitingApproval)
        XCTAssertEqual(books.probes + books.validations + books.registers, 0)
    }

    func testRegisterFailureIsReported() {
        let books = Books()
        guard case .failed = registration(
            status: .notRegistered, registerFails: true, books: books).run()
        else { return XCTFail("a failed register must say so") }
    }
}
