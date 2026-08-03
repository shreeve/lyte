import LyteCore
import LyteClientTestKit
import XCTest
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE CL-1 GATE: the client's receive path verifies against the frozen
// Wire/Vectors/envelope-v1.json byte-exact — the same artifact Wire/Tests
// pins — proving client-side consumption of the wire contract before the
// host sends a datagram. Decodes run through LyteTransport's own ingest
// path (ReceiveDemux), not LyteWire directly.

final class EnvelopeVectorGateTests: XCTestCase {

    private static var vectorsPath: String {
        ClientTestPaths.repositoryRoot + "/Wire/Vectors/envelope-v1.json"
    }

    private func loadFile() throws -> EnvelopeVectorFile {
        try EnvelopeVectorFile.load(from: Self.vectorsPath)
    }

    private func makeDemux() -> ReceiveDemux {
        ReceiveDemux(crypto: InsecureTransportCrypto())
    }

    func testFileIsTheFrozenContract() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, EnvelopeVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertEqual(file.vectors.count, 17, "the W0 contract ships 17 vectors")
    }

    func testAllVectorsThroughTransportIngest() throws {
        for vector in try loadFile().vectors {
            switch vector.kind {
            case .roundtrip:
                try checkDecodeAccepted(vector)
                try checkEncodeByteExact(vector)
            case .decodeLenient:
                try checkDecodeAccepted(vector)
            case .encodeReject:
                try checkEncodeReject(vector)
            case .decodeReject:
                try checkDecodeReject(vector)
            }
        }
    }

    func testSeqComparisonContract() throws {
        for row in try loadFile().seqComparisons {
            let a = ChannelSeq(rawValue: row.a)
            let b = ChannelSeq(rawValue: row.b)
            XCTAssertEqual(a < b, row.aBeforeB, "\(row.a) vs \(row.b)")
            XCTAssertEqual(a.distance(to: b), row.distance, "\(row.a) → \(row.b)")
        }
    }

    // MARK: Checks

    /// The vector's datagram bytes through ReceiveDemux.ingest must produce
    /// the vector's envelope field-exact and its payload byte-exact.
    private func checkDecodeAccepted(_ vector: EnvelopeVector) throws {
        guard
            let fields = vector.envelope,
            let payloadHex = vector.payloadHex,
            let expectedPayload = Hex.bytes(payloadHex),
            let datagramHex = vector.datagramHex,
            let datagram = Hex.bytes(datagramHex)
        else {
            return XCTFail("\(vector.name): missing decode fields")
        }
        let expected = try fields.makeEnvelope()
        // Reserved channels drop at the demux by design; the frozen file
        // has none, but assert that assumption so a future vector is loud.
        XCTAssertFalse(expected.channel.isReserved, vector.name)

        let outcome = makeDemux().ingest(datagram: datagram[...], arrivalMicroseconds: 0)
        guard case .accepted(let envelope, let payload) = outcome else {
            return XCTFail("\(vector.name): ingest did not accept — \(outcome)")
        }
        XCTAssertEqual(envelope, expected, "\(vector.name): envelope fields differ")
        XCTAssertEqual(Hex.string(payload), Hex.string(expectedPayload),
                       "\(vector.name): payload not byte-exact")
    }

    /// Round trips also re-encode byte-exact via LyteWire — the encode half
    /// of the client's contract consumption (feedback/beacon sends later).
    private func checkEncodeByteExact(_ vector: EnvelopeVector) throws {
        guard
            let fields = vector.envelope,
            let payloadHex = vector.payloadHex,
            let payload = Hex.bytes(payloadHex),
            let datagramHex = vector.datagramHex
        else {
            return XCTFail("\(vector.name): missing roundtrip fields")
        }
        let encoded = try fields.makeEnvelope().encode(payload: payload)
        XCTAssertEqual(Hex.string(encoded), datagramHex,
                       "\(vector.name): encode not byte-exact")
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

    /// Reject vectors must surface through ingest as .malformed with the
    /// exact WireError the contract names.
    private func checkDecodeReject(_ vector: EnvelopeVector) throws {
        guard
            let datagramHex = vector.datagramHex,
            let datagram = Hex.bytes(datagramHex),
            let expected = vector.error
        else {
            return XCTFail("\(vector.name): malformed decodeReject vector")
        }
        let demux = makeDemux()
        let outcome = demux.ingest(datagram: datagram[...], arrivalMicroseconds: 0)
        guard case .malformed(let wireError) = outcome else {
            return XCTFail("\(vector.name): ingest did not reject — \(outcome)")
        }
        XCTAssertEqual(wireErrorName(wireError), expected, vector.name)
        XCTAssertEqual(demux.snapshotTotals().malformed, 1, vector.name)
    }
}
