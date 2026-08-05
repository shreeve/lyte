// The Lyte-UDP datagram envelope, exactly as the overview §2 pins it.
// All multi-byte fields are little-endian — both ends are ours, no
// network-order tax. 24 bytes fixed:
//
//   offset size field
//   0      1    chan       channel number (ChannelId registry)
//   1      1    flags      bit0: TLV block present; bits 1–7 reserved,
//                          MUST be 0 on send, ignored on receive
//   2      2    seq        per-channel datagram sequence (serial u16)
//   4      4    frame      frame number / audio packet number / FEC group id
//   8      8    timestamp  µs; host PipeWire monotonic domain on host-sent
//                          datagrams, client monotonic on client-sent —
//                          apply WireTimestamp<Domain> at the ends
//   16     8    fec        FEC field; interior layout and codec in
//                          FecField.swift (W1)
//   24     …    [TLV block when flags bit0] then payload
//
// The header (fixed 24 bytes plus any TLV block) rides as AAD; the payload
// is the AEAD ciphertext + authentication tag in a live session. Bare
// shards exist only as frozen-vector/test equipment. Budgets are enforced
// at encode time: 1112 B per
// plaintext shard, 1128 B per wire payload, 1152 B per datagram.

public struct Envelope: Hashable, Sendable {
    public var channel: ChannelId
    public var seq: ChannelSeq
    public var frame: FrameNumber
    /// Raw µs value of the sender's clock domain; see the layout comment.
    public var timestamp: UInt64
    /// The 8-byte FEC field as its little-endian u64 image; the interior
    /// layout is `FecField`'s (decode on demand — most channels carry 0).
    public var fec: UInt64
    /// TLV extensions, in wire order, unknown types preserved verbatim.
    public var extensions: [WireExtension]

    public init(
        channel: ChannelId,
        seq: ChannelSeq,
        frame: FrameNumber,
        timestamp: UInt64,
        fec: UInt64,
        extensions: [WireExtension] = []
    ) {
        self.channel = channel
        self.seq = seq
        self.frame = frame
        self.timestamp = timestamp
        self.fec = fec
        self.extensions = extensions
    }

    private static let extensionsFlag: UInt8 = 0x01

    /// Header size on the wire: the fixed 24 bytes plus the TLV block.
    public var headerByteCount: Int {
        var count = WireBudget.envelopeByteCount
        if !extensions.isEmpty {
            count += 1 + extensions.reduce(0) { $0 + $1.encodedByteCount }
        }
        return count
    }

    // MARK: Encode

    /// Encodes header + wire payload (ciphertext + tag, or the bare shard in
    /// insecure mode). Rejects payloads over 1128 B and datagrams over
    /// 1152 B — exact enforcement is gate W-G1's requirement.
    public func encode(payload: ArraySlice<UInt8>) throws -> [UInt8] {
        guard payload.count <= WireBudget.maxWirePayloadByteCount else {
            throw WireError.payloadOverBudget(payload.count)
        }
        guard extensions.count <= 0xFF else {
            throw WireError.tooManyExtensions
        }
        let total = headerByteCount + payload.count
        guard total <= WireBudget.maxDatagramByteCount else {
            throw WireError.datagramOverBudget(total)
        }

        var out = [UInt8]()
        out.reserveCapacity(total)
        out.append(channel.rawValue)
        out.append(extensions.isEmpty ? 0 : Self.extensionsFlag)
        appendLE(seq.rawValue, to: &out)
        appendLE(frame.rawValue, to: &out)
        appendLE(timestamp, to: &out)
        appendLE(fec, to: &out)
        if !extensions.isEmpty {
            out.append(UInt8(extensions.count))
            for ext in extensions {
                out.append(ext.type)
                out.append(UInt8(ext.value.count))
                out.append(contentsOf: ext.value)
            }
        }
        out.append(contentsOf: payload)
        return out
    }

