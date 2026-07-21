// The IDR-request CTRL message (CL-3) — the on-wire closing of CL-2's
// fecImpossible seam. Build-plan ruling §4.7: at H0b the heal path for an
// unrecoverable frame is IDR-request, NOT NACK — the host's NACK responder
// is HS-17 (H2), and until then the feedback report's NACK section stays
// empty while this message asks for the one thing the host can already do
// (HS-6's pacer has IDR-on-demand from day one).
//
// Type byte: 0x10, client→host. Wire's CtrlMessage registry (W4a, READ
// ONLY from this package) assigns 0x01/0x02 to the beacon pair and states
// that further CTRL types register when W3's ArqEndpoint lands; 0x10 is
// picked clear of that low range (0x03…0x0F left for W3's session
// machinery) and MUST migrate into the Wire registry with the next W-slice
// that touches CtrlMessage.swift. Like the beacon pair it is ARQ-exempt
// fire-and-forget: a lost request is superseded by the next one (the
// requester below re-fires while frames keep dying).
//
// Layout, fixed 10 bytes, multi-byte fields little-endian:
//
//   offset size field
//   0      1    type            0x10
//   1      4    requestSeq      u32, from 0 per session, one per emitted
//                               request — the host's dedupe/log handle
//   5      4    frame           u32, the newest frame written off as
//                               FEC-impossible when this request fired
//   9      1    coalescedCount  how many fecImpossible verdicts this
//                               request covers (≥1; saturates at 255) —
//                               burst-severity evidence for the host
//
// Exactly its fixed size: truncation and trailing bytes reject, a foreign
// type byte rejects with what it found (the beacon codecs' doctrine).

import Foundation
import LyteWire

/// CTRL type bytes minted by the client until the Wire registry grows a
/// slice that can own them (see the header comment).
public enum ClientCtrlMessageType {
    /// Client→host IDR request (IdrRequest). ARQ-exempt.
    public static let idrRequest: UInt8 = 0x10
}

public struct IdrRequest: Hashable, Sendable {
    public var requestSeq: UInt32
    /// The newest FEC-impossible frame at emit time.
    public var frame: FrameNumber
    /// fecImpossible verdicts covered by this request, saturating at 255.
    public var coalescedCount: UInt8

    public init(requestSeq: UInt32, frame: FrameNumber, coalescedCount: UInt8) {
        self.requestSeq = requestSeq
        self.frame = frame
        self.coalescedCount = coalescedCount
    }

    public static let encodedByteCount = 10

    /// Encodes the 10-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(ClientCtrlMessageType.idrRequest)
        appendLE32(requestSeq, to: &out)
        appendLE32(frame.rawValue, to: &out)
        out.append(coalescedCount)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the wrong
    /// type, truncation, and trailing bytes; never traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> IdrRequest {
        guard payload.count >= encodedByteCount else {
            throw IdrRequestError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw IdrRequestError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == ClientCtrlMessageType.idrRequest else {
            throw IdrRequestError.unexpectedType(payload[base])
        }
        return IdrRequest(
            requestSeq: readLE32(payload, at: base + 1),
            frame: FrameNumber(rawValue: readLE32(payload, at: base + 5)),
            coalescedCount: payload[base + 9]
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> IdrRequest {
        try decode(payload[...])
    }
}

public enum IdrRequestError: Error, Equatable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
}

// MARK: - The coalescing requester

/// Turns fecImpossible verdicts into rate-limited IDR requests. The rule:
/// at most one request per `minIntervalMicroseconds` (~100 ms — one IDR
/// heals everything, so a burst of dead frames needs one request, and the
/// interval comfortably covers host IDR turnaround at 60 fps). A verdict
/// inside the window is absorbed into the pending count; it flushes on the
/// first verdict past the window or on `flushIfDue` — the feedback
/// cadence tick (25–50 ms, always shorter than the window) drives that,
/// bounding coalesced-request latency to one cadence.
public final class IdrRequester: @unchecked Sendable {
    /// Emit-side counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var verdicts: UInt64 = 0
        public var requestsSent: UInt64 = 0
    }

    private let minIntervalMicroseconds: UInt64
    private let emit: @Sendable (IdrRequest) -> Void
    private let lock = NSLock()

    private var nextRequestSeq: UInt32 = 0
    private var lastSentAt: ClientTimestamp?
    private var pendingCount: UInt64 = 0
    private var pendingNewestFrame: FrameNumber?
    private var stats = Stats()

    /// - Parameter emit: sends one encoded request (TransportSender via
    ///   CTRL in production, a capture closure in tests).
    public init(
        minIntervalMilliseconds: Int = 100,
        emit: @escaping @Sendable (IdrRequest) -> Void
    ) {
        self.minIntervalMicroseconds = UInt64(max(1, minIntervalMilliseconds)) * 1_000
        self.emit = emit
    }

    /// One fecImpossible verdict — LyteVideoPipeline's onFecImpossible
    /// hook calls this. Emits immediately when outside the rate window,
    /// otherwise coalesces.
    public func recordFecImpossible(frame: FrameNumber, now: ClientTimestamp) {
        lock.lock()
        stats.verdicts += 1
        pendingCount += 1
        pendingNewestFrame = frame
        let request = dueRequestLocked(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    /// Flushes a coalesced pending request once the rate window has
    /// passed; the feedback cadence timer calls this.
    public func flushIfDue(now: ClientTimestamp) {
        lock.lock()
        let request = dueRequestLocked(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    private func dueRequestLocked(now: ClientTimestamp) -> IdrRequest? {
        guard pendingCount > 0, let frame = pendingNewestFrame else { return nil }
        if let last = lastSentAt,
           now.microseconds(since: last) < Int64(minIntervalMicroseconds) {
            return nil
        }
        let request = IdrRequest(
            requestSeq: nextRequestSeq,
            frame: frame,
            coalescedCount: UInt8(min(pendingCount, 255))
        )
        nextRequestSeq &+= 1
        lastSentAt = now
        pendingCount = 0
        pendingNewestFrame = nil
        stats.requestsSent += 1
        return request
    }
}

// MARK: - Local LE primitives (LyteWire's are internal to that module)

@inline(__always)
private func appendLE32(_ value: UInt32, to out: inout [UInt8]) {
    for shift in stride(from: 0, to: 32, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

@inline(__always)
private func readLE32(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt32 {
    UInt32(bytes[index])
        | UInt32(bytes[index + 1]) << 8
        | UInt32(bytes[index + 2]) << 16
        | UInt32(bytes[index + 3]) << 24
}
