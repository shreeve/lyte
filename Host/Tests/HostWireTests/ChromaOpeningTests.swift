import HostWire
import LyteWire
import XCTest

final class ChromaOpeningTests: XCTestCase {
    /// B16: the leg opened 4:2:0 and reopened as 4:4:4 once the Best
    /// agreement landed, so 4:2:0 frames preceded the agreed posture —
    /// the mid-stream chroma dial the standing ruling forbids.
    func testTheEncoderWaitsForTheDeclarationAndOpensInTheAgreedPosture() {
        XCTAssertNil(ChromaPosture.opening(
            agreedChromaModes: nil, waitedNS: 10_000_000))
        XCTAssertEqual(
            ChromaPosture.opening(
                agreedChromaModes: [CapabilityChroma.yuv444],
                waitedNS: 20_000_000),
            .yuv444)
        XCTAssertEqual(
            ChromaPosture.opening(
                agreedChromaModes: [CapabilityChroma.yuv420],
                waitedNS: 20_000_000),
            .yuv420)
    }

    func testAPeerThatNeverDeclaresGetsTheGoodTierWhenTheWaitLapses() {
        XCTAssertEqual(
            ChromaPosture.opening(
                agreedChromaModes: nil,
                waitedNS: ChromaPosture.openingAgreementWaitNS),
            .yuv420)
    }
}
