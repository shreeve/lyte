import HostCore
import LyteWire

extension PacerClass {
    /// The wire channel whose delivery evidence names this paced class.
    var sessionChannel: ChannelId {
        switch self {
        case .control: .ctrl
        case .audio: .audio
        case .bulk: .bulkTransfer
        case .freshVideo, .videoTail, .refinement, .telemetry: .videoActive
        }
    }

    var countsAsPendingVideo: Bool {
        self == .freshVideo || self == .videoTail || self == .refinement
    }
}

/// The sans-IO owner of datagrams released by the pacer but not yet accepted
/// by the socket. It retains release-rate evidence and video backlog/recusal
/// books until either confirmation or explicit discard removes the datagram.
public struct SessionSocketPendingBook: Equatable, Sendable {
    public private(set) var videoDatagramCount = 0
    public private(set) var videoByteCount = 0
    public var pendingDatagramCount: Int { releaseRates.count }
    public var videoFrameNumbers: Set<UInt32> {
        Set(videoDatagramsByFrame.keys)
    }

    private var releaseRates: [UInt32: Int] = [:]
    private var videoDatagramsByFrame: [UInt32: Int] = [:]

    public init() {}

    public mutating func note(
        _ datagram: VideoChannelDatagram,
        releaseRateBitsPerSecond: Int
    ) {
        guard datagram.destination == nil else { return }
        releaseRates[key(for: datagram)] = releaseRateBitsPerSecond
        guard datagram.pacerClass.countsAsPendingVideo else { return }
        let frame = datagram.frameNumber.rawValue
        videoDatagramsByFrame[frame, default: 0] += 1
        videoDatagramCount += 1
        videoByteCount += datagram.bytes.count
    }

    /// Removes one confirmed or discarded datagram and returns its original
    /// release rate for estimator accounting. A repeated removal is inert.
    @discardableResult
    public mutating func remove(
        _ datagram: VideoChannelDatagram
    ) -> Int? {
        guard datagram.destination == nil else { return nil }
        guard let rate = releaseRates.removeValue(forKey: key(for: datagram))
        else { return nil }
        guard datagram.pacerClass.countsAsPendingVideo,
              let frameCount = videoDatagramsByFrame[
                datagram.frameNumber.rawValue
              ]
        else { return rate }
        let frame = datagram.frameNumber.rawValue
        if frameCount == 1 {
            videoDatagramsByFrame.removeValue(forKey: frame)
        } else {
            videoDatagramsByFrame[frame] = frameCount - 1
        }
        videoDatagramCount -= 1
        videoByteCount -= datagram.bytes.count
        return rate
    }

    private func key(for datagram: VideoChannelDatagram) -> UInt32 {
        UInt32(datagram.pacerClass.sessionChannel.rawValue) << 16
            | UInt32(datagram.seq.rawValue)
    }
}
