// AudioDepacketizer: the receive half of the audio wire (AudioFramer.swift
// documents the layout) — chan-1 datagrams in, 5 ms Opus packets out,
// with RS recovery through the same FecDecoder video uses. The geometry
// rides the wire, so this side follows whatever the fec field declares.
//
// Parity follows a group's last data packet, so recovery is possible at
// most ~3 packet durations after a loss; that sizes the jitter buffer's
// reorder wait. Recovery runs eagerly once any k distinct shards of a
// group are present; recovered bytes are byte-identical to the originals,
// so an original arriving afterwards is a counted duplicate. Sans-IO.

/// The audio format both ends code against: 48 kHz stereo, 5 ms
/// CELT-only frames.
public enum AudioWire {
    public static let sampleRate = 48_000
    public static let channels = 2
    /// Samples per channel per packet: 5 ms at 48 kHz.
    public static let samplesPerPacket = 240
    public static let packetDurationMicroseconds: UInt64 = 5_000
}

/// One depacketized 5 ms Opus packet, in the frame-field number domain.
public struct AudioPacket: Equatable, Sendable {
    /// The audio-doc packet number: frame + shardIndex.
    public var number: UInt32
    /// The packet's first sample's capture µs (host graph clock) —
    /// verbatim from the envelope for arrived packets, derived for
    /// recovered ones.
    public var captureMicroseconds: UInt64
    public var bytes: [UInt8]
    /// True when FEC rebuilt this packet instead of the wire carrying it.
    public var recovered: Bool

    public init(
        number: UInt32, captureMicroseconds: UInt64,
        bytes: [UInt8], recovered: Bool
    ) {
        self.number = number
        self.captureMicroseconds = captureMicroseconds
        self.bytes = bytes
        self.recovered = recovered
    }
}

public struct AudioDepacketizerStats: Equatable, Sendable {
    public var datagramsIngested: UInt64 = 0
    /// Packets handed downstream (arrived + rebuilt).
    public var packetsEmitted: UInt64 = 0
    /// Packets FEC reconstructed (subset of packetsEmitted).
    public var packetsRebuilt: UInt64 = 0
    /// Groups where recovery ran and rebuilt at least one packet.
    public var groupsRecovered: UInt64 = 0
    /// Groups evicted still missing data packets — honest loss.
    public var groupsUnrecoverable: UInt64 = 0
    /// Data packets those evicted groups never yielded.
    public var packetsUnrecoverable: UInt64 = 0
    /// Shards for already-emitted packets / already-stored slots.
    public var duplicateShards: UInt64 = 0
    /// Wrong-size payloads, non-RS fec fields, hostile shard indices.
    public var malformedDatagrams: UInt64 = 0
    /// Shards for groups older than the tracking horizon.
    public var staleShards: UInt64 = 0

    public init() {}
}

public struct AudioDepacketizer: Sendable {
    /// Groups kept in flight behind the newest — 8 groups of 4 packets
    /// = 160 ms, comfortably past any jitter the buffer would absorb.
    public let horizonGroups: Int
    /// The retention horizon in packet numbers — local policy fixed at
    /// init from the nominal group size. It must never follow an arriving
    /// shard's declared geometry: a k=1 shard would shrink retention 4×
    /// and a k=254 shard would widen admission ~64×.
    private let horizonPackets: UInt32
    /// The most groups ever retained: twice the nominal horizon's group
    /// count. Honest traffic keeps `horizonGroups + 1`; a peer declaring
    /// small groups at every packet number inside the horizon hits this
    /// cap and the oldest group makes room.
    private let maxGroups: Int

    public private(set) var stats = AudioDepacketizerStats()

    private struct Group {
        var geometry: FecGeometry
        var slots: [[UInt8]?]
        var emitted: [Bool]          // data shards already handed out
        var firstCaptureMicroseconds: UInt64?
        var recoveredOnce = false

        init(geometry: FecGeometry) {
            self.geometry = geometry
            self.slots = [[UInt8]?](repeating: nil, count: geometry.totalShards)
            self.emitted = [Bool](repeating: false, count: geometry.dataShards)
        }

        var presentShards: Int { slots.lazy.filter { $0 != nil }.count }
        var missingDataIndices: [Int] {
            (0..<geometry.dataShards).filter { !emitted[$0] }
        }
    }

    private var groups: [UInt32: Group] = [:]
    private var newestGroupId: UInt32?

    public init(horizonGroups: Int = 8, nominalDataShards: Int = 4) {
        self.horizonGroups = max(horizonGroups, 2)
        self.horizonPackets = UInt32(
            self.horizonGroups * max(nominalDataShards, 1))
        self.maxGroups = 2 * self.horizonGroups
    }

    /// Groups currently held; never above twice `horizonGroups`.
    public var trackedGroupCount: Int { groups.count }

