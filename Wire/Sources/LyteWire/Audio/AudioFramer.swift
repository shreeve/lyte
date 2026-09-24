// AudioFramer: 5 ms Opus packets → audio-channel datagrams under the
// Lyte-UDP envelope, with a 4+2 Reed-Solomon interleave through the same
// FEC machinery video uses (FecField, FecGeometry, FecEncoder). Sans-IO:
// capture timestamps are injected; the caller owns pacing, sealing and
// syscalls. It composes frozen formats and changes none of them; the
// layout is pinned as hand-built bytes in AudioInteriorTests.
//
// Wire layout:
//
//   • channel: ChannelId.audio (unreliable, WirePriority.audio).
//   • One 5 ms Opus packet = one data shard = one datagram payload,
//     verbatim. Under hard CBR all packets of a group are the same size,
//     so the balanced split's shards ARE the packets. A mid-group size
//     change would shear shard boundaries off packet boundaries, so the
//     framer closes the open group without parity and opens a fresh one.
//   • FEC group: 4 consecutive packets + 2 parity shards (counts are
//     config); the fec field carries FecField.reedSolomon(shardIndex,
//     geometry), the same 8-byte interior video uses.
//   • frame field = FEC group id = packet number of the group's first
//     packet: a data shard's packet number is frame + shardIndex, and all
//     six shards agree on the group id recovery keys by.
//   • timestamp: a data shard carries its packet's capture µs (PipeWire
//     graph clock, never wall clock); parity shards carry the group's
//     FIRST packet's stamp, so a recovered packet n is stamped
//     groupFirstTs + (n − frame) × packetDuration.
//   • seq: per-channel u16 in emit order; parity follows the last data
//     shard immediately, so seqs are contiguous per group.
//   • A data shard emits IMMEDIATELY on ingest (the 5 ms cadence is the
//     receiver's clock and the path's delay probe); parity emits when the
//     group completes. A stream ending mid-group leaves parity unsent.

public struct AudioFramerConfig: Sendable {
    public var channel: ChannelId
    public var firstSeq: ChannelSeq
    public var firstPacketNumber: FrameNumber
    /// The RS interleave (default 4 + 2).
    public var dataShardsPerGroup: Int
    public var parityShardsPerGroup: Int
    /// When set, every audio datagram carries the connection-ID TLV.
    public var connectionId: ConnectionId?

    public init(
        channel: ChannelId = .audio,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        firstPacketNumber: FrameNumber = FrameNumber(rawValue: 0),
        dataShardsPerGroup: Int = 4,
        parityShardsPerGroup: Int = 2,
        connectionId: ConnectionId? = nil
    ) {
        precondition(dataShardsPerGroup >= 1)
        precondition(parityShardsPerGroup >= 0)
        precondition(dataShardsPerGroup + parityShardsPerGroup <= 255)
        self.channel = channel
        self.firstSeq = firstSeq
        self.firstPacketNumber = firstPacketNumber
        self.dataShardsPerGroup = dataShardsPerGroup
        self.parityShardsPerGroup = parityShardsPerGroup
        self.connectionId = connectionId
    }

    /// The TLV block bytes every datagram of this config carries.
    var tlvBlockByteCount: Int {
        connectionId == nil ? 0 : 1 + 2 + ConnectionId.byteCount
    }

    /// The largest Opus packet one datagram can carry under this
    /// config's per-datagram overhead, AEAD tag reserved unconditionally
    /// (geometry never depends on crypto).
    public var packetBudgetByteCount: Int {
        min(
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxWirePayloadByteCount
                - WireBudget.aeadTagByteCount
                - tlvBlockByteCount
        )
    }
}

public enum AudioFramerError: Error, Equatable, Sendable {
    case emptyPacket
    case packetOverBudget(Int)
}

/// Lifetime totals, `UInt64` like `AudioDepacketizerStats` so a 32-bit
/// (wasm32) `Int` cannot overflow on a long-running stream.
public struct AudioFramerCounters: Equatable, Sendable {
    public var packetsIngested: UInt64 = 0
    public var groupsCompleted: UInt64 = 0
    /// Groups closed early without parity: by a packet size change
    /// mid-group, or by `abandonOpenGroup()`.
    public var groupsAbandoned: UInt64 = 0
    public var datagramsFramed: UInt64 = 0

    public init() {}
}

public struct AudioFramer: Sendable {
    public let config: AudioFramerConfig
    public private(set) var counters = AudioFramerCounters()

    /// The next audio-channel seq (emit order; contiguous per group).
    public private(set) var nextSeq: ChannelSeq
    /// The next packet's number (the frame-field domain).
    public private(set) var nextPacketNumber: FrameNumber

