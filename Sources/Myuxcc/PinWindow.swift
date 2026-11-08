import AppKit

/// Always-on-top floating image ("pin to desktop").
final class PinWindowController: NSObject, NSWindowDelegate {
    private(set) static var open: [PinWindowController] = []
    /// Set by the silent e2e test: receives the controller instead of the window being shown.
    @MainActor static var testPresenter: ((PinWindowController) -> Void)?

    let window: PinPanel
    let original: CGImage
    /// The screenshot with its text replaced by the translation, once that is done.
    private(set) var translated: CGImage?
    private(set) var showingTranslation = false
    private(set) var translationRunning = false
    private(set) var translationFailure: String?
    /// In-place OCR recognized lines directly on the pinned image (Live Text style).
    private(set) var recognizedLines: [RecognizedLine]?
    private(set) var recognitionRunning = false
    private(set) var recognitionFailure: String?
    /// What copy, save and recognise work on: the image as it is shown.
    var image: CGImage { showingTranslation ? translated ?? original : original }
    private let baseSize: CGSize
    private var zoom: CGFloat = 1
    let view: PinImageView
    /// The one-line status ("正在翻译…", then the language pair and time). It sits in its own panel just
    /// outside the image, because drawn inside it covered the text that had just been translated.
    private var statusPanel: PinStatusPanel?
    /// All-around shadow + dual-contrast halo panel behind the pin so a pinned or translated
    /// sticker stands out clearly from the original background underneath on both dark and light themes.
    private var shadowPanel: PinStatusPanel?
    private static let shadowOutset: CGFloat = 22
    private(set) var statusText: String?
    /// Where the status line ended up, for the e2e test to check it is outside the image.
    var statusFrame: CGRect? { statusPanel?.frame }
    private var statusHide: DispatchWorkItem?

    /// With `translating` the pin first shows the screenshot, then the translation drawn over it.
    /// With `recognizing` the pin stays in place over the original image and lets the user
    /// drag directly across recognized text lines/characters to select and copy text.
    @discardableResult @MainActor
    static func pin(_ image: CGImage, pointSize: CGSize, at origin: CGPoint?,
                    translating: Bool = false, recognizing: Bool = false) -> PinWindowController {
        let controller = PinWindowController(image: image, pointSize: pointSize, origin: origin)
        open.append(controller)
        if let testPresenter {
            testPresenter(controller)
        } else {
            controller.presentShadow()
            controller.window.orderFrontRegardless()
            controller.window.makeKey()
        }
        if translating { controller.translate() }
        if recognizing { controller.recognizeText() }
        return controller
    }

    private init(image: CGImage, pointSize: CGSize, origin: CGPoint?) {
        original = image
        baseSize = pointSize
        view = PinImageView(frame: CGRect(origin: .zero, size: pointSize))
        let frame = CGRect(origin: origin ?? CGPoint(x: 200, y: 200), size: pointSize)
        window = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        super.init()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.animationBehavior = .none // appear exactly where the selection was, without a zoom-in
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        view.image = NSImage(cgImage: image, size: pointSize)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        // Subtle inner highlight rim so the sticker edge is crisp against same-colour backgrounds.
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        view.controller = self
        window.contentView = view
        // Esc, ⌘C and T are handled by the image view, so it must hold the keyboard, not the window.
        window.initialFirstResponder = view
        window.makeFirstResponder(view)
    }

    /// Creates and attaches the 360° shadow/halo backdrop panel right behind `window`.
    @MainActor private func presentShadow() {
        let outset = Self.shadowOutset
        let shadowFrame = window.frame.insetBy(dx: -outset, dy: -outset)
        let panel = PinStatusPanel(contentRect: shadowFrame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let shadowView = PinShadowView(frame: CGRect(origin: .zero, size: shadowFrame.size), outset: outset)
        shadowView.autoresizingMask = [.width, .height]
        panel.contentView = shadowView
        shadowPanel = panel
        panel.order(.below, relativeTo: window.windowNumber)
        window.addChildWindow(panel, ordered: .below)
    }

    private func positionShadow() {
        guard let panel = shadowPanel else { return }
        let outset = Self.shadowOutset
        let shadowFrame = window.frame.insetBy(dx: -outset, dy: -outset)
        panel.setFrame(shadowFrame, display: true)
        panel.contentView?.needsDisplay = true
    }

    func zoom(by delta: CGFloat) {
        zoom = min(max(zoom * (1 + delta), 0.2), 5)
        let old = window.frame
        let size = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        // Keep the top-left corner fixed while zooming.
        window.setFrame(CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height),
                        display: true)
        view.needsDisplay = true
        window.invalidateCursorRects(for: view)
        positionShadow()
        positionStatus()
    }

