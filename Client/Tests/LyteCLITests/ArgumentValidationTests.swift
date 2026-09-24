import ArgumentParser
import LyteCorpus
import XCTest
@testable import lyte_cli

/// Arguments that used to trap mid-run or leak are refused at parse time.
final class ArgumentValidationTests: XCTestCase {
    func testDecodeProbeRefusesNegativeDelayAndEmptyWindows() throws {
        for arguments in [
            ["stream.hevc", "--snapshot-delay", "-1"],
            ["stream.hevc", "--snapshot-delay", "nan"],
            ["stream.hevc", "--window-scale", "0"],
            ["stream.hevc", "--window-scale", "-0.5"],
        ] {
            XCTAssertThrowsError(try DecodeProbe.parse(arguments), "\(arguments)")
        }
        XCTAssertNoThrow(try DecodeProbe.parse(
            ["stream.hevc", "--snapshot-delay", "0", "--window-scale", "0.5"]))
    }

    func testCorpusGenRefusesGeometryTheFramesCannotFit() {
        XCTAssertThrowsError(try CorpusGen.parse(
            ["--out", "/tmp/corpus", "--width", "100"]))
        XCTAssertThrowsError(try CorpusGen.parse(
            ["--out", "/tmp/corpus", "--height", "\(CorpusFrames.minimumHeight - 1)"]))
        XCTAssertNoThrow(try CorpusGen.parse([
            "--out", "/tmp/corpus",
            "--width", "\(CorpusFrames.minimumWidth)",
            "--height", "\(CorpusFrames.minimumHeight)",
        ]))
    }

    func testTheMinimumCorpusGeometryGenerates() {
        let frames = CorpusFrames.generate(
            width: CorpusFrames.minimumWidth, height: CorpusFrames.minimumHeight)
        XCTAssertFalse(frames.isEmpty)
    }

    /// `--pin -` keeps the PIN out of `ps`: it arrives on standard input.
    func testPinCanArriveOnStandardInput() throws {
        XCTAssertNoThrow(try WirePair.parse(["pup", "--pin", "-"]))
        XCTAssertEqual(
            try WirePair.resolvedPin("-", readLine: { "123456 " }), "123456")
        XCTAssertEqual(
            try WirePair.resolvedPin("654321", readLine: {
                XCTFail("an argued PIN never reads standard input")
                return nil
            }),
            "654321")
        XCTAssertThrowsError(try WirePair.resolvedPin("-", readLine: { nil }))
        XCTAssertThrowsError(try WirePair.resolvedPin("-", readLine: { "12ab56" }))
        XCTAssertThrowsError(try WirePair.parse(["pup", "--pin", "12"]))
    }
}
