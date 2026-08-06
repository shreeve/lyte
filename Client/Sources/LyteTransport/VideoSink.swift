import AVFoundation
import CoreMedia
import LyteWire

/// Client video's final organ boundary. The pipeline and session own decode,
/// recovery, and timing policy; a sink owns what happens to a ready native
/// sample. Platform renderers and headless gates implement the same seam.
public protocol VideoSink: Sendable {
    func submit(sample: CMSampleBuffer, unit: DecodeUnit)
}

/// CoreMedia adapter at the session's final delivery seam. The core decides
/// whether the IO-free `DecodeUnit` may cross; this leaf alone carries the
/// native sample into the downstream renderer. Binding finishes before the
/// pipeline can receive a sample, and the weak owner keeps the
/// core → pipeline → sink graph acyclic.
///
/// Recovery-episode close stays with the leaf that actually enqueues into
/// AVFoundation (`noteVideoIrapEnqueued`). Admit here only fences non-IRAP
/// units while recovery is outstanding — it is not delivery proof.
final class SessionVideoSink: VideoSink, @unchecked Sendable {
    private weak var owner: LyteUdpSessionCore?
    private let downstream: any VideoSink

    init(downstream: any VideoSink) {
        self.downstream = downstream
    }

    func bind(_ owner: LyteUdpSessionCore) {
        self.owner = owner
    }

    func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        guard let owner else {
            // Preserve the retired weak-self callback's teardown behavior:
            // sample work already in flight still reaches its owned sink.
            downstream.submit(sample: sample, unit: unit)
            return
        }
        guard owner.admitVideoUnit(unit) else { return }
        downstream.submit(sample: sample, unit: unit)
    }
}

/// The direct AVFoundation leaf used by diagnostic shells such as wire-view.
/// The app's richer renderer handoff implements `VideoSink` itself so queue,
/// recovery, and telemetry policy remain visible there.
///
/// `onIrapEnqueued` is required: an IRAP that reaches `renderer.enqueue`
/// must close the client's coalesced IDR episode. Omitting that close left
/// wire-view retrying 0x10 forever under mild loss while the host's
/// in-flight offer window re-armed static-screen IDRs at ~2 Hz.
public final class AVSampleBufferRendererVideoSink:
    VideoSink, @unchecked Sendable
{
    private let renderer: AVSampleBufferVideoRenderer
    private let onIrapEnqueued: @Sendable (FrameNumber) -> Void

    public init(
        renderer: AVSampleBufferVideoRenderer,
        onIrapEnqueued: @escaping @Sendable (FrameNumber) -> Void
    ) {
        self.renderer = renderer
        self.onIrapEnqueued = onIrapEnqueued
    }

    public func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        renderer.enqueue(sample)
        if unit.isIDR {
            onIrapEnqueued(unit.frameNumber)
        }
    }
}