    func adjustOpacity(by delta: CGFloat) {
        window.alphaValue = min(max(window.alphaValue + delta, 0.2), 1)
        shadowPanel?.alphaValue = window.alphaValue
    }

    /// Window moved (dragged, or the screen changed): the status line follows it.
    func windowDidMove(_ notification: Notification) {
        positionShadow()
        positionStatus()
    }

    @objc func copyImage() { ImageOutput.copyToPasteboard(image, pointSize: baseSize) }

    /// Recognizes text in-place on the pinned image so the user can drag-select characters
    /// directly over the original image, similar to how translation pins directly in place.
    @objc func recognizeText() {
        MainActor.assumeIsolated {
            guard !recognitionRunning else { return }
            recognitionRunning = true
            recognitionFailure = nil
            let targetImage = image
            showStatus("正在识别文字…")
            let started = Date()
            Task { @MainActor in
                do {
                    let lines = try await TextRecognizer.recognize(targetImage)
                    recognizedLines = lines
                    view.setRecognizedLines(lines)
                    let elapsed = Date().timeIntervalSince(started)
                    if lines.isEmpty {
                        showStatus("未识别到文字", for: 2.5)
                    } else {
                        showStatus(String(format: "已识别 %d 行 (%.1f秒) · 直接拖拽选字 · ⌘C 复制 · ⌘A 全选", lines.count, elapsed), for: 3.5)
                    }
                } catch {
                    recognitionFailure = error.localizedDescription
                    showStatus(nil)
                    if Self.testPresenter == nil { Toast.show("识别失败：\(error.localizedDescription)") }
                }
                recognitionRunning = false
            }
        }
    }

    /// Copies currently selected OCR text on the image to the pasteboard.
    @objc func copySelectedText() {
        MainActor.assumeIsolated {
            let text = view.selectedText
            guard !text.isEmpty else { return }
            let pb = ImageOutput.pasteboard
            pb.clearContents()
            pb.setString(text, forType: .string)
            showStatus("已复制选中文字（\(text.count) 字）", for: 2.0)
        }
    }

    /// Copies all recognized OCR text from the image to the pasteboard.
    @objc func copyAllRecognizedText() {
        MainActor.assumeIsolated {
            guard let lines = recognizedLines, !lines.isEmpty else { return }
            let text = TextRecognizer.keepingLines(lines)
            let pb = ImageOutput.pasteboard
            pb.clearContents()
            pb.setString(text, forType: .string)
            showStatus("已复制全部文字（\(text.count) 字）", for: 2.0)
        }
    }

    /// Selects all recognized OCR text on the image.
    @objc func selectAllText() {
        MainActor.assumeIsolated {
            view.selectAllRecognizedText()
        }
    }

    /// Draws the translation over the screenshot, or switches between it and the original once done.
    @objc func translate() {
        MainActor.assumeIsolated {
            if translated != nil { showTranslation(!showingTranslation); return }
            guard !translationRunning else { return }
            translationRunning = true
            translationFailure = nil
            showStatus("正在翻译…")
            let started = Date()
            Task { @MainActor in
                do {
                    let (image, pair) = try await ImageTranslator.translate(original, target: ScreenTranslator.target)
                    translated = image
                    showTranslation(true)
                    showStatus(String(format: "%@ · %.1f 秒 · T 切换原文", pair, Date().timeIntervalSince(started)), for: 2.5)
                } catch {
                    translationFailure = error.localizedDescription
                    showStatus(nil)
                    if Self.testPresenter == nil { Toast.show("翻译失败：\(error.localizedDescription)") }
                }
                translationRunning = false
            }
        }
    }

    @MainActor func showTranslation(_ on: Bool) {
        showingTranslation = on && translated != nil
        view.image = NSImage(cgImage: image, size: baseSize)
        view.needsDisplay = true
    }

