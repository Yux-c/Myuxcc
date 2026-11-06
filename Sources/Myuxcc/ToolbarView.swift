import AppKit

/// Floating toolbar shown under the selection.
final class ToolbarView: NSVisualEffectView {
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var longCaptureButton: NSButton!
    private var recordButton: NSButton!
    /// All buttons, left to right; the number keys 1–9 press the first nine.
    private(set) var buttons: [NSButton] = []

    init(target: OverlayView) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (i, tool) in Tool.allCases.enumerated() {
            let b = Self.button(tool.symbol, tool.title, target, #selector(OverlayView.selectTool(_:)))
            b.setButtonType(.pushOnPushOff)
            b.tag = i
            toolButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(Self.separator())
        undoButton = Self.button("arrow.uturn.backward", "撤销 ⌘Z", target, #selector(OverlayView.undo))
        redoButton = Self.button("arrow.uturn.forward", "重做 ⇧⌘Z", target, #selector(OverlayView.redo))
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        stack.addArrangedSubview(Self.separator())
        longCaptureButton = Self.button("rectangle.expand.vertical", "长截图（滚动拼接）", target, #selector(OverlayView.longCapture))
        stack.addArrangedSubview(longCaptureButton)
        recordButton = Self.button("record.circle", "录屏", target, #selector(OverlayView.recordScreen))
        stack.addArrangedSubview(recordButton)
        stack.addArrangedSubview(Self.button("text.viewfinder", "识别文字（OCR）", target, #selector(OverlayView.recognizeText)))
        stack.addArrangedSubview(Self.button("character.bubble", "截图翻译", target, #selector(OverlayView.translate)))
        stack.addArrangedSubview(Self.button("pin", "钉在桌面", target, #selector(OverlayView.pin)))
        stack.addArrangedSubview(Self.button("square.and.arrow.down", "保存 ⌘S", target, #selector(OverlayView.save)))
        let cancel = Self.button("xmark", "取消 Esc", target, #selector(OverlayView.cancel))
        cancel.contentTintColor = .systemRed
        stack.addArrangedSubview(cancel)
        let done = Self.button("checkmark", "复制并关闭 ↩", target, #selector(OverlayView.copyAndClose))
        done.contentTintColor = .systemGreen
        stack.addArrangedSubview(done)
        buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        for (i, b) in buttons.prefix(9).enumerated() { b.toolTip = "\(b.toolTip ?? "")  ·  \(i + 1)" }
    }

    /// Presses the `n`th button (from 1), as a click would; false when there is none or it is disabled.
    @discardableResult
    func press(_ n: Int) -> Bool {
        guard (1...min(9, buttons.count)).contains(n), buttons[n - 1].isEnabled else { return false }
        buttons[n - 1].performClick(nil)
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(selectedTool: Tool?, canUndo: Bool, canRedo: Bool, canLongCapture: Bool) {
        for (i, b) in toolButtons.enumerated() {
            let on = Tool.allCases[i] == selectedTool
            b.state = on ? .on : .off
            b.contentTintColor = on ? .systemBlue : nil
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        longCaptureButton.isEnabled = canLongCapture
        longCaptureButton.toolTip = canLongCapture ? "长截图（滚动拼接）" : "长截图（标注后不可用）"
        // Annotations are drawn on the frozen image, so they cannot be part of a live recording either.
        recordButton.isEnabled = canLongCapture
        recordButton.toolTip = canLongCapture ? "录屏" : "录屏（标注后不可用）"
    }

    static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? NSImage()
        let b = ToolbarButton(image: image, target: target, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.toolTip = tip
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    private static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }
}

/// Reacts to the first click even when the overlay is not yet the key window.
private final class ToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
