import AppKit
import QuartzCore

func runCaptureInteractionChecks() throws -> Int {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "CaptureInteractionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func closeCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { if $0.pointee.type == .closeSubpath { count += 1 } }
        return count
    }

    var checks = 0
    var stroke = CaptureStroke()
    let start = CGPoint(x: 20, y: 30)
    stroke.begin(at: start, rectangle: false)
    try require(stroke.isDrawing && stroke.origin == start && stroke.current == start, "Starting point missing")
    try require(closeCount(stroke.openPath) == 0 && stroke.openPath.currentPoint == start, "Starting stroke is unexpectedly closed")
    checks += 1

    // Render synthetic quadrants through the same preview setup as the unflipped AppKit view.
    // No window or user-screen pixels are involved.
    let side = 200
    let bitmapSpace = CGColorSpaceCreateDeviceRGB()
    func bitmap() -> CGContext {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: bitmapSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    let fixture = bitmap()
    let quadrants: [(CGRect, [CGFloat])] = [
        (CGRect(x: 0, y: 100, width: 100, height: 100), [1, 0, 0, 1]),
        (CGRect(x: 100, y: 100, width: 100, height: 100), [0, 1, 0, 1]),
        (CGRect(x: 0, y: 0, width: 100, height: 100), [0, 0, 1, 1]),
        (CGRect(x: 100, y: 0, width: 100, height: 100), [1, 1, 0, 1])]
    for (rect, color) in quadrants {
        fixture.setFillColor(CGColor(colorSpace: bitmapSpace, components: color)!)
        fixture.fill(rect)
    }
    let image = fixture.makeImage()!
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: side, height: side)
    root.isGeometryFlipped = false
    let preview = CALayer()
    CaptureLayerGeometry.configurePreview(preview, image: image, bounds: root.bounds)
    root.addSublayer(preview)
    let rendered = bitmap()
    root.render(in: rendered)
    func pixel(_ context: CGContext, x: Int, topRow: Int) -> [UInt8] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let index = topRow * context.bytesPerRow + x * 4
        return [bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]]
    }
    for point in [(50, 50), (150, 50), (50, 150), (150, 150)] {
        let expected = pixel(fixture, x: point.0, topRow: point.1)
        let actual = pixel(rendered, x: point.0, topRow: point.1)
        try require(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "Static preview was mirrored or inverted")
    }
    try require(pixel(rendered, x: 50, topRow: 50)[0] > 240 && pixel(rendered, x: 50, topRow: 150)[2] > 240,
                "Synthetic top/bottom fixture was inverted")
    checks += 1

    let trace = CAShapeLayer()
    trace.frame = root.bounds
    trace.strokeColor = CGColor(colorSpace: bitmapSpace, components: [1, 0, 1, 1])!
    trace.lineWidth = 10
    trace.fillColor = nil
    let logicalTop = CGMutablePath()
    logicalTop.move(to: CGPoint(x: 25, y: 150))
    logicalTop.addLine(to: CGPoint(x: 75, y: 150))
    trace.path = logicalTop
    root.addSublayer(trace)
    let composited = bitmap()
    root.render(in: composited)
    let marked = pixel(composited, x: 50, topRow: 50)
    try require(marked[0] > 240 && marked[1] < 15 && marked[2] > 240, "AppKit y-up stroke did not align with image top")
    try require(pixel(composited, x: 50, topRow: 150)[2] > 240, "Stroke changed the opposite side of the preview")
    checks += 1

    stroke.update(to: CGPoint(x: 80, y: 30), rectangle: false)
    stroke.update(to: CGPoint(x: 80, y: 90), rectangle: false)
    try require(closeCount(stroke.openPath) == 0, "Live freehand stroke closed before release")
    try require(stroke.openPath.currentPoint == CGPoint(x: 80, y: 90), "Visible stroke tip lagged pointer")
    checks += 1

    let committed = stroke.points.count
    stroke.update(to: CGPoint(x: 80.3, y: 90.2), rectangle: false)
    try require(stroke.points.count == committed, "Subpixel point defeated sampling")
    try require(stroke.openPath.currentPoint == CGPoint(x: 80.3, y: 90.2), "Subpixel pointer movement did not move visible tip")
    checks += 1

    let finished = stroke.finish(at: CGPoint(x: 20, y: 90), rectangle: false)!
    try require(closeCount(finished.path) == 1, "Mouse release must close the selected shape once")
    try require(!stroke.isDrawing && stroke.finish(at: start, rectangle: false) == nil, "A completed gesture fired twice")
    checks += 1

    stroke.begin(at: start, rectangle: true)
    stroke.update(to: CGPoint(x: 100, y: 120), rectangle: true)
    try require(closeCount(stroke.openPath) == 0, "Live rectangle closed before release")
    let rectangle = stroke.finish(at: CGPoint(x: 100, y: 120), rectangle: true)!
    try require(rectangle.isRectangle && rectangle.bounds == CGRect(x: 20, y: 30, width: 80, height: 90), "Shift rectangle geometry incorrect")
    try require(closeCount(rectangle.path) == 1, "Released rectangle did not close once")
    checks += 1

    let geometry = CaptureOutlineGeometry(selection: rectangle, screenFrame: CGRect(x: -1_440, y: 900, width: 1_440, height: 900))
    try require(geometry.selectionFrame == CGRect(x: -1_420, y: 930, width: 80, height: 90), "Global outline frame lost display origin")
    try require(geometry.windowFrame == CGRect(x: -1_426, y: 924, width: 92, height: 102), "Transparent outline window padding incorrect")
    try require(geometry.localPath.boundingBoxOfPath == CGRect(x: 6, y: 6, width: 80, height: 90), "Outline was not translated into its small window")
    try require(geometry.contains(CGPoint(x: -1_400, y: 950)), "Global outline hit test omitted interior")
    try require(!geometry.contains(CGPoint(x: -1_300, y: 950)), "Global outline hit test included exterior")
    checks += 1

    let concave = CaptureSelection(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 30),
                                            CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 100), CGPoint(x: 0, y: 100)], isRectangle: false)
    let concaveOutline = CaptureOutlineGeometry(selection: concave, screenFrame: CGRect(x: 50, y: -500, width: 1_000, height: 700))
    try require(concaveOutline.contains(CGPoint(x: 65, y: -420)), "Concave outline interior missing")
    try require(!concaveOutline.contains(CGPoint(x: 130, y: -420)), "Concave outline hit test used its bounding box")
    checks += 1

    stroke.begin(at: .zero, rectangle: false)
    for index in 1...3_000 {
        let angle = CGFloat(index) * .pi * 2 / 3_000
        stroke.update(to: CGPoint(x: 500 * cos(angle), y: 500 * sin(angle)), rectangle: false)
    }
    try require(stroke.points.count > 500, "Live gesture was simplified while dragging")
    try require(closeCount(stroke.openPath) == 0, "Long live gesture unexpectedly closed")
    let reduced = stroke.finish(at: CGPoint(x: 500, y: 0), rectangle: false)!
    try require(reduced.points.count <= 384, "Released gesture was not simplified")
    checks += 1

    stroke.begin(at: start, rectangle: false)
    stroke.update(to: CGPoint(x: 80, y: 90), rectangle: false)
    stroke.clear()
    try require(!stroke.isDrawing && stroke.points.isEmpty && stroke.origin == nil && stroke.current == nil, "Cancelled gesture retained state")
    try require(stroke.openPath.isEmpty && stroke.finish(at: start, rectangle: false) == nil, "Cancelled gesture can still produce a selection")
    checks += 1
    return checks
}

/// CPU geometry/layer-property benchmark only; this does not measure display or mouse frame rate.
func captureInteractionGeometryBenchmark(points: Int = 2_000) -> TimeInterval {
    var stroke = CaptureStroke()
    stroke.begin(at: CGPoint(x: 1_000, y: 500), rectangle: false)
    let shape = CAShapeLayer()
    let start = Date()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for index in 1...points {
        let angle = CGFloat(index) * .pi * 2 / CGFloat(points)
        stroke.update(to: CGPoint(x: 500 + 500 * cos(angle), y: 500 + 500 * sin(angle)), rectangle: false)
        shape.path = stroke.openPath
    }
    CATransaction.commit()
    return Date().timeIntervalSince(start)
}
