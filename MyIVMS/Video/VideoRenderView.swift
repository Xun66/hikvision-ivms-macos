import SwiftUI
import AVFoundation

/// Hosts an `AVSampleBufferDisplayLayer` inside SwiftUI. The layer is made the
/// NSView's *backing layer* directly (via `makeBackingLayer`) — the reliable
/// AppKit pattern that keeps it correctly sized and in the layer tree. The
/// earlier "add as sublayer of a wrapper CALayer" approach rendered black.
struct VideoRenderView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(displayLayer: layer)
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {}
}

final class SampleBufferHostView: NSView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Make the display layer the view's backing layer.
    override func makeBackingLayer() -> CALayer {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        return displayLayer
    }
}
