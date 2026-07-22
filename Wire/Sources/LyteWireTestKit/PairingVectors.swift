// The pairing vector-file model and loader (W6):
// `Wire/Vectors/pairing-v1.json`, gate W-G7's frozen artifact. Three
// sections with the noise-v1 provenance discipline:
//
// - `draftVectors` are EXTERNAL canonical vectors transcribed verbatim
//   from draft-irtf-cfrg-cpace-21's appendices (A utilities, B.1
//   CPACE-X25519-SHA512, B.1.10 low-order table), with the upstream
//   file's URL and sha256 recorded — the strongest correctness claim
//   available for the suite.
// - `exchangeVectors` cover Lyte's PairingPake composition (the Noise
//   handshake-hash binding, CI from the statics, the §10.4 tags in the
//   0x0B–0x0D messages) that no published set can cover, because the
//   composition is ours. PINNED SELF-CONSISTENT, honest about being a
//   regression pin; the CPace math beneath them is externally verified
//   by the section above.
// - `messageVectors` freeze the codec byte layouts, anchored against
//   the hand-built bytes in PairingCodecTests.

import Foundation
import LyteWire

public struct PairingVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var draftVectors: PairingDraftVectors
    public var exchangeVectors: [PairingExchangeVector]
    public var messageVectors: [PairingMessageVector]

    public static let expectedFormat = "lyte-wire-pairing-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        draftVectors: PairingDraftVectors,
        exchangeVectors: [PairingExchangeVector],
        messageVectors: [PairingMessageVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.draftVectors = draftVectors
        self.exchangeVectors = exchangeVectors
        self.messageVectors = messageVectors
    }

    public static func load(from path: String) throws -> PairingVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(PairingVectorFile.self, from: data)
    }
}

/// The external draft vectors. `source`/`sourceSha256` record the exact
/// upstream text file the values were transcribed from.
public struct PairingDraftVectors: Codable, Sendable {
    public var source: String
    public var sourceSha256: String
    public var utilities: Utilities
    public var generator: Generator
    public var exchange: Exchange
    public var lowOrder: LowOrder

    /// Appendix A.1/A.3: prepend_len, lv_cat, transcript_ir.
    public struct Utilities: Codable, Sendable {
        public var prependLen: [InOut]
        public var lvCat: PartsOut
        public var transcriptIr: [TranscriptCase]

        public struct InOut: Codable, Sendable {
            public var inputHex: String
            public var outputHex: String

            public init(inputHex: String, outputHex: String) {
                self.inputHex = inputHex
                self.outputHex = outputHex
            }
        }

        public struct PartsOut: Codable, Sendable {
            public var partsHex: [String]
            public var outputHex: String

            public init(partsHex: [String], outputHex: String) {
                self.partsHex = partsHex
                self.outputHex = outputHex
            }
        }

        public struct TranscriptCase: Codable, Sendable {
            public var yaHex: String
            public var adaHex: String
            public var ybHex: String
            public var adbHex: String
            public var outputHex: String

            public init(
                yaHex: String, adaHex: String, ybHex: String,
                adbHex: String, outputHex: String
            ) {
                self.yaHex = yaHex
                self.adaHex = adaHex
                self.ybHex = ybHex
                self.adbHex = adbHex
                self.outputHex = outputHex
            }
        }

        public init(
            prependLen: [InOut], lvCat: PartsOut,
            transcriptIr: [TranscriptCase]
        ) {
            self.prependLen = prependLen
            self.lvCat = lvCat
            self.transcriptIr = transcriptIr
        }
    }

    /// B.1.1: the calculate_generator chain, every intermediate pinned.
    public struct Generator: Codable, Sendable {
        public var prsHex: String
        public var ciHex: String
        public var sidHex: String
        public var generatorStringHex: String
        public var generatorHex: String

        public init(
            prsHex: String, ciHex: String, sidHex: String,
            generatorStringHex: String, generatorHex: String
        ) {
            self.prsHex = prsHex
            self.ciHex = ciHex
            self.sidHex = sidHex
            self.generatorStringHex = generatorStringHex
            self.generatorHex = generatorHex
        }
    }

    /// B.1.2–B.1.5: scalars → shares → K → ISK (initiator-responder).
    public struct Exchange: Codable, Sendable {
        public var yaHex: String
        public var adaHex: String
        public var yaShareHex: String
        public var ybHex: String
        public var adbHex: String
        public var ybShareHex: String
        public var kHex: String
        public var iskIrHex: String

