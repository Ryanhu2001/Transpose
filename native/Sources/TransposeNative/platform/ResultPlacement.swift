import Foundation

enum ResultWindowSizing {
    /// The top left stays still while the bottom-right grip follows the pointer.
    static func resizedFrame(start: CGRect, delta: CGSize, minimum: CGSize, visibleFrame: CGRect) -> CGRect {
        let available = visibleFrame.insetBy(dx: 10, dy: 10)
        let minimumWidth = min(minimum.width, available.width)
        let minimumHeight = min(minimum.height, available.height)
        // A freely moved panel may be partly offscreen. Keep its controls usable
        // by bringing the anchor back far enough to fit the minimum size.
        let left = max(available.minX, min(start.minX, available.maxX - minimumWidth))
        let top = min(available.maxY, max(start.maxY, available.minY + minimumHeight))
        let width = min(max(minimumWidth, start.width + delta.width), available.maxX - left)
        let height = min(max(minimumHeight, start.height - delta.height), top - available.minY)
        return CGRect(x: left, y: top - height, width: width, height: height)
    }
}

/// Keeps a captured source region and its translation visible together when space permits.
enum ResultPlacement {
    static func frame(size requested: CGSize, near point: CGPoint, avoiding region: CGRect?, visibleFrame: CGRect) -> CGRect {
        let available = visibleFrame.insetBy(dx: 10, dy: 10)
        let size = CGSize(width: min(requested.width, available.width), height: min(requested.height, available.height))
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(x: max(available.minX, min(origin.x, available.maxX - size.width)),
                   y: max(available.minY, min(origin.y, available.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        guard let region, !region.isEmpty else {
            let below = point.y - size.height - 12
            return clamped(CGPoint(x: point.x + 10, y: below < available.minY ? point.y + 16 : below))
        }
        let origins = [
            CGPoint(x: region.maxX + 12, y: region.maxY - size.height),
            CGPoint(x: region.minX - size.width - 12, y: region.maxY - size.height),
            CGPoint(x: region.minX, y: region.minY - size.height - 12),
            CGPoint(x: region.minX, y: region.maxY + 12)
        ]
        let candidates = origins.map(clamped)
        func overlap(_ frame: CGRect) -> CGFloat {
            let intersection = frame.intersection(region.insetBy(dx: -6, dy: -6))
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        return candidates.enumerated().min {
            let left = overlap($0.element), right = overlap($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }!.element
    }
}
