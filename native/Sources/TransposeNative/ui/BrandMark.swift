import AppKit
import SwiftUI

/// A drawn serif T with a lifted crossbar, open brackets, and a balanced foot.
/// Keep this contour in sync with Assets/GenerateIcon.swift.
enum TransposeBrand {
    static func outline(in rect: CGRect, flipped: Bool = false) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 17, y: 86))
        path.addCurve(to: CGPoint(x: 35, y: 85), control1: CGPoint(x: 23, y: 84), control2: CGPoint(x: 29, y: 85))
        path.addLine(to: CGPoint(x: 75, y: 85))
        path.addCurve(to: CGPoint(x: 86, y: 89), control1: CGPoint(x: 80, y: 85), control2: CGPoint(x: 83, y: 87))
        path.addLine(to: CGPoint(x: 81, y: 67))
        path.addLine(to: CGPoint(x: 77, y: 67))
        path.addCurve(to: CGPoint(x: 58, y: 78), control1: CGPoint(x: 76, y: 76), control2: CGPoint(x: 68, y: 78))
        path.addLine(to: CGPoint(x: 55, y: 27))
        path.addCurve(to: CGPoint(x: 61, y: 18), control1: CGPoint(x: 55, y: 21), control2: CGPoint(x: 57, y: 19))
        path.addLine(to: CGPoint(x: 65, y: 16))
        path.addLine(to: CGPoint(x: 65, y: 12))
        path.addLine(to: CGPoint(x: 34, y: 12))
        path.addLine(to: CGPoint(x: 34, y: 16))
        path.addLine(to: CGPoint(x: 39, y: 18))
        path.addCurve(to: CGPoint(x: 44, y: 27), control1: CGPoint(x: 43, y: 19), control2: CGPoint(x: 44, y: 22))
        path.addLine(to: CGPoint(x: 47, y: 78))
        path.addCurve(to: CGPoint(x: 24, y: 67), control1: CGPoint(x: 36, y: 78), control2: CGPoint(x: 28, y: 76))
        path.addLine(to: CGPoint(x: 20, y: 64))
        path.addLine(to: CGPoint(x: 15, y: 64))
        path.closeSubpath()

        var transform = CGAffineTransform(a: rect.width / 100, b: 0, c: 0,
                                         d: rect.height / (flipped ? -100 : 100),
                                         tx: rect.minX, ty: flipped ? rect.maxY : rect.minY)
        return path.copy(using: &transform) ?? path
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.1)
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.4, dy: 1.4), cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.strokePath()
            context.addPath(outline(in: rect.insetBy(dx: 3.3, dy: 3.3)))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Transpose"
        return image
    }
}

struct TransposeMark: Shape {
    func path(in rect: CGRect) -> Path { Path(TransposeBrand.outline(in: rect, flipped: true)) }
}

/// The mark supplies the initial T, so the written name starts at “ranspose”.
struct TransposeWordmark: View {
    var fontSize: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: -fontSize * 0.07) {
            TransposeMark()
                .fill(.tint)
                .frame(width: fontSize * 1.1, height: fontSize * 1.1)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions.height * 0.88
                }
            Text("ranspose")
                .font(.system(size: fontSize, weight: .semibold))
                .tracking(-fontSize * 0.008)
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transpose")
    }
}