    /// A one-line label under the image; nil hides it. It never covers the picture, so a translation is
    /// readable the moment it appears.
    @MainActor func showStatus(_ text: String?, for seconds: Double? = nil) {
        statusHide?.cancel()
        statusHide = nil
        guard let text else {
            statusPanel?.orderOut(nil)
            statusPanel = nil
            statusText = nil
            return
        }
        statusText = text
        let label = statusPanel?.contentView?.subviews.first as? NSTextField ?? NSTextField(labelWithString: "")
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        let size = label.fittingSize
        let panelWidth = size.width + 16, panelHeight = size.height + 8
        let panel: PinStatusPanel
        if let existing = statusPanel {
            panel = existing
            label.frame = CGRect(x: 8, y: (panelHeight - size.height) / 2, width: size.width, height: size.height)
        } else {
            panel = PinStatusPanel(contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .none
            let background = NSView(frame: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            background.layer?.cornerRadius = panelHeight / 2
            label.frame = CGRect(x: 8, y: (panelHeight - size.height) / 2, width: size.width, height: size.height)
            background.addSubview(label)
            panel.contentView = background
            statusPanel = panel
        }
        panel.setContentSize(CGSize(width: panelWidth, height: panelHeight))
        panel.contentView?.frame = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        positionStatus()
        if Self.testPresenter == nil { panel.orderFrontRegardless() }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.showStatus(nil) }
            }
            statusHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// Under the image, left-aligned with it; above it when the bottom of the screen is in the way.
    private func positionStatus() {
        guard let panel = statusPanel else { return }
        let image = window.frame
        let size = panel.frame.size
        var origin = CGPoint(x: image.minX, y: image.minY - size.height - 6)
        if origin.y < (window.screen?.visibleFrame.minY ?? 0) + 4 { origin.y = image.maxY + 6 }
        panel.setFrameOrigin(origin)
    }

    @objc func saveImage() { ImageOutput.save(image) }
    @objc func resetZoom() { zoom = 1; zoom(by: 0) }
    @objc func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        showStatus(nil)
        if let shadowPanel {
            window.removeChildWindow(shadowPanel)
            shadowPanel.orderOut(nil)
            self.shadowPanel = nil
        }
        // 关闭贴图窗口时显式释放视图图像、译文合成大图与 OCR 文本布局缓存，防止贴图大位图滞留内存
        view.image = nil
        view.setRecognizedLines([])
        view.controller = nil
        translated = nil
        recognizedLines = nil
        PinWindowController.open.removeAll { $0 === self }
    }
}

/// The read-only status line that follows a pin; never takes clicks or focus.
final class PinStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws an all-around drop shadow + subtle luminous halo around the pinned/translated card,
/// clipped out inside the card rect so lowering opacity (⌥+scroll) never darkens the image itself.
final class PinShadowView: NSView {
    let outset: CGFloat

