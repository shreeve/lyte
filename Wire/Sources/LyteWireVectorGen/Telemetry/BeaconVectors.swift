// The beacon/feedback vector-file model and loader:
// `Wire/Vectors/beacon-v1.json`.

import LyteCore
import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/beacon-v1.json`, the beacon pair, the
/// feedback report, and the clock worked example.
public struct BeaconVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var beaconVectors: [BeaconVector]
    public var feedbackVectors: [FeedbackVector]
    /// The README's offset/RTT computation, as checkable data.
    public var clockWorkedExample: ClockWorkedExample

    public static let expectedFormat = "lyte-wire-beacon-vectors"
    public static let fileName = "beacon-v1.json"

    public var vectorNameGroups: [[String]] {
        [beaconVectors.map(\.name), feedbackVectors.map(\.name)]
    }
}

/// One CTRL beacon-pair vector. `decoder` names the codec under test.
/// Kinds match the envelope file: `roundtrip`, `decodeLenient` (reserved
/// flag bits), and `decodeReject` (`error` is a BeaconError case name).
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
        ClockBeacon(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(
                microseconds: try vectorU64(hostSendHex, "hostSendHex")
            ),
            lastEcho: try lastEcho.map { fields in
                ClockBeacon.LastEcho(
                    beaconSeq: fields.beaconSeq,
                    clientSend: ClientTimestamp(microseconds: try vectorU64(
                        fields.clientSendHex, "lastEcho clientSendHex"
                    )),
                    hostReceive: HostTimestamp(microseconds: try vectorU64(
                        fields.hostReceiveHex, "lastEcho hostReceiveHex"
                    ))
                )
            }
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
        BeaconEcho(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(
                microseconds: try vectorU64(hostSendHex, "hostSendHex")
            ),
            clientReceive: ClientTimestamp(
                microseconds: try vectorU64(clientReceiveHex, "clientReceiveHex")
            ),
            clientSend: ClientTimestamp(
                microseconds: try vectorU64(clientSendHex, "clientSendHex")
            )
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
            .init(
                base: ClientTimestamp(
                    microseconds: try vectorU64(baseHex, "baseHex")
                ),
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
        self.tlvs = tlvFields(report.extensions)
    }

    public func makeReport() throws -> FeedbackReport {
        FeedbackReport(
            pathId: pathId,
            clientTimestamp: ClientTimestamp(microseconds: try vectorU64(
                clientTimestampHex, "clientTimestampHex"
            )),
            channels: (channels ?? []).map { $0.makeStats() },
            dispersion: try dispersion?.makeDispersion(),
            nacks: try (nacks ?? []).map { try $0.makeEntry() },
            extensions: try wireExtensions(tlvs)
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
}
