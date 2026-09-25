import AppKit
@preconcurrency import AVFoundation
import LyteUI
import LyteWire
import XCTest
@testable import Lyte

/// The worn host cursor matches the video's on-glass magnification
/// whenever the stream size or the view's size changes, not only when
/// the host announces a new shape.
@MainActor
final class HostCursorTests: XCTestCase {
    func testTheHostCursorRefitsToTheVideoAndTheViewSize() {
        let model = ConnectionModel(services: LifecycleHarness().services)
        let view = VideoLayerView(layer: AVSampleBufferDisplayLayer())
        view.setFrameSize(NSSize(width: 1_000, height: 500))
        model.lyteVideoView = view
        model.handleLyteEvent(.hostCursorShapeChanged(CursorShape(
            width: 32, height: 32, hotspotX: 0, hotspotY: 0,
            pixels: [UInt8](repeating: 0xFF, count: 32 * 32 * 4))))
        XCTAssertEqual(view.hostCursor?.image.size.width, 24,
                       "before the first sample: the 0.75 guess")

        model.lyteVideoSize = CGSize(width: 2_000, height: 1_000)
        XCTAssertEqual(view.hostCursor?.image.size.width, 16)

        view.setFrameSize(NSSize(width: 4_000, height: 2_000))
        XCTAssertEqual(view.hostCursor?.image.size.width, 64)
    }
}
