// AudioDepacketizer (CL-11): the receive half of HS-15's audio wire —
// chan-1 datagrams in, ordered-enough 5 ms Opus packets out, with the
// RS 4+2 recovery the video path already trusts (the SAME FecDecoder;
// "audio's 4+2 expresses in the same field"). This file MIRRORS the
// HOST-PINNED layout in Host/Sources/HostWire/AudioFramer.swift
// byte-for-byte — both copies promote into Wire/ together (the
// 0x15/0x16 precedent); nothing here may move a wire byte.
//
// The mirrored contract, restated from the framer's pin:
//   • channel 1 (ChannelId.audio); one 5 ms Opus packet = one data
//     shard = one datagram payload, verbatim, zero interior framing.
//   • fec field = FecField.reedSolomon(shardIndex, geometry) — the
//     video-identical 8-byte interior; k data + m parity per group
//     (4 + 2 today; the geometry rides the wire, so this side follows
//     whatever the field declares).
//   • frame field = the FEC group id = the group's FIRST packet
//     number: packet n = frame + shardIndex (Vocabulary's two
//     readings holding at once).
//   • timestamp: data shards carry THEIR packet's capture µs (the
//     PipeWire graph clock); parity shards the group's FIRST packet's.
//     A reconstructed packet n derives its stamp as
//     groupFirstTs + (n − frame) × packetDuration — honest under the
//     hard-CBR dialect ("seq × packetDuration IS the sender media
//     timeline", audio-continuity §3).
//   • Data shards were emitted immediately by the sender (cadence
//     before protection), parity behind the group's 4th packet — so
//     recovery becomes possible at most ~3 packet durations after a
//     loss, which is what sizes the jitter buffer's reorder wait.
//
// Sans-IO: no clock reads, no locks (AudioReceiver owns the lock), no
// sockets. Recovery is attempted eagerly the moment any k distinct
// shards of a group are present — recovered bytes are byte-identical
// to the originals by RS construction, so an original arriving after
// its recovery is just a counted duplicate.

import LyteWire

/// The HS-15 audio ground truth this side decodes against (mirrors
/// Host/'s lyte_opus.h pins — 48 kHz stereo, 5 ms CELT-only frames).
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

public final class AudioDepacketizer {
    /// Groups kept in flight behind the newest — 8 groups of 4 packets
    /// = 160 ms, comfortably past any jitter the buffer would absorb.
    public let horizonGroups: Int

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

    public init(horizonGroups: Int = 8) {
        self.horizonGroups = max(horizonGroups, 2)
    }

    /// Feeds one accepted chan-1 datagram. Returns the packets it made
    /// available NOW: the shard's own packet when it is a fresh data
    /// shard, plus any packets a completed recovery rebuilt.
    public func ingest(envelope: Envelope, payload: [UInt8]) -> [AudioPacket] {
        stats.datagramsIngested += 1

        guard let field = try? FecField.decode(envelope.fec),
              case .reedSolomon(let shardIndex, let geometry) = field,
              Int(shardIndex) < geometry.totalShards
        else {
            stats.malformedDatagrams += 1
            return []
        }
        let index = Int(shardIndex)
        guard payload.count == geometry.wireByteCount(ofShard: index) else {
            stats.malformedDatagrams += 1
            return []
        }

        let groupId = envelope.frame.rawValue
        if let newest = newestGroupId {
            let age = Int32(bitPattern: newest &- groupId)
            if age > Int32(horizonGroups * geometry.dataShards) {
                stats.staleShards += 1
                return []
            }
            if Int32(bitPattern: groupId &- newest) > 0 {
                newestGroupId = groupId
                evictBeyondHorizon(dataShards: geometry.dataShards)
            }
        } else {
            newestGroupId = groupId
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

        if group.missingDataIndices.isEmpty {
            // Every data packet is out; the group only lingers to
            // absorb late duplicates, which the horizon handles.
            groups[groupId] = group
        } else {
            groups[groupId] = group
        }
        return out
    }

    public func snapshotStats() -> AudioDepacketizerStats { stats }

    // MARK: - Interior

    /// Runs the RS decode the moment k distinct shards exist and data
    /// packets are still missing. Rebuilt packets stamp as
    /// firstTs + index × 5 ms (the framer's derivation rule).
    private func recoverIfPossible(
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
    private func evictBeyondHorizon(dataShards: Int) {
        guard let newest = newestGroupId else { return }
        let horizon = Int32(horizonGroups * dataShards)
        for (id, group) in groups {
            guard Int32(bitPattern: newest &- id) > horizon else { continue }
            let missing = group.missingDataIndices.count
            if missing > 0 {
                stats.groupsUnrecoverable += 1
                stats.packetsUnrecoverable += UInt64(missing)
            }
            groups.removeValue(forKey: id)
        }
    }
}
