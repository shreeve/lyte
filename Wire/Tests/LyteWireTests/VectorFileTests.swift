import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/ artifacts byte-exact. This suite passing
// on macOS and Linux is what makes the files a contract: the client's CL-1
// codes against the same bytes before the host sends a datagram.

final class VectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/envelope-v1.json"

    private static var packageRoot: String {
        // Tests/LyteWireTests/VectorFileTests.swift → the Wire/ root.
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> EnvelopeVectorFile {
        try EnvelopeVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, EnvelopeVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        XCTAssertEqual(
            Set(file.vectors.map(\.name)).count, file.vectors.count,
            "vector names must be unique"
        )
    }

    func testAllVectors() throws {
        for vector in try loadFile().vectors {
            switch vector.kind {
            case .roundtrip:
                try checkRoundtrip(vector)
            case .decodeLenient:
                try checkDecodeLenient(vector)
            case .encodeReject:
                try checkEncodeReject(vector)
            case .decodeReject:
                try checkDecodeReject(vector)
            }
        }
    }

    func testSeqComparisons() throws {
        for row in try loadFile().seqComparisons {
            let a = ChannelSeq(rawValue: row.a)
            let b = ChannelSeq(rawValue: row.b)
            XCTAssertEqual(a < b, row.aBeforeB, "\(row.a) vs \(row.b)")
            XCTAssertEqual(a.distance(to: b), row.distance, "\(row.a) → \(row.b)")
        }
    }

    // MARK: Checks per kind

    private func checkRoundtrip(_ vector: EnvelopeVector) throws {
        let (envelope, payload, datagram) = try requireEncodeInputs(vector)
        let encoded = try envelope.encode(payload: payload)
        XCTAssertEqual(
            Hex.string(encoded), Hex.string(datagram),
            "\(vector.name): encode is not byte-exact"
        )
        let (decoded, decodedPayload) = try Envelope.decode(datagram)
        XCTAssertEqual(decoded, envelope, vector.name)
        XCTAssertEqual(Array(decodedPayload), payload, vector.name)
    }

    private func checkDecodeLenient(_ vector: EnvelopeVector) throws {
        let (envelope, payload, datagram) = try requireEncodeInputs(vector)
        let (decoded, decodedPayload) = try Envelope.decode(datagram)
        XCTAssertEqual(decoded, envelope, vector.name)
        XCTAssertEqual(Array(decodedPayload), payload, vector.name)
    }

    private func checkEncodeReject(_ vector: EnvelopeVector) throws {
        guard
            let fields = vector.envelope,
            let payloadHex = vector.payloadHex,
            let payload = Hex.bytes(payloadHex),
            let encoder = vector.encoder,
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed encodeReject vector")
        }
        let envelope = try fields.makeEnvelope()
        XCTAssertThrowsError(
            encoder == .plaintextShard
                ? try envelope.encode(plaintextShard: payload)
                : try envelope.encode(payload: payload),
            vector.name
        ) { error in
            guard let wireError = error as? WireError else {
                return XCTFail("\(vector.name): non-WireError \(error)")
            }
            XCTAssertEqual(wireErrorName(wireError), expected, vector.name)
        }
    }

    private func checkDecodeReject(_ vector: EnvelopeVector) throws {
        guard
            let datagramHex = vector.datagramHex,
            let datagram = Hex.bytes(datagramHex),
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed decodeReject vector")
        }
        XCTAssertThrowsError(try Envelope.decode(datagram), vector.name) { error in
            guard let wireError = error as? WireError else {
                return XCTFail("\(vector.name): non-WireError \(error)")
            }
            XCTAssertEqual(wireErrorName(wireError), expected, vector.name)
        }
    }

    private func requireEncodeInputs(
        _ vector: EnvelopeVector
    ) throws -> (Envelope, [UInt8], [UInt8]) {
        guard
            let fields = vector.envelope,
            let payloadHex = vector.payloadHex,
            let payload = Hex.bytes(payloadHex),
            let datagramHex = vector.datagramHex,
            let datagram = Hex.bytes(datagramHex)
        else {
            XCTFail("\(vector.name): missing roundtrip fields")
            throw VectorFileError.malformedField(vector.name)
        }
        return (try fields.makeEnvelope(), payload, datagram)
    }
}
