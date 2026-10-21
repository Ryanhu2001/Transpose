import AppKit
import SwiftUI

/// A visible target for resizing a borderless result panel without moving it.
struct WindowResizeHandle: NSViewRepresentable {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.toolTip = L10n.text("拖动以调整窗口大小")
        view.setAccessibilityLabel(L10n.text("调整窗口大小"))
    }
}

final class ResizeHandleView: NSView {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var startFrame: NSRect?
    private var startPoint: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 5, y: 4))
        path.line(to: NSPoint(x: 14, y: 13))
        path.move(to: NSPoint(x: 10, y: 4))
        path.line(to: NSPoint(x: 14, y: 8))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startPoint = window.convertPoint(toScreen: event.locationInWindow)
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startFrame, let startPoint else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? startFrame
        let frame = ResultWindowSizing.resizedFrame(start: startFrame, delta: delta,
                                                   minimum: window.minSize, visibleFrame: screen)
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard startFrame != nil else { return }
        startFrame = nil
        startPoint = nil
        onEnd?()
    }
}
