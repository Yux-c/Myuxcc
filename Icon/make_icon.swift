// Draws the Myuxcc app icon at 1024×1024: swift Icon/make_icon.swift <variant> <out.png>
import AppKit

let size: CGFloat = 1024
// macOS icon grid: the rounded square sits inside a 100 pt margin.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(gradient(colors), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], at center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(gradient(colors), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

/// Fills `path` with a linear gradient, under an optional shadow.
func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint, shadow: (CGSize, CGFloat, CGColor)? = nil) {
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: shadow.0, blur: shadow.1, color: shadow.2)
        ctx.addPath(path)
        ctx.setFillColor(colors[0])
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, colors, from: from, to: to)
    ctx.restoreGState()
}

func roundedRect(_ rect: CGRect, _ r: CGFloat) -> CGPath { CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil) }

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }

/// A screenshot card: a white rounded card holding a small landscape, rotated about its centre.
func card(_ ctx: CGContext, center: CGPoint, size s: CGSize, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let rect = CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height)
    fill(ctx, roundedRect(rect, 46), [color(0xFFFFFF), color(0xE9ECFB)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY),
         shadow: (CGSize(width: 0, height: -26), 48, color(0x14104A, 0.45)))
    // The picture inside.
    let photo = rect.insetBy(dx: 24, dy: 24)
    ctx.saveGState()
    ctx.addPath(roundedRect(photo, 26))
    ctx.clip()
    linear(ctx, [color(0x7FD0FF), color(0xB9A8FF), color(0xFFC6E0)], from: CGPoint(x: 0, y: photo.maxY), to: CGPoint(x: 0, y: photo.minY))
    let sun = CGPoint(x: photo.minX + photo.width * 0.70, y: photo.minY + photo.height * 0.66)
    radial(ctx, [color(0xFFF3B0, 0.9), color(0xFFF3B0, 0)], at: sun, radius: 100)
    ctx.addPath(circle(sun, 38))
    ctx.setFillColor(color(0xFFD45C))
    ctx.fillPath()
    // Two ranges of hills, the near one darker.
    for (lift, colors) in [(0.42, [color(0x8A9BFF), color(0x6B7CF0)]), (0.24, [color(0x5146D8), color(0x3B2FB0)])] as [(CGFloat, [CGColor])] {
        let base = photo.minY + photo.height * lift
        let hills = CGMutablePath()
        hills.move(to: CGPoint(x: photo.minX, y: photo.minY))
        hills.addLine(to: CGPoint(x: photo.minX, y: base))
        hills.addCurve(to: CGPoint(x: photo.midX, y: base + photo.height * 0.10),
                       control1: CGPoint(x: photo.minX + photo.width * 0.18, y: base + photo.height * 0.30),
                       control2: CGPoint(x: photo.midX - photo.width * 0.16, y: base - photo.height * 0.04))
        hills.addCurve(to: CGPoint(x: photo.maxX, y: base + photo.height * 0.04),
                       control1: CGPoint(x: photo.midX + photo.width * 0.18, y: base + photo.height * 0.26),
                       control2: CGPoint(x: photo.maxX - photo.width * 0.12, y: base + photo.height * 0.18))
        hills.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        hills.closeSubpath()
        fill(ctx, hills, colors, from: CGPoint(x: 0, y: base + photo.height * 0.2), to: CGPoint(x: 0, y: photo.minY))
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

/// A glossy record button: white rim, red gradient face, soft highlight.
func recordButton(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    fill(ctx, circle(c, r), [color(0xFFFFFF), color(0xE6E8F2)], from: CGPoint(x: c.x, y: c.y + r), to: CGPoint(x: c.x, y: c.y - r),
         shadow: (CGSize(width: 0, height: -18), 36, color(0x14104A, 0.5)))
    let inner = r * 0.74
    fill(ctx, circle(c, inner), [color(0xFF6A7A), color(0xF0244A), color(0xC8102E)], from: CGPoint(x: c.x, y: c.y + inner), to: CGPoint(x: c.x, y: c.y - inner))
    ctx.saveGState()
    ctx.addPath(circle(c, inner))
    ctx.clip()
    let gloss = CGPath(ellipseIn: CGRect(x: c.x - inner * 0.62, y: c.y + inner * 0.18, width: inner * 1.24, height: inner * 0.72), transform: nil)
    fill(ctx, gloss, [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0.0)], from: CGPoint(x: c.x, y: c.y + inner * 0.9), to: CGPoint(x: c.x, y: c.y + inner * 0.2))
    ctx.restoreGState()
}

