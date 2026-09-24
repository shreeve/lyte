// Input messages: the client captures an event, stamps it, sequences it
// and sends it on the sealed ARQ ordered stream; the host injects it and
// answers with echo tuples (seq, rx µs, inject µs), and stamps
// lastInputSeq into the next frame, closing the input-to-photon loop.
//
// Both types ride the ordered stream: a lost or reordered keystroke is
// corruption, not weather. Latency comes from pacer priority (CTRL/input
// outranks everything). Echo tuples carry timestamps, not freshness, so a
// late echo still reports the true instants.
//
// InputEvent (0x16), client→host. Layout, multi-byte fields LE:
//
//   offset size field
//   0      1    type          0x16
//   1      4    seq           u32 — client-allocated, ascending from 0
//                             per session; the echo/lastInputSeq handle
//   5      8    clientMicros  u64 — the client's monotonic µs when the
//                             event was captured (client clock domain;
//                             the client owns mapping it)
//   13     1    kind          see below
//   14     …    body          kind-determined, exact length (trailing
//                             bytes reject)
//
// Kinds and bodies (coordinates are f64 IEEE-754 bit patterns, LE):
//
//   0x01 keyKeycode             keycode u32 (evdev), pressed u8 (0/1)
//   0x02 pointerMotionAbsolute  x f64, y f64 — pixels in the host's
//                               recorded-monitor space (the client
//                               scales; the injector owns any further
//                               mapping)
//   0x03 pointerMotionRelative  dx f64, dy f64
//   0x04 pointerButton          button u32 (evdev BTN_*), pressed u8
//   0x05 pointerAxis            dx f64, dy f64 (smooth-scroll deltas),
//                               flags u8 (bit0 = finish; rest reserved,
//                               must be 0)
//
// Evdev keycodes on purpose: the host session's XKB map owns layout; the
// client sends position codes and never guesses keysyms. Unknown kinds
// and nonzero reserved bits reject as a protocol break.
//
// InputEcho (0x17), host→client. Layout:
//
//   offset size field
//   0      1    type       0x17
//   1      1    count      u8 ≥ 1 — tuples that follow
//   2      20·n tuples     seq u32 ‖ receivedMicros u64 ‖ injectedMicros
//                          u64, all LE. Host graph/monotonic µs — the
//                          SAME domain the beacon's t1/t4 ride, so the
//                          client's HostClockModel maps rx/inject onto
//                          its own timeline with no new machinery.
//
// Truncation, a foreign type byte, count = 0, and a length that
// disagrees with count all reject. Never traps on hostile bytes.

/// One client input event (type 0x16).
public struct InputEvent: Hashable, Sendable, SliceDecodable {
    public enum Body: Hashable, Sendable {
        case keyKeycode(keycode: UInt32, pressed: Bool)
        /// Pixels in the host's recorded-monitor coordinate space.
        case pointerMotionAbsolute(x: Double, y: Double)
        case pointerMotionRelative(dx: Double, dy: Double)
        case pointerButton(button: UInt32, pressed: Bool)
        /// Smooth-scroll deltas; `finish` marks the gesture's end.
        case pointerAxis(dx: Double, dy: Double, finish: Bool)
    }

    /// Client-allocated, ascending from 0 per session.
    public var seq: UInt32
    /// The client's monotonic µs at event capture (client domain).
    public var clientMicroseconds: UInt64
    public var body: Body

    public init(seq: UInt32, clientMicroseconds: UInt64, body: Body) {
        self.seq = seq
        self.clientMicroseconds = clientMicroseconds
        self.body = body
    }

    // Kind bytes (wire values; see the file comment).
    private static let kindKeyKeycode: UInt8 = 0x01
    private static let kindPointerMotionAbsolute: UInt8 = 0x02
    private static let kindPointerMotionRelative: UInt8 = 0x03
    private static let kindPointerButton: UInt8 = 0x04
    private static let kindPointerAxis: UInt8 = 0x05

    public static let headerByteCount = 14