    init(frame: NSRect, outset: CGFloat) {
        self.outset = outset
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = bounds.insetBy(dx: outset, dy: outset)
        guard card.width > 0, card.height > 0 else { return }

        ctx.saveGState()
        // Clip to the exterior ring outside `card` using the even-odd rule so the interior stays clear.
        ctx.addRect(bounds)
        ctx.addRect(card)
        ctx.clip(using: .evenOdd)

        // 1. Soft outer luminous halo so dark stickers on dark backgrounds remain clearly separated.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10, color: NSColor.white.withAlphaComponent(0.26).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(card)
        ctx.restoreGState()

        // 2. All-around 360° contact shadow + deeper drop shadow for elevation on light/medium backgrounds.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(card)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(card)
        ctx.restoreGState()

        // 3. Crisp dual-contrast rim (1pt dark hairline + 1pt outer light ring) around the card boundary.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(card.insetBy(dx: -1.25, dy: -1.25))

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(card.insetBy(dx: -0.5, dy: -0.5))

        ctx.restoreGState()
    }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PinImageView: NSImageView {
    weak var controller: PinWindowController?

    /// Caret position inside `ocrLines` (line index in reading order, character index `0...chars.count`).
    struct TextPos: Comparable, Equatable {
        var line: Int
        var char: Int
        static func < (lhs: TextPos, rhs: TextPos) -> Bool {
            lhs.line != rhs.line ? lhs.line < rhs.line : lhs.char < rhs.char
        }
    }

    /// Precomputed character array and normalized horizontal x-fractions (`0.0 ... 1.0`) per line.
    private struct LineLayout {
        let line: RecognizedLine
        let chars: [Character]
        /// Cumulative horizontal fraction boundaries of length `chars.count + 1`, from `0.0` to `1.0`.
        let fractions: [CGFloat]
    }

    private var ocrLayouts: [LineLayout] = []
    private var selectionAnchor: TextPos?
    private var selectionHead: TextPos?
    private var isSelectingText = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Populates recognized OCR lines and precomputes proportional character boundaries for smooth dragging.
    func setRecognizedLines(_ lines: [RecognizedLine]) {
        let font = NSFont.systemFont(ofSize: 20)
        ocrLayouts = lines.map { line in
            let chars = Array(line.text)
            guard !chars.isEmpty else {
                return LineLayout(line: line, chars: [], fractions: [0, 1])
            }
            var weights = [CGFloat]()
            weights.reserveCapacity(chars.count)
            for ch in chars {
                let w = (String(ch) as NSString).size(withAttributes: [.font: font]).width
                weights.append(max(w, 2))
            }
            let total = max(weights.reduce(0, +), 1)
            var fractions: [CGFloat] = [0]
            fractions.reserveCapacity(chars.count + 1)
            var acc: CGFloat = 0
            for w in weights {
                acc += w
                fractions.append(min(acc / total, 1))
            }
            fractions[fractions.count - 1] = 1
            return LineLayout(line: line, chars: chars, fractions: fractions)
        }
        selectionAnchor = nil
        selectionHead = nil
        isSelectingText = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    var hasTextSelection: Bool {
        guard let a = selectionAnchor, let b = selectionHead else { return false }
        return a != b && !ocrLayouts.isEmpty
    }

    /// Returns the currently selected text across one or more recognized lines.
    var selectedText: String {
        guard let a = selectionAnchor, let b = selectionHead, a != b, !ocrLayouts.isEmpty else { return "" }
        let start = min(a, b), end = max(a, b)
        var result = ""
        var prevBox: CGRect?
        for idx in start.line...end.line where ocrLayouts.indices.contains(idx) {
            let layout = ocrLayouts[idx]
            let c0 = (idx == start.line) ? min(max(start.char, 0), layout.chars.count) : 0
            let c1 = (idx == end.line) ? min(max(end.char, 0), layout.chars.count) : layout.chars.count
            guard c0 < c1 else { continue }
            let slice = String(layout.chars[c0..<c1])
            if let prev = prevBox {
                let cur = layout.line.box
                let sameRow = abs(prev.midY - cur.midY) < min(prev.height, cur.height) * 0.6
                result += sameRow ? "\t" : "\n"
            }
            result += slice
            prevBox = layout.line.box
        }
        return result
    }

    func clearSelection() {
        guard selectionAnchor != nil || selectionHead != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        isSelectingText = false
        needsDisplay = true
    }

    func selectAllRecognizedText() {
        guard !ocrLayouts.isEmpty else { return }
        let lastIdx = ocrLayouts.count - 1
        selectionAnchor = TextPos(line: 0, char: 0)
        selectionHead = TextPos(line: lastIdx, char: ocrLayouts[lastIdx].chars.count)
        needsDisplay = true
        let text = selectedText
        if !text.isEmpty {
            controller?.showStatus("已全选 \(text.count) 个字 · ⌘C 复制", for: 2.5)
        }
    }

    /// Converts a `RecognizedLine.box` (top-left image pixel coordinates) into `PinImageView` coordinates (bottom-left).
    private func viewRect(for pixelBox: CGRect) -> CGRect {
        guard let cg = controller?.original, cg.width > 0, cg.height > 0 else { return .zero }
        let sx = bounds.width / CGFloat(cg.width)
        let sy = bounds.height / CGFloat(cg.height)
        return CGRect(
            x: pixelBox.minX * sx,
            y: bounds.height - pixelBox.maxY * sy,
            width: pixelBox.width * sx,
            height: pixelBox.height * sy
        )
    }

    /// Returns the index of the recognized line directly under `point` (with a small hit-test padding).
    private func hitLineIndex(at point: CGPoint) -> Int? {
        for (i, layout) in ocrLayouts.enumerated() {
            let rect = viewRect(for: layout.line.box).insetBy(dx: -5, dy: -3)
            if rect.contains(point) { return i }
        }
        return nil
    }

    /// Maps a point in view coordinates to the nearest character caret position within line `lineIndex`.
    private func charIndex(in lineIndex: Int, atX x: CGFloat) -> Int {
        let layout = ocrLayouts[lineIndex]
        guard !layout.chars.isEmpty else { return 0 }
        let rect = viewRect(for: layout.line.box)
        guard rect.width > 0 else { return 0 }
        let rel = min(max((x - rect.minX) / rect.width, 0), 1)
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, f) in layout.fractions.enumerated() {
            let d = abs(f - rel)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// Maps an arbitrary drag point in view coordinates to a `(line, char)` caret position in reading order.
    private func textPos(at point: CGPoint) -> TextPos? {
        guard !ocrLayouts.isEmpty else { return nil }
        if let hit = hitLineIndex(at: point) {
            return TextPos(line: hit, char: charIndex(in: hit, atX: point.x))
        }
        // Check lines whose vertical band spans `point.y` first.
        var bandCandidates: [Int] = []
        for i in ocrLayouts.indices {
            let r = viewRect(for: ocrLayouts[i].line.box)
            if point.y >= r.minY - 4 && point.y <= r.maxY + 4 {
                bandCandidates.append(i)
            }
        }
        if !bandCandidates.isEmpty {
            let chosen = bandCandidates.min { a, b in
                let ra = viewRect(for: ocrLayouts[a].line.box)
                let rb = viewRect(for: ocrLayouts[b].line.box)
                let da = point.x < ra.minX ? ra.minX - point.x : (point.x > ra.maxX ? point.x - ra.maxX : 0)
                let db = point.x < rb.minX ? rb.minX - point.x : (point.x > rb.maxX ? point.x - rb.maxX : 0)
                return da < db
            }!
            return TextPos(line: chosen, char: charIndex(in: chosen, atX: point.x))
        }
        // Otherwise pick the vertically closest line.
        let closest = ocrLayouts.indices.min { a, b in
            let ra = viewRect(for: ocrLayouts[a].line.box)
            let rb = viewRect(for: ocrLayouts[b].line.box)
            return abs(ra.midY - point.y) < abs(rb.midY - point.y)
        }!
        let r = viewRect(for: ocrLayouts[closest].line.box)
        // In bottom-left coordinates, a larger Y is higher on screen (earlier in reading order).
        if point.y > r.maxY + 4 {
            return TextPos(line: closest, char: 0)
        } else if point.y < r.minY - 4 {
            return TextPos(line: closest, char: ocrLayouts[closest].chars.count)
        }
        return TextPos(line: closest, char: charIndex(in: closest, atX: point.x))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for layout in ocrLayouts {
            let rect = viewRect(for: layout.line.box).insetBy(dx: -3, dy: -2)
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ocrLayouts.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        // 1. Subtle Live-Text style outlines around recognized text blocks so the user sees what can be selected.
        for layout in ocrLayouts {
            let rect = viewRect(for: layout.line.box).insetBy(dx: -2, dy: -1.5)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // 2. Highlight currently selected character ranges directly over the original image.
        if let a = selectionAnchor, let b = selectionHead, a != b {
            let start = min(a, b), end = max(a, b)
            for idx in start.line...end.line where ocrLayouts.indices.contains(idx) {
                let layout = ocrLayouts[idx]
                guard !layout.chars.isEmpty else { continue }
                let c0 = (idx == start.line) ? min(max(start.char, 0), layout.chars.count) : 0
                let c1 = (idx == end.line) ? min(max(end.char, 0), layout.chars.count) : layout.chars.count
                guard c0 < c1 else { continue }
                let lineRect = viewRect(for: layout.line.box)
                let x0 = lineRect.minX + lineRect.width * layout.fractions[c0]
                let x1 = lineRect.minX + lineRect.width * layout.fractions[c1]
                let selRect = CGRect(x: x0, y: lineRect.minY - 1, width: max(x1 - x0, 2), height: lineRect.height + 2)
                let selPath = CGPath(roundedRect: selRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
                ctx.addPath(selPath)
                ctx.setFillColor(NSColor.selectedControlColor.withAlphaComponent(0.48).cgColor)
                ctx.fillPath()
                ctx.addPath(selPath)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
        }

        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)

        // Holding Option (⌥) always drags the window, even when starting on text.
        if !event.modifierFlags.contains(.option), let lineIdx = hitLineIndex(at: pt) {
            let layout = ocrLayouts[lineIdx]
            if event.clickCount >= 3 {
                // Triple-click selects the entire line.
                selectionAnchor = TextPos(line: lineIdx, char: 0)
                selectionHead = TextPos(line: lineIdx, char: layout.chars.count)
                isSelectingText = false
                needsDisplay = true
                controller?.showStatus("已选中整行（\(selectedText.count) 字）· ⌘C 复制", for: 2.5)
                return
            } else if event.clickCount == 2 {
                // Double-click selects the word/run around the clicked character (or the full line).
                let c = min(max(charIndex(in: lineIdx, atX: pt.x), 0), max(layout.chars.count - 1, 0))
                let (w0, w1) = Self.wordRange(in: layout.chars, around: c)
                selectionAnchor = TextPos(line: lineIdx, char: w0)
                selectionHead = TextPos(line: lineIdx, char: w1)
                isSelectingText = false
                needsDisplay = true
                controller?.showStatus("已选中 \(selectedText.count) 个字 · ⌘C 复制", for: 2.5)
                return
            }
            let pos = TextPos(line: lineIdx, char: charIndex(in: lineIdx, atX: pt.x))
            if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
                selectionHead = pos
                selectionAnchor = anchor
            } else {
                selectionAnchor = pos
                selectionHead = pos
            }
            isSelectingText = true
            needsDisplay = true
            return
        }

        // Clicked outside recognized text boxes (on image background):
        isSelectingText = false
        if event.clickCount == 2 {
            controller?.close()
            return
        }
        clearSelection()
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingText else {
            super.mouseDragged(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        if let pos = textPos(at: pt) {
            selectionHead = pos
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelectingText else {
            super.mouseUp(with: event)
            return
        }
        isSelectingText = false
        let text = selectedText
        if !text.isEmpty {
            controller?.showStatus("已选中 \(text.count) 个字 · ⌘C 复制 · 右键更多操作", for: 3.0)
        }
    }

    /// Finds word boundaries around `index` for double-click selection.
    private static func wordRange(in chars: [Character], around index: Int) -> (Int, Int) {
        guard chars.indices.contains(index) else { return (0, chars.count) }
        func kind(_ ch: Character) -> Int {
            if ch.isWhitespace || ch.isPunctuation || ch.isSymbol { return 0 }
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") { return 1 }
            return 2 // CJK or other scripts
        }
        let target = kind(chars[index])
        if target == 0 { return (index, index + 1) }
        var l = index
        while l > 0 && kind(chars[l - 1]) == target { l -= 1 }
        var r = index + 1
        while r < chars.count && kind(chars[r]) == target { r += 1 }
        return (l, r)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        // ⌥ + scroll changes opacity, plain scroll zooms.
        if event.modifierFlags.contains(.option) {
            controller?.adjustOpacity(by: dy)
        } else {
            controller?.zoom(by: dy)
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.zoom(by: event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { // Esc: clear text selection first if any, otherwise close pin
            if hasTextSelection {
                clearSelection()
                controller?.showStatus(nil)
            } else {
                controller?.close()
            }
        } else if event.keyCode == 8, flags == .command { // ⌘C: copy selected text if any, else copy image
            if hasTextSelection {
                controller?.copySelectedText()
            } else {
                controller?.copyImage()
            }
        } else if event.keyCode == 0, flags == .command, !ocrLayouts.isEmpty { // ⌘A: select all recognized text
            selectAllRecognizedText()
        } else if event.keyCode == 17, controller?.translated != nil { // T: original / translation
            controller?.translate()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if hasTextSelection {
            let copySel = NSMenuItem(title: "复制选中文字", action: #selector(PinWindowController.copySelectedText), keyEquivalent: "")
            copySel.target = controller
            menu.addItem(copySel)
        }
        if controller?.recognizedLines?.isEmpty == false {
            let copyAll = NSMenuItem(title: "复制全部文字", action: #selector(PinWindowController.copyAllRecognizedText), keyEquivalent: "")
            copyAll.target = controller
            menu.addItem(copyAll)
            let selAll = NSMenuItem(title: "全选文字", action: #selector(PinWindowController.selectAllText), keyEquivalent: "")
            selAll.target = controller
            menu.addItem(selAll)
            menu.addItem(.separator())
        }
        let translateTitle = controller?.translated == nil ? "翻译" : controller?.showingTranslation == true ? "显示原文" : "显示译文"
        let copyTitle = controller?.recognizedLines?.isEmpty == false ? "复制图片" : "复制"
        let ocrTitle = controller?.recognizedLines == nil ? "识别文字" : "重新识别文字"
        for (title, action) in [(copyTitle, #selector(PinWindowController.copyImage)),
                                (ocrTitle, #selector(PinWindowController.recognizeText)),
                                (translateTitle, #selector(PinWindowController.translate)),
                                ("保存", #selector(PinWindowController.saveImage)),
                                ("恢复原始大小", #selector(PinWindowController.resetZoom)),
                                ("关闭", #selector(PinWindowController.close))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }
}
