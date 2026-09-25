// Shared byte fixtures and field parsers for the vector files.

import LyteCore
import LyteWire

/// `count` bytes counting up from `offset`, wrapping at 256 — the
/// recognizable payload most vectors carry.
func counting(from offset: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8((offset + $0) & 0xFF) }
}

/// `count` printable-ASCII characters cycling byte i = 0x20 + i mod 0x5F,
/// auditable by eye in a hex dump.
func printableASCII(count: Int) -> String {
    String(decoding: (0..<count).map { UInt8(0x20 + $0 % 0x5F) }, as: UTF8.self)
}

/// The hex of a fixed video datagram (chan 2, seq 7, frame 3, t = 1 s,
/// shard `01 02 03`) carrying `extensions` — the carrier every TLV-value
/// codec vector rides.
func tlvCarrierDatagram(_ extensions: [WireExtension]) throws -> String {
    Hex.string(try Envelope(
        channel: .videoActive, seq: ChannelSeq(rawValue: 7),
        frame: FrameNumber(rawValue: 3), timestamp: 1_000_000, fec: 0,
        extensions: extensions
    ).encode(plaintextShard: [1, 2, 3]))
}

/// A vector file's hex u64 field, or `malformedField(field)`.
func vectorU64(_ hex: String, _ field: String) throws -> UInt64 {
    guard let value = Hex.uint64(hex) else {
        throw VectorFileError.malformedField(field)
    }
    return value
}

/// A vector file's hex byte field, or `malformedField(field)`.
func vectorBytes(_ hex: String, _ field: String) throws -> [UInt8] {
    guard let bytes = Hex.bytes(hex) else {
        throw VectorFileError.malformedField(field)
    }
    return bytes
}

/// Wire extensions as vector TLV fields; nil when there are none.
func tlvFields(_ extensions: [WireExtension]) -> [TlvField]? {
    extensions.isEmpty ? nil : extensions.map {
        TlvField(type: $0.type, valueHex: Hex.string($0.value))
    }
}

/// The wire extensions a vector's TLV fields describe.
func wireExtensions(_ tlvs: [TlvField]?) throws -> [WireExtension] {
    try (tlvs ?? []).map {
        try WireExtension(
            type: $0.type, value: vectorBytes($0.valueHex, "tlv valueHex")
        )
    }
}
