import AppKit
import SwiftUI

/// MenuBarExtra grows its window with the content but never shrinks it, which leaves the content
/// floating in a blank band under the menu bar. Keep the top edge in place and fit the height.
struct PanelHeightFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        // The window is only attached, and safe to resize, after SwiftUI's own layout pass.
        DispatchQueue.main.async { [weak view] in
            guard height > 0, let window = view?.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) > 0.5 else { return }
            var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height,
                width: content.width, height: height))
            frame.origin.y = window.frame.maxY - frame.height
            window.setFrame(frame, display: true)
        }
    }
}
