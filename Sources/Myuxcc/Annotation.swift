import AppKit

enum Tool: CaseIterable {
    case rectangle, ellipse, arrow, pen, highlighter, text, mosaic

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        }
    }

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }
}

/// One drawn mark. Coordinates are in the overlay view's flipped point space.
enum Annotation {
    case rectangle(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
    case mosaic(CGRect)

    /// Draws into the current (flipped) graphics context.
    /// `base` is the frozen screen image, needed by the mosaic to sample pixels.
    func draw(base: CGImage, viewSize: CGSize) {
        switch self {
        case let .rectangle(r, color, width):
            color.setStroke()
            let path = NSBezierPath(rect: r.standardized)
            path.lineWidth = width
            path.stroke()

        case let .ellipse(r, color, width):
            color.setStroke()
            let path = NSBezierPath(ovalIn: r.standardized)
            path.lineWidth = width
            path.stroke()

        case let .arrow(from, to, color, width):
            Annotation.drawArrow(from: from, to: to, color: color, width: width)

        case let .pen(points, color, width):
            guard let first = points.first else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case let .text(string, origin, color, size):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Annotation.textFont(size),
                .foregroundColor: color,
            ]
            (string as NSString).draw(at: origin, withAttributes: attrs)

        case let .mosaic(r):
            Annotation.drawMosaic(in: r.standardized, base: base, viewSize: viewSize)
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = min(max(width * 5, 12), length * 0.6)
        let headAngle: CGFloat = .pi / 7

        // Shaft stops at the base of the head so the tip stays sharp.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * headLength * 0.8,
                               y: to.y - sin(angle) * headLength * 0.8)
        color.set()
        let shaft = NSBezierPath()
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: CGPoint(x: to.x - cos(angle - headAngle) * headLength,
                              y: to.y - sin(angle - headAngle) * headLength))
        head.line(to: CGPoint(x: to.x - cos(angle + headAngle) * headLength,
                              y: to.y - sin(angle + headAngle) * headLength))
        head.close()
        head.fill()
    }

    /// Pixelates the region by downsampling the frozen image and scaling it back up without interpolation.
    private static func drawMosaic(in rect: CGRect, base: CGImage, viewSize: CGSize) {
        guard rect.width >= 2, rect.height >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = CGFloat(base.width) / viewSize.width
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = base.cropping(to: pixelRect) else { return }

        let block: CGFloat = 12 * scale
        let w = max(1, Int(pixelRect.width / block)), h = max(1, Int(pixelRect.height / block))
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixelated = small.makeImage() else { return }

        // The context is flipped; flip locally so the image is not drawn upside down.
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelated, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

// MARK: - Geometry for selecting and editing marks

extension Annotation {
    var isText: Bool { if case .text = self { return true } else { return false } }
    var isArrow: Bool { if case .arrow = self { return true } else { return false } }

    /// Tight box around the mark (not including stroke width).
    var bounds: CGRect {
        switch self {
        case let .rectangle(r, _, _), let .ellipse(r, _, _):
            return r.standardized
        case let .mosaic(r):
            return r.standardized
        case let .arrow(a, b, _, _):
            return Annotation.box(around: [a, b])
        case let .pen(points, _, _):
            return Annotation.box(around: points)
        case let .text(string, origin, _, size):
            let measured = (string as NSString).size(withAttributes: [.font: Annotation.textFont(size)])
            return CGRect(origin: origin, size: measured)
        }
    }

    /// Whether a click at `p` should grab this mark. Hollow shapes only respond near their outline,
    /// so a new shape can still be drawn inside an existing one.
    func hitTest(_ p: CGPoint) -> Bool {
        let slop: CGFloat = 6
        switch self {
        case let .rectangle(r, _, w):
            let r = r.standardized, t = slop + w / 2
            return r.insetBy(dx: -t, dy: -t).contains(p) && !r.insetBy(dx: t, dy: t).contains(p)
        case let .ellipse(r, _, w):
            let r = r.standardized
            guard r.width > 0, r.height > 0 else { return false }
            // Normalised distance from the centre; 1 is on the outline.
            let dx = (p.x - r.midX) / (r.width / 2), dy = (p.y - r.midY) / (r.height / 2)
            let d = hypot(dx, dy)
            let tolerance = (slop + w / 2) / max(min(r.width, r.height) / 2, 1)
            return abs(d - 1) <= tolerance
        case let .arrow(a, b, _, w):
            return Annotation.distance(from: p, toSegment: a, b) <= slop + w / 2
        case let .pen(points, _, w):
            guard points.count > 1 else { return points.first.map { hypot($0.x - p.x, $0.y - p.y) <= slop + w / 2 } ?? false }
            return zip(points, points.dropFirst()).contains { Annotation.distance(from: p, toSegment: $0, $1) <= slop + w / 2 }
        case .text, .mosaic:
            return bounds.insetBy(dx: -slop / 2, dy: -slop / 2).contains(p)
        }
    }

    func moved(by d: CGVector) -> Annotation {
        transformed { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    /// Maps the mark from one box onto another, e.g. when a resize handle is dragged.
    func scaled(from old: CGRect, to new: CGRect) -> Annotation {
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1
        return transformed { CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy) }
    }

    /// Replaces one end of an arrow.
    func withArrowEnd(_ isTip: Bool, at p: CGPoint) -> Annotation {
        guard case let .arrow(a, b, color, width) = self else { return self }
        return isTip ? .arrow(a, p, color, width) : .arrow(p, b, color, width)
    }

    private func transformed(_ f: (CGPoint) -> CGPoint) -> Annotation {
        func rect(_ r: CGRect) -> CGRect {
            let a = f(CGPoint(x: r.minX, y: r.minY)), b = f(CGPoint(x: r.maxX, y: r.maxY))
            return Annotation.box(around: [a, b])
        }
        switch self {
        case let .rectangle(r, c, w): return .rectangle(rect(r.standardized), c, w)
        case let .ellipse(r, c, w): return .ellipse(rect(r.standardized), c, w)
        case let .mosaic(r): return .mosaic(rect(r.standardized))
        case let .arrow(a, b, c, w): return .arrow(f(a), f(b), c, w)
        case let .pen(points, c, w): return .pen(points.map(f), c, w)
        case let .text(s, origin, c, size): return .text(s, f(origin), c, size)
        }
    }

    static func textFont(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .medium) }

    private static func box(around points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