    public func encode(payload: [UInt8] = []) throws -> [UInt8] {
        try encode(payload: payload[...])
    }

    /// Encodes a plaintext shard, additionally enforcing the 1112 B shard
    /// budget so FEC geometry and gate results are identical with and
    /// without crypto (master plan §4.2).
    public func encode(plaintextShard: ArraySlice<UInt8>) throws -> [UInt8] {
        guard plaintextShard.count <= WireBudget.maxPlaintextShardByteCount else {
            throw WireError.shardOverBudget(plaintextShard.count)
        }
        return try encode(payload: plaintextShard)
    }

    public func encode(plaintextShard: [UInt8]) throws -> [UInt8] {
        try encode(plaintextShard: plaintextShard[...])
    }

    // MARK: Decode

    /// Decodes a received datagram into its envelope and payload slice.
    /// Throws on truncation, on a promised-but-missing TLV block, and on
    /// datagrams over the 1152 B budget; never traps on hostile bytes.
    /// Reserved flag bits are ignored, and unknown TLV types decode
    /// successfully — skipping them is the consumer's job.
    public static func decode(
        _ datagram: ArraySlice<UInt8>
    ) throws -> (envelope: Envelope, payload: ArraySlice<UInt8>) {
        guard datagram.count <= WireBudget.maxDatagramByteCount else {
            throw WireError.datagramOverBudget(datagram.count)
        }
        guard datagram.count >= WireBudget.envelopeByteCount else {
            throw WireError.truncatedEnvelope
        }

        let base = datagram.startIndex
        let channel = ChannelId(rawValue: datagram[base])
        let flags = datagram[base + 1]
        let seq = ChannelSeq(rawValue: readLE(datagram, at: base + 2))
        let frame = FrameNumber(rawValue: readLE(datagram, at: base + 4))
        let timestamp: UInt64 = readLE(datagram, at: base + 8)
        let fec: UInt64 = readLE(datagram, at: base + 16)

        var cursor = base + WireBudget.envelopeByteCount
        var extensions: [WireExtension] = []
        if flags & extensionsFlag != 0 {
            guard cursor < datagram.endIndex else {
                throw WireError.truncatedExtensions
            }
            let count = Int(datagram[cursor])
            cursor += 1
            extensions.reserveCapacity(count)
            for _ in 0..<count {
                guard cursor + 2 <= datagram.endIndex else {
                    throw WireError.truncatedExtensions
                }
                let type = datagram[cursor]
                let length = Int(datagram[cursor + 1])
                cursor += 2
                guard cursor + length <= datagram.endIndex else {
                    throw WireError.truncatedExtensions
                }
                extensions.append(
                    try WireExtension(
                        type: type,
                        value: Array(datagram[cursor..<cursor + length])
                    )
                )
                cursor += length
            }
        }

        let envelope = Envelope(
            channel: channel,
            seq: seq,
            frame: frame,
            timestamp: timestamp,
            fec: fec,
            extensions: extensions
        )
        return (envelope, datagram[cursor...])
    }

    public static func decode(
        _ datagram: [UInt8]
    ) throws -> (envelope: Envelope, payload: ArraySlice<UInt8>) {
        try decode(datagram[...])
    }
}

// MARK: - Little-endian primitives

private func appendLE(_ value: UInt16, to out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: value))
    out.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendLE(_ value: UInt32, to out: inout [UInt8]) {
    for shift in stride(from: 0, to: 32, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

private func appendLE(_ value: UInt64, to out: inout [UInt8]) {
    for shift in stride(from: 0, to: 64, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

private func readLE<T: FixedWidthInteger & UnsignedInteger>(
    _ bytes: ArraySlice<UInt8>, at index: Int
) -> T {
    var value: T = 0
    for i in 0..<(T.bitWidth / 8) {
        value |= T(bytes[index + i]) << (8 * i)
    }
    return value
}
