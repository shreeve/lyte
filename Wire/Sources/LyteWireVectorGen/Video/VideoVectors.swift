// The video vector-file model and loader for Wire/Vectors/video-v1.json:
// the packetized golden corpus and assembly scenarios, frozen wire contract.

import Foundation
import LyteCore
import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/video-v1.json`.
public struct VideoVectorFile: FrozenVectorFile {
    /// Always "lyte-wire-video-vectors".
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    /// Packetize vectors: frame in, frozen shard datagrams out.
    public var frames: [VideoFrameVector]
    /// Assembly scenarios: scripted delivery over the frames above.
    public var scenarios: [VideoScenario]

    public static let expectedFormat = "lyte-wire-video-vectors"
    public static let fileName = "video-v1.json"

    public var vectorNameGroups: [[String]] {
        [frames.map(\.name), scenarios.map(\.name)]
    }
}

/// Where a frame vector's Annex-B bytes live. Inline hex for the small
/// synthetic frames (auditable by eye); corpus files for the real HEVC
/// material, pinned by sha256 so the vector file and the corpus can
/// never drift apart silently.
public struct VideoFrameSource: Codable, Sendable {
    /// "inline" or "corpus".
    public var kind: String
    /// Inline: the frame's Annex-B bytes as hex.
    public var annexBHex: String?
    /// Corpus: the file name inside Vectors/video-corpus-v1/.
    public var file: String?
    /// Corpus: sha256 of the file's bytes.
    public var sha256: String?

    public static func inline(_ bytes: [UInt8]) -> VideoFrameSource {
        VideoFrameSource(kind: "inline", annexBHex: Hex.string(bytes))
    }

    public static func corpus(file: String, bytes: [UInt8]) -> VideoFrameSource {
        VideoFrameSource(
            kind: "corpus", file: file,
            sha256: Hex.string(Sha256.digest(bytes))
        )
    }

    /// Resolves the frame bytes, verifying the corpus pin.
    public func loadBytes(corpusDirectory: String) throws -> [UInt8] {
        switch kind {
        case "inline":
            guard let annexBHex, let bytes = Hex.bytes(annexBHex) else {
                throw VectorFileError.malformedField("inline annexBHex")
            }
            return bytes
        case "corpus":
            guard let file, let sha256 else {
                throw VectorFileError.malformedField("corpus file/sha256")
            }
            let data = try Data(
                contentsOf: URL(fileURLWithPath: corpusDirectory + "/" + file)
            )
            let bytes = [UInt8](data)
            guard Hex.string(Sha256.digest(bytes)) == sha256 else {
                throw VectorFileError.malformedField(
                    "corpus \(file): sha256 mismatch — corpus and vector file have drifted"
                )
            }
            return bytes
        default:
            throw VectorFileError.malformedField("source kind \(kind)")
        }
    }
}

/// One packetize vector: `VideoPacketizer` on the source bytes with these
/// parameters must produce exactly `shards.count` shards whose encoded
/// datagrams hash to `shards[i].datagramSha256` (and match
/// `datagramHex` byte-exact where present — inline frames carry it,
/// corpus frames stay hash-only to keep the repo lean).
public struct VideoFrameVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var source: VideoFrameSource
    public var frameNumber: UInt32
    /// Hex u64 (JSON numbers lose precision), host-clock µs.
    public var timestampHex: String
    public var isIDR: Bool
    public var regime: String
    public var firstSeq: UInt16
    public var dataShards: Int
    public var parityShards: Int
    public var groupByteCount: Int
    public var shards: [VideoShardVector]

    public init(
        name: String,
        description: String,
        source: VideoFrameSource,
        frameNumber: FrameNumber,
        timestamp: HostTimestamp,
        isIDR: Bool,
        regime: FecRegime,
        firstSeq: ChannelSeq,
        geometry: FecGeometry,
        shards: [VideoShardVector]
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.frameNumber = frameNumber.rawValue
        self.timestampHex = Hex.uint64String(timestamp.microseconds)
        self.isIDR = isIDR
        self.regime = regime.rawValue
        self.firstSeq = firstSeq.rawValue
        self.dataShards = geometry.dataShards
        self.parityShards = geometry.parityShards
        self.groupByteCount = geometry.groupByteCount
        self.shards = shards
    }
}

/// One frozen bare shard datagram (envelope + payload) for contract tests.
public struct VideoShardVector: Codable, Sendable {
    public var seq: UInt16
    /// The envelope fec field, hex u64.
    public var fecHex: String
    public var datagramSha256: String
    /// Full datagram bytes, inline frames only.
    public var datagramHex: String?

    public init(
        seq: ChannelSeq, fecHex: String, datagram: [UInt8], includeHex: Bool
    ) {
        self.seq = seq.rawValue
        self.fecHex = fecHex
        self.datagramSha256 = Hex.string(Sha256.digest(datagram))
        self.datagramHex = includeHex ? Hex.string(datagram) : nil
    }
}

/// One assembly scenario: deliver the named frames' shards in `steps`
/// order (indices absent from steps are lost; repeated indices are
/// duplicate datagrams), all at the same injected instant, then — when
/// `finalTickMicroseconds` is set — one `evictStale` tick at that
/// instant. Assertions:
/// - decoded frames come out exactly `expectDecoded`, in that order,
///   each byte-identical to its source and with the vector's
///   frameNumber/timestamp/isIDR;
/// - `expectFecImpossible` frames each raise the fec-impossible event.
public struct VideoScenario: Codable, Sendable {
    public var name: String
    public var description: String
    public var steps: [VideoDeliveryStep]
    public var finalTickMicroseconds: Int64?
    public var expectDecoded: [String]
    public var expectFecImpossible: [String] = []
}

public struct VideoDeliveryStep: Codable, Sendable {
    /// A `VideoFrameVector.name`.
    public var frame: String
    public var shardIndex: Int
}