    /// Feeds one accepted chan-1 datagram. Returns the packets it made
    /// available NOW: the shard's own packet when it is a fresh data
    /// shard, plus any packets a completed recovery rebuilt.
    public mutating func ingest(envelope: Envelope, payload: [UInt8]) -> [AudioPacket] {
        stats.datagramsIngested += 1

        guard let field = try? FecField.decode(envelope.fec),
              case .reedSolomon(let shardIndex, let geometry) = field
        else {
            stats.malformedDatagrams += 1
            return []
        }
        let index = Int(shardIndex)
        guard payload.count == geometry.wireByteCount(ofShard: index) else {
            stats.malformedDatagrams += 1
            return []
        }

        // Serial distances are judged unsigned so no id is both "not
        // behind" and "not ahead": an id within the horizon behind the
        // newest (or equal) is admitted, one up to 2³¹ − 1 ahead advances
        // the newest, and everything else — the exact 2³¹ antipode
        // included — is stale.
        let groupId = envelope.frame.rawValue
        if let newest = newestGroupId {
            if newest &- groupId > horizonPackets {
                guard groupId &- newest <= UInt32(Int32.max) else {
                    stats.staleShards += 1
                    return []
                }
                newestGroupId = groupId
                evictBeyondHorizon()
            }
        } else {
            newestGroupId = groupId
        }

        if groups[groupId] == nil, groups.count >= maxGroups {
            evictOldest()
        }
        var group = groups[groupId] ?? Group(geometry: geometry)
        guard group.geometry == geometry else {
            // A group's six shards all advertise one geometry; a
            // disagreeing shard is hostile or corrupt.
            stats.malformedDatagrams += 1
            return []
        }
        guard group.slots[index] == nil else {
            stats.duplicateShards += 1
            return []
        }
        group.slots[index] = payload

        var out: [AudioPacket] = []
        if geometry.isParityShard(index) {
            // Parity carries the group's FIRST packet's capture µs.
            if group.firstCaptureMicroseconds == nil {
                group.firstCaptureMicroseconds = envelope.timestamp
            }
        } else {
            // A data shard IS its packet, stamped with its own µs; the
            // group-first stamp derives back under CBR when shard 0 is
            // the one the network ate.
            if group.firstCaptureMicroseconds == nil {
                group.firstCaptureMicroseconds = envelope.timestamp
                    &- UInt64(index) &* AudioWire.packetDurationMicroseconds
            }
            if !group.emitted[index] {
                group.emitted[index] = true
                stats.packetsEmitted += 1
                out.append(AudioPacket(
                    number: groupId &+ UInt32(index),
                    captureMicroseconds: envelope.timestamp,
                    bytes: payload,
                    recovered: false))
            } else {
                stats.duplicateShards += 1
            }
        }

        out += recoverIfPossible(&group, groupId: groupId)

        // A group whose data packets are all out still lingers, to absorb
        // late duplicates until the horizon evicts it.
        groups[groupId] = group
        return out
    }

    public func snapshotStats() -> AudioDepacketizerStats { stats }

    // MARK: - Interior

    /// Runs the RS decode the moment k distinct shards exist and data
    /// packets are still missing. Rebuilt packets stamp as
    /// firstTs + index × 5 ms (the framer's derivation rule).
    private mutating func recoverIfPossible(
        _ group: inout Group, groupId: UInt32
    ) -> [AudioPacket] {
        let missing = group.missingDataIndices
        guard !missing.isEmpty,
              group.presentShards >= group.geometry.dataShards,
              let firstMicros = group.firstCaptureMicroseconds,
              let decoded = try? FecDecoder.decode(
                  shards: group.slots, geometry: group.geometry)
        else { return [] }

        var out: [AudioPacket] = []
        for index in missing {
            let range = group.geometry.byteRange(ofDataShard: index)
            let bytes = Array(decoded[range])
            group.slots[index] = bytes
            group.emitted[index] = true
            stats.packetsEmitted += 1
            stats.packetsRebuilt += 1
            out.append(AudioPacket(
                number: groupId &+ UInt32(index),
                captureMicroseconds: firstMicros
                    &+ UInt64(index) &* AudioWire.packetDurationMicroseconds,
                bytes: bytes,
                recovered: true))
        }
        if !group.recoveredOnce {
            group.recoveredOnce = true
            stats.groupsRecovered += 1
        }
        return out
    }

    /// Drops groups older than the horizon behind the newest, counting
    /// the honest losses (missing data the wire never yielded).
    private mutating func evictBeyondHorizon() {
        guard let newest = newestGroupId else { return }
        for id in groups.keys where newest &- id > horizonPackets {
            evict(id)
        }
    }

    /// Makes room at the group cap: every retained id is within the
    /// horizon behind the newest, so the largest unsigned age is oldest.
    private mutating func evictOldest() {
        guard let newest = newestGroupId,
              let oldest = groups.keys.max(by: { newest &- $0 < newest &- $1 })
        else { return }
        evict(oldest)
    }

    private mutating func evict(_ id: UInt32) {
        guard let group = groups.removeValue(forKey: id) else { return }
        let missing = group.missingDataIndices.count
        if missing > 0 {
            stats.groupsUnrecoverable += 1
            stats.packetsUnrecoverable += UInt64(missing)
        }
    }
}