/// A camera iris: six blades in a colour wheel around a dark opening, set in a dark ring.
func aperture(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    fill(ctx, circle(c, r + 34), [color(0x4A5063), color(0x16181F), color(0x2C303C)], from: CGPoint(x: c.x, y: c.y + r), to: CGPoint(x: c.x, y: c.y - r),
         shadow: (CGSize(width: 0, height: -20), 40, color(0x000000, 0.35)))
    let colors: [UInt32] = [0xFF5F6D, 0xFFB347, 0x4CD97B, 0x2EC5FF, 0x6C63FF, 0xE056FD]
    let opening = r * 0.30, twist: CGFloat = 0.62
    ctx.saveGState()
    ctx.addPath(circle(c, r))
    ctx.clip()
    for i in 0..<6 {
        let a0 = CGFloat(i) * .pi / 3, a1 = a0 + .pi / 3
        let inner0 = CGPoint(x: c.x + opening * cos(a0), y: c.y + opening * sin(a0))
        let inner1 = CGPoint(x: c.x + opening * cos(a1), y: c.y + opening * sin(a1))
        let blade = CGMutablePath()
        blade.move(to: inner0)
        blade.addLine(to: CGPoint(x: c.x + r * 1.2 * cos(a0 + twist), y: c.y + r * 1.2 * sin(a0 + twist)))
        blade.addLine(to: CGPoint(x: c.x + r * 1.2 * cos(a1 + twist), y: c.y + r * 1.2 * sin(a1 + twist)))
        blade.addLine(to: inner1)
        blade.closeSubpath()
        let mid = (a0 + a1) / 2 + twist / 2
        // Lit along the trailing edge, shaded towards the next blade that covers it.
        let lit = CGPoint(x: c.x + r * cos(a1 + twist * 0.7), y: c.y + r * sin(a1 + twist * 0.7))
        let shade = CGPoint(x: c.x + r * cos(a0 + twist * 1.1), y: c.y + r * sin(a0 + twist * 1.1))
        _ = mid
        fill(ctx, blade, [color(colors[i]), color(colors[i])], from: lit, to: shade)
        ctx.saveGState()
        ctx.addPath(blade)
        ctx.clip()
        linear(ctx, [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0), color(0x000000, 0.14)], from: lit, to: shade)
        ctx.restoreGState()
        // A dark seam along the leading edge of each blade.
        ctx.move(to: inner0)
        ctx.addLine(to: CGPoint(x: c.x + r * 1.2 * cos(a0 + twist), y: c.y + r * 1.2 * sin(a0 + twist)))
        ctx.setStrokeColor(color(0x000000, 0.28))
        ctx.setLineWidth(6)
        ctx.strokePath()
    }
    // Dark opening with a glassy glint.
    let hex = CGMutablePath()
    for i in 0..<6 {
        let p = CGPoint(x: c.x + opening * cos(CGFloat(i) * .pi / 3), y: c.y + opening * sin(CGFloat(i) * .pi / 3))
        i == 0 ? hex.move(to: p) : hex.addLine(to: p)
    }
    hex.closeSubpath()
    fill(ctx, hex, [color(0x1B1E2B), color(0x05060A)], from: CGPoint(x: c.x, y: c.y + opening), to: CGPoint(x: c.x, y: c.y - opening))
    ctx.addPath(circle(CGPoint(x: c.x - opening * 0.25, y: c.y + opening * 0.3), opening * 0.18))
    ctx.setFillColor(color(0xFFFFFF, 0.7))
    ctx.fillPath()
    // A soft reflection across the whole lens.
    let sheen = CGPath(ellipseIn: CGRect(x: c.x - r * 0.95, y: c.y + r * 0.05, width: r * 1.9, height: r * 1.1), transform: nil)
    fill(ctx, sheen, [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], from: CGPoint(x: c.x, y: c.y + r), to: CGPoint(x: c.x, y: c.y + r * 0.1))
    ctx.restoreGState()
    ctx.addPath(circle(c, r))
    ctx.setStrokeColor(color(0x000000, 0.45))
    ctx.setLineWidth(5)
    ctx.strokePath()
}