    /// The open group's data shards so far: the packets verbatim plus
    /// the capture stamp of the FIRST one (the parity timestamp).
    private var groupPackets: [[UInt8]] = []
    private var groupFirstPacketNumber: FrameNumber
    private var groupFirstCaptureMicros: UInt64 = 0

    public init(config: AudioFramerConfig) {
        self.config = config
        self.nextSeq = config.firstSeq
        self.nextPacketNumber = config.firstPacketNumber
        self.groupFirstPacketNumber = config.firstPacketNumber
        self.groupPackets.reserveCapacity(config.dataShardsPerGroup)
    }

    /// Frames one encoded Opus packet. Returns the datagrams to emit
    /// NOW, in send order: always the packet's own data shard, plus
    /// the group's parity shards when this packet completes it. A packet
    /// whose size differs from the open group's closes that group
    /// without parity and opens a fresh one. Throws on an empty or
    /// over-budget packet. `captureTimestampMicroseconds` is the
    /// packet's first sample's PipeWire graph-clock stamp; it rides the
    /// envelope timestamp verbatim.
    public mutating func ingest(
        packet: [UInt8],
        captureTimestampMicroseconds: UInt64
    ) throws -> [(envelope: Envelope, payload: [UInt8])] {
        guard !packet.isEmpty else {
            throw AudioFramerError.emptyPacket
        }
        guard packet.count <= config.packetBudgetByteCount else {
            throw AudioFramerError.packetOverBudget(packet.count)
        }
        if let first = groupPackets.first, first.count != packet.count {
            abandonOpenGroup()
        }

        // The geometry the whole group advertises, promised at its
        // first packet under the CBR contract: k equal-size shards,
        // shardByteCount = packet.count exactly.
        let geometry = try FecGeometry(
            dataShards: config.dataShardsPerGroup,
            parityShards: config.parityShardsPerGroup,
            groupByteCount: packet.count * config.dataShardsPerGroup
        )

        if groupPackets.isEmpty {
            groupFirstPacketNumber = nextPacketNumber
            groupFirstCaptureMicros = captureTimestampMicroseconds
        }
        let shardIndex = groupPackets.count
        groupPackets.append(packet)
        nextPacketNumber = nextPacketNumber.next
        counters.packetsIngested += 1

        var out: [(envelope: Envelope, payload: [UInt8])] = [(
            try makeEnvelope(
                shardIndex: shardIndex,
                geometry: geometry,
                timestamp: captureTimestampMicroseconds
            ),
            packet
        )]

        if groupPackets.count == config.dataShardsPerGroup {
            out += try completeGroup(geometry: geometry)
        }
        counters.datagramsFramed += UInt64(out.count)
        return out
    }

    /// Closes the open group without parity; `ingest` does this itself
    /// when the packet size changes mid-group. Only that group's loss
    /// protection is forfeit; the next packet opens a fresh group
    /// (receivers key groups by the frame field and never assume
    /// alignment). Returns false when no group was open.
    @discardableResult
    public mutating func abandonOpenGroup() -> Bool {
        guard !groupPackets.isEmpty else { return false }
        groupPackets.removeAll(keepingCapacity: true)
        counters.groupsAbandoned += 1
        return true
    }

    /// Parity shards, stamped with the group's first capture µs.
    private mutating func completeGroup(
        geometry: FecGeometry
    ) throws -> [(envelope: Envelope, payload: [UInt8])] {
        defer {
            groupPackets.removeAll(keepingCapacity: true)
            counters.groupsCompleted += 1
        }
        guard config.parityShardsPerGroup > 0 else { return [] }

        var group = [UInt8]()
        group.reserveCapacity(geometry.groupByteCount)
        for packet in groupPackets {
            group.append(contentsOf: packet)
        }
        // Only the parity suffix is new; the data shards are the packets.
        let shards = try FecEncoder.encode(group: group, geometry: geometry)

        var out: [(envelope: Envelope, payload: [UInt8])] = []
        out.reserveCapacity(config.parityShardsPerGroup)
        for index in geometry.dataShards..<geometry.totalShards {
            out.append((
                try makeEnvelope(
                    shardIndex: index,
                    geometry: geometry,
                    timestamp: groupFirstCaptureMicros
                ),
                shards[index]
            ))
        }
        return out
    }

    private mutating func makeEnvelope(
        shardIndex: Int,
        geometry: FecGeometry,
        timestamp: UInt64
    ) throws -> Envelope {
        let field = try FecField.reedSolomonShard(shardIndex, of: geometry)
        var envelope = Envelope(
            channel: config.channel,
            seq: nextSeq,
            frame: groupFirstPacketNumber,
            timestamp: timestamp,
            fec: field.encoded
        )
        if let connectionId = config.connectionId {
            envelope.extensions.append(connectionId.wireExtension)
        }
        nextSeq = nextSeq.next
        return envelope
    }
}
