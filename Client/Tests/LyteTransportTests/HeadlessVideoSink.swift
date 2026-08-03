import CoreMedia
import LyteTransport
import LyteWire

/// The display-free implementation of the production video organ seam. Gate
/// tests drive real assembly and sample construction into this sink without
/// constructing a window, display layer, or AV renderer.
final class HeadlessVideoSink: VideoSink, @unchecked Sendable {
    private let receive:
        @Sendable (CMSampleBuffer, DecodeUnit) -> Void

    init(
        receive: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void = {
            _, _ in
        }
    ) {
        self.receive = receive
    }

    func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        receive(sample, unit)
    }
}
