import SwiftUI
@preconcurrency import AVFoundation
import LyteUI

/// The stream surface: wraps the shared VideoLayerView and wires input
/// capture to the session once the view lands in a window.
struct StreamView: NSViewRepresentable {
    let model: ConnectionModel
    /// CL-13: pinged on every mouse event the capture sees — the
    /// control strip's reveal clock (the capture consumes moves over
    /// the video, so SwiftUI hover tracking alone would go blind).
    var onMouseActivity: @MainActor () -> Void = {}

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView(layer: model.displayLayer)
        let onMouseActivity = onMouseActivity
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // CL-9: evdev-speaking capture onto the session's reliable
            // input stream. Coordinates map through the aspect-fit rect
            // into the host's stream space, learned from the first
            // delivered sample (model.lyteVideoSize).
            guard let lyte = model.lyteSession, model.lyteInputCapture == nil else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.makeFirstResponder(view)
            let capture = LyteInputCapture(
                view: view, window: window,
                videoSize: { model.lyteVideoSize },
                send: { body in
                    // A refused send is a teardown race — the
                    // session is already ending; never crash the
                    // event monitor over it.
                    _ = try? lyte.sendInput(body)
                },
                onActivity: onMouseActivity)
            capture.start()
            model.lyteInputCapture = capture
        }
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}
