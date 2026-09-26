import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/beacon-v1.json byte-exact — the clock
// beacon, its echo and the feedback report both ends code against, on
// both platforms.

final class BeaconVectorFileTests: XCTestCase {

    private func loadFile() throws -> BeaconVectorFile {
        try BeaconVectorFile.loadCommitted()
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
        assertVectorReject(BeaconError.self, expected, vector.name) {
            try decode()
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
        assertVectorReject(FeedbackError.self, expected, vector.name) {
            try report.encode()
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
        assertVectorReject(FeedbackError.self, expected, vector.name) {
            try FeedbackReport.decode(bytes)
        }
    }
}
