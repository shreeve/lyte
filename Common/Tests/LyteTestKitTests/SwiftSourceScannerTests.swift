import LyteTestKit
import XCTest

final class SwiftSourceScannerTests: XCTestCase {
    func testTokensDiscardCommentsAndEveryStringForm() {
        let source = [
            "// Decoy(ignored)",
            "/* outer /* nested */ ignoredCall() */",
            #"let ordinary = "ignoredCall(\"still ignored\")""#,
            "let multiline = \"\"\"ignoredCall(\n)\"\"\"",
            ##"let raw = #"ignoredCall("#"##,
            "let kept = RealType.make(value)",
        ].joined(separator: "\n")

        XCTAssertEqual(
            SwiftSourceScanner.tokens(in: source),
            ["let", "ordinary", "=", "let", "multiline", "=", "let", "raw",
             "=", "let", "kept", "=", "RealType", ".", "make", "(",
             "value", ")"]
        )
    }

    func testImportsRecognizeAttributesAccessAndQualifiedDeclarations() {
        let source = [
            "@testable import HostWire",
            "package import HostWire",
            "@preconcurrency public import LyteClientSession",
            "import struct HostCore.Pacer",
            "import let LyteClientSession.defaultValue",
            "// import Decoy",
            "let prose = \"import AnotherDecoy\"",
            "/* a leading comment */ import LyteWire",
        ].joined(separator: "\n")

        XCTAssertEqual(
            SwiftSourceScanner.importedModules(in: source),
            ["HostWire", "HostWire", "LyteClientSession", "HostCore",
             "LyteClientSession", "LyteWire"]
        )
    }

    func testTokenSequenceMatchingIsExactAndOrdered() {
        let tokens = SwiftSourceScanner.tokens(
            in: "let session = Session(config: config)"
        )
        XCTAssertTrue(SwiftSourceScanner.contains(
            ["session", "=", "Session", "("],
            in: tokens
        ))
        XCTAssertFalse(SwiftSourceScanner.contains(
            ["Session", "=", "session"],
            in: tokens
        ))
    }
}