        public init(
            yaHex: String, adaHex: String, yaShareHex: String,
            ybHex: String, adbHex: String, ybShareHex: String,
            kHex: String, iskIrHex: String
        ) {
            self.yaHex = yaHex
            self.adaHex = adaHex
            self.yaShareHex = yaShareHex
            self.ybHex = ybHex
            self.adbHex = adbHex
            self.ybShareHex = ybShareHex
            self.kHex = kHex
            self.iskIrHex = iskIrHex
        }
    }

    /// B.1.10: scalar_mult_vfy over low-order and non-canonical points.
    /// `resultHex` nil means the result MUST be the neutral element
    /// (and a pairing run receiving that share MUST abort).
    public struct LowOrder: Codable, Sendable {
        public var scalarHex: String
        public var cases: [Case]

        public struct Case: Codable, Sendable {
            public var uHex: String
            public var resultHex: String?

            public init(uHex: String, resultHex: String?) {
                self.uHex = uHex
                self.resultHex = resultHex
            }
        }

        public init(scalarHex: String, cases: [Case]) {
            self.scalarHex = scalarHex
            self.cases = cases
        }
    }

    public init(
        source: String, sourceSha256: String, utilities: Utilities,
        generator: Generator, exchange: Exchange, lowOrder: LowOrder
    ) {
        self.source = source
        self.sourceSha256 = sourceSha256
        self.utilities = utilities
        self.generator = generator
        self.exchange = exchange
        self.lowOrder = lowOrder
    }
}

/// One pinned PairingPake run: fixed PIN, statics, handshake hash, and
/// scalars → the exact 0x0B/0x0C/0x0D message bytes and the ISK both
/// ends must derive. Replayed through the real state machines.
public struct PairingExchangeVector: Codable, Sendable {
    public var name: String
    public var description: String
    /// Honesty marker; always "pinned-self-consistent" in v1.
    public var provenance: String
    public var pinHex: String
    public var clientStaticHex: String
    public var hostStaticHex: String
    public var handshakeHashHex: String
    public var initiatorScalarHex: String
    public var responderScalarHex: String
    public var shareAMessageHex: String
    public var shareBMessageHex: String
    public var confirmMessageHex: String
    public var iskHex: String

    public init(
        name: String, description: String, provenance: String,
        pinHex: String, clientStaticHex: String, hostStaticHex: String,
        handshakeHashHex: String, initiatorScalarHex: String,
        responderScalarHex: String, shareAMessageHex: String,
        shareBMessageHex: String, confirmMessageHex: String,
        iskHex: String
    ) {
        self.name = name
        self.description = description
        self.provenance = provenance
        self.pinHex = pinHex
        self.clientStaticHex = clientStaticHex
        self.hostStaticHex = hostStaticHex
        self.handshakeHashHex = handshakeHashHex
        self.initiatorScalarHex = initiatorScalarHex
        self.responderScalarHex = responderScalarHex
        self.shareAMessageHex = shareAMessageHex
        self.shareBMessageHex = shareBMessageHex
        self.confirmMessageHex = confirmMessageHex
        self.iskHex = iskHex
    }
}

/// One codec vector for the 0x0B–0x0E message layouts, the lifecycle
/// file's kinds over `messageHex`.
public struct PairingMessageVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: Codec
    public var messageHex: String
    /// Roundtrip fields, by codec: shares/tags as hex, reject reason
    /// as its raw byte.
    public var shareHex: String?
    public var tagHex: String?
    public var reason: UInt8?
    /// decodeReject: the PairingMessageError case name.
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum Codec: String, Codable, Sendable {
        case shareA
        case shareB
        case confirm
        case reject
    }

    public init(
        name: String, description: String, kind: Kind, codec: Codec,
        messageHex: String, shareHex: String? = nil,
        tagHex: String? = nil, reason: UInt8? = nil, error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.shareHex = shareHex
        self.tagHex = tagHex
        self.reason = reason
        self.error = error
    }
}

/// The error-name mapper the file tests assert against.
public func pairingMessageErrorName(_ error: PairingMessageError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .trailingBytes: return "trailingBytes"
    case .unexpectedType: return "unexpectedType"
    case .unknownReason: return "unknownReason"
    case .invalidShareLength: return "invalidShareLength"
    case .invalidTagLength: return "invalidTagLength"
    }
}
