import SwiftUI
@preconcurrency import AVFoundation
import LyteUI

/// The stream surface: wraps the shared VideoLayerView and wires input
/// capture to the session once the view lands in a window.
struct StreamView: NSViewRepresentable {
    let model: ConnectionModel
    /// CL-13: fed on every mouse event the capture sees — the control
    /// strip's reveal clock (the capture consumes moves over the
    /// video, so SwiftUI hover tracking alone would go blind). Carries
    /// the pointer's edge geometry since CL-18 (the dwell reveal).
    var onMouseActivity: @MainActor (PointerActivity) -> Void = { _ in }

    /// The window attaches sometime AFTER makeNSView returns — usually
    /// one runloop turn, but not dependably. CL-13 shipped a one-shot
    /// async that gave up silently when it wasn't, leaving a session
    /// with no input path and no evidence (CL-16's latent finding):
    /// bounded retry instead, verdict logged either way, and the stats
    /// overlay renders capture active/INACTIVE live off
    /// `model.lyteInputCapture`.
    private static let installRetryInterval: Duration = .milliseconds(50)
    private static let installMaxAttempts = 80   // ~4 s bound

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView(layer: model.displayLayer)
        // E3: the model dresses this surface with the host's 0x24
        // cursor shapes (weak — the view's lifetime stays SwiftUI's).
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
                    // CL-9: evdev-speaking capture onto the session's
                    // reliable input stream. Coordinates map through
                    // the aspect-fit rect into the host's stream
                    // space, learned from the first delivered sample
                    // (model.lyteVideoSize).
                    window.collectionBehavior.insert(.fullScreenPrimary)
                    window.makeFirstResponder(view)
                    let capture = LyteInputCapture(
                        view: view, window: window,
                        videoSize: { model.lyteVideoSize },
                        send: { body in
                            // Routed through the model's LIVE session
                            // (F-5): the capture outlives a roaming
                            // re-dial — sends against a detached
                            // session simply drop, and the reconnected
                            // one picks them up without a reinstall.
                            // A refused send is a teardown race — the
                            // session is already ending; never crash
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
