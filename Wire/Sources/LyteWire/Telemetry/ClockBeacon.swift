// The clock beacon pair: host→client on CTRL at 1 Hz (plus session start),
// client-echoed, doubling as slow session liveness. It is NOT the fast
// blackout detector. Both messages are ARQ-exempt fire-and-forget CTRL
// datagrams: a lost beacon is superseded by the next one.
//
// The pair carries the four NTP timestamps (RFC 5905 §8): t1 = host send
// (beacon), t2 = client receive, t3 = client send (echo), t4 = host
// receive (measured locally, never on the wire). From one pair:
//
//   rtt    = (t4 − t1) − (t3 − t2)
//   offset = ((t2 − t1) + (t3 − t4)) / 2      (client − host, µs)
//
// The beacon optionally carries the host's view of the last echo it
// received, so the client can compute the host-side estimate symmetrically.
//
// ClockBeacon, host→client, fixed 34 bytes, all multi-byte fields
// little-endian:
//
//   offset size field
//   0      1    type       CtrlMessageType.clockBeacon (0x01)
//   1      1    flags      bit0: lastEcho fields populated; bits 1–7
//                          reserved, MUST be 0 on send, ignored on receive
//   2      4    beaconSeq  u32 beacon counter, from 0 at session start
//   6      8    hostSend   t1: host monotonic µs (CLOCK_MONOTONIC) at send
//   14     4    lastEchoBeaconSeq    beaconSeq of the echo this reports
//   18     8    lastEchoClientSend   its t3 (client µs, echoed verbatim)
//   26     8    lastEchoHostReceive  its t4 (host µs, measured at arrival)
//
// When flags bit0 is clear the three lastEcho fields MUST be zero on the
// wire; non-zero bytes there are rejected as malformed.
//
// BeaconEcho, client→host, fixed 29 bytes:
//
//   offset size field
//   0      1    type           CtrlMessageType.beaconEcho (0x02)
//   1      4    beaconSeq      u32, copied from the beacon
//   5      8    hostSend       t1, copied verbatim from the beacon
//   13     8    clientReceive  t2: client monotonic µs at beacon arrival
//   21     8    clientSend     t3: client monotonic µs at echo send
//
// Both messages are exactly their fixed size: truncation and trailing
// bytes reject. A different type byte rejects with the type it found, so
// a CTRL dispatcher's misrouting is loud.

public struct ClockBeacon: Hashable, Sendable, SliceDecodable {
    /// The host's view of the last echo it received, mirrored back to the
    /// client for symmetric offset estimation.
    public struct LastEcho: Hashable, Sendable {
        /// beaconSeq of the beacon that echo answered.
        public var beaconSeq: UInt32
        /// That echo's t3, echoed verbatim.
        public var clientSend: ClientTimestamp
        /// That echo's t4, measured by the host at arrival.
        public var hostReceive: HostTimestamp

        public init(
            beaconSeq: UInt32,
            clientSend: ClientTimestamp,
            hostReceive: HostTimestamp
        ) {
            self.beaconSeq = beaconSeq
            self.clientSend = clientSend
            self.hostReceive = hostReceive
        }
    }

    public var beaconSeq: UInt32
    /// t1: host monotonic µs (CLOCK_MONOTONIC) at send.
    public var hostSend: HostTimestamp
    /// Nil until the host has received its first echo.
    public var lastEcho: LastEcho?

    public init(
        beaconSeq: UInt32, hostSend: HostTimestamp, lastEcho: LastEcho? = nil
    ) {
        self.beaconSeq = beaconSeq
        self.hostSend = hostSend
        self.lastEcho = lastEcho
    }

    /// Fixed wire size: the beacon has no variable sections.
    public static let encodedByteCount = 34

    private static let lastEchoFlag: UInt8 = 0x01

