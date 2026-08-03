import CoreMedia
import LyteTransport
import LyteWire

/// The display-free implementation of the production video organ seam. Gate
/// tests drive real assembly and sample construction into this sink without
/// constructing a window, display layer, or AV renderer.
public final class HeadlessVideoSink: VideoSink, @unchecked Sendable {
    private let receive:
        @Sendable (CMSampleBuffer, DecodeUnit) -> Void

    public init(
        receive: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void = {
            _, _ in
        }
    ) {
        self.receive = receive
    }

    public func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        receive(sample, unit)
    }
}
