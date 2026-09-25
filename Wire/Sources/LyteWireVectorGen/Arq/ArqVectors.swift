// The ARQ frame vector-file model and loader: `Wire/Vectors/arq-v1.json`
// (data segment 0x07, ACK 0x08, and the frame-sequence payload rule).

import LyteCore
import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/arq-v1.json`.
public struct ArqVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [ArqVector]

    public static let expectedFormat = "lyte-wire-arq-vectors"
    public static let fileName = "arq-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One ARQ vector. `payloadHex` is a whole reliable-channel datagram
/// payload (a frame sequence). Kinds match the envelope file:
/// `roundtrip` decodes `payloadHex` to exactly the typed `frames` and
/// re-encodes byte-exactly; `decodeLenient` decodes (reserved flag bits
/// set) but re-encodes differently; `decodeReject` throws `error`, an
/// `ArqFrameError` case name.
public struct ArqVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var payloadHex: String
    /// The expected frame sequence (roundtrip/decodeLenient).
    public var frames: [Frame]?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case decodeReject
    }

    /// One typed frame: exactly one of `segment` / `ack` is set.
    public struct Frame: Codable, Sendable {
        public var segment: Segment?
        public var ack: Ack?
    }

    public struct Segment: Codable, Sendable {
        public var group: UInt16
        public var seq: UInt16
        public var endOfMessage: Bool
        public var bodyHex: String
    }

    public struct Ack: Codable, Sendable {
        public var blocks: [Block]

        public struct Block: Codable, Sendable {
            public var chan: UInt8
            public var group: UInt16
            public var cumulative: UInt16
            public var bitmapHex: String
        }
    }
}

/// Builds the LyteWire frame a typed vector frame describes. Traps on a
/// malformed vector file — vectors are trusted repo artifacts.
public func arqFrame(from vector: ArqVector.Frame) throws -> ArqFrame {
    if let segment = vector.segment {
        guard let body = Hex.bytes(segment.bodyHex) else {
            fatalError("bad bodyHex in arq vector")
        }
        return .segment(try ArqSegment(
            group: ArqGroupId(rawValue: segment.group),
            seq: ArqSegmentSeq(rawValue: segment.seq),
            endOfMessage: segment.endOfMessage,
            body: body
        ))
    }
    if let ack = vector.ack {
        return .ack(try ArqAck(blocks: ack.blocks.map { block in
            guard let bitmap = Hex.bytes(block.bitmapHex) else {
                fatalError("bad bitmapHex in arq vector")
            }
            return try ArqAck.Block(
                channel: ChannelId(rawValue: block.chan),
                group: ArqGroupId(rawValue: block.group),
                cumulative: ArqSegmentSeq(rawValue: block.cumulative),
                receivedBitmap: bitmap
            )
        }))
    }
    fatalError("vector frame with neither segment nor ack")
}