/// The macOS icon outline: straight sides joined by continuous-curvature corners. Each corner is a
/// quarter superellipse spanning 1.528 × the nominal radius, which matches a circular corner at 45°
/// but eases into the straight edges instead of meeting them with a kink.
func squircle(_ rect: CGRect, radius r: CGFloat = 185) -> CGPath {
    let k = r * 1.528, n: CGFloat = 3.3, steps = 90
    let path = CGMutablePath()
    // Corner centres and the quadrant each corner occupies, going anticlockwise from bottom-right.
    let corners: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
        (CGPoint(x: rect.maxX - k, y: rect.minY + k), 1, -1, -.pi / 2),
        (CGPoint(x: rect.maxX - k, y: rect.maxY - k), 1, 1, 0),
        (CGPoint(x: rect.minX + k, y: rect.maxY - k), -1, 1, .pi / 2),
        (CGPoint(x: rect.minX + k, y: rect.minY + k), -1, -1, .pi),
    ]
    for (index, (c, _, _, start)) in corners.enumerated() {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let x = cos(t), y = sin(t)
            let p = CGPoint(x: c.x + k * (x < 0 ? -1 : 1) * pow(abs(x), 2 / n),
                            y: c.y + k * (y < 0 ? -1 : 1) * pow(abs(y), 2 / n))
            index == 0 && i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
    }
    path.closeSubpath()
    return path
}

/// An M drawn as a folded ribbon: four strokes, each laid over the previous ones with a soft
/// shadow cast only onto what is already drawn, so the folds read as depth.
func ribbonM(_ ctx: CGContext, center c: CGPoint, width w: CGFloat, paint: (CGPath) -> Void, fold: CGColor) {
    let left = c.x - 215, right = c.x + 215, top = c.y + 205, bottom = c.y - 205, valley = c.y - 30
    let lines: [(CGPoint, CGPoint)] = [
        (CGPoint(x: left, y: bottom), CGPoint(x: left, y: top)),
        (CGPoint(x: left, y: top), CGPoint(x: c.x, y: valley)),
        (CGPoint(x: right, y: bottom), CGPoint(x: right, y: top)),
        (CGPoint(x: right, y: top), CGPoint(x: c.x, y: valley)),
    ]
    var drawn: [CGPath] = []
    for (a, b) in lines {
        let line = CGMutablePath()
        line.move(to: a)
        line.addLine(to: b)
        let band = line.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        if !drawn.isEmpty {
            ctx.saveGState()
            drawn.forEach { ctx.addPath($0) }
            ctx.clip()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 34, color: fold)
            ctx.addPath(band)
            ctx.setFillColor(fold)
            ctx.fillPath()
            ctx.restoreGState()
        }
        paint(band)
        drawn.append(band)
    }
}

/// Light or shade cast inward from the edge of `path`: the shadow of everything outside it, shifted by `offset`.
func innerShadow(_ ctx: CGContext, _ path: CGPath, offset: CGSize, blur: CGFloat, color shadow: CGColor) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setShadow(offset: offset, blur: blur, color: shadow)
    ctx.addRect(CGRect(x: -size, y: -size, width: size * 3, height: size * 3))
    ctx.addPath(path)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// The M as one continuous rounded stroke, returned as a fillable outline.
func monogram(center c: CGPoint, width w: CGFloat) -> CGPath {
    let m = CGMutablePath()
    m.move(to: CGPoint(x: c.x - 200, y: c.y - 190))
    m.addLine(to: CGPoint(x: c.x - 200, y: c.y + 190))
    m.addLine(to: CGPoint(x: c.x, y: c.y - 20))
    m.addLine(to: CGPoint(x: c.x + 200, y: c.y + 190))
    m.addLine(to: CGPoint(x: c.x + 200, y: c.y - 190))
    // normalized() merges the stroke's overlapping pieces into one clean outline, so even-odd fills
    // and inner shadows do not punch holes where the joins overlap.
    return m.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
}

/// The M split at its valley into a left half (leg and diagonal) and a right half.
func monogramHalves(center c: CGPoint, width w: CGFloat) -> (CGPath, CGPath) {
    func half(_ sign: CGFloat) -> CGPath {
        let m = CGMutablePath()
        m.move(to: CGPoint(x: c.x + sign * 200, y: c.y - 190))
        m.addLine(to: CGPoint(x: c.x + sign * 200, y: c.y + 190))
        m.addLine(to: CGPoint(x: c.x, y: c.y - 20))
        return m.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
    }
    return (half(-1), half(1))
}

