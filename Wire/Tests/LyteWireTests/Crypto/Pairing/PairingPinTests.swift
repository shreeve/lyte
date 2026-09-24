import XCTest
import LyteWire

// The typed-PIN gate every client surface shares: exactly the host's six
// ASCII digits reach CPace; look-alike digits never do.

final class PairingPinTests: XCTestCase {

    func testAsciiDigitsPassThroughAsBytes() {
        XCTAssertEqual(PairingPin.normalize("482913"), Array("482913".utf8))
        XCTAssertEqual(PairingPin.normalize("482 913"), Array("482913".utf8))
        XCTAssertEqual(PairingPin.normalize("482-913"), Array("482913".utf8))
        XCTAssertTrue(PairingPin.isValid(" 000000 "))
    }

    /// Fullwidth and other Unicode digits satisfy `Character.isNumber`
    /// but are different bytes than the host minted: refused.
    func testNonAsciiDigitsAreRefused() {
        let fullwidth = "\u{FF14}\u{FF18}\u{FF12}\u{FF19}\u{FF11}\u{FF13}"
        XCTAssertTrue(fullwidth.allSatisfy(\.isNumber))
        XCTAssertNil(PairingPin.normalize(fullwidth))
        XCTAssertNil(PairingPin.normalize("48291\u{0663}")) // Arabic-Indic 3
        XCTAssertNil(PairingPin.normalize("48291\u{0969}")) // Devanagari 3
        XCTAssertNil(PairingPin.normalize("4829١3"))
    }

    func testWrongLengthsAndStrayCharactersAreRefused() {
        XCTAssertNil(PairingPin.normalize(""))
        XCTAssertNil(PairingPin.normalize("48291"))
        XCTAssertNil(PairingPin.normalize("4829130"))
        XCTAssertNil(PairingPin.normalize("48291a"))
        XCTAssertNil(PairingPin.normalize("482.913"))
        XCTAssertFalse(PairingPin.isValid("½12345"))
    }
}
