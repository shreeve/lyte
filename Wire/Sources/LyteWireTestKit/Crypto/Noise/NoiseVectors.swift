// The Noise vector-file model and loader (W5): `Wire/Vectors/noise-v1.json`,
// gate W-G6's frozen artifact. Two sections with two provenances, kept
// honestly distinct:
//
// - `handshakeVectors` are EXTERNAL canonical vectors in the standard
//   snow/cacophony JSON shape (fixed statics, ephemerals, prologue →
//   exact handshake + transport-message bytes). Our implementation must
//   reproduce them byte-for-byte — the strongest correctness claim
//   available for `Noise_IK_25519_ChaChaPoly_SHA256`.
// - `transportVectors` cover the Lyte transport EXTENSION (extended-
//   counter nonces from (chan, seq), epoch rekey) that no published
//   vector set covers, because the nonce discipline is ours. They are
//   PINNED SELF-CONSISTENT: generated once by lyte-wire-vectorgen from
//   this implementation, frozen, and honest about being a regression pin
//   rather than an external oracle. The AEAD/handshake beneath them is
//   externally verified by the section above.

import LyteCore
import Foundation
import LyteWire

public struct NoiseVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var handshakeVectors: [NoiseHandshakeVector]
    public var transportVectors: [NoiseTransportVector]

    public static let expectedFormat = "lyte-wire-noise-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        handshakeVectors: [NoiseHandshakeVector],
        transportVectors: [NoiseTransportVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.handshakeVectors = handshakeVectors
        self.transportVectors = transportVectors
    }

    public static func load(from path: String) throws -> NoiseVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(NoiseVectorFile.self, from: data)
    }
}

/// One external handshake vector, the standard noise-c/snow/cacophony
/// shape. `source` records provenance: upstream file URL and the sha256
/// of the file the vector was copied from, so the chain of custody is
/// auditable. `messages` alternate initiator/responder starting with the
/// initiator: for IK, [0] is handshake message 1, [1] message 2, [2…]
/// transport messages under the split keys with sequential Noise nonces.
public struct NoiseHandshakeVector: Codable, Sendable {
    public var name: String
    public var source: String
    public var sourceSha256: String
    public var protocolName: String
    public var initPrologueHex: String
    public var initStaticHex: String
    public var initEphemeralHex: String
    public var initRemoteStaticHex: String
    public var respPrologueHex: String
    public var respStaticHex: String
    public var respEphemeralHex: String
    /// Present when the upstream file carries it (cacophony does).
    public var handshakeHashHex: String?
    public var messages: [Message]

    public struct Message: Codable, Sendable {
        public var payloadHex: String
        public var ciphertextHex: String

        public init(payloadHex: String, ciphertextHex: String) {
            self.payloadHex = payloadHex
            self.ciphertextHex = ciphertextHex
        }
    }

    public init(
        name: String,
        source: String,
        sourceSha256: String,
        protocolName: String,
        initPrologueHex: String,
        initStaticHex: String,
        initEphemeralHex: String,
        initRemoteStaticHex: String,
        respPrologueHex: String,
        respStaticHex: String,
        respEphemeralHex: String,
        handshakeHashHex: String? = nil,
        messages: [Message]
    ) {
        self.name = name
        self.source = source
        self.sourceSha256 = sourceSha256
        self.protocolName = protocolName
        self.initPrologueHex = initPrologueHex
        self.initStaticHex = initStaticHex
        self.initEphemeralHex = initEphemeralHex
        self.initRemoteStaticHex = initRemoteStaticHex
        self.respPrologueHex = respPrologueHex
        self.respStaticHex = respStaticHex
        self.respEphemeralHex = respEphemeralHex
        self.handshakeHashHex = handshakeHashHex
        self.messages = messages
    }
}

/// One pinned Lyte transport scenario: a fixed-key NoiseSession handshake
/// (message 1/2 bytes and handshake hash frozen), then `steps` applied in
/// order — seals producing exact wire payloads, rekeys bumping epochs.
public struct NoiseTransportVector: Codable, Sendable {
    public var name: String
    public var description: String
    /// Honesty marker; always "pinned-self-consistent" in v1.
    public var provenance: String
    public var initStaticHex: String
    public var initEphemeralHex: String
    public var respStaticHex: String
    public var respEphemeralHex: String
    public var prologueHex: String
    public var message1Hex: String
    public var message2Hex: String
    public var handshakeHashHex: String
    public var steps: [Step]

    /// `kind` "seal": the named direction seals `plaintextHex` under the
    /// envelope fields (whose encoded header is the AAD) and must produce
    /// exactly `wirePayloadHex`; the other end must unseal it back.
    /// `kind` "rekey": the named direction's sender rekeys send and the
    /// receiver rekeys receive; subsequent seals ride the new epoch.
    public struct Step: Codable, Sendable {
        public var kind: Kind
        public var direction: Direction
        public var channel: UInt8?
        public var seq: UInt16?
        public var frame: UInt32?
        public var timestampHex: String?
        public var fecHex: String?
        public var plaintextHex: String?
        public var wirePayloadHex: String?

        public enum Kind: String, Codable, Sendable {
            case seal
            case rekey
        }

        public enum Direction: String, Codable, Sendable {
            /// Initiator sends, responder receives.
            case clientToHost
            /// Responder sends, initiator receives.
            case hostToClient
        }

        public init(
            kind: Kind,
            direction: Direction,
            channel: UInt8? = nil,
            seq: UInt16? = nil,
            frame: UInt32? = nil,
            timestampHex: String? = nil,
            fecHex: String? = nil,
            plaintextHex: String? = nil,
            wirePayloadHex: String? = nil
        ) {
            self.kind = kind
            self.direction = direction
            self.channel = channel
            self.seq = seq
            self.frame = frame
            self.timestampHex = timestampHex
            self.fecHex = fecHex
            self.plaintextHex = plaintextHex
            self.wirePayloadHex = wirePayloadHex
        }

        /// The envelope for a seal step; its encoded header is the AAD.
        public func makeEnvelope() throws -> Envelope {
            guard
                let channel, let seq, let frame,
                let timestampHex, let fecHex,
                let timestamp = Hex.uint64(timestampHex),
                let fec = Hex.uint64(fecHex)
            else {
                throw VectorFileError.malformedField("seal step envelope")
            }
            return Envelope(
                channel: ChannelId(rawValue: channel),
                seq: ChannelSeq(rawValue: seq),
                frame: FrameNumber(rawValue: frame),
                timestamp: timestamp,
                fec: fec
            )
        }
    }

    public init(
        name: String,
        description: String,
        provenance: String,
        initStaticHex: String,
        initEphemeralHex: String,
        respStaticHex: String,
        respEphemeralHex: String,
        prologueHex: String,
        message1Hex: String,
        message2Hex: String,
        handshakeHashHex: String,
        steps: [Step]
    ) {
        self.name = name
        self.description = description
        self.provenance = provenance
        self.initStaticHex = initStaticHex
        self.initEphemeralHex = initEphemeralHex
        self.respStaticHex = respStaticHex
        self.respEphemeralHex = respEphemeralHex
        self.prologueHex = prologueHex
        self.message1Hex = message1Hex
        self.message2Hex = message2Hex
        self.handshakeHashHex = handshakeHashHex
        self.steps = steps
    }
}