/// A glass glyph floating above the tile: drop shadow, a body, a bright rim along its upper edge
/// and a tinted thickness along its lower edge.
func glassGlyph(_ ctx: CGContext, _ path: CGPath, body: [CGColor], shadow: CGColor, rim: CGColor, depth: CGColor) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: shadow)
    ctx.addPath(path)
    ctx.setFillColor(body[0])
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, path, body, from: CGPoint(x: 0, y: box.maxY), to: CGPoint(x: 0, y: box.minY))
    innerShadow(ctx, path, offset: CGSize(width: 0, height: 10), blur: 16, color: depth)
    innerShadow(ctx, path, offset: CGSize(width: 0, height: -5), blur: 3, color: rim)
}

/// Liquid-glass tile finish: a soft top sheen and a specular rim that is brightest at the
/// top-left and bottom-right corners.
func glassTile(_ ctx: CGContext, _ shape: CGPath, rimStrength: CGFloat) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    radial(ctx, [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)], at: CGPoint(x: tile.midX, y: tile.maxY + 120), radius: 620)
    ctx.addPath(shape)
    ctx.setLineWidth(10)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, rimStrength), color(0xFFFFFF, 0), color(0xFFFFFF, 0), color(0xFFFFFF, rimStrength * 0.6)], [0, 0.35, 0.65, 1]),
                           start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()
}

/// Single-hue glass palettes: tile top/bottom, glyph top/bottom, glyph shadow, tile rim strength,
/// glyph rim strength and the tint of the glyph's lower edge.
struct GlassPalette {
    let tile: (UInt32, UInt32), glyph: (UInt32, UInt32), shadow: UInt32, rim: CGFloat, glyphRim: CGFloat, depth: UInt32
}
let glassPalettes: [String: GlassPalette] = [
    "glass-jade": GlassPalette(tile: (0x17A98F, 0x0B7F6E), glyph: (0xFFFFFF, 0xEEF2F1), shadow: 0x04473D, rim: 0.5, glyphRim: 1, depth: 0x0B7F6E),
    "glass-navy": GlassPalette(tile: (0x24407A, 0x142A57), glyph: (0xFFFFFF, 0xEEF2F1), shadow: 0x060F24, rim: 0.5, glyphRim: 1, depth: 0x142A57),
    "glass-amber": GlassPalette(tile: (0xFFC53D, 0xF5A30A), glyph: (0x3A3530, 0x1F1B17), shadow: 0x8A5200, rim: 0.6, glyphRim: 0.45, depth: 0x000000),
    "glass-sakura": GlassPalette(tile: (0xFF8FAB, 0xF0648A), glyph: (0xFFFFFF, 0xFFF0F4), shadow: 0x9E2347, rim: 0.6, glyphRim: 1, depth: 0xF0648A),
    "glass-lilac": GlassPalette(tile: (0xC8A8FF, 0xA27CF0), glyph: (0xFFFFFF, 0xF6F0FF), shadow: 0x5A3A9E, rim: 0.6, glyphRim: 1, depth: 0xA27CF0),
    "glass-sky": GlassPalette(tile: (0x6FD3FF, 0x2EAAF0), glyph: (0xFFFFFF, 0xEEF8FF), shadow: 0x0D5A8C, rim: 0.6, glyphRim: 1, depth: 0x2EAAF0),
    "glass-wine": GlassPalette(tile: (0x8E2A47, 0x641833), glyph: (0xFFF8EE, 0xF3E6D6), shadow: 0x2A0512, rim: 0.45, glyphRim: 1, depth: 0x641833),
    "glass-ivory": GlassPalette(tile: (0xFBF7EF, 0xEFE8DA), glyph: (0x34302C, 0x1C1916), shadow: 0x6B5A3E, rim: 0.9, glyphRim: 0.5, depth: 0x000000),
    "glass-black": GlassPalette(tile: (0x2A2A2E, 0x0E0E10), glyph: (0xFFFFFF, 0xE8E8EE), shadow: 0x000000, rim: 0.4, glyphRim: 1, depth: 0x000000),
]

