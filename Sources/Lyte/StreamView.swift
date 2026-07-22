import SwiftUI
@preconcurrency import AVFoundation
import LyteKit
import LyteUI

/// The stream surface: wraps the shared VideoLayerView and wires input
/// capture to the session once the view lands in a window.
struct StreamView: NSViewRepresentable {
    let model: ConnectionModel

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView(layer: model.displayLayer)
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // The Lyte-UDP path (CL-9): evdev-speaking capture onto the
            // session's reliable input stream. Coordinates map through
            // the aspect-fit rect into the host's stream space, learned
            // from the first delivered sample (model.lyteVideoSize).
            if let lyte = model.lyteSession {
                guard model.lyteInputCapture == nil else { return }
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
                    })
                capture.start()
                model.lyteInputCapture = capture
                return
            }

            guard let session = model.session, model.inputCapture == nil else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.makeFirstResponder(view)
            let capture = InputCapture(view: view, window: window) { packet, channel in
                session.sendInput(packet, channel: channel)
            }
            if let policy = model.policy {
                capture.videoSize = CGSize(width: policy.width, height: policy.height)
            }
            capture.start()
            if model.policy?.mouseLockedByDefault == true {
                capture.toggleLock()
            }
            model.inputCapture = capture
        }
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}
