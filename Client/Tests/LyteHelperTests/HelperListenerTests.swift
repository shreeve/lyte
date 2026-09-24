import Foundation
import LyteHelperProtocol
import Security
import XCTest
@testable import lyte_helperd

/// The helper's listener, armed exactly as the daemon arms it, against a
/// real in-process XPC peer: a peer that fails the code requirement never
/// reaches the delegate, and one that satisfies it does.
final class HelperListenerTests: XCTestCase {
    private final class Delegate: NSObject, NSXPCListenerDelegate,
        LyteHelperCommands, @unchecked Sendable
    {
        private let lock = NSLock()
        private var accepted = 0
        var acceptedCount: Int { lock.withLock { accepted } }

        func listener(
            _ listener: NSXPCListener,
            shouldAcceptNewConnection connection: NSXPCConnection
        ) -> Bool {
            lock.withLock { accepted += 1 }
            connection.exportedInterface = NSXPCInterface(
                with: LyteHelperCommands.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }

        func streamBegan() {}
        func streamEnded() {}
        func version(reply: @escaping @Sendable (String) -> Void) {
            reply(LyteHelper.version)
        }
    }

    /// The version call's outcome: an answer, or the connection's error.
    private func callVersion(
        on listener: NSXPCListener
    ) -> VersionOutcome {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(
            with: LyteHelperCommands.self)
        connection.resume()
        defer { connection.invalidate() }
        let outcome = VersionOutcome()
        let done = expectation(description: "version call settled")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            if outcome.set(.refused) { done.fulfill() }
        } as? LyteHelperCommands
        proxy?.version { answer in
            if outcome.set(.answered(answer)) { done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    private func ownDesignatedRequirement() throws -> String {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode),
            errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(
            try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(
            try XCTUnwrap(requirement), [], &text), errSecSuccess)
        return try XCTUnwrap(text) as String
    }

    func testForeignPeerIsRefusedBeforeTheDelegateRuns() {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        HelperListener.activate(
            listener,
            requiring: "identifier \"dev.shreeve.lyte\" and anchor apple generic",
            delegate: delegate)
        defer { listener.invalidate() }

        XCTAssertEqual(callVersion(on: listener).value, .refused)
        XCTAssertEqual(delegate.acceptedCount, 0,
                       "a foreign peer reached the delegate")
    }

    func testPeerSatisfyingTheRequirementIsServed() throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        HelperListener.activate(
            listener, requiring: try ownDesignatedRequirement(),
            delegate: delegate)
        defer { listener.invalidate() }

        XCTAssertEqual(
            callVersion(on: listener).value, .answered(LyteHelper.version))
        XCTAssertEqual(delegate.acceptedCount, 1)
    }
}

private enum Settled: Equatable {
    case answered(String)
    case refused
}

/// One version call's settlement; the first one wins.
private final class VersionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Settled?

    /// True for the first settlement only.
    @discardableResult
    func set(_ value: Settled) -> Bool {
        lock.withLock {
            guard settled == nil else { return false }
            settled = value
            return true
        }
    }

    var value: Settled? { lock.withLock { settled } }
}