    /// Encodes the 34-byte message, type byte included. Cannot fail: every
    /// representable beacon is encodable.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(CtrlMessageType.clockBeacon)
        out.append(lastEcho == nil ? 0 : Self.lastEchoFlag)
        wireAppendLE(beaconSeq, to: &out)
        wireAppendLE(hostSend.microseconds, to: &out)
        wireAppendLE(lastEcho?.beaconSeq ?? 0, to: &out)
        wireAppendLE(lastEcho?.clientSend.microseconds ?? 0, to: &out)
        wireAppendLE(lastEcho?.hostReceive.microseconds ?? 0, to: &out)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the wrong
    /// type, truncation, trailing bytes, and non-zero lastEcho fields under
    /// a clear flag; never traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> ClockBeacon {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.clockBeacon,
            byteCount: encodedByteCount, BeaconError.self
        )
        let flags = payload[base + 1]
        let beaconSeq: UInt32 = wireReadLE(payload, at: base + 2)
        let hostSend: UInt64 = wireReadLE(payload, at: base + 6)
        let echoSeq: UInt32 = wireReadLE(payload, at: base + 14)
        let echoClientSend: UInt64 = wireReadLE(payload, at: base + 18)
        let echoHostReceive: UInt64 = wireReadLE(payload, at: base + 26)

        let lastEcho: LastEcho?
        if flags & lastEchoFlag != 0 {
            lastEcho = LastEcho(
                beaconSeq: echoSeq,
                clientSend: ClientTimestamp(microseconds: echoClientSend),
                hostReceive: HostTimestamp(microseconds: echoHostReceive)
            )
        } else {
            guard echoSeq == 0, echoClientSend == 0, echoHostReceive == 0 else {
                throw BeaconError.nonZeroAbsentEchoFields
            }
            lastEcho = nil
        }
        return ClockBeacon(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(microseconds: hostSend),
            lastEcho: lastEcho
        )
    }
}

public struct BeaconEcho: Hashable, Sendable, SliceDecodable {
    /// Copied from the beacon being echoed.
    public var beaconSeq: UInt32
    /// t1, copied verbatim from the beacon.
    public var hostSend: HostTimestamp
    /// t2: client monotonic µs when the beacon arrived.
    public var clientReceive: ClientTimestamp
    /// t3: client monotonic µs when this echo was sent.
    public var clientSend: ClientTimestamp

    public init(
        beaconSeq: UInt32,
        hostSend: HostTimestamp,
        clientReceive: ClientTimestamp,
        clientSend: ClientTimestamp
    ) {
        self.beaconSeq = beaconSeq
        self.hostSend = hostSend
        self.clientReceive = clientReceive
        self.clientSend = clientSend
    }

    /// Fixed wire size: the echo has no variable sections.
    public static let encodedByteCount = 29

    /// Encodes the 29-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(CtrlMessageType.beaconEcho)
        wireAppendLE(beaconSeq, to: &out)
        wireAppendLE(hostSend.microseconds, to: &out)
        wireAppendLE(clientReceive.microseconds, to: &out)
        wireAppendLE(clientSend.microseconds, to: &out)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the wrong
    /// type, truncation, and trailing bytes; never traps.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> BeaconEcho {
        let base = try checkFixedFrame(
            payload, type: CtrlMessageType.beaconEcho,
            byteCount: encodedByteCount, BeaconError.self
        )
        return BeaconEcho(
            beaconSeq: wireReadLE(payload, at: base + 1),
            hostSend: HostTimestamp(microseconds: wireReadLE(payload, at: base + 5)),
            clientReceive: ClientTimestamp(microseconds: wireReadLE(payload, at: base + 13)),
            clientSend: ClientTimestamp(microseconds: wireReadLE(payload, at: base + 21))
        )
    }

    /// One raw clock sample from this echo plus the locally measured t4:
    /// `offsetMicroseconds` is client − host (clientTime ≈ hostTime +
    /// offset), `rttMicroseconds` excludes the client's turnaround. Signed
    /// wrap-safe arithmetic; one sample only — filtering belongs to the
    /// caller's clock model.
    public func clockSample(
        hostReceive: HostTimestamp
    ) -> (offsetMicroseconds: Int64, rttMicroseconds: Int64) {
        let outbound = Int64(bitPattern:
            clientReceive.microseconds &- hostSend.microseconds)
        let inbound = Int64(bitPattern:
            clientSend.microseconds &- hostReceive.microseconds)
        let roundTrip = Int64(bitPattern:
            hostReceive.microseconds &- hostSend.microseconds)
        let turnaround = Int64(bitPattern:
            clientSend.microseconds &- clientReceive.microseconds)
        return (
            offsetMicroseconds: (outbound &+ inbound) / 2,
            rttMicroseconds: roundTrip &- turnaround
        )
    }
}

/// Everything the beacon codecs can refuse; hostile bytes throw, never trap.
public enum BeaconError: FixedFrameError, Equatable, Sendable {
    /// Fewer bytes than the fixed message size.
    case truncatedMessage
    /// More bytes than the fixed message size: beacon messages are exactly
    /// their layout, nothing rides behind them.
    case trailingBytes
    /// The type byte names a different message; carries what it found.
    case unexpectedType(UInt8)
    /// flags bit0 clear but lastEcho bytes non-zero.
    case nonZeroAbsentEchoFields
}
