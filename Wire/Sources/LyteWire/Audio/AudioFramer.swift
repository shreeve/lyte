// AudioFramer (HS-15 → CL-11, promoted home by the second
// codec-promotion slice — the bytes never changed): 5 ms Opus packets
// from the host capture path → audio-channel datagrams under the
// Lyte-UDP envelope, with the resiliency pillar's 4+2 Reed-Solomon
// interleave expressed through the SAME frozen machinery video uses
// (FecField, FecGeometry, FecEncoder — the nanors codebook). Sans-IO:
// no sockets, no threads, no clock — capture timestamps are injected,
// the caller owns pacing and syscalls. This file COMPOSES frozen wire
// formats for the audio channel; it changes none of them (which is why
// it carries no vector file of its own — the envelope/fec vectors own
// the bytes beneath it, and the layout is pinned as hand-built bytes
// in AudioInteriorTests and both ends' gates).
//
// The wire layout (pinned host-side at HS-15, byte-mirrored client-side
// at CL-11, canonical here):
//
//   • channel: 1 (ChannelId.audio — unreliable, WirePriority.audio).
//   • One 5 ms Opus packet = one data shard = one datagram payload,
//     verbatim, zero interior framing. Under hard CBR (the dialect —
//     DTX off, constant packet bytes; HS-14's encoder pins it) all
//     four packets of a group are the same size, so the W1 balanced
//     split's shards ARE the packets: shardByteCount = group/4 =
//     packetBytes exactly, and the trailing-shard remainder case never
//     arises. The framer ENFORCES the CBR contract — a mid-group size
//     change throws loud, because it would silently shear shard
//     boundaries off packet boundaries.
//   • FEC group: 4 consecutive packets + 2 parity shards
//     (resiliency §1.2: keep 4+2 unchanged; the future knob is the
//     ratio, e.g. 4+4, which is why the counts live in config). The
//     fec field carries FecField.reedSolomon(shardIndex, geometry) —
//     the identical 8-byte interior video uses (overview §2: "Audio's
//     4+2 RS expresses in the same field").
//   • frame field = the FEC group id = the PACKET NUMBER of the
//     group's first packet (groups sit at packet numbers 0, 4, 8, …).
//     Vocabulary.swift says the frame field is "the audio-doc packet
//     number for audio, and the FEC group id for both" — this layout
//     is how both readings hold at once: a data shard's packet number
//     is frame + shardIndex, and all six shards of a group agree on
//     the group id the assembler keys recovery by.
//   • timestamp: a data shard carries ITS packet's capture µs (the
//     PipeWire graph clock, per the audio-continuity decision §4.3 —
//     never wall clock); parity shards carry the group's FIRST
//     packet's capture µs (they correspond to no single packet; a
//     receiver reconstructing a lost packet n derives its stamp as
//     groupFirstTs + (n − frame) × packetDuration, and the audio doc's
//     "seq × packetDuration IS the sender media timeline" makes that
//     honest under CBR).
//   • seq: per-channel u16, allocated in emit order — data shards at
//     their capture instants, the two parity shards immediately after
//     the fourth data shard, so seqs are contiguous per group by
//     construction.
//   • Emission order is load-bearing: a data shard emits IMMEDIATELY
//     on ingest — the 5 ms cadence is the receiver's clock and the
//     path's always-on delay probe (resiliency §2), so FEC grouping
//     must never delay a packet. Parity emits only when the group
//     completes. A stream ending mid-group leaves parity unsent: data
//     shards are self-sufficient (each IS one packet), so only the
//     tail group's loss protection is forfeit.
//
// Sealing is the caller's (the host Session's) job — same
// header-bytes-as-AAD discipline as every other datagram; this framer
// emits (envelope, plaintext payload) pairs so the layout is pinnable
// without crypto.

public struct AudioFramerConfig: Sendable {
    public var channel: ChannelId
    public var firstSeq: ChannelSeq
    public var firstPacketNumber: FrameNumber
    /// The RS interleave: resiliency §1.2 pins 4 + 2; the ratio is the
    /// future WAN knob, so the counts are config, not constants.
    public var dataShardsPerGroup: Int
    public var parityShardsPerGroup: Int
    /// HS-12: when set, every audio datagram carries the connection-ID
    /// TLV like every other session datagram (QUIC's every-packet rule).
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

    /// The TLV block bytes every datagram of this config carries
    /// (VideoChannelConfig's accounting, mirrored).
    var tlvBlockByteCount: Int {
        connectionId == nil ? 0 : 1 + 2 + ConnectionId.byteCount
    }

    /// The largest Opus packet one datagram can carry under this
    /// config's real per-datagram overhead — the AEAD tag reserved
    /// unconditionally (the §4.2 geometry-never-depends-on-crypto
    /// rule). A 5 ms packet at 128 kbps is ~80 B; this ceiling exists
    /// for loud enforcement, not because it is ever near.
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
    /// The hard-CBR contract broke: a packet's size differs from the
    /// size the open group was promised at its first packet. Loud,
    /// because the already-emitted geometry advertised shard
    /// boundaries that would no longer align to packet boundaries.
    case packetSizeChangedMidGroup(expected: Int, actual: Int)
}

public struct AudioFramerCounters: Equatable, Sendable {
    public var packetsIngested = 0
    public var groupsCompleted = 0
    public var datagramsFramed = 0

    public init() {}
}

public final class AudioFramer {
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
    /// the group's parity shards when this packet completes it. Throws
    /// on an empty/over-budget packet and on a CBR-contract violation —
    /// loud, per the W2 rule. `captureTimestampMicroseconds` is the
    /// packet's first sample's PipeWire graph-clock stamp; it rides the
    /// envelope timestamp verbatim.
    public func ingest(
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
            throw AudioFramerError.packetSizeChangedMidGroup(
                expected: first.count, actual: packet.count
            )
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
        counters.datagramsFramed += out.count
        return out
    }

    /// The group is full: parity shards ride out right behind the
    /// fourth data shard, stamped with the group's first capture µs.
    private func completeGroup(
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
        // FecEncoder returns k data + m parity; the data shards are the
        // packets verbatim by the balanced-split/CBR alignment — only
        // the parity suffix is new bytes.
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

    private func makeEnvelope(
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
