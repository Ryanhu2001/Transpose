import AppKit
import Vision

/// A selection in screen-local, bottom-left-origin points. Image pixels are never persisted.
// The cached CGPath is copied to an immutable path before crossing threads.
struct CaptureSelection: @unchecked Sendable {
    let points: [CGPoint]
    let isRectangle: Bool
    let bounds: CGRect
    let path: CGPath

    init(points: [CGPoint], isRectangle: Bool) {
        self.points = isRectangle ? points : CaptureGeometry.simplified(points, tolerance: 0.75, maximumPoints: 384)
        self.isRectangle = isRectangle
        self.bounds = CaptureGeometry.bounds(of: self.points)
        let path = CGMutablePath()
        if let first = self.points.first {
            path.move(to: first)
            for point in self.points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        self.path = path.copy()!
    }

    func includes(_ rect: CGRect) -> Bool {
        if isRectangle { return bounds.intersection(rect).area >= rect.area * 0.45 }
        return CaptureGeometry.coverage(of: rect, polygon: points) >= 0.45
    }
}

enum CaptureGeometry {
    /// Remove hand jitter and cap path complexity while preserving endpoints and major corners.
    static func simplified(_ points: [CGPoint], tolerance: CGFloat, maximumPoints: Int) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let toleranceSquared = tolerance * tolerance
        var keep = Set([0, points.count - 1])
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
            var farthest = -1, farthestDistance = toleranceSquared
            for index in (start + 1)..<end {
                let point = points[index]
                let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
                let px = point.x - a.x - t * dx, py = point.y - a.y - t * dy
                let distance = px * px + py * py
                if distance > farthestDistance { farthest = index; farthestDistance = distance }
            }
            if farthest >= 0 {
                keep.insert(farthest)
                stack.append((start, farthest)); stack.append((farthest, end))
            }
        }
        let reduced = keep.sorted().map { points[$0] }
        guard reduced.count > maximumPoints else { return reduced }
        return (0..<maximumPoints).map { reduced[Int((Double($0) * Double(reduced.count - 1) / Double(maximumPoints - 1)).rounded())] }
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            sum += polygon[index].x * next.y - next.x * polygon[index].y
        }
        return abs(sum) / 2
    }

    /// Even-odd scanline area also accepts self-intersecting lassos whose signed areas cancel.
    static func filledAreaEstimate(_ polygon: [CGPoint]) -> CGFloat {
        let rect = bounds(of: polygon)
        guard polygon.count >= 3, rect.width > 0, rect.height > 0 else { return 0 }
        let samples = min(128, max(16, Int(ceil(rect.height))))
        let step = rect.height / CGFloat(samples)
        return (0..<samples).reduce(CGFloat.zero) { total, row in
            let crossings = scanlineIntersections(at: rect.minY + (CGFloat(row) + 0.5) * step, polygon: polygon)
            var width: CGFloat = 0
            for pair in stride(from: 0, to: crossings.count - 1, by: 2) { width += crossings[pair + 1] - crossings[pair] }
            return total + width * step
        }
    }

    static func scanlineIntersections(at y: CGFloat, polygon: [CGPoint]) -> [CGFloat] {
        guard polygon.count >= 3 else { return [] }
        var intersections: [CGFloat] = []
        var previous = polygon.last!
        for point in polygon {
            if (point.y > y) != (previous.y > y) {
                intersections.append(point.x + (previous.x - point.x) * (y - point.y) / (previous.y - point.y))
            }
            previous = point
        }
        return intersections.sorted()
    }

    static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index], b = polygon[previous]
            // Include the edge to avoid dropping characters exactly on the selection boundary.
            let cross = (point.y - a.y) * (b.x - a.x) - (point.x - a.x) * (b.y - a.y)
            if abs(cross) < 0.001,
               point.x >= min(a.x, b.x) - 0.001, point.x <= max(a.x, b.x) + 0.001,
               point.y >= min(a.y, b.y) - 0.001, point.y <= max(a.y, b.y) + 0.001 { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    /// Sample the glyph area, rather than only its center or the lasso's bounding rectangle.
    static func coverage(of rect: CGRect, polygon: [CGPoint]) -> CGFloat {
        guard !rect.isEmpty, bounds(of: polygon).intersects(rect) else { return 0 }
        let samples = 5
        var selected = 0
        for row in 0..<samples {
            for column in 0..<samples {
                let point = CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(samples),
                                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(samples))
                if contains(point, polygon: polygon) { selected += 1 }
            }
        }
        return CGFloat(selected) / CGFloat(samples * samples)
    }

    /// CGImage cropping uses top-left pixel coordinates; AppKit screen points use bottom-left.
    static func pixelCrop(for rect: CGRect, canvas: CGSize, pixels: CGSize) -> CGRect? {
        guard canvas.width > 0, canvas.height > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: canvas))
        guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3 else { return nil }
        let sx = pixels.width / canvas.width, sy = pixels.height / canvas.height
        let crop = CGRect(x: floor(clipped.minX * sx), y: floor((canvas.height - clipped.maxY) * sy),
                          width: ceil(clipped.maxX * sx) - floor(clipped.minX * sx),
                          height: ceil((canvas.height - clipped.minY) * sy) - floor((canvas.height - clipped.maxY) * sy))
            .intersection(CGRect(origin: .zero, size: pixels))
        return crop.isEmpty ? nil : crop
    }

    static func screenRect(for normalizedRect: CGRect, crop: CGRect, canvas: CGSize, pixels: CGSize) -> CGRect {
        let sx = canvas.width / pixels.width, sy = canvas.height / pixels.height
        return CGRect(x: (crop.minX + normalizedRect.minX * crop.width) * sx,
                      y: canvas.height - crop.maxY * sy + normalizedRect.minY * crop.height * sy,
                      width: normalizedRect.width * crop.width * sx,
                      height: normalizedRect.height * crop.height * sy)
    }
}

