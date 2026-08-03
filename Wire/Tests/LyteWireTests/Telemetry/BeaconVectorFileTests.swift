import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/beacon-v1.json byte-exact — the W4a
// contract CL-3's beacon echo and feedback sender code against before the
// host exists (master plan §4.12), on both platforms.

final class BeaconVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/beacon-v1.json"

    private static let packageRoot = WireTestPaths.packageRoot

    private func loadFile() throws -> BeaconVectorFile {
        try BeaconVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, BeaconVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.beaconVectors.isEmpty)
        XCTAssertFalse(file.feedbackVectors.isEmpty)
        let names = file.beaconVectors.map(\.name) + file.feedbackVectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "vector names must be unique")
    }

    func testAllBeaconVectors() throws {
        for vector in try loadFile().beaconVectors {
            switch vector.kind {
            case .roundtrip:
                try checkBeaconRoundtrip(vector, decodeOnly: false)
            case .decodeLenient:
                try checkBeaconRoundtrip(vector, decodeOnly: true)
            case .decodeReject:
                try checkBeaconDecodeReject(vector)
            }
        }
    }

    func testAllFeedbackVectors() throws {
        for vector in try loadFile().feedbackVectors {
            switch vector.kind {
            case .roundtrip:
                try checkFeedbackRoundtrip(vector, decodeOnly: false)
            case .decodeLenient:
                try checkFeedbackRoundtrip(vector, decodeOnly: true)
            case .encodeReject:
                try checkFeedbackEncodeReject(vector)
            case .decodeReject:
                try checkFeedbackDecodeReject(vector)
            }
        }
    }

    func testClockWorkedExample() throws {
        let example = try loadFile().clockWorkedExample
        guard
            let echoBytes = Hex.bytes(example.echoHex),
            let hostReceive = Hex.uint64(example.hostReceiveHex)
        else {
            return XCTFail("malformed clockWorkedExample")
        }
        let echo = try BeaconEcho.decode(echoBytes)
        let sample = echo.clockSample(
            hostReceive: HostTimestamp(microseconds: hostReceive)
        )
        XCTAssertEqual(sample.offsetMicroseconds, example.offsetMicroseconds)
        XCTAssertEqual(sample.rttMicroseconds, example.rttMicroseconds)
    }

    // MARK: Beacon checks

    private func checkBeaconRoundtrip(
        _ vector: BeaconVector, decodeOnly: Bool
    ) throws {
        guard
            let messageHex = vector.messageHex,
            let bytes = Hex.bytes(messageHex)
        else {
            return XCTFail("\(vector.name): missing messageHex")
        }
        switch vector.decoder {
        case .beacon:
            guard let fields = vector.beacon else {
                return XCTFail("\(vector.name): missing beacon fields")
            }
            let beacon = try fields.makeBeacon()
            XCTAssertEqual(try ClockBeacon.decode(bytes), beacon, vector.name)
            if !decodeOnly {
                XCTAssertEqual(
                    Hex.string(beacon.encode()), messageHex,
                    "\(vector.name): encode is not byte-exact"
                )
            }
        case .echo:
            guard let fields = vector.echo else {
                return XCTFail("\(vector.name): missing echo fields")
            }
            let echo = try fields.makeEcho()
            XCTAssertEqual(try BeaconEcho.decode(bytes), echo, vector.name)
            if !decodeOnly {
                XCTAssertEqual(
                    Hex.string(echo.encode()), messageHex,
                    "\(vector.name): encode is not byte-exact"
                )
            }
        }
    }

    private func checkBeaconDecodeReject(_ vector: BeaconVector) throws {
        guard
            let messageHex = vector.messageHex,
            let bytes = Hex.bytes(messageHex),
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed decodeReject vector")
        }
        let decode: () throws -> Void = vector.decoder == .beacon
            ? { _ = try ClockBeacon.decode(bytes) }
            : { _ = try BeaconEcho.decode(bytes) }
        XCTAssertThrowsError(try decode(), vector.name) { error in
            guard let beaconError = error as? BeaconError else {
                return XCTFail("\(vector.name): non-BeaconError \(error)")
            }
            XCTAssertEqual(beaconErrorName(beaconError), expected, vector.name)
        }
    }

    // MARK: Feedback checks

    private func checkFeedbackRoundtrip(
        _ vector: FeedbackVector, decodeOnly: Bool
    ) throws {
        guard
            let fields = vector.report,
            let reportHex = vector.reportHex,
            let bytes = Hex.bytes(reportHex)
        else {
            return XCTFail("\(vector.name): missing roundtrip fields")
        }
        let report = try fields.makeReport()
        XCTAssertEqual(try FeedbackReport.decode(bytes), report, vector.name)
        if !decodeOnly {
            XCTAssertEqual(
                Hex.string(try report.encode()), reportHex,
                "\(vector.name): encode is not byte-exact"
            )
        }
    }

    private func checkFeedbackEncodeReject(_ vector: FeedbackVector) throws {
        guard
            let fields = vector.report,
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed encodeReject vector")
        }
        let report = try fields.makeReport()
        XCTAssertThrowsError(try report.encode(), vector.name) { error in
            guard let feedbackError = error as? FeedbackError else {
                return XCTFail("\(vector.name): non-FeedbackError \(error)")
            }
            XCTAssertEqual(feedbackErrorName(feedbackError), expected, vector.name)
        }
    }

    private func checkFeedbackDecodeReject(_ vector: FeedbackVector) throws {
        guard
            let reportHex = vector.reportHex,
            let bytes = Hex.bytes(reportHex),
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed decodeReject vector")
        }
        XCTAssertThrowsError(try FeedbackReport.decode(bytes), vector.name) { error in
            guard let feedbackError = error as? FeedbackError else {
                return XCTFail("\(vector.name): non-FeedbackError \(error)")
            }
            XCTAssertEqual(feedbackErrorName(feedbackError), expected, vector.name)
        }
    }
}
