// SocketOutbox: the host's userspace send queue between the session's
// pacer and the kernel. Pacer-released datagrams wait here until a
// socket accepts them; this type owns their order, the two-socket lane
// batching, the EAGAIN/ENOBUFS/transient-error bookkeeping, stale fresh
// video shedding, and the accept ledger. It performs no IO: the shell
// supplies the socket writes as closures and executes the returned
// outcome (kernel-pressure sampling, peer-gone, fatal errors).
//
// Invariants:
// - Datagrams leave in pacer order, except that control and audio move
//   ahead of video (Session.prioritizeLatency — Noise state is per
//   channel, so a cross-channel move is byte-identical).
// - A would-block or ENOBUFS write re-queues every unsent datagram in
//   order; nothing is reordered within a channel.
// - Every accepted datagram is confirmed to the ledger exactly once; a
//   datagram that will never be written is discarded from it instead.
// - A fresh-video frame with any datagram already accepted is never shed
//   (shedding the rest would guarantee an undecodable frame).

import HostCore
import HostSession

/// The session hooks the outbox reports into (`Session` in production).
public protocol SocketOutboxLedger: AnyObject {
    /// The validated primary tuple; datagrams addressed elsewhere are
    /// path challenges and travel off-primary.
    var primaryTuple: FourTuple { get }
    func confirmDatagramSent(_ datagram: VideoChannelDatagram, now: UInt64)
    func discardPendingDatagram(_ datagram: VideoChannelDatagram)
    func noteKernelPressureFreshVideoShed(datagrams: Int, bytes: Int)
}

extension Session: SocketOutboxLedger {
    public var primaryTuple: FourTuple { validator.primary.tuple }
}

/// One socket write's result — the CNetIO return codes, typed.
public enum SocketWriteResult: Equatable, Sendable {
    /// The kernel accepted this many datagrams from the front of the batch.
    case accepted(Int)
    /// EAGAIN: the socket's send buffer is full.
    case wouldBlock
    /// ENOBUFS: local buffer exhaustion — retryable like EAGAIN.
    case noBuffer
    /// ECONNREFUSED: the peer's socket is closed.
    case peerGone
    /// A soft network error (host/net unreachable, netfilter EPERM): the
    /// head datagram is lost, the session is not.
    case transient
    /// Anything else — session-fatal.
    case failed(String)
}

/// What a flush ended on; the shell executes it.
public enum SocketFlushOutcome: Equatable, Sendable {
    case drained
    case wouldBlock(SocketLane)
    case noBuffer(SocketLane)
    case peerGone
    case failed(String)
}

public struct SocketOutboxCounters: Equatable, Sendable {
    public var datagramsSent = 0
    public var bytesSent = 0
    public var challengesSentOffPrimary = 0
    public var wouldBlockCount = 0
    public var videoWouldBlockCount = 0
    public var latencyWouldBlockCount = 0
    public var audioWouldBlockCount = 0
    public var noBufferCount = 0
    public var videoNoBufferCount = 0
    public var latencyNoBufferCount = 0
    public var transientErrors = 0
    public var pendingMaxDatagrams = 0
    public var pendingMaxBytes = 0
    public var freshVideoShedDatagrams = 0
    public var freshVideoShedBytes = 0
    public var audioOutboxMaxNS: UInt64 = 0
    public var audioWorstSeq: UInt16?
    public var audioWorstEnqueuedAtNS: UInt64?
    public var audioWorstAcceptedAtNS: UInt64?
    public var audioWorstBlockedByVideo = false

    public init() {}
}

public struct SocketOutbox {
    private struct AudioTrace {
        var enqueuedAtNS: UInt64
        var blockedByVideo: Bool
    }

    public private(set) var datagrams: [VideoChannelDatagram] = []
    /// Empty buffer swapped with `datagrams` on every flush, so the queue
    /// keeps its capacity without a copy-on-write copy per flush.
    private var spare: [VideoChannelDatagram] = []
    private var audioTraces: [UInt16: AudioTrace] = [:]
    private var freshVideoReleasedAtNS: [UInt64: UInt64] = [:]
    /// Fresh-video frames with at least one datagram accepted and more
    /// possibly still to come. Fresh video leaves in frame order, so a
    /// newer frame's first accept retires every older entry.
    public private(set) var framesPartiallyAccepted: Set<UInt32> = []
    public private(set) var counters = SocketOutboxCounters()

    public init() {}

    public var isEmpty: Bool { datagrams.isEmpty }
    public var count: Int { datagrams.count }

    /// A datagram the pacer released, stamped with its release instant.
    public mutating func enqueue(_ datagram: VideoChannelDatagram, now: UInt64) {
        if datagram.pacerClass == .audio {
            let blockedByVideo = datagrams.contains { Self.isVideo($0.pacerClass) }
            audioTraces[datagram.seq.rawValue] = AudioTrace(
                enqueuedAtNS: now, blockedByVideo: blockedByVideo)
        }
        if datagram.pacerClass == .freshVideo {
            freshVideoReleasedAtNS[Self.traceKey(datagram)] = now
        }
        datagrams.append(datagram)
    }

