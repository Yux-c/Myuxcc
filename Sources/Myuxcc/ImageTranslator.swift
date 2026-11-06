import AppKit

/// A paragraph found in an image: lines that wrap into one another. `box` covers all of them, in image
/// pixels with a top-left origin.
struct TextBlock {
    var lines: [RecognizedLine]
    var text: String { TextRecognizer.mergingLines(lines) }
    var box: CGRect { lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) } }
    var lineHeight: CGFloat { lines.map(\.box.height).reduce(0, +) / CGFloat(lines.count) }
}

/// Translation drawn over the screenshot: each paragraph's text is covered with the colour around it
/// and its translation is written into the same place.
enum ImageTranslator {
    /// Lines in reading order grouped into paragraphs: a line joins the paragraph whose last line sits
    /// right above it, overlaps it horizontally and is about as tall, unless the merging rules would
    /// start a new paragraph there.
    static func blocks(_ lines: [RecognizedLine]) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for line in lines {
            let h = line.box.height
            let i = blocks.lastIndex { block in
                guard let last = block.lines.last else { return false }
                let gap = line.box.minY - last.box.maxY
                let ratio = h / max(last.box.height, 1)
                return gap > -h * 0.3 && gap < h * 0.9 && ratio > 0.7 && ratio < 1.4
                    && line.box.minX < last.box.maxX && line.box.maxX > last.box.minX
                    && abs(line.box.minX - last.box.minX) < h * 2
                    && !TextRecognizer.mergingLines(block.lines + [line]).contains("\n")
            }
            if let i { blocks[i].lines.append(line) } else { blocks.append(TextBlock(lines: [line])) }
        }
        return blocks
    }

    /// The finished image with the original's text replaced by its translation, plus the language pair.
    @MainActor
    static func translate(_ image: CGImage, target: ScreenTranslator.Target) async throws -> (CGImage, String) {
        let blocks = blocks(try await TextRecognizer.recognize(image))
        guard !blocks.isEmpty else { throw Failure.noText }
        let texts = blocks.map(\.text)
        let (from, to) = try ScreenTranslator.languages(for: texts.joined(separator: "\n"), target: target)
        let translated = try await ScreenTranslator.translate(segments: texts, from: from, to: to)
        guard let result = render(image, blocks: blocks, translations: translated) else { throw Failure.drawing }
        return (result, "\(ScreenTranslator.name(of: from)) → \(ScreenTranslator.name(of: to))")
    }

    enum Failure: LocalizedError {
        case noText, drawing
        var errorDescription: String? { self == .noText ? "截图里没有识别到文字" : "译文绘制失败" }
    }

    /// Draws `translations[i]` over `blocks[i]`.
    static func render(_ image: CGImage, blocks: [TextBlock], translations: [String]) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = Pixels(bytes: data.assumingMemoryBound(to: UInt8.self), width: w, height: h)

        // From here on y grows downwards, like the recognised boxes.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        for (block, translation) in zip(blocks, translations) {
            // Colours are read before anything is painted over this block.
            let background = pixels.background(around: block.lines.map(\.box))
            let foreground = pixels.foreground(in: block.lines.map(\.box), background: background)
            let pad = block.lineHeight * 0.18
            var covers = block.lines.map { $0.box.insetBy(dx: -pad, dy: -pad).intersection(bounds) }
            var area = block.box.insetBy(dx: -pad, dy: -pad).intersection(bounds)

            // The text starts where the original did; the padding only widens the cover.
            let textRect = CGRect(x: block.box.minX, y: area.minY, width: area.maxX - block.box.minX, height: area.height)
            let (font, needed) = fit(translation, in: textRect.size, lineHeight: block.lineHeight)
            if needed > area.height {
                // Too long even at the smallest size: grow downwards over what is below.
                area.size.height = min(needed, bounds.maxY - area.minY)
                covers.append(area)
            }
            ctx.setFillColor(background)
            for r in covers { ctx.fill(r) }

            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: foreground) ?? .black,
                                                        .paragraphStyle: style]
            let string = NSAttributedString(string: translation, attributes: attrs)
            let size = string.boundingRect(with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            // Vertically centred like the original line(s), left-aligned like most text.
            string.draw(with: CGRect(x: textRect.minX, y: area.minY + max(0, (area.height - size.height) / 2), width: textRect.width, height: size.height + 1),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        return ctx.makeImage()
    }

    /// The largest font, from about the original size down, at which `text` wraps into `size`;
    /// returns the font and the height it takes. Vision's line boxes are about 0.8 of the font size
    /// tall, so the original size is about 1.25 box heights.
    private static func fit(_ text: String, in size: CGSize, lineHeight: CGFloat) -> (NSFont, CGFloat) {
        var points = lineHeight * 1.25
        let smallest = max(lineHeight * 0.5, 9)
        while true {
            let font = NSFont.systemFont(ofSize: points)
            let needed = NSAttributedString(string: text, attributes: [.font: font])
                .boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if needed <= size.height || points <= smallest { return (font, ceil(needed)) }
            points = max(points * 0.92, smallest)
        }
    }

    /// RGBA bytes of the image, top row first.
    private struct Pixels {
        let bytes: UnsafeMutablePointer<UInt8>
        let width: Int, height: Int

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        /// The most common colour on a ring just outside the boxes.
        func background(around boxes: [CGRect]) -> CGColor {
            var samples: [(Int, Int, Int)] = []
            for b in boxes {
                let pad = max(b.height * 0.25, 2)
                let r = b.insetBy(dx: -pad, dy: -pad)
                let xs = stride(from: Int(r.minX), through: Int(r.maxX), by: max(1, Int(r.width) / 60))
                let ys = stride(from: Int(r.minY), through: Int(r.maxY), by: max(1, Int(r.height) / 12))
                for x in xs { samples.append(contentsOf: [at(x, Int(r.minY)), at(x, Int(r.maxY))].compactMap { $0 }) }
                for y in ys { samples.append(contentsOf: [at(Int(r.minX), y), at(Int(r.maxX), y)].compactMap { $0 }) }
            }
            return Self.color(Self.dominant(samples) ?? (255, 255, 255))
        }

        /// The most common colour inside the boxes that stands out from the background; black or white
        /// by contrast when nothing does.
        func foreground(in boxes: [CGRect], background: CGColor) -> CGColor {
            let bg = background.components.map { (Int($0[0] * 255), Int($0[1] * 255), Int($0[2] * 255)) } ?? (255, 255, 255)
            var samples: [(Int, Int, Int)] = []
            for b in boxes {
                for y in stride(from: Int(b.minY), to: Int(b.maxY), by: max(1, Int(b.height) / 16)) {
                    for x in stride(from: Int(b.minX), to: Int(b.maxX), by: max(1, Int(b.width) / 200)) {
                        if let p = at(x, y), Self.distance(p, bg) > 120 { samples.append(p) }
                    }
                }
            }
            if let ink = Self.dominant(samples) { return Self.color(ink) }
            let luminance = 0.299 * Double(bg.0) + 0.587 * Double(bg.1) + 0.114 * Double(bg.2)
            return luminance > 140 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        }

        private func at(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            x >= 0 && y >= 0 && x < width && y < height ? rgb(x, y) : nil
        }

        /// The average of the fullest bucket, with each channel split into 8 ranges.
        private static func dominant(_ samples: [(Int, Int, Int)]) -> (Int, Int, Int)? {
            var buckets: [Int: [(Int, Int, Int)]] = [:]
            for s in samples { buckets[(s.0 >> 5) << 6 | (s.1 >> 5) << 3 | s.2 >> 5, default: []].append(s) }
            guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
            let n = best.count
            return (best.map(\.0).reduce(0, +) / n, best.map(\.1).reduce(0, +) / n, best.map(\.2).reduce(0, +) / n)
        }

        private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }

        private static func color(_ c: (Int, Int, Int)) -> CGColor {
            CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
    }
}