/// An even-odd selection raster plus summed-area table. Construction is once per OCR job;
/// every glyph/line coverage lookup is constant time regardless of the lasso's point count.
struct CaptureCoverage {
    private let selection: CaptureSelection
    private let scale: CGFloat
    private let width: Int
    private let height: Int
    private let sums: [UInt32]

    init(selection: CaptureSelection) {
        self.selection = selection
        let scale = min(1, 1_600 / max(1, max(selection.bounds.width, selection.bounds.height)))
        self.scale = scale
        let width = max(1, Int(ceil(selection.bounds.width * scale)))
        let height = max(1, Int(ceil(selection.bounds.height * scale)))
        self.width = width; self.height = height
        if selection.isRectangle { sums = []; return }
        var prefix = [UInt32](repeating: 0, count: (width + 1) * (height + 1))
        for row in 0..<height {
            let y = selection.bounds.minY + (CGFloat(row) + 0.5) / scale
            let crossings = CaptureGeometry.scanlineIntersections(at: y, polygon: selection.points)
            var intervals: [Range<Int>] = []
            for pair in stride(from: 0, to: max(0, crossings.count - 1), by: 2) {
                let start = max(0, min(width, Int(ceil((crossings[pair] - selection.bounds.minX) * scale - 0.5))))
                let end = max(start, min(width, Int(ceil((crossings[pair + 1] - selection.bounds.minX) * scale - 0.5))))
                if end > start { intervals.append(start..<end) }
            }
            var interval = 0
            var selected: UInt32 = 0
            for column in 0..<width {
                while interval < intervals.count, column >= intervals[interval].upperBound { interval += 1 }
                if interval < intervals.count, intervals[interval].contains(column) { selected += 1 }
                prefix[(row + 1) * (width + 1) + column + 1] = prefix[row * (width + 1) + column + 1] + selected
            }
        }
        sums = prefix
    }

    func fraction(of rect: CGRect) -> CGFloat {
        guard !rect.isEmpty, selection.bounds.intersects(rect) else { return 0 }
        if selection.isRectangle { return selection.bounds.intersection(rect).area / rect.area }
        let x0 = Int(floor((rect.minX - selection.bounds.minX) * scale))
        let x1 = Int(ceil((rect.maxX - selection.bounds.minX) * scale))
        let y0 = Int(floor((rect.minY - selection.bounds.minY) * scale))
        let y1 = Int(ceil((rect.maxY - selection.bounds.minY) * scale))
        let left = min(width, max(0, x0)), right = min(width, max(0, x1))
        let bottom = min(height, max(0, y0)), top = min(height, max(0, y1))
        guard right > left, top > bottom else { return 0 }
        let stride = width + 1
        let selected = Int64(sums[top * stride + right]) + Int64(sums[bottom * stride + left])
            - Int64(sums[top * stride + left]) - Int64(sums[bottom * stride + right])
        return min(1, CGFloat(selected) / CGFloat(max(1, (x1 - x0) * (y1 - y0))))
    }
}

struct OCRLine {
    let text: String
    let rect: CGRect
}

enum OCRReadingOrder {
    /// Basic document layout: split genuine column gutters before ordering lines vertically.
    /// A spanning heading is emitted first, then the columns beneath it.
    static func ordered(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1 else { return lines }
        if let columns = splitColumns(lines) { return ordered(columns.0) + ordered(columns.1) }
        let byHeight = lines.sorted { $0.rect.midY > $1.rect.midY }
        if lines.count >= 5 {
            for count in 1...min(3, lines.count - 4) {
                let headings = Array(byHeight.prefix(count)), body = Array(byHeight.dropFirst(count))
                if let columns = splitColumns(body),
                   headings.allSatisfy({ $0.rect.minX < columns.0.map(\.rect.maxX).max()! && $0.rect.maxX > columns.1.map(\.rect.minX).min()! }) {
                    return rowOrder(headings) + ordered(columns.0) + ordered(columns.1)
                }
            }
        }
        return rowOrder(lines)
    }

