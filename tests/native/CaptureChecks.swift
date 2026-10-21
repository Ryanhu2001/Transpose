import AppKit
import CoreText

func runCaptureChecks() async throws -> Int {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "CaptureChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    var passed = 0
    let lasso = CaptureSelection(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 30),
                                          CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 100), CGPoint(x: 0, y: 100)], isRectangle: false)
    let mask = CaptureCoverage(selection: lasso)
    try require(mask.fraction(of: CGRect(x: 5, y: 60, width: 18, height: 14)) > 0.99, "Lasso omitted selected text")
    try require(mask.fraction(of: CGRect(x: 65, y: 60, width: 18, height: 14)) == 0, "Lasso included text outside its concave shape")
    passed += 1

    let canvas = CGSize(width: 200, height: 100), pixels = CGSize(width: 400, height: 200)
    let crop = CaptureGeometry.pixelCrop(for: CGRect(x: 20, y: 30, width: 40, height: 50), canvas: canvas, pixels: pixels)
    try require(crop == CGRect(x: 40, y: 40, width: 80, height: 100), "Retina crop y-flip failed")
    try require(CaptureGeometry.screenRect(for: CGRect(x: 0, y: 0, width: 1, height: 1), crop: crop!, canvas: canvas, pixels: pixels)
                == CGRect(x: 20, y: 30, width: 40, height: 50), "Retina coordinate round trip failed")
    passed += 1

    try require(CaptureGeometry.pixelCrop(for: CGRect(x: -10, y: 80, width: 40, height: 80), canvas: canvas, pixels: pixels)
                == CGRect(x: 0, y: 0, width: 60, height: 40), "Crop did not clamp to display")
    try require(CaptureGeometry.pixelCrop(for: CGRect(x: 10, y: 10, width: 2, height: 30), canvas: canvas, pixels: pixels) == nil,
                "Tiny crop was accepted")
    passed += 1

    let bowtie = CaptureSelection(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 0)],
                                  isRectangle: false)
    try require(CaptureGeometry.filledAreaEstimate(bowtie.points) > 4_900, "Self-intersecting lasso was treated as zero area")
    let bowtieMask = CaptureCoverage(selection: bowtie)
    try require(bowtieMask.fraction(of: CGRect(x: 40, y: 10, width: 10, height: 10)) > 0.99, "Even-odd lasso interior missing")
    try require(bowtieMask.fraction(of: CGRect(x: 5, y: 40, width: 10, height: 10)) == 0, "Even-odd lasso exterior included")
    passed += 1

    let trajectory = (0..<10_000).map { index in
        let angle = CGFloat(index) * .pi * 2 / 9_999
        return CGPoint(x: 200 + 150 * cos(angle), y: 200 + 150 * sin(angle))
    }
    let simplified = CaptureSelection(points: trajectory, isRectangle: false)
    try require(simplified.points.count <= 384, "Lasso complexity is unbounded")
    try require(CaptureGeometry.filledAreaEstimate(simplified.points) > 69_000, "Simplification destroyed the lasso")
    passed += 1

    let lines = [OCRLine(text: "heading", rect: CGRect(x: 0, y: 100, width: 400, height: 20)),
                 OCRLine(text: "right 1", rect: CGRect(x: 240, y: 65, width: 150, height: 16)),
                 OCRLine(text: "left 2", rect: CGRect(x: 0, y: 40, width: 150, height: 16)),
                 OCRLine(text: "left 1", rect: CGRect(x: 0, y: 65, width: 150, height: 16)),
                 OCRLine(text: "right 2", rect: CGRect(x: 240, y: 40, width: 150, height: 16))]
    try require(OCRReadingOrder.ordered(lines).map(\.text) == ["heading", "left 1", "left 2", "right 1", "right 2"],
                "Two-column reading order was interleaved")
    passed += 1

    // Synthetic pixels stay in memory; no screen capture permission or screenshot history is used.
    let width = 720, height = 320
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
    for (text, point) in [("KEEP TOP", CGPoint(x: 30, y: 240)), ("KEEP LEFT", CGPoint(x: 30, y: 80)),
                          ("DROP OUTSIDE", CGPoint(x: 330, y: 80))] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = point
        CTLineDraw(line, context)
    }
    let image = context.makeImage()!
    let imageLasso = CaptureSelection(points: [CGPoint(x: 0, y: 0), CGPoint(x: 210, y: 0), CGPoint(x: 210, y: 180),
                                               CGPoint(x: 720, y: 180), CGPoint(x: 720, y: 320), CGPoint(x: 0, y: 320)], isRectangle: false)
    let text = try await OCRService.recognize(image: image, canvas: CGSize(width: width, height: height), selection: imageLasso)
    try require(text.contains("KEEP TOP") && text.contains("KEEP LEFT"), "Vision omitted selected synthetic text: \(text)")
    try require(!text.contains("DROP") && !text.contains("OUTSIDE"), "Vision included text outside the lasso: \(text)")
    passed += 1

    let cancelled = Task { try await OCRService.recognize(image: image, canvas: CGSize(width: width, height: height), selection: imageLasso) }
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        try require(false, "Cancelled OCR returned a translation source")
    } catch is CancellationError { passed += 1 }
    return passed
}