func draw(_ variant: String, _ ctx: CGContext) {
    let shape = variant.hasPrefix("ribbon") || variant.hasPrefix("glass") || variant.hasPrefix("ivory") ? squircle(tile) : roundedRect(tile, radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let center = CGPoint(x: tile.midX, y: tile.midY)
    switch variant {
    case "ivory-dot", "ivory-duo", "ivory-bar", "ivory-m", "ivory-arches", "ivory-layers":
        // Ivory tile, ink M, one vermilion accent.
        let p = glassPalettes["glass-ivory"]!
        linear(ctx, [color(p.tile.0), color(p.tile.1)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        glassTile(ctx, shape, rimStrength: p.rim)
        let ink = { (path: CGPath) in
            glassGlyph(ctx, path, body: [color(p.glyph.0), color(p.glyph.1)], shadow: color(p.shadow, 0.45),
                       rim: color(0xFFFFFF, p.glyphRim), depth: color(p.depth, 0.32))
        }
        let accent = { (path: CGPath) in
            glassGlyph(ctx, path, body: [color(0xF2643F), color(0xD93A22)], shadow: color(0x8A2A10, 0.40),
                       rim: color(0xFFFFFF, 0.8), depth: color(0x8A1E0A, 0.35))
        }
        // The accent drawn as translucent glass, so what lies underneath tints through.
        let tinted = { (path: CGPath) in
            ctx.saveGState()
            ctx.setAlpha(0.86)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            accent(path)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        let stroke = { (path: CGPath, width: CGFloat) in
            path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
        }
        switch variant {
        case "ivory-m":
            // A geometric lowercase m; its last arch in the accent colour.
            let c = CGPoint(x: center.x, y: center.y - 4), r: CGFloat = 122, base = c.y - 190, shoulder = c.y + 50
            let left = CGMutablePath()
            left.move(to: CGPoint(x: c.x - 2 * r, y: base))
            left.addLine(to: CGPoint(x: c.x - 2 * r, y: shoulder))
            left.addArc(center: CGPoint(x: c.x - r, y: shoulder), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
            left.addLine(to: CGPoint(x: c.x, y: base))
            let right = CGMutablePath()
            right.move(to: CGPoint(x: c.x, y: shoulder))
            right.addArc(center: CGPoint(x: c.x + r, y: shoulder), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
            right.addLine(to: CGPoint(x: c.x + 2 * r, y: base))
            ink(stroke(left, 100))
            accent(stroke(right, 100))
        case "ivory-arches":
            // Two tall arches overlapping into an M; the right one is translucent glass.
            func arch(_ x: CGFloat) -> CGPath {
                let a = CGMutablePath(), bottom = center.y - 200, top = center.y + 205
                a.move(to: CGPoint(x: x - 160, y: bottom))
                a.addCurve(to: CGPoint(x: x, y: top), control1: CGPoint(x: x - 140, y: center.y + 110), control2: CGPoint(x: x - 80, y: top))
                a.addCurve(to: CGPoint(x: x + 160, y: bottom), control1: CGPoint(x: x + 80, y: top), control2: CGPoint(x: x + 140, y: center.y + 110))
                return a
            }
            ink(stroke(arch(center.x - 100), 96))
            tinted(stroke(arch(center.x + 100), 96))
        case "ivory-layers":
            // Two glass panes overlapping: ink behind, vermilion in front.
            ink(squircle(CGRect(x: center.x - 250, y: center.y - 250, width: 330, height: 330), radius: 76))
            tinted(squircle(CGRect(x: center.x - 80, y: center.y - 80, width: 330, height: 330), radius: 76))
        case "ivory-dot":
            // A dot off the M's upper right, like a status light.
            let glyph = CGPoint(x: center.x - 34, y: center.y - 14)
            ink(monogram(center: glyph, width: 102))
            accent(circle(CGPoint(x: glyph.x + 300, y: glyph.y + 236), 48))
        case "ivory-duo":
            // The right half of the M in the accent colour, laid over the left half at the valley.
            let halves = monogramHalves(center: CGPoint(x: center.x, y: center.y + 4), width: 102)
            ink(halves.0)
            accent(halves.1)
        default:
            // A short accent bar under the M, like a text cursor's baseline.
            let glyph = CGPoint(x: center.x, y: center.y + 44)
            ink(monogram(center: glyph, width: 102))
            accent(roundedRect(CGRect(x: center.x - 130, y: center.y - 290, width: 260, height: 54), 27))
        }
    case _ where glassPalettes[variant] != nil:
        let p = glassPalettes[variant]!
        linear(ctx, [color(p.tile.0), color(p.tile.1)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        glassTile(ctx, shape, rimStrength: p.rim)
        glassGlyph(ctx, monogram(center: CGPoint(x: center.x, y: center.y + 4), width: 102),
                   body: [color(p.glyph.0), color(p.glyph.1)], shadow: color(p.shadow, 0.45),
                   rim: color(0xFFFFFF, p.glyphRim), depth: color(p.depth, 0.32))
    case "glass-indigo":
        // One deep indigo, lifted slightly towards the top; a frosted white M.
        linear(ctx, [color(0x5E5CE6), color(0x4A47D1)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        glassTile(ctx, shape, rimStrength: 0.55)
        glassGlyph(ctx, monogram(center: CGPoint(x: center.x, y: center.y + 4), width: 102),
                   body: [color(0xFFFFFF), color(0xEEEEFB)], shadow: color(0x1C1A6E, 0.45),
                   rim: color(0xFFFFFF, 1), depth: color(0x4A47D1, 0.30))
    case "glass-white":
        // A near-white tile with an indigo glass M.
        linear(ctx, [color(0xFFFFFF), color(0xF0F0F4)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        glassTile(ctx, shape, rimStrength: 0.9)
        glassGlyph(ctx, monogram(center: CGPoint(x: center.x, y: center.y + 4), width: 102),
                   body: [color(0x6866F0), color(0x4643CF)], shadow: color(0x2E2C8C, 0.35),
                   rim: color(0xFFFFFF, 0.75), depth: color(0x1E1C80, 0.45))
    case "glass-graphite":
        // Graphite tile, frosted white M.
        linear(ctx, [color(0x3A3A3F), color(0x1C1C20)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        glassTile(ctx, shape, rimStrength: 0.45)
        glassGlyph(ctx, monogram(center: CGPoint(x: center.x, y: center.y + 4), width: 102),
                   body: [color(0xFFFFFF), color(0xE6E6EC)], shadow: color(0x000000, 0.55),
                   rim: color(0xFFFFFF, 1), depth: color(0x000000, 0.22))
    case "ribbon-light", "ribbon-dark":
        // A folded-ribbon M in one sweeping gradient: blue, violet, pink, amber.
        let dark = variant == "ribbon-dark"
        if dark {
            linear(ctx, [color(0x23263A), color(0x0B0C14)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
            radial(ctx, [color(0x7C5CFF, 0.38), color(0x7C5CFF, 0)], at: CGPoint(x: center.x, y: center.y + 10), radius: 440)
        } else {
            linear(ctx, [color(0xFFFFFF), color(0xEEF0F6)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        }
        let sweep = [color(0x2F7BFF), color(0x7B5CFF), color(0xE94FB0), color(0xFF9F43)]
        let glyph = CGPoint(x: center.x, y: center.y - 6)
        ribbonM(ctx, center: glyph, width: 124, paint: { band in
            ctx.saveGState()
            ctx.addPath(band)
            ctx.clip()
            linear(ctx, sweep, from: CGPoint(x: glyph.x - 280, y: glyph.y + 240), to: CGPoint(x: glyph.x + 280, y: glyph.y - 240))
            // A faint top light so the ribbon is not a dead flat fill.
            linear(ctx, [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0), color(0x000000, 0.10)], from: CGPoint(x: 0, y: glyph.y + 280), to: CGPoint(x: 0, y: glyph.y - 280))
            ctx.restoreGState()
        }, fold: color(dark ? 0x000000 : 0x1E1240, dark ? 0.55 : 0.38))
    case "ribbon-white":
        // A white ribbon M on a deep violet-to-pink tile.
        linear(ctx, [color(0x4C3BFF), color(0x8A3FFC), color(0xF0479B)], from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
        radial(ctx, [color(0x3FC8FF, 0.55), color(0x3FC8FF, 0)], at: CGPoint(x: tile.minX + 120, y: tile.maxY - 80), radius: 520)
        radial(ctx, [color(0xFFB347, 0.45), color(0xFFB347, 0)], at: CGPoint(x: tile.maxX - 80, y: tile.minY + 60), radius: 460)
        let glyph = CGPoint(x: center.x, y: center.y - 6)
        ribbonM(ctx, center: glyph, width: 124, paint: { band in
            ctx.saveGState()
            ctx.addPath(band)
            ctx.clip()
            linear(ctx, [color(0xFFFFFF), color(0xEDE9FF)], from: CGPoint(x: 0, y: glyph.y + 260), to: CGPoint(x: 0, y: glyph.y - 260))
            ctx.restoreGState()
        }, fold: color(0x2A0A6B, 0.45))
    case "mono-m":
        // A monogram: one continuous rounded stroke drawing an M.
        linear(ctx, [color(0x4F46E5), color(0x9333EA)], from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
        let m = CGMutablePath()
        m.move(to: CGPoint(x: center.x - 215, y: center.y - 200))
        m.addLine(to: CGPoint(x: center.x - 215, y: center.y + 200))
        m.addLine(to: CGPoint(x: center.x, y: center.y - 40))
        m.addLine(to: CGPoint(x: center.x + 215, y: center.y + 200))
        m.addLine(to: CGPoint(x: center.x + 215, y: center.y - 200))
        ctx.addPath(m)
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setLineWidth(112)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    case "duo-m":
        // The same M in two offset layers of colour on a light tile.
        ctx.setFillColor(color(0xFAFAF7))
        ctx.fill(tile)
        for (offset, c) in [(CGPoint(x: 26, y: -26), color(0xFF5A5F)), (CGPoint(x: -14, y: 14), color(0x3D5AFE, 0.92))] {
            let m = CGMutablePath()
            m.move(to: CGPoint(x: center.x - 205 + offset.x, y: center.y - 195 + offset.y))
            m.addLine(to: CGPoint(x: center.x - 205 + offset.x, y: center.y + 195 + offset.y))
            m.addLine(to: CGPoint(x: center.x + offset.x, y: center.y - 30 + offset.y))
            m.addLine(to: CGPoint(x: center.x + 205 + offset.x, y: center.y + 195 + offset.y))
            m.addLine(to: CGPoint(x: center.x + 205 + offset.x, y: center.y - 195 + offset.y))
            ctx.addPath(m)
            ctx.setStrokeColor(c)
            ctx.setLineWidth(96)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    case "bars":
        // Abstract: three rounded bars fanning out from one corner, overlapping in translucent colour.
        ctx.setFillColor(color(0x111827))
        ctx.fill(tile)
        let pivot = CGPoint(x: center.x - 190, y: center.y - 190)
        for (angle, c) in [(18.0, color(0x22D3EE, 0.9)), (45.0, color(0x8B5CF6, 0.9)), (72.0, color(0xF43F5E, 0.9))] as [(CGFloat, CGColor)] {
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.addPath(roundedRect(CGRect(x: -70, y: -70, width: 560, height: 140), 70))
            ctx.setFillColor(c)
            ctx.setBlendMode(.screen)
            ctx.fillPath()
            ctx.restoreGState()
        }
    case "flat-cards":
        // Flat: solid shapes, no gloss or inner shadows.
        ctx.setFillColor(color(0x5B5CF6))
        ctx.fill(tile)
        // Offsets centre the whole group (back card, front card, record dot) on the tile.
        let o = CGPoint(x: center.x - 36, y: center.y + 12)
        let back = CGRect(x: o.x - 230, y: o.y - 70, width: 400, height: 300)
        ctx.addPath(roundedRect(back, 44))
        ctx.setFillColor(color(0xFFFFFF, 0.38))
        ctx.fillPath()
        let front = CGRect(x: o.x - 190, y: o.y - 170, width: 400, height: 300)
        ctx.addPath(roundedRect(front, 44))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        // A simple picture mark on the front card: sun and one hill.
        ctx.addPath(circle(CGPoint(x: front.maxX - 100, y: front.maxY - 90), 34))
        ctx.setFillColor(color(0xFFB020))
        ctx.fillPath()
        // Two mountains, the far one lighter.
        for (left, peak, right, c) in [(140.0, 250.0, 360.0, color(0xA5A6FA)), (40.0, 150.0, 270.0, color(0x5B5CF6))] as [(CGFloat, CGFloat, CGFloat, CGColor)] {
            let m = CGMutablePath()
            m.move(to: CGPoint(x: front.minX + left, y: front.minY + 44))
            m.addLine(to: CGPoint(x: front.minX + peak, y: front.minY + 44 + (peak - left) * 1.05))
            m.addLine(to: CGPoint(x: front.minX + right, y: front.minY + 44))
            m.closeSubpath()
            ctx.addPath(m)
            ctx.setFillColor(c)
            ctx.fillPath()
        }
        let dot = CGPoint(x: front.maxX - 6, y: front.minY + 8)
        ctx.addPath(circle(dot, 92))
        ctx.setFillColor(color(0x5B5CF6))
        ctx.fillPath()
        ctx.addPath(circle(dot, 70))
        ctx.setFillColor(color(0xFF4D6A))
        ctx.fillPath()
    case "flat-overlap":
        // A square (the screenshot) and a circle (the recording) overlapping, Bauhaus style.
        ctx.setFillColor(color(0xF5F1EA))
        ctx.fill(tile)
        let square = roundedRect(CGRect(x: center.x - 260, y: center.y - 105, width: 360, height: 360), 64)
        let disc = circle(CGPoint(x: center.x + 80, y: center.y - 75), 180)
        ctx.addPath(square)
        ctx.setFillColor(color(0x3D5AFE))
        ctx.fillPath()
        ctx.addPath(disc)
        ctx.setFillColor(color(0xFF5A5F))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(square)
        ctx.clip()
        ctx.addPath(disc)
        ctx.setFillColor(color(0x1A1F71))
        ctx.fillPath()
        ctx.restoreGState()
    case "flat-iris":
        ctx.setFillColor(color(0x15161E))
        ctx.fill(tile)
        let colors: [UInt32] = [0xFF5F6D, 0xFFB347, 0x4CD97B, 0x2EC5FF, 0x6C63FF, 0xE056FD]
        let r: CGFloat = 290, opening: CGFloat = 84, twist: CGFloat = 0.62
        ctx.saveGState()
        ctx.addPath(circle(center, r))
        ctx.clip()
        for i in 0..<6 {
            let a0 = CGFloat(i) * .pi / 3, a1 = a0 + .pi / 3
            let blade = CGMutablePath()
            blade.move(to: CGPoint(x: center.x + opening * cos(a0), y: center.y + opening * sin(a0)))
            blade.addLine(to: CGPoint(x: center.x + r * 1.3 * cos(a0 + twist), y: center.y + r * 1.3 * sin(a0 + twist)))
            blade.addLine(to: CGPoint(x: center.x + r * 1.3 * cos(a1 + twist), y: center.y + r * 1.3 * sin(a1 + twist)))
            blade.addLine(to: CGPoint(x: center.x + opening * cos(a1), y: center.y + opening * sin(a1)))
            blade.closeSubpath()
            ctx.addPath(blade)
            ctx.setFillColor(color(colors[i]))
            ctx.fillPath()
        }
        // Gaps between the blades in the background colour, along the blades' own edges.
        for i in 0..<6 {
            let a0 = CGFloat(i) * .pi / 3
            ctx.move(to: CGPoint(x: center.x + opening * cos(a0), y: center.y + opening * sin(a0)))
            ctx.addLine(to: CGPoint(x: center.x + r * 1.3 * cos(a0 + twist), y: center.y + r * 1.3 * sin(a0 + twist)))
        }
        ctx.setStrokeColor(color(0x15161E))
        ctx.setLineWidth(14)
        ctx.strokePath()
        ctx.restoreGState()
    case "card":
        linear(ctx, [color(0x6F86FF), color(0x5B3FD9), color(0x3A1C8C)], from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
        radial(ctx, [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], at: CGPoint(x: tile.minX + 200, y: tile.maxY - 120), radius: 520)
        // A second card behind: the clipboard keeps more than one thing.
        ctx.saveGState()
        ctx.setAlpha(0.45)
        card(ctx, center: CGPoint(x: center.x - 6, y: center.y + 62), size: CGSize(width: 450, height: 340), angle: 8)
        ctx.restoreGState()
        card(ctx, center: CGPoint(x: center.x - 18, y: center.y + 14), size: CGSize(width: 470, height: 356), angle: -5)
        recordButton(ctx, center: CGPoint(x: center.x + 196, y: center.y - 158), radius: 98)
    case "iris":
        linear(ctx, [color(0xFFFFFF), color(0xE4E8F2)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        aperture(ctx, center: CGPoint(x: center.x, y: center.y + 6), radius: 270)
    default: // "iris-dark"
        linear(ctx, [color(0x2B2F45), color(0x10121C)], from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
        radial(ctx, [color(0x6C63FF, 0.35), color(0x6C63FF, 0)], at: center, radius: 420)
        aperture(ctx, center: CGPoint(x: center.x, y: center.y + 6), radius: 270)
    }
    ctx.restoreGState()
    // Fine edge: light on top, so the tile reads on any wallpaper.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0.05)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    ctx.restoreGState()
}

let args = CommandLine.arguments
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
draw(args[1], ctx)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