    /// The peer is gone: nothing queued will ever be written.
    public mutating func dropAll() {
        datagrams.removeAll(keepingCapacity: true)
        audioTraces.removeAll(keepingCapacity: true)
        freshVideoReleasedAtNS.removeAll(keepingCapacity: true)
        framesPartiallyAccepted.removeAll()
    }

    /// Writes everything it can. `write` receives consecutive runs of one
    /// socket lane, at most `maxBatch` long; `sendOffPrimary` carries one
    /// path challenge to its own tuple. `log` receives the lines the shell
    /// prints (challenge sends and failures).
    public mutating func flush(
        ledger: some SocketOutboxLedger,
        now: () -> UInt64,
        maxBatch: Int,
        sendOffPrimary: (VideoChannelDatagram, FourTuple) -> SocketWriteResult,
        write: (SocketLane, ArraySlice<VideoChannelDatagram>) -> SocketWriteResult,
        log: (String) -> Void
    ) -> SocketFlushOutcome {
        guard !datagrams.isEmpty else { return .drained }
        precondition(maxBatch > 0, "a socket batch holds at least one datagram")
        var queued: [VideoChannelDatagram] = []
        swap(&queued, &spare)
        swap(&queued, &datagrams)
        defer {
            queued.removeAll(keepingCapacity: true)
            spare = queued
        }

        // Challenges to unvalidated tuples travel on the exact probed
        // tuple — that is what they prove.
        if queued.contains(where: { $0.destination != nil }) {
            let primary = ledger.primaryTuple
            var peerGone = false
            queued.removeAll { datagram in
                guard let destination = datagram.destination,
                      destination != primary
                else { return false }
                let target = "\(destination.remoteAddress):\(destination.remotePort)"
                switch sendOffPrimary(datagram, destination) {
                case .accepted:
                    counters.challengesSentOffPrimary += 1
                    counters.datagramsSent += 1
                    counters.bytesSent += datagram.bytes.count
                    log("path: challenge sent to \(target) (off-primary sendto)")
                case .peerGone:
                    peerGone = true
                case .failed(let why):
                    log("path: challenge to \(target) failed: \(why)")
                case .wouldBlock, .noBuffer, .transient:
                    log("path: challenge to \(target) not sent (socket busy or unreachable)")
                }
                return true
            }
            if peerGone { return .peerGone }
        }
        Session.prioritizeLatency(&queued)

        var staged = 0
        while staged < queued.count {
            let lane = SocketLane.forClass(queued[staged].pacerClass)
            var batchEnd = staged
            while batchEnd < queued.count, batchEnd - staged < maxBatch,
                  SocketLane.forClass(queued[batchEnd].pacerClass) == lane {
                batchEnd += 1
            }
            var next = staged
            while next < batchEnd {
                switch write(lane, queued[next..<batchEnd]) {
                case .accepted(let accepted):
                    precondition(accepted > 0 && accepted <= batchEnd - next,
                                 "a socket accepts part of what it was offered")
                    let acceptedAt = now()
                    for datagram in queued[next..<(next + accepted)] {
                        noteAccepted(datagram, ledger: ledger, at: acceptedAt)
                    }
                    next += accepted
                case .wouldBlock:
                    requeue(queued[next...])
                    noteWouldBlock(lane: lane)
                    return .wouldBlock(lane)
                case .noBuffer:
                    requeue(queued[next...])
                    counters.noBufferCount += 1
                    if lane == .latency {
                        counters.latencyNoBufferCount += 1
                    } else {
                        counters.videoNoBufferCount += 1
                    }
                    return .noBuffer(lane)
                case .transient:
                    counters.transientErrors += 1
                    forget(queued[next], ledger: ledger)
                    next += 1
                case .peerGone:
                    return .peerGone
                case .failed(let why):
                    return .failed(why)
                }
            }
            staged = batchEnd
        }
        return .drained
    }

