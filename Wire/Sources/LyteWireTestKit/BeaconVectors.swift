// The beacon/feedback vector-file model and loader (W4a):
// `Wire/Vectors/beacon-v1.json`, the contract CL-3 codes its beacon echo
// and feedback sender against before the host exists. Same doctrine as
// the envelope loader: TestKit may import Foundation, LyteWire may not.

import LyteCore
import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/beacon-v1.json`. Both W4a codecs live
/// in one file — they land together, and the clock worked example needs
/// the echo vectors next to it.
public struct BeaconVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var beaconVectors: [BeaconVector]
    public var feedbackVectors: [FeedbackVector]
    /// The README's offset/RTT computation, as checkable data.
    public var clockWorkedExample: ClockWorkedExample

    public static let expectedFormat = "lyte-wire-beacon-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        beaconVectors: [BeaconVector],
        feedbackVectors: [FeedbackVector],
        clockWorkedExample: ClockWorkedExample
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.beaconVectors = beaconVectors
        self.feedbackVectors = feedbackVectors
        self.clockWorkedExample = clockWorkedExample
    }

    public static func load(from path: String) throws -> BeaconVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BeaconVectorFile.self, from: data)
    }
}

/// One CTRL beacon-pair vector. `decoder` names the codec under test
/// (both decoders see every reject's bytes come from somewhere specific).
/// Kinds match the envelope file: `roundtrip` encodes the struct to
/// exactly `messageHex` and back; `decodeLenient` decodes `messageHex` to
/// the struct but a canonical re-encode differs (reserved flag bits);
/// `decodeReject` throws `error` (a BeaconError case name).
public struct BeaconVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var decoder: Decoder
    public var beacon: BeaconFields?
    public var echo: EchoFields?
    public var messageHex: String?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case decodeReject
    }

    public enum Decoder: String, Codable, Sendable {
        case beacon
        case echo
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        decoder: Decoder,
        beacon: BeaconFields? = nil,
        echo: EchoFields? = nil,
        messageHex: String? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.decoder = decoder
        self.beacon = beacon
        self.echo = echo
        self.messageHex = messageHex
        self.error = error
    }
}

/// ClockBeacon in vector-file form; timestamps are hex strings (u64 does
/// not survive JSON number precision).
public struct BeaconFields: Codable, Sendable {
    public var beaconSeq: UInt32
    public var hostSendHex: String
    public var lastEcho: LastEchoFields?

    public struct LastEchoFields: Codable, Sendable {
        public var beaconSeq: UInt32
        public var clientSendHex: String
        public var hostReceiveHex: String

        public init(beaconSeq: UInt32, clientSendHex: String, hostReceiveHex: String) {
            self.beaconSeq = beaconSeq
            self.clientSendHex = clientSendHex
            self.hostReceiveHex = hostReceiveHex
        }
    }

    public init(from beacon: ClockBeacon) {
        self.beaconSeq = beacon.beaconSeq
        self.hostSendHex = Hex.uint64String(beacon.hostSend.microseconds)
        self.lastEcho = beacon.lastEcho.map {
            LastEchoFields(
                beaconSeq: $0.beaconSeq,
                clientSendHex: Hex.uint64String($0.clientSend.microseconds),
                hostReceiveHex: Hex.uint64String($0.hostReceive.microseconds)
            )
        }
    }

    public func makeBeacon() throws -> ClockBeacon {
        guard let hostSend = Hex.uint64(hostSendHex) else {
            throw VectorFileError.malformedField("hostSendHex")
        }
        let echo = try lastEcho.map { fields -> ClockBeacon.LastEcho in
            guard
                let clientSend = Hex.uint64(fields.clientSendHex),
                let hostReceive = Hex.uint64(fields.hostReceiveHex)
            else {
                throw VectorFileError.malformedField("lastEcho timestamps")
            }
            return ClockBeacon.LastEcho(
                beaconSeq: fields.beaconSeq,
                clientSend: ClientTimestamp(microseconds: clientSend),
                hostReceive: HostTimestamp(microseconds: hostReceive)
            )
        }
        return ClockBeacon(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(microseconds: hostSend),
            lastEcho: echo
        )
    }
}

/// BeaconEcho in vector-file form.
public struct EchoFields: Codable, Sendable {
    public var beaconSeq: UInt32
    public var hostSendHex: String
    public var clientReceiveHex: String
    public var clientSendHex: String

    public init(from echo: BeaconEcho) {
        self.beaconSeq = echo.beaconSeq
        self.hostSendHex = Hex.uint64String(echo.hostSend.microseconds)
        self.clientReceiveHex = Hex.uint64String(echo.clientReceive.microseconds)
        self.clientSendHex = Hex.uint64String(echo.clientSend.microseconds)
    }

    public func makeEcho() throws -> BeaconEcho {
        guard
            let hostSend = Hex.uint64(hostSendHex),
            let clientReceive = Hex.uint64(clientReceiveHex),
            let clientSend = Hex.uint64(clientSendHex)
        else {
            throw VectorFileError.malformedField("echo timestamps")
        }
        return BeaconEcho(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(microseconds: hostSend),
            clientReceive: ClientTimestamp(microseconds: clientReceive),
            clientSend: ClientTimestamp(microseconds: clientSend)
        )
    }
}

/// One chan=3 feedback-report vector. Kinds match the envelope file;
/// `error` is a FeedbackError case name.
public struct FeedbackVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var report: FeedbackFields?
    public var reportHex: String?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case encodeReject
        case decodeReject
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        report: FeedbackFields? = nil,
        reportHex: String? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.report = report
        self.reportHex = reportHex
        self.error = error
    }
}

/// FeedbackReport in vector-file form.
public struct FeedbackFields: Codable, Sendable {
    public var pathId: UInt8
    public var clientTimestampHex: String
    public var channels: [ChannelStatsFields]?
    public var dispersion: DispersionFields?
    public var nacks: [NackFields]?
    public var tlvs: [TlvField]?

    public struct ChannelStatsFields: Codable, Sendable {
        public var chan: UInt8
        public var highestSeq: UInt16
        public var received: UInt32
        public var missing: UInt32
        public var duplicates: UInt32

        public init(from stats: FeedbackReport.ChannelStats) {
            self.chan = stats.channel.rawValue
            self.highestSeq = stats.highestSeq.rawValue
            self.received = stats.received
            self.missing = stats.missing
            self.duplicates = stats.duplicates
        }

        public func makeStats() -> FeedbackReport.ChannelStats {
            .init(
                channel: ChannelId(rawValue: chan),
                highestSeq: ChannelSeq(rawValue: highestSeq),
                received: received,
                missing: missing,
                duplicates: duplicates
            )
        }
    }

    public struct DispersionFields: Codable, Sendable {
        public var baseHex: String
        public var samples: [SampleFields]

        public struct SampleFields: Codable, Sendable {
            public var chan: UInt8
            public var seq: UInt16
            public var deltaMicroseconds: UInt32

            public init(from sample: FeedbackReport.Dispersion.Sample) {
                self.chan = sample.channel.rawValue
                self.seq = sample.seq.rawValue
                self.deltaMicroseconds = sample.arrivalDeltaMicroseconds
            }

            public func makeSample() -> FeedbackReport.Dispersion.Sample {
                .init(
                    channel: ChannelId(rawValue: chan),
                    seq: ChannelSeq(rawValue: seq),
                    arrivalDeltaMicroseconds: deltaMicroseconds
                )
            }
        }

        public init(from dispersion: FeedbackReport.Dispersion) {
            self.baseHex = Hex.uint64String(dispersion.base.microseconds)
            self.samples = dispersion.samples.map(SampleFields.init(from:))
        }

        public func makeDispersion() throws -> FeedbackReport.Dispersion {
            guard let base = Hex.uint64(baseHex) else {
                throw VectorFileError.malformedField("baseHex")
            }
            return .init(
                base: ClientTimestamp(microseconds: base),
                samples: samples.map { $0.makeSample() }
            )
        }
    }

    public struct NackFields: Codable, Sendable {
        public var frame: UInt32
        public var missingShards: [UInt8]

        public init(from entry: FeedbackReport.NackEntry) {
            self.frame = entry.frame.rawValue
            self.missingShards = entry.missingShards
        }

        public func makeEntry() throws -> FeedbackReport.NackEntry {
            try .init(
                frame: FrameNumber(rawValue: frame),
                missingShards: missingShards
            )
        }
    }

    public init(from report: FeedbackReport) {
        self.pathId = report.pathId
        self.clientTimestampHex = Hex.uint64String(report.clientTimestamp.microseconds)
        let channels = report.channels.map(ChannelStatsFields.init(from:))
        self.channels = channels.isEmpty ? nil : channels
        self.dispersion = report.dispersion.map(DispersionFields.init(from:))
        let nacks = report.nacks.map(NackFields.init(from:))
        self.nacks = nacks.isEmpty ? nil : nacks
        let tlvs = report.extensions.map {
            TlvField(type: $0.type, valueHex: Hex.string($0.value))
        }
        self.tlvs = tlvs.isEmpty ? nil : tlvs
    }

    public func makeReport() throws -> FeedbackReport {
        guard let clientTimestamp = Hex.uint64(clientTimestampHex) else {
            throw VectorFileError.malformedField("clientTimestampHex")
        }
        let extensions = try (tlvs ?? []).map { tlv -> WireExtension in
            guard let value = Hex.bytes(tlv.valueHex) else {
                throw VectorFileError.malformedField("tlv valueHex")
            }
            return try WireExtension(type: tlv.type, value: value)
        }
        return FeedbackReport(
            pathId: pathId,
            clientTimestamp: ClientTimestamp(microseconds: clientTimestamp),
            channels: (channels ?? []).map { $0.makeStats() },
            dispersion: try dispersion?.makeDispersion(),
            nacks: try (nacks ?? []).map { try $0.makeEntry() },
            extensions: extensions
        )
    }
}

/// The README's beacon/echo offset+RTT computation as data: decoding
/// `echoHex` yields t1–t3, `hostReceiveHex` is the locally measured t4,
/// and `clockSample` must produce exactly these µs values.
public struct ClockWorkedExample: Codable, Sendable {
    public var description: String
    public var echoHex: String
    public var hostReceiveHex: String
    public var offsetMicroseconds: Int64
    public var rttMicroseconds: Int64

    public init(
        description: String,
        echoHex: String,
        hostReceiveHex: String,
        offsetMicroseconds: Int64,
        rttMicroseconds: Int64
    ) {
        self.description = description
        self.echoHex = echoHex
        self.hostReceiveHex = hostReceiveHex
        self.offsetMicroseconds = offsetMicroseconds
        self.rttMicroseconds = rttMicroseconds
    }
}

/// Stable names for `BeaconError` cases, as they appear in vector files.
public func beaconErrorName(_ error: BeaconError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .trailingBytes: return "trailingBytes"
    case .unexpectedType: return "unexpectedType"
    case .nonZeroAbsentEchoFields: return "nonZeroAbsentEchoFields"
    }
}

/// Stable names for `FeedbackError` cases, as they appear in vector files.
public func feedbackErrorName(_ error: FeedbackError) -> String {
    switch error {
    case .truncatedReport: return "truncatedReport"
    case .trailingBytes: return "trailingBytes"
    case .tooManyChannelBlocks: return "tooManyChannelBlocks"
    case .tooManyDispersionSamples: return "tooManyDispersionSamples"
    case .tooManyNackEntries: return "tooManyNackEntries"
    case .emptyDispersionSection: return "emptyDispersionSection"
    case .arrivalDeltaOutOfRange: return "arrivalDeltaOutOfRange"
    case .nonZeroBaseWithoutSamples: return "nonZeroBaseWithoutSamples"
    case .emptyNackShardList: return "emptyNackShardList"
    case .nackBitmapByteCountOutOfRange: return "nackBitmapByteCountOutOfRange"
    case .nonCanonicalNackBitmap: return "nonCanonicalNackBitmap"
    case .tooManyExtensions: return "tooManyExtensions"
    case .reportOverBudget: return "reportOverBudget"
    }
}
