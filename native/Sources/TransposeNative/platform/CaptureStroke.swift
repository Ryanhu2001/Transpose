import AppKit
import QuartzCore

/// A thin blue line stays legible on busy, light, and dark source content.
/// Both the live stroke and the retained outline use these exact layers.
enum CaptureAppearance {
    static let accent = NSColor(calibratedRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
    static let paper = NSColor(calibratedWhite: 1, alpha: 1)
    static let ink = NSColor(calibratedWhite: 0.25, alpha: 1)
    static let strokeWidth: CGFloat = 1.7
    static let haloWidth: CGFloat = 4.2
    static let startDiameter: CGFloat = 5.5

    static func configure(_ shape: CAShapeLayer, bounds: CGRect, scale: CGFloat, halo: Bool = false) {
        shape.frame = bounds
        shape.contentsScale = scale
        shape.fillColor = nil
        shape.strokeColor = (halo ? paper.withAlphaComponent(0.94) : accent).cgColor
        shape.lineWidth = halo ? haloWidth : strokeWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.fillRule = .evenOdd
        // Explicit actions also cover initial layer attachment and AppKit layout transactions.
        shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
    }
}

enum CaptureLayerGeometry {
    /// AppKit's unflipped view coordinates and this layer both use a bottom-left origin.
    static func configurePreview(_ layer: CALayer, image: CGImage, bounds: CGRect) {
        layer.frame = bounds
        layer.isGeometryFlipped = false
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = CGFloat(image.width) / max(1, bounds.width)
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
    }
}

/// Live gesture geometry stays open. Expensive simplification happens only in finish().
struct CaptureStroke {
    private(set) var points: [CGPoint] = []
    private(set) var current: CGPoint?
    private(set) var isDrawing = false
    private(set) var isRectangle = false

    var origin: CGPoint? { points.first }

    mutating func begin(at point: CGPoint, rectangle: Bool) {
        points = [point]
        current = point
        isDrawing = true
        isRectangle = rectangle
    }

    mutating func update(to point: CGPoint, rectangle: Bool) {
        guard isDrawing else { return }
        current = point
        isRectangle = rectangle
        if let previous = points.last, hypot(point.x - previous.x, point.y - previous.y) >= 1.5 {
            points.append(point)
        }
    }

    mutating func setRectangle(_ value: Bool) {
        guard isDrawing else { return }
        isRectangle = value
    }

    var openPath: CGPath {
        let path = CGMutablePath()
        guard let origin, let current else { return path }
        path.move(to: origin)
        if isRectangle {
            path.addLine(to: CGPoint(x: current.x, y: origin.y))
            path.addLine(to: current)
            path.addLine(to: CGPoint(x: origin.x, y: current.y))
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
            // Keep the visible tip under the pointer even below the sampling distance.
            if current != points.last { path.addLine(to: current) }
        }
        return path
    }

    mutating func finish(at point: CGPoint, rectangle: Bool) -> CaptureSelection? {
        guard isDrawing, let origin else { return nil }
        update(to: point, rectangle: rectangle)
        let selection: CaptureSelection
        if rectangle {
            selection = CaptureSelection(points: [origin, CGPoint(x: point.x, y: origin.y), point,
                                                   CGPoint(x: origin.x, y: point.y)], isRectangle: true)
        } else {
            var finished = points
            if finished.last != point { finished.append(point) }
            selection = CaptureSelection(points: finished, isRectangle: false)
        }
        isDrawing = false
        return selection
    }

    mutating func clear() {
        points.removeAll(keepingCapacity: false)
        current = nil
        isDrawing = false
        isRectangle = false
    }
}

/// The retained outline uses a small transparent window in global AppKit coordinates.
struct CaptureOutlineGeometry {
    let selectionFrame: CGRect
    let windowFrame: CGRect
    let localPath: CGPath
    let globalPath: CGPath

    init(selection: CaptureSelection, screenFrame: CGRect, padding: CGFloat = 6) {
        selectionFrame = selection.bounds.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        windowFrame = selectionFrame.insetBy(dx: -padding, dy: -padding)
        var globalTransform = CGAffineTransform(translationX: screenFrame.minX, y: screenFrame.minY)
        globalPath = selection.path.copy(using: &globalTransform)!
        var localTransform = CGAffineTransform(translationX: screenFrame.minX - windowFrame.minX,
                                               y: screenFrame.minY - windowFrame.minY)
        localPath = selection.path.copy(using: &localTransform)!
    }

    func contains(_ point: CGPoint) -> Bool {
        guard windowFrame.contains(point) else { return false }
        if globalPath.contains(point, using: .evenOdd) { return true }
        return globalPath.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
    }
}
