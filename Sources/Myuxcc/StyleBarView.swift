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
    /// 文字工具专用的字号减小/增大按钮与当前字号数字标签
    private(set) var textSizeDecreaseButton: NSButton!
    private(set) var textSizeIncreaseButton: NSButton!
    private(set) var textSizeLabel: NSTextField!
    private let sizeGroup = NSStackView()
    private let textSizeGroup = NSStackView()

    init(target: OverlayView) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7 // 与主工具栏保持统一利落圆角
        layer?.borderWidth = 1 // 细微高光描边，确保深色背景下边缘清晰
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

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

        // 图形/画笔/荧光笔使用的三档粗细圆点组
        sizeGroup.orientation = .horizontal
        sizeGroup.spacing = 4
        for (i, name) in Self.sizeNames.enumerated() {
            // 与加粗后的三档标注线宽对应，圆点直径同步微调为 5 / 8 / 12 pt
            let b = Self.button(Self.dot(diameter: [5, 8, 12][i]), name, target, #selector(OverlayView.pickSize(_:)), tag: i)
            sizeButtons.append(b)
            sizeGroup.addArrangedSubview(b)
        }
        stack.addArrangedSubview(sizeGroup)

        // 文字工具专用的「− 字号数字 +」调节组（默认隐藏，选中文字工具或文字标注时切换显示）
        textSizeGroup.orientation = .horizontal
        textSizeGroup.spacing = 2
        textSizeGroup.alignment = .centerY
        textSizeDecreaseButton = Self.button(Self.stepperSymbol(plus: false), "减小字号", target,
                                             #selector(OverlayView.adjustTextSize(_:)), tag: -MarkStyle.textSizeStep)
        textSizeDecreaseButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        textSizeLabel = NSTextField(labelWithString: "\(MarkStyle.defaultTextSize)")
        textSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textSizeLabel.textColor = .labelColor
        textSizeLabel.alignment = .center
        textSizeLabel.lineBreakMode = .byClipping
        textSizeLabel.widthAnchor.constraint(equalToConstant: 26).isActive = true
        textSizeIncreaseButton = Self.button(Self.stepperSymbol(plus: true), "增大字号", target,
                                             #selector(OverlayView.adjustTextSize(_:)), tag: MarkStyle.textSizeStep)
        textSizeIncreaseButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        textSizeGroup.addArrangedSubview(textSizeDecreaseButton)
        textSizeGroup.addArrangedSubview(textSizeLabel)
        textSizeGroup.addArrangedSubview(textSizeIncreaseButton)
        textSizeGroup.isHidden = true
        stack.addArrangedSubview(textSizeGroup)

        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Marks the current colour and size with a light rounded backing, the same for both groups.
    /// Not with a colour: next to the palette a tinted size button would read as "blue".
    /// 当 `textSize` 非空时切换为文字字号加减模式，否则展示三档粗细圆点。
    func update(colorIndex: Int, sizeIndex: Int, textSize: Int? = nil) {
        for (i, b) in colorButtons.enumerated() { Self.mark(b, selected: i == colorIndex) }
        if let textSize {
            sizeGroup.isHidden = true
            textSizeGroup.isHidden = false
            textSizeLabel.stringValue = "\(textSize)"
            textSizeDecreaseButton.isEnabled = textSize > MarkStyle.minTextSize
            textSizeIncreaseButton.isEnabled = textSize < MarkStyle.maxTextSize
            textSizeDecreaseButton.alphaValue = textSizeDecreaseButton.isEnabled ? 1 : 0.35
            textSizeIncreaseButton.alphaValue = textSizeIncreaseButton.isEnabled ? 1 : 0.35
        } else {
            sizeGroup.isHidden = false
            textSizeGroup.isHidden = true
            for (i, b) in sizeButtons.enumerated() {
                b.state = i == sizeIndex ? .on : .off
                Self.mark(b, selected: i == sizeIndex)
            }
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

    /// 绘制字号调节用的居中「−」或「+」模板矢量图标，保证在 HUD 样式条中清晰锐利
    private static func stepperSymbol(plus: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            // 水平横线（减号与加号共用）
            path.move(to: CGPoint(x: 4, y: 8))
            path.line(to: CGPoint(x: 12, y: 8))
            if plus {
                // 垂直竖线（组成加号）
                path.move(to: CGPoint(x: 8, y: 4))
                path.line(to: CGPoint(x: 8, y: 12))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Reacts to the first click even when the overlay is not yet the key window.
private final class StyleButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The stroke width, text size and colour each size step and palette entry stand for.
enum MarkStyle {
    /// 细 / 中 / 粗三档标注线宽（由原先 [2, 3, 6] 适度加粗至 [3, 4.5, 7.5]，让截图标注框更加醒目饱满）
    static let shapeWidths: [CGFloat] = [3, 4.5, 7.5]
    static let highlighterWidths: [CGFloat] = [10, 16, 24]
    /// 文字标注字号的默认值、合法范围与每次点击加减的步长（pt）
    static let defaultTextSize = 20
    static let minTextSize = 10
    static let maxTextSize = 72
    static let textSizeStep = 2
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
    /// 跨截图记忆的文字标注字号（独立于图形粗细三档）
    static var textSize: Int {
        get {
            let raw = inMemory.map { $0["markTextSize"] ?? defaultTextSize }
                ?? (UserDefaults.standard.object(forKey: "markTextSize") != nil
                    ? UserDefaults.standard.integer(forKey: "markTextSize") : defaultTextSize)
            return min(max(raw, minTextSize), maxTextSize)
        }
        set { store(min(max(newValue, minTextSize), maxTextSize), "markTextSize") }
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

    /// The same mark in another palette colour and/or size step (or explicit text font size); the mosaic has neither.
    func restyled(color: NSColor?, sizeIndex: Int? = nil, textSize: CGFloat? = nil) -> Annotation {
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
        case let .text(s, origin, c, size): return .text(s, origin, color ?? c, textSize ?? size)
        case .mosaic: return self
        }
    }
}
