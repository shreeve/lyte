import LyteCore
import LyteClientTestKit
import XCTest
import LyteTransport
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// The client's receive path against the frozen Wire/Vectors/envelope-v1.json:
// every decode vector runs through LyteTransport's own ingest path
// (ReceiveDemux), byte-exact.

final class EnvelopeVectorGateTests: XCTestCase {

    private func loadFile() throws -> EnvelopeVectorFile {
        try EnvelopeVectorFile.loadCommitted()
    }

    private func makeDemux() -> ReceiveDemux {
        ReceiveDemux(crypto: PassthroughTransportCrypto())
    }

    func testFileIsTheFrozenContract() throws {
        let file = try loadFile()
        XCTAssertEqual(file.identityProblems, [])
        XCTAssertEqual(file.vectors.count, 17, "the W0 contract ships 17 vectors")
    }

    func testAllVectorsThroughTransportIngest() throws {
        for vector in try loadFile().vectors {
            // Encode rejects are LyteWire's alone (VectorFileTests).
            switch vector.kind {
            case .roundtrip, .decodeLenient:
                try checkDecodeAccepted(vector)
            case .decodeReject:
                try checkDecodeReject(vector)
            case .encodeReject:
                continue
            }
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
        XCTAssertEqual(vectorErrorName(wireError), expected, vector.name)
        XCTAssertEqual(demux.snapshotTotals().malformed, 1, vector.name)
    }
}
