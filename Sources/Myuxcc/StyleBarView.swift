import AppKit

/// Colour and size for marks, shown under the toolbar while a tool or a mark is selected.
/// Picking one changes what the next mark is drawn with and restyles the selected mark.
final class StyleBarView: NSVisualEffectView {
    static let colors: [(name: String, color: NSColor)] = [
        ("红色", NSColor(srgbRed: 0.95, green: 0.23, blue: 0.21, alpha: 1)),
        ("橙色", NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)),
        ("黄色", NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)),
        ("绿色", NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ("蓝色", NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)),
        ("紫色", NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        ("黑色", NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)),
        ("白色", NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)),
    ]
    static let sizeNames = ["细", "中", "粗"]

    private(set) var colorButtons: [NSButton] = []
    private(set) var sizeButtons: [NSButton] = []

    init(target: OverlayView) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (i, c) in Self.colors.enumerated() {
            let b = Self.button(Self.swatch(c.color), c.name, target, #selector(OverlayView.pickColor(_:)), tag: i)
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(separator)
        for (i, name) in Self.sizeNames.enumerated() {
            let b = Self.button(Self.dot(diameter: [4, 7, 11][i]), name, target, #selector(OverlayView.pickSize(_:)), tag: i)
            sizeButtons.append(b)
            stack.addArrangedSubview(b)
        }
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Marks the current colour and size with a light rounded backing, the same for both groups.
    /// Not with a colour: next to the palette a tinted size button would read as "blue".
    func update(colorIndex: Int, sizeIndex: Int) {
        for (i, b) in colorButtons.enumerated() { Self.mark(b, selected: i == colorIndex) }
        for (i, b) in sizeButtons.enumerated() {
            b.state = i == sizeIndex ? .on : .off
            Self.mark(b, selected: i == sizeIndex)
        }
    }

    private static func mark(_ b: NSButton, selected: Bool) {
        // The HUD material is always dark, so a white wash shows the selection in light and dark mode alike.
        b.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.22).cgColor : nil
        b.layer?.borderWidth = selected ? 1 : 0
    }

    /// Whether `b` is drawn as the current choice; read by the e2e test.
    static func isMarked(_ b: NSButton) -> Bool { b.layer?.backgroundColor != nil }

    private static func button(_ image: NSImage, _ tip: String, _ target: AnyObject, _ action: Selector, tag: Int) -> NSButton {
        let b = StyleButton(image: image, target: target, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.toolTip = tip
        b.tag = tag
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.gray.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    private static func dot(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: r.midX - diameter / 2, y: r.midY - diameter / 2, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true // tinted like the toolbar's symbols
        return image
    }
}

/// Reacts to the first click even when the overlay is not yet the key window.
private final class StyleButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The stroke width, text size and colour each size step and palette entry stand for.
enum MarkStyle {
    static let shapeWidths: [CGFloat] = [2, 3, 6]
    static let highlighterWidths: [CGFloat] = [10, 16, 24]
    static let textSizes: [CGFloat] = [14, 20, 30]
    static let highlighterAlpha: CGFloat = 0.4

    /// Set by the silent e2e test, so picking styles there leaves the user's saved choice alone.
    static var inMemory: [String: Int]?

    /// Remembered between captures: one colour for the highlighter, one for everything else.
    static var colorIndex: Int {
        get { stored("markColor", default: 0) }
        set { store(newValue, "markColor") }
    }
    static var highlighterColorIndex: Int {
        get { stored("highlighterColor", default: 2) }
        set { store(newValue, "highlighterColor") }
    }
    static var sizeIndex: Int {
        get { stored("markSize", default: 1) }
        set { store(newValue, "markSize") }
    }

    private static func stored(_ key: String, default value: Int) -> Int {
        let count = key == "markSize" ? shapeWidths.count : StyleBarView.colors.count
        let raw = inMemory.map { $0[key] ?? value }
            ?? (UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.integer(forKey: key) : value)
        return min(max(raw, 0), count - 1)
    }

    private static func store(_ value: Int, _ key: String) {
        if inMemory != nil { inMemory?[key] = value } else { UserDefaults.standard.set(value, forKey: key) }
    }
}

extension Annotation {
    /// A pen mark drawn translucent is a highlighter stroke.
    var isHighlighter: Bool {
        if case let .pen(_, color, _) = self { return color.alphaComponent < 1 }
        return false
    }

    /// The same mark in another palette colour and/or size step; the mosaic has neither.
    func restyled(color: NSColor?, sizeIndex: Int?) -> Annotation {
        switch self {
        case let .rectangle(r, c, w): return .rectangle(r, color ?? c, sizeIndex.map { MarkStyle.shapeWidths[$0] } ?? w)
        case let .ellipse(r, c, w): return .ellipse(r, color ?? c, sizeIndex.map { MarkStyle.shapeWidths[$0] } ?? w)
        case let .arrow(a, b, c, w): return .arrow(a, b, color ?? c, sizeIndex.map { MarkStyle.shapeWidths[$0] } ?? w)
        case let .pen(points, c, w):
            if isHighlighter {
                return .pen(points, color?.withAlphaComponent(MarkStyle.highlighterAlpha) ?? c,
                            sizeIndex.map { MarkStyle.highlighterWidths[$0] } ?? w)
            }
            return .pen(points, color ?? c, sizeIndex.map { MarkStyle.shapeWidths[$0] } ?? w)
        case let .text(s, origin, c, size): return .text(s, origin, color ?? c, sizeIndex.map { MarkStyle.textSizes[$0] } ?? size)
        case .mosaic: return self
        }
    }
}