    private static func splitColumns(_ lines: [OCRLine]) -> ([OCRLine], [OCRLine])? {
        guard lines.count >= 4 else { return nil }
        let sorted = lines.sorted { $0.rect.minX < $1.rect.minX }
        let heights = lines.map(\.rect.height).sorted()
        let minimumGap = max(18, heights[heights.count / 2] * 1.4)
        var rightEdge = sorted[0].rect.maxX
        var best: (gap: CGFloat, cut: CGFloat)?
        for line in sorted.dropFirst() {
            let gap = line.rect.minX - rightEdge
            if gap >= minimumGap, best == nil || gap > best!.gap { best = (gap, rightEdge + gap / 2) }
            rightEdge = max(rightEdge, line.rect.maxX)
        }
        guard let cut = best?.cut else { return nil }
        let left = lines.filter { $0.rect.maxX <= cut }, right = lines.filter { $0.rect.minX >= cut }
        guard left.count >= 2, right.count >= 2, left.count + right.count == lines.count else { return nil }
        return (left, right)
    }

    private static func rowOrder(_ lines: [OCRLine]) -> [OCRLine] {
        var rows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let index = rows.indices.last,
               abs(rows[index][0].rect.midY - line.rect.midY) <= min(rows[index][0].rect.height, line.rect.height) * 0.55 {
                rows[index].append(line)
            } else { rows.append([line]) }
        }
        return rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

enum OCRService {
    /// Vision runs off the main thread. Only the resulting text leaves the capture subsystem.
    static func recognize(image: CGImage, canvas: CGSize, selection: CaptureSelection) async throws -> String {
        let cancellation = OCRCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let text = try recognizeSynchronously(image: image, canvas: canvas, selection: selection, cancellation: cancellation)
                        continuation.resume(returning: text)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func recognizeSynchronously(image: CGImage, canvas: CGSize, selection: CaptureSelection,
                                              cancellation: OCRCancellation) throws -> String {
        try cancellation.check()
        let pixels = CGSize(width: image.width, height: image.height)
        guard let cropRect = CaptureGeometry.pixelCrop(for: selection.bounds.insetBy(dx: -3, dy: -3), canvas: canvas, pixels: pixels),
              let crop = image.cropping(to: cropRect) else {
            throw NSError(domain: "Transpose.OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "圈选区域太小，请重新圈选。"])
        }
        let request = VNRecognizeTextRequest()
        try cancellation.register(request)
        defer { cancellation.clear() }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]
        request.recognitionLanguages = preferred.filter { supported.contains($0) }
        request.minimumTextHeight = min(0.006, 7 / Float(crop.height))
        do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw error }
        try cancellation.check()
        let coverage = CaptureCoverage(selection: selection)
        try cancellation.check()

        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            try cancellation.check()
            guard let candidate = observation.topCandidates(1).first else { continue }
            let lineRect = CaptureGeometry.screenRect(for: observation.boundingBox, crop: cropRect, canvas: canvas, pixels: pixels)
            let selected = try selectedText(candidate, lineRect: lineRect, crop: cropRect, canvas: canvas, pixels: pixels,
                                            coverage: coverage, cancellation: cancellation)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty { lines.append(OCRLine(text: selected, rect: lineRect)) }
        }
        return OCRReadingOrder.ordered(lines).map(\.text).joined(separator: "\n")
    }

    private static func selectedText(_ candidate: VNRecognizedText, lineRect: CGRect, crop: CGRect,
                                     canvas: CGSize, pixels: CGSize, coverage: CaptureCoverage,
                                     cancellation: OCRCancellation) throws -> String {
        // Ask Vision for individual glyph/word geometry so text inside the lasso's bounding box
        // but outside the actual shape cannot enter the translation.
        let lineCoverage = coverage.fraction(of: lineRect)
        guard lineCoverage > 0 else { return "" }
        if lineCoverage >= 0.999 { return candidate.string }
        let source = candidate.string
        var result = "", pendingSpace = false
        var start = source.startIndex
        while start < source.endIndex {
            try cancellation.check()
            let end = source.index(after: start)
            let character = source[start..<end]
            if character.allSatisfy(\.isWhitespace) {
                pendingSpace = !result.isEmpty
            } else {
                let glyph = try? candidate.boundingBox(for: start..<end)
                // Unknown glyph geometry must not fall back to a partially selected whole line.
                let fraction = glyph.map {
                    coverage.fraction(of: CaptureGeometry.screenRect(for: $0.boundingBox, crop: crop, canvas: canvas, pixels: pixels))
                } ?? 0
                if fraction >= 0.45 {
                    if pendingSpace && !result.isEmpty { result += " " }
                    result += character
                    pendingSpace = false
                } else if !result.isEmpty { pendingSpace = true }
            }
            start = end
        }
        return result
    }
}

/// The lock closes the cancellation-vs-registration race, while VNRequest.cancel stops active work.
private final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false

    func register(_ request: VNRequest) throws {
        lock.lock()
        let stopped = cancelled
        if !stopped { self.request = request }
        lock.unlock()
        if stopped { request.cancel(); throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = request
        lock.unlock()
        active?.cancel()
    }

    func clear() {
        lock.lock(); request = nil; lock.unlock()
    }

    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}