    /// Encodes the whole message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.headerByteCount + 17)
        out.append(CtrlMessageType.inputEvent)
        wireAppendLE(seq, to: &out)
        wireAppendLE(clientMicroseconds, to: &out)
        switch body {
        case .keyKeycode(let keycode, let pressed):
            out.append(Self.kindKeyKeycode)
            wireAppendLE(keycode, to: &out)
            out.append(pressed ? 1 : 0)
        case .pointerMotionAbsolute(let x, let y):
            out.append(Self.kindPointerMotionAbsolute)
            wireAppendLE(x.bitPattern, to: &out)
            wireAppendLE(y.bitPattern, to: &out)
        case .pointerMotionRelative(let dx, let dy):
            out.append(Self.kindPointerMotionRelative)
            wireAppendLE(dx.bitPattern, to: &out)
            wireAppendLE(dy.bitPattern, to: &out)
        case .pointerButton(let button, let pressed):
            out.append(Self.kindPointerButton)
            wireAppendLE(button, to: &out)
            out.append(pressed ? 1 : 0)
        case .pointerAxis(let dx, let dy, let finish):
            out.append(Self.kindPointerAxis)
            wireAppendLE(dx.bitPattern, to: &out)
            wireAppendLE(dy.bitPattern, to: &out)
            out.append(finish ? 1 : 0)
        }
        return out
    }

    /// Decodes a whole ARQ-delivered message (type byte first). Throws
    /// on the wrong type, truncation, an unknown kind, a body whose
    /// length disagrees with its kind, and nonzero reserved bits; never
    /// traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> InputEvent {
        guard payload.count >= headerByteCount + 1 else {
            throw InputMessageError.truncatedMessage
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.inputEvent else {
            throw InputMessageError.unexpectedType(payload[base])
        }
        let seq: UInt32 = wireReadLE(payload, at: base + 1)
        let clientMicros: UInt64 = wireReadLE(payload, at: base + 5)
        let kind = payload[base + 13]
        let body = payload[(base + headerByteCount)...]
        let decoded: Body
        switch kind {
        case kindKeyKeycode:
            guard body.count == 5 else {
                throw InputMessageError.bodyLengthMismatch(
                    kind: kind, byteCount: body.count
                )
            }
            decoded = .keyKeycode(
                keycode: wireReadLE(body, at: body.startIndex),
                pressed: try flag(body[body.startIndex + 4])
            )
        case kindPointerMotionAbsolute, kindPointerMotionRelative:
            guard body.count == 16 else {
                throw InputMessageError.bodyLengthMismatch(
                    kind: kind, byteCount: body.count
                )
            }
            let a = Double(bitPattern: wireReadLE(body, at: body.startIndex))
            let b = Double(bitPattern: wireReadLE(body, at: body.startIndex + 8))
            decoded = kind == kindPointerMotionAbsolute
                ? .pointerMotionAbsolute(x: a, y: b)
                : .pointerMotionRelative(dx: a, dy: b)
        case kindPointerButton:
            guard body.count == 5 else {
                throw InputMessageError.bodyLengthMismatch(
                    kind: kind, byteCount: body.count
                )
            }
            decoded = .pointerButton(
                button: wireReadLE(body, at: body.startIndex),
                pressed: try flag(body[body.startIndex + 4])
            )
        case kindPointerAxis:
            guard body.count == 17 else {
                throw InputMessageError.bodyLengthMismatch(
                    kind: kind, byteCount: body.count
                )
            }
            let flags = body[body.startIndex + 16]
            guard flags & ~0x01 == 0 else {
                throw InputMessageError.reservedBitsSet(flags)
            }
            decoded = .pointerAxis(
                dx: Double(bitPattern: wireReadLE(body, at: body.startIndex)),
                dy: Double(bitPattern: wireReadLE(body, at: body.startIndex + 8)),
                finish: flags & 0x01 != 0
            )
        default:
            throw InputMessageError.unknownKind(kind)
        }
        return InputEvent(
            seq: seq, clientMicroseconds: clientMicros, body: decoded
        )
    }

    private static func flag(_ byte: UInt8) throws -> Bool {
        switch byte {
        case 0: return false
        case 1: return true
        default: throw InputMessageError.malformedFlag(byte)
        }
    }
}

/// One (seq, rx, inject) accounting tuple, host µs domain.
public struct InputEchoTuple: Hashable, Sendable {
    public var seq: UInt32
    /// Host monotonic µs when the event's datagram was received.
    public var receivedMicroseconds: UInt64
    /// Host monotonic µs when the injection call returned.
    public var injectedMicroseconds: UInt64

