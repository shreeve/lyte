import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/control-v1.json byte-exact — the
// codecs promoted by the second codec-promotion slice (IdleFrame 0x15,
// InputEvent 0x16, InputEcho 0x17, the lastInputSeq TLV 0x03, the
// audio-routing pair 0x18/0x19, capability key 9) both ends now code
// against, on both platforms.

final class ControlVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/control-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> ControlVectorFile {
        try ControlVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, ControlVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "vector names must be unique")
    }

    /// The file pins the WHOLE value spaces of the enum-shaped codecs:
    /// every InputEvent body kind and every routing mode of both 0x18
    /// and 0x19 must appear as a roundtrip — a case added to either
    /// enum without a vector-file (and wire-version) discussion fails
    /// loudly (the lifecycle file's discipline).
    func testValueSpacesCovered() throws {
        let file = try loadFile()
        let bodyKinds = Set(file.vectors.lazy
            .filter { $0.codec == .inputEvent && $0.kind == .roundtrip }
            .compactMap(\.bodyKind))
        XCTAssertEqual(bodyKinds.count, 5, "every InputEvent kind pinned")
        for codec: ControlVector.ControlCodec
            in [.audioRoutingRequest, .audioRoutingStatus] {
            let modes = Set(file.vectors.lazy
                .filter { $0.codec == codec && $0.kind == .roundtrip }
                .compactMap(\.mode))
            XCTAssertEqual(
                modes.count, HostAudioRoutingMode.allCases.count,
                "\(codec)'s whole mode space pinned"
            )
        }
    }

    func testAllControlVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            switch vector.codec {
            case .idleFrame:
                try checkIdleFrame(vector, message: message)
            case .inputEvent:
                try checkInputEvent(vector, message: message)
            case .inputEcho:
                try checkInputEcho(vector, message: message)
            case .lastInputSeqTlv:
                try checkLastInputSeqTlv(vector, message: message)
            case .audioRoutingRequest:
                try checkRouting(
                    vector, message: message,
                    encode: { AudioRoutingRequest(mode: $0).encode() },
                    decode: { try AudioRoutingRequest.decode($0).mode }
                )
            case .audioRoutingStatus:
                try checkRouting(
                    vector, message: message,
                    encode: { AudioRoutingStatus(mode: $0).encode() },
                    decode: { try AudioRoutingStatus.decode($0).mode }
                )
            case .capabilitySet:
                try checkCapabilitySet(vector, message: message)
            }
        }
    }

    private func checkIdleFrame(
        _ vector: ControlVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let frame = vector.frame,
                  let timestamp = vector.timestampHex.flatMap(Hex.uint64),
                  let annexB = vector.annexBHex.flatMap(Hex.bytes) else {
                return XCTFail("\(vector.name): missing fields")
            }
            let idle = IdleFrame(
                frame: FrameNumber(rawValue: frame),
                captureTimestampMicroseconds: timestamp,
                annexB: annexB
            )
            XCTAssertEqual(idle.encode(), message, vector.name)
            XCTAssertEqual(try IdleFrame.decode(message), idle, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try IdleFrame.decode(message), vector.name) {
                guard let error = $0 as? IdleFrameError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(idleFrameErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkInputEvent(
        _ vector: ControlVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let seq = vector.seq,
                  let micros = vector.clientMicrosHex.flatMap(Hex.uint64),
                  let body = controlVectorBody(vector) else {
                return XCTFail("\(vector.name): missing fields")
            }
            let event = InputEvent(
                seq: seq, clientMicroseconds: micros, body: body
            )
            XCTAssertEqual(event.encode(), message, vector.name)
            XCTAssertEqual(try InputEvent.decode(message), event, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try InputEvent.decode(message), vector.name) {
                guard let error = $0 as? InputMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(inputMessageErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkInputEcho(
        _ vector: ControlVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let rows = vector.tuples else {
                return XCTFail("\(vector.name): missing tuples")
            }
            let tuples = try rows.map { row -> InputEchoTuple in
                guard let received = Hex.uint64(row.receivedHex),
                      let injected = Hex.uint64(row.injectedHex) else {
                    throw XCTSkip("\(vector.name): malformed tuple hex")
                }
                return InputEchoTuple(
                    seq: row.seq,
                    receivedMicroseconds: received,
                    injectedMicroseconds: injected
                )
            }
            let echo = InputEcho(tuples: tuples)
            XCTAssertEqual(echo.encode(), message, vector.name)
            XCTAssertEqual(try InputEcho.decode(message), echo, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try InputEcho.decode(message), vector.name) {
                guard let error = $0 as? InputMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(inputMessageErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkLastInputSeqTlv(
        _ vector: ControlVector, message: [UInt8]
    ) throws {
        // The datagram itself always decodes — the seq codec is what
        // the vector exercises (the conn-id precedent).
        let (envelope, payload) = try Envelope.decode(message)
        switch vector.kind {
        case .roundtrip:
            guard let expected = vector.lastInputSeq else {
                return XCTFail("\(vector.name): missing lastInputSeq")
            }
            XCTAssertEqual(
                try LastInputSeqTlv.decode(extensions: envelope.extensions),
                expected, vector.name
            )
            // The whole datagram re-encodes byte-exactly.
            XCTAssertEqual(try envelope.encode(payload: Array(payload)),
                           message, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(
                try LastInputSeqTlv.decode(extensions: envelope.extensions),
                vector.name
            ) {
                guard let error = $0 as? InputMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(inputMessageErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkRouting(
        _ vector: ControlVector, message: [UInt8],
        encode: (HostAudioRoutingMode) -> [UInt8],
        decode: ([UInt8]) throws -> HostAudioRoutingMode
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let mode = vector.mode.map(controlVectorMode) else {
                return XCTFail("\(vector.name): missing mode")
            }
            XCTAssertEqual(encode(mode), message, vector.name)
            XCTAssertEqual(try decode(message), mode, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try decode(message), vector.name) {
                guard let error = $0 as? AudioRoutingMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(audioRoutingMessageErrorName(error),
                               vector.error, vector.name)
            }
        }
    }

    private func checkCapabilitySet(
        _ vector: ControlVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let expected = vector.hostAudioRouting else {
                return XCTFail("\(vector.name): missing hostAudioRouting")
            }
            let set = try Capabilities.decodeCbor(message)
            XCTAssertEqual(set.hostAudioRouting, expected, vector.name)
            XCTAssertEqual(try set.encodeCbor(), message, vector.name)
        case .decodeReject:
            XCTFail("\(vector.name): capabilitySet vectors are roundtrips")
        }
    }
}
