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
            guard let window = view.window, let session = model.session,
                  model.inputCapture == nil else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.makeFirstResponder(view)
            let capture = InputCapture(view: view, window: window) { packet, channel in
                session.sendInput(packet, channel: channel)
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
