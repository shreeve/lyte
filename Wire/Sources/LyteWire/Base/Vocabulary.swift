// The shared vocabulary (overview §3, conflict 16): "frame number" is the
// envelope `frame` field, "sequence" is the per-channel `seq` field, and
// timestamps are tagged by clock domain so host-PipeWire µs and client µs
// can never meet in one expression.

/// The envelope `frame` field: per-channel u32 frame counter for video, the
/// audio-doc packet number for audio, and the FEC group id for both. At 60
/// fps a u32 wraps in ~2.2 years — plain ordering is honest, wrapping
/// increment keeps the arithmetic total anyway.
public struct FrameNumber: RawRepresentable, Hashable, Comparable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var next: FrameNumber {
        FrameNumber(rawValue: rawValue &+ 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The envelope `seq` field: per-channel u16 datagram sequence with serial
/// arithmetic (RFC 1982 shape). At peak rate the space wraps in ~3.6 s,
/// far beyond every NACK/feedback gate window, so a half-window comparison
/// is always unambiguous in practice. The one theoretical exception —
/// two values exactly 0x8000 apart — compares as unordered (both `<` are
/// false); callers never operate at that distance.
public struct ChannelSeq: RawRepresentable, Hashable, Comparable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public var next: ChannelSeq {
        ChannelSeq(rawValue: rawValue &+ 1)
    }

    public func advanced(by delta: Int16) -> ChannelSeq {
        ChannelSeq(rawValue: rawValue &+ UInt16(bitPattern: delta))
    }

    /// Signed serial distance from `self` to `other`: positive when `other`
    /// is ahead, computed through the wrap. Distance 0x8000 reports as
    /// Int16.min; see the type comment.
    public func distance(to other: ChannelSeq) -> Int16 {
        Int16(bitPattern: other.rawValue &- rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.distance(to: rhs) > 0
    }
}

/// Clock domains for `WireTimestamp`. The envelope timestamp is host
/// PipeWire monotonic µs on host-sent datagrams and client monotonic µs on
/// client-sent ones (overview §2); the beacon codec (W4a) is the only
/// sanctioned conversion point between the two.
public enum HostClock {}
public enum ClientClock {}

/// A u64 microsecond instant tagged by its clock domain. Mixing domains in
/// arithmetic is a compile error, which is the entire point of the phantom
/// parameter.
public struct WireTimestamp<Domain>: Hashable, Comparable, Sendable {
    /// Microseconds since the domain clock's (unspecified) epoch.
    public var microseconds: UInt64

    public init(microseconds: UInt64) {
        self.microseconds = microseconds
    }

    public func advanced(byMicroseconds delta: Int64) -> WireTimestamp {
        WireTimestamp(microseconds: microseconds &+ UInt64(bitPattern: delta))
    }

    /// Signed elapsed µs from `earlier` to `self`, same domain only.
    public func microseconds(since earlier: WireTimestamp) -> Int64 {
        Int64(bitPattern: microseconds &- earlier.microseconds)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}

public typealias HostTimestamp = WireTimestamp<HostClock>
public typealias ClientTimestamp = WireTimestamp<ClientClock>
