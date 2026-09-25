// Shared byte fixtures and field parsers for the vector files.

import LyteCore
import LyteWire

/// `count` bytes counting up from `offset`, wrapping at 256 — the
/// recognizable payload most vectors carry.
func counting(from offset: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8((offset + $0) & 0xFF) }
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