    /// Latency-only kernel pressure: drops the oldest fresh-video frame
    /// whose datagrams have all overstayed `budgetNS` since release and
    /// none of which reached the socket.
    public mutating func shedOldestStaleFreshVideo(
        ledger: some SocketOutboxLedger, now: UInt64, budgetNS: UInt64
    ) {
        var oldest: (frame: UInt32, releasedAt: UInt64)?
        for datagram in datagrams where datagram.pacerClass == .freshVideo {
            let frame = datagram.frameNumber.rawValue
            guard !framesPartiallyAccepted.contains(frame),
                  let releasedAt = freshVideoReleasedAtNS[Self.traceKey(datagram)],
                  KernelPressureGovernor.shouldShedAtSocket(
                      priorityClass: datagram.pacerClass,
                      releasedAtNS: releasedAt,
                      nowNS: now,
                      videoQueueBudgetNS: budgetNS)
            else { continue }
            if oldest == nil || releasedAt < oldest!.releasedAt {
                oldest = (frame, releasedAt)
            }
        }
        guard let oldest else { return }
        var droppedDatagrams = 0
        var droppedBytes = 0
        datagrams.removeAll { datagram in
            guard datagram.pacerClass == .freshVideo,
                  datagram.frameNumber.rawValue == oldest.frame
            else { return false }
            freshVideoReleasedAtNS.removeValue(forKey: Self.traceKey(datagram))
            ledger.discardPendingDatagram(datagram)
            droppedDatagrams += 1
            droppedBytes += datagram.bytes.count
            return true
        }
        ledger.noteKernelPressureFreshVideoShed(
            datagrams: droppedDatagrams, bytes: droppedBytes)
        counters.freshVideoShedDatagrams += droppedDatagrams
        counters.freshVideoShedBytes += droppedBytes
    }

    /// A fall purge: every queued video datagram is dropped with the
    /// pacer's own backlog.
    public mutating func purgeVideo(ledger: some SocketOutboxLedger) {
        datagrams.removeAll { datagram in
            guard Self.isVideo(datagram.pacerClass) else { return false }
            ledger.discardPendingDatagram(datagram)
            freshVideoReleasedAtNS.removeValue(forKey: Self.traceKey(datagram))
            return true
        }
    }

    private mutating func requeue(_ unsent: ArraySlice<VideoChannelDatagram>) {
        datagrams.append(contentsOf: unsent)
    }

    private mutating func noteWouldBlock(lane: SocketLane) {
        counters.wouldBlockCount += 1
        if lane == .latency {
            counters.latencyWouldBlockCount += 1
        } else {
            counters.videoWouldBlockCount += 1
        }
        if datagrams.contains(where: { $0.pacerClass == .audio }) {
            counters.audioWouldBlockCount += 1
        }
        counters.pendingMaxDatagrams = max(
            counters.pendingMaxDatagrams, datagrams.count)
        counters.pendingMaxBytes = max(
            counters.pendingMaxBytes,
            datagrams.reduce(0) { $0 + $1.bytes.count })
    }

    private mutating func noteAccepted(
        _ datagram: VideoChannelDatagram,
        ledger: some SocketOutboxLedger,
        at acceptedAt: UInt64
    ) {
        if datagram.pacerClass == .freshVideo {
            let frame = datagram.frameNumber.rawValue
            if !framesPartiallyAccepted.contains(frame) {
                framesPartiallyAccepted = framesPartiallyAccepted.filter {
                    Self.isOlder(frame, than: $0)
                }
                framesPartiallyAccepted.insert(frame)
            }
            freshVideoReleasedAtNS.removeValue(forKey: Self.traceKey(datagram))
        }
        if datagram.pacerClass == .audio,
           let trace = audioTraces.removeValue(forKey: datagram.seq.rawValue) {
            let delay = acceptedAt &- trace.enqueuedAtNS
            if delay > counters.audioOutboxMaxNS {
                counters.audioOutboxMaxNS = delay
                counters.audioWorstSeq = datagram.seq.rawValue
                counters.audioWorstEnqueuedAtNS = trace.enqueuedAtNS
                counters.audioWorstAcceptedAtNS = acceptedAt
                counters.audioWorstBlockedByVideo = trace.blockedByVideo
            }
        }
        ledger.confirmDatagramSent(datagram, now: acceptedAt)
        counters.datagramsSent += 1
        counters.bytesSent += datagram.bytes.count
    }

    /// A datagram that will never be written.
    private mutating func forget(
        _ datagram: VideoChannelDatagram, ledger: some SocketOutboxLedger
    ) {
        ledger.discardPendingDatagram(datagram)
        freshVideoReleasedAtNS.removeValue(forKey: Self.traceKey(datagram))
        if datagram.pacerClass == .audio {
            audioTraces.removeValue(forKey: datagram.seq.rawValue)
        }
    }

    private static func isVideo(_ pacerClass: PacerClass) -> Bool {
        pacerClass == .freshVideo || pacerClass == .videoTail
            || pacerClass == .refinement
    }

    /// Wrapping frame-number order: true when `candidate` is newer than
    /// `frame` (keeps entries newer than the accepting frame).
    private static func isOlder(_ frame: UInt32, than candidate: UInt32) -> Bool {
        Int32(bitPattern: candidate &- frame) > 0
    }

    private static func traceKey(_ datagram: VideoChannelDatagram) -> UInt64 {
        UInt64(datagram.frameNumber.rawValue) << 16 | UInt64(datagram.seq.rawValue)
    }
}
