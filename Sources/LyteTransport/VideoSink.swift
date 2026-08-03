import AVFoundation
import CoreMedia
import LyteWire

/// Client video's final organ boundary. The pipeline and session own decode,
/// recovery, and timing policy; a sink owns what happens to a ready native
/// sample. Platform renderers and headless gates implement the same seam.
public protocol VideoSink: Sendable {
    func submit(sample: CMSampleBuffer, unit: DecodeUnit)
}

/// The direct AVFoundation leaf used by diagnostic shells such as wire-view.
/// The app's richer renderer handoff implements `VideoSink` itself so queue,
/// recovery, and telemetry policy remain visible there.
public final class AVSampleBufferRendererVideoSink:
    VideoSink, @unchecked Sendable
{
    private let renderer: AVSampleBufferVideoRenderer

    public init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    public func submit(sample: CMSampleBuffer, unit _: DecodeUnit) {
        renderer.enqueue(sample)
    }
}
