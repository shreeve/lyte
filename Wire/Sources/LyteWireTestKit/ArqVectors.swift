// The ARQ frame vector-file model and loader: `Wire/Vectors/arq-v1.json`
// — the W3 wire formats (data segment 0x07, ACK 0x08, and the
// frame-sequence payload rule). Same doctrine as the other loaders:
// TestKit may import Foundation, LyteWire may not.

import LyteCore
import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/arq-v1.json`.
public struct ArqVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ArqVector]

    public static let expectedFormat = "lyte-wire-arq-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [ArqVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

    public static func load(from path: String) throws -> ArqVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ArqVectorFile.self, from: data)
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

        public init(segment: Segment) {
            self.segment = segment
        }

        public init(ack: Ack) {
            self.ack = ack
        }
    }

    public struct Segment: Codable, Sendable {
        public var group: UInt16
        public var seq: UInt16
        public var endOfMessage: Bool
        public var bodyHex: String

        public init(
            group: UInt16, seq: UInt16, endOfMessage: Bool, bodyHex: String
        ) {
            self.group = group
            self.seq = seq
            self.endOfMessage = endOfMessage
            self.bodyHex = bodyHex
        }
    }

    public struct Ack: Codable, Sendable {
        public var blocks: [Block]

        public init(blocks: [Block]) {
            self.blocks = blocks
        }

        public struct Block: Codable, Sendable {
            public var chan: UInt8
            public var group: UInt16
            public var cumulative: UInt16
            public var bitmapHex: String

            public init(
                chan: UInt8, group: UInt16, cumulative: UInt16,
                bitmapHex: String
            ) {
                self.chan = chan
                self.group = group
                self.cumulative = cumulative
                self.bitmapHex = bitmapHex
            }
        }
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        payloadHex: String,
        frames: [Frame]? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.payloadHex = payloadHex
        self.frames = frames
        self.error = error
    }
}

/// Stable names for `ArqFrameError` cases, as they appear in vectors.
public func arqFrameErrorName(_ error: ArqFrameError) -> String {
    switch error {
    case .truncatedFrame: return "truncatedFrame"
    case .unknownFrameType: return "unknownFrameType"
    case .emptyPayload: return "emptyPayload"
    case .zeroLengthSegmentBody: return "zeroLengthSegmentBody"
    case .segmentBodyOverBudget: return "segmentBodyOverBudget"
    case .zeroAckBlocks: return "zeroAckBlocks"
    case .tooManyAckBlocks: return "tooManyAckBlocks"
    case .ackBitmapTooLong: return "ackBitmapTooLong"
    case .nonCanonicalAckBitmap: return "nonCanonicalAckBitmap"
    case .payloadOverBudget: return "payloadOverBudget"
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