    public init(
        seq: UInt32,
        receivedMicroseconds: UInt64,
        injectedMicroseconds: UInt64
    ) {
        self.seq = seq
        self.receivedMicroseconds = receivedMicroseconds
        self.injectedMicroseconds = injectedMicroseconds
    }
}

/// The input echo message (type 0x17): 1–`maxTupleCount` tuples.
public struct InputEcho: Hashable, Sendable, SliceDecodable {
    public var tuples: [InputEchoTuple]

    /// Bounds one message well inside the session's 1093 B clamped ARQ
    /// segment body (2 + 32·20 = 642 B) — a burst of injections flushes
    /// as several messages, never a burst datagram.
    public static let maxTupleCount = 32
    private static let tupleByteCount = 20

    /// Traps on construction with 0 or > maxTupleCount tuples — that is
    /// a sender bug, not hostile input (decode rejects the same shapes).
    public init(tuples: [InputEchoTuple]) {
        precondition(
            !tuples.isEmpty && tuples.count <= Self.maxTupleCount,
            "an echo carries 1...\(Self.maxTupleCount) tuples"
        )
        self.tuples = tuples
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(2 + tuples.count * Self.tupleByteCount)
        out.append(CtrlMessageType.inputEcho)
        out.append(UInt8(tuples.count))
        for tuple in tuples {
            wireAppendLE(tuple.seq, to: &out)
            wireAppendLE(tuple.receivedMicroseconds, to: &out)
            wireAppendLE(tuple.injectedMicroseconds, to: &out)
        }
        return out
    }

    /// Throws on the wrong type, count = 0, over-limit count, and a
    /// length that disagrees with count; never traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> InputEcho {
        guard payload.count >= 2 else {
            throw InputMessageError.truncatedMessage
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.inputEcho else {
            throw InputMessageError.unexpectedType(payload[base])
        }
        let count = Int(payload[base + 1])
        guard count >= 1, count <= maxTupleCount else {
            throw InputMessageError.malformedTupleCount(payload[base + 1])
        }
        guard payload.count == 2 + count * tupleByteCount else {
            throw InputMessageError.bodyLengthMismatch(
                kind: CtrlMessageType.inputEcho,
                byteCount: payload.count - 2
            )
        }
        var tuples: [InputEchoTuple] = []
        tuples.reserveCapacity(count)
        var cursor = base + 2
        for _ in 0..<count {
            tuples.append(InputEchoTuple(
                seq: wireReadLE(payload, at: cursor),
                receivedMicroseconds: wireReadLE(payload, at: cursor + 4),
                injectedMicroseconds: wireReadLE(payload, at: cursor + 12)
            ))
            cursor += tupleByteCount
        }
        return InputEcho(tuples: tuples)
    }
}

/// The lastInputSeq envelope TLV codec (type 0x03, value = u32 LE).
public enum LastInputSeqTlv {
    public static let valueByteCount = 4
    /// The TLV's on-wire cost inside an existing extensions block:
    /// type + length + value.
    public static let encodedByteCount = 2 + valueByteCount

    /// Cannot fail: a 4-byte value always fits the length prefix.
    public static func wireExtension(seq: UInt32) -> WireExtension {
        var value = [UInt8]()
        wireAppendLE(seq, to: &value)
        return try! WireExtension(
            type: WireExtension.ReservedType.lastInputSeq, value: value
        )
    }

    /// Nil when absent (every pre-input frame); throws on a duplicate
    /// or a malformed value.
    public static func decode(extensions: [WireExtension]) throws -> UInt32? {
        guard let value = try WireExtension.uniqueValue(
            ofType: WireExtension.ReservedType.lastInputSeq, in: extensions,
            duplicate: InputMessageError.duplicateLastInputSeqTlv
        ) else { return nil }
        guard value.count == valueByteCount else {
            throw InputMessageError.malformedLastInputSeqTlv(
                byteCount: value.count
            )
        }
        return wireReadLE(value[...], at: 0)
    }
}

public enum InputMessageError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case unknownKind(UInt8)
    case bodyLengthMismatch(kind: UInt8, byteCount: Int)
    case malformedFlag(UInt8)
    case reservedBitsSet(UInt8)
    case malformedTupleCount(UInt8)
    case duplicateLastInputSeqTlv
    case malformedLastInputSeqTlv(byteCount: Int)
}
