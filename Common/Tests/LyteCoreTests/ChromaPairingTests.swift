import XCTest
@testable import LyteCore

final class ChromaPairingTests: XCTestCase {
    func testBestDeclarationIsExactlyOne444Mode() {
        let best = ChromaPairing.bestSingleton(UInt64(444))
        XCTAssertEqual(best, [444])
        XCTAssertEqual(best.count, 1)
        XCTAssertNotEqual(best, [420, 444])
        XCTAssertNotEqual(best, [])
    }

    func testRuleIsVocabularyAgnostic() {
        XCTAssertEqual(ChromaPairing.bestSingleton("4:4:4"), ["4:4:4"])
    }
}
