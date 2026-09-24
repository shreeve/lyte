import SwiftUI
@preconcurrency import AVFoundation
import LyteUI

/// The stream surface: wraps the shared VideoLayerView and wires input
/// capture to the session once the view lands in a window.
struct StreamView: NSViewRepresentable {
    let model: ConnectionModel
    /// Fed on every mouse event the capture sees, with the pointer's edge
    /// geometry — the control strip's reveal clock (the capture consumes
    /// moves over the video, so SwiftUI hover tracking alone is blind).
    var onMouseActivity: @MainActor (PointerActivity) -> Void = { _ in }

    /// The window attaches sometime after makeNSView returns — usually
    /// one runloop turn, but not dependably — so attachment is a bounded
    /// retry with the verdict logged either way; the stats overlay shows
    /// capture active/INACTIVE live.
    private static let installRetryInterval: Duration = .milliseconds(50)
    private static let installMaxAttempts = 80   // ~4 s bound

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView(layer: model.displayLayer)
        // The model dresses this surface with the host's cursor shapes
        // (weak — the view's lifetime stays SwiftUI's).
        model.lyteVideoView = view
        let model = model
        let onMouseActivity = onMouseActivity
        Task { @MainActor in
            for attempt in 1...Self.installMaxAttempts {
                // Session already gone (teardown race) or another
                // make pass installed first: nothing left to do.
                guard model.lyteSession != nil,
                      model.lyteInputCapture == nil else { return }
                if let window = view.window {
                    // Evdev-speaking capture onto the session's reliable
                    // input stream, mapped into the host's stream space
                    // (model.lyteVideoSize).
                    window.collectionBehavior.insert(.fullScreenPrimary)
                    window.makeFirstResponder(view)
                    let capture = LyteInputCapture(
                        view: view, window: window,
                        videoSize: { model.lyteVideoSize },
                        send: { body in
                            // Routed through the model's live session: the
                            // capture outlives a roaming re-dial, and sends
                            // against a detached session simply drop. A
                            // refused send is a teardown race — never crash
                            // the event monitor over it.
                            model.lyteSession?.enqueueInput(body)
                        },
                        onActivity: onMouseActivity)
                    capture.start()
                    model.lyteInputCapture = capture
                    NSLog("lyte input capture: installed (attempt \(attempt))")
                    return
                }
                try? await Task.sleep(for: Self.installRetryInterval)
            }
            NSLog("lyte input capture: GAVE UP — no window after "
                + "\(Self.installMaxAttempts) attempts; input cannot reach "
                + "the host (stats overlay reads capture INACTIVE)")
        }
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}
