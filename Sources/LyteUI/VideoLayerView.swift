import AppKit
@preconcurrency import AVFoundation

/// Layer-hosting NSView around an AVSampleBufferDisplayLayer — the stream
/// surface shared by the dev CLI and the app.
public final class VideoLayerView: NSView {
    public init(layer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        // Layer-hosting view: the layer MUST be set before wantsLayer,
        // otherwise AppKit treats it as layer-backed and swaps in its own.
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Terminate key events silently: anything not consumed by InputCapture's
    // monitor (or a menu) would otherwise fall off the responder chain and
    // trigger NSBeep on every keystroke.
    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) {}
    public override func keyUp(with event: NSEvent) {}
    public override func flagsChanged(with event: NSEvent) {}
}
