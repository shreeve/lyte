// The shape a capability-spine vector takes in files authored after the
// per-feature spine models: one declaration and every flag accessor's
// expected read.

import LyteWire

/// One capability-spine vector: `messageHex` is a declaration's CBOR map;
/// decode must answer each `Capabilities` accessor named in `flags` with
/// its value and re-encode byte-exactly.
public struct CapabilitySpineVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var messageHex: String
    public var flags: [String: Bool]
}
