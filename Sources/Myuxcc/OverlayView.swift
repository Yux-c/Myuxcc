import AppKit

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayDidBeginSelection(_ view: OverlayView)
    func overlay(_ view: OverlayView, finishWith action: FinishAction)
    func overlayDidRequestLongCapture(_ view: OverlayView)
    func overlayDidRequestRecording(_ view: OverlayView)
}

enum FinishAction {
    case copy, save, pin, recognizeText, translate, cancel
}

/// Full-screen view that shows the frozen screen, lets the user pick a region and annotate it.
final class OverlayView: NSView, NSTextFieldDelegate {
    weak var delegate: OverlayViewDelegate?
    let frozen: CGImage

    private(set) var selection: CGRect?
    /// Window frame under a point (view coordinates); set by the session. nil means no window there.
    var windowFrameAt: ((CGPoint) -> CGRect?)?
    /// Window (or whole screen) highlighted while hovering, before a selection exists.
    private(set) var hoverRect: CGRect?
    private(set) var annotations: [Annotation] = []
    /// Snapshots of `annotations` before each change, so moves, resizes and deletes undo too.
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    /// Set once the selection is handed to a long capture.
    private(set) var isLongCapture = false
    /// The mark selected for editing, PowerPoint-style.
    private(set) var selectedAnnotation: Int?
    /// Marks as they were when a drag on a mark began; recorded for undo only if the drag changed something.
    private var markEditSnapshot: [Annotation]?
    /// Set while re-editing an existing text mark (its undo snapshot is already recorded):
    /// where it sat in the stack and its style, so the edit lands back in place.
    private var reeditedText: (index: Int, color: NSColor, size: CGFloat)?
    private var currentTool: Tool?
    private var draft: Annotation?
    private var color: NSColor { StyleBarView.colors[MarkStyle.colorIndex].color }
    private var lineWidth: CGFloat { MarkStyle.shapeWidths[MarkStyle.sizeIndex] }
    private var textSize: CGFloat { MarkStyle.textSizes[MarkStyle.sizeIndex] }
    private var highlighterColor: NSColor {
        StyleBarView.colors[MarkStyle.highlighterColorIndex].color.withAlphaComponent(MarkStyle.highlighterAlpha)
    }

    private enum DragMode {
        case none, creating(start: CGPoint), moving(offset: CGPoint), resizing(Handle), drawing(start: CGPoint)
        case markMoving(index: Int, start: CGPoint, original: Annotation)
        case markResizing(index: Int, handle: Handle, original: Annotation, box: CGRect)
        case arrowEnd(index: Int, isTip: Bool, original: Annotation)
    }
    /// What a press on the selected mark's chrome grabs.
    private enum MarkGrab {
        case box(Handle), arrowEnd(isTip: Bool)
    }
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private var dragMode: DragMode = .none
    private var mouseLocation: CGPoint?
    /// 触控板三指拖移/轻点拖移松手后，在系统延迟发送 mouseUp 窗口期内暂存的拖拽状态。
    /// 使松手后能立即完成框选或将新建标注转为选中态，同时若用户在系统延迟期内继续拖动也能无缝衔接。
    private struct LatchedDrag {
        let mode: DragMode
        /// 提前提交前的草稿标注（用于继续拖动时无缝恢复，特别是画笔/荧光笔的采样点序列）
        let rawDraft: Annotation?
        /// 是否已将草稿标注追加到 annotations 及 undoStack
        let committedAnnotation: Bool
        /// 提前提交前的标注编辑快照（用于标注移动/缩放继续拖动时恢复）
        let markEditSnapshot: [Annotation]?
        /// 是否已将标注编辑快照压入 undoStack
        let committedMarkEditUndo: Bool
    }
    private var latchedDrag: LatchedDrag?
    /// 当前拖拽过程中触控板同时接触的最大手指数（用于识别三指拖移或轻点拖移抬手）
    private var maxTrackpadTouchesInDrag = 0
    /// 针对 macOS 三指拖移（系统底层会屏蔽 NSTouch 并延迟约 0.45 秒才发送 mouseUp）的释放检测定时器：
    /// 当拖拽停止移动短暂时间后立即完成框选/选中标注，无需干等系统延迟超时。
    private var dragReleaseWorkItem: DispatchWorkItem?
    /// 拖拽停止移动后提前进入完成/选中态的等待阈值（秒）
    private static let dragReleaseDelay: TimeInterval = 0.065

    private(set) lazy var toolbar = ToolbarView(target: self)
    private(set) lazy var styleBar = StyleBarView(target: self)
    private var editingField: NSTextField?

    init(frame: CGRect, frozen: CGImage) {
        self.frozen = frozen
        super.init(frame: frame)
        // 开启触控板间接接触事件（NSTouch），用于在轻点拖移/触控板松手瞬间立即结束拖拽
        allowedTouchTypes = [.indirect]
        toolbar.isHidden = true
        // Sized from the start, so a layout pass before the first selection doesn't fight its constraints.
        toolbar.frame.size = toolbar.fittingSize
        addSubview(toolbar)
        styleBar.isHidden = true
        addSubview(styleBar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Public

    func clearSelection() {
        commitTextEditing()
        cancelDragReleaseTimer()
        dragMode = .none
        latchedDrag = nil
        maxTrackpadTouchesInDrag = 0
        draft = nil
        markEditSnapshot = nil
        selection = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedAnnotation = nil
        currentTool = nil
        toolbar.isHidden = true
        styleBar.isHidden = true
        if let p = mouseLocation { updateHover(at: p) }
        needsDisplay = true
    }

    /// Tracks the pointer before a selection exists: highlights the window under it (or the whole screen).
    func updateHover(at p: CGPoint) {
        mouseLocation = p
        if selection == nil { hoverRect = windowFrameAt?(p) ?? bounds }
        needsDisplay = true
    }

    /// sRGB hex of the frozen pixel under a view point, e.g. "#1E90FF".
    func colorHex(at p: CGPoint) -> String? {
        let px = pixelPoint(p)
        guard let c = frozen.srgbPixel(x: px.x, y: px.y) else { return nil }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    private func pixelPoint(_ p: CGPoint) -> (x: Int, y: Int) {
        let scale = CGFloat(frozen.width) / bounds.width
        return (min(max(Int(p.x * scale), 0), frozen.width - 1), min(max(Int(p.y * scale), 0), frozen.height - 1))
    }

    /// Renders the selected region with its annotations at native pixel resolution.
    func renderSelection() -> CGImage? {
        commitTextEditing()
        // 导出截图前强制结算尚未收到 mouseUp 的拖拽（如触控板三指拖移延迟期内直接按 Return）
        finishActiveDrag()
        guard let sel = selection?.integral, sel.width > 0, sel.height > 0 else { return nil }
        let scale = CGFloat(frozen.width) / bounds.width
        let pw = Int(sel.width * scale), ph = Int(sel.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip to top-left origin and map view points to pixels, so drawing code is shared with draw(_:).
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawFrozen(in: ctx)
        for a in annotations { a.draw(base: frozen, viewSize: bounds.size) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Seeds a selection and marks without mouse input; used by `--selftest`.
    func loadForTesting(selection: CGRect, annotations: [Annotation]) {
        // 重置残留的拖拽、工具与选中状态，确保多轮自测互不干扰
        clearSelection()
        self.selection = selection
        self.annotations = annotations
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isLongCapture { drawLongCaptureFrame(); return }
        drawFrozen(in: ctx)

        // Dim everything outside the selection (or the hovered window).
        let dim = NSBezierPath(rect: bounds)
        if let hole = selection ?? hoverRect {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        guard let sel = selection else {
            if let hover = hoverRect {
                NSColor.systemBlue.setStroke()
                // 加粗悬停高亮框线宽，使窗口吸附预览边框更醒目清晰
                let border = NSBezierPath(rect: hover.insetBy(dx: 1.25, dy: 1.25))
                border.lineWidth = 2.5
                border.stroke()
                drawSizeLabel(for: hover)
            }
            drawLoupe()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        for a in annotations { a.draw(base: frozen, viewSize: bounds.size) }
        draft?.draw(base: frozen, viewSize: bounds.size)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.systemBlue.setStroke()
        // 将截图选区边框从 1pt 加粗至 2.2pt，解决原先选区框过细、在复杂背景上不够明显的问题
        let border = NSBezierPath(rect: sel.insetBy(dx: -1.1, dy: -1.1))
        border.lineWidth = 2.2
        border.stroke()

        if currentTool == nil {
            for h in Handle.allCases {
                let r = handleRect(h, in: sel)
                NSColor.white.setFill()
                let oval = NSBezierPath(ovalIn: r)
                oval.fill()
                NSColor.systemBlue.setStroke()
                // 同步加粗选区控制点描边，与加粗后的选区外框保持视觉协调
                oval.lineWidth = 1.5
                oval.stroke()
            }
        }
        drawMarkSelection()
        drawSizeLabel(for: sel)
        switch dragMode {
        case .creating, .resizing: drawLoupe()
        default: break
        }
    }

    /// Long capture shows the live screen: only the dimmed surroundings and the region's border are drawn.
    private func drawLongCaptureFrame() {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        guard let sel = selection else { return }
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: sel))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -1.25, dy: -1.25))
        border.lineWidth = 2.5
        border.stroke()
    }

    /// Dashed box and handles around the selected mark.
    private func drawMarkSelection() {
        guard let i = selectedAnnotation, annotations.indices.contains(i) else { return }
        let mark = annotations[i]
        if case let .arrow(a, b, _, _) = mark {
            for end in [a, b] { drawHandle(CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)) }
            return
        }
        let box = mark.bounds
        let outline = NSBezierPath(rect: box.insetBy(dx: -3, dy: -3))
        // 加粗选中标注的双色虚线框与控制点描边，提升选中态的清晰度
        outline.lineWidth = 1.4
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.setStroke()
        outline.stroke()
        outline.setLineDash([4, 3], count: 2, phase: 4)
        NSColor.systemBlue.setStroke()
        outline.stroke()
        if !mark.isText {
            for h in Handle.allCases { drawHandle(handleRect(h, in: box)) }
        }
    }

    private func drawHandle(_ r: CGRect) {
        NSColor.white.setFill()
        let path = NSBezierPath(rect: r)
        path.fill()
        NSColor.systemBlue.setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }

    private func drawFrozen(in ctx: CGContext) {
        // CGContext.draw assumes a bottom-left origin; flip locally inside our flipped space.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(frozen, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }

    private func drawSizeLabel(for sel: CGRect) {
        let scale = CGFloat(frozen.width) / bounds.width
        let text = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))"
        let outside = sel.minY - 26 >= 0 && !(selection == sel && !toolbar.isHidden && toolbarPlacement == .above)
        drawPill(text, at: CGPoint(x: sel.minX, y: outside ? sel.minY - 26 : sel.minY + 4))
    }

    private static let loupeCells = 11
    private static let loupeCell: CGFloat = 13

    /// Magnified pixels around the pointer with its pixel coordinate and color, at the pointer's lower right.
    private func drawLoupe() {
        guard let p = mouseLocation, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = Self.loupeCells, cell = Self.loupeCell, half = n / 2
        let side = CGFloat(n) * cell
        let infoHeight: CGFloat = selection == nil ? 78 : 46
        let size = CGSize(width: side, height: side + infoHeight)
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + size.width > bounds.width - 4 { origin.x = p.x - 20 - size.width }
        if origin.y + size.height > bounds.height - 4 { origin.y = p.y - 20 - size.height }
        let outer = CGRect(origin: origin, size: size)
        let gridRect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: outer, xRadius: 6, yRadius: 6).addClip()
        NSColor.black.setFill()
        outer.fill()

        // Pixels: crop around the pointer; off-screen cells stay black.
        let pixel = pixelPoint(p)
        let wanted = CGRect(x: pixel.x - half, y: pixel.y - half, width: n, height: n)
        if let crop = frozen.cropping(to: wanted) {
            let actual = wanted.intersection(CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
            let dest = CGRect(x: gridRect.minX + (actual.minX - wanted.minX) * cell,
                              y: gridRect.minY + (actual.minY - wanted.minY) * cell,
                              width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(crop, in: CGRect(origin: .zero, size: dest.size))
            ctx.restoreGState()
        }

        let grid = NSBezierPath()
        for i in 1..<n {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: gridRect.minX + o, y: gridRect.minY)); grid.line(to: CGPoint(x: gridRect.minX + o, y: gridRect.maxY))
            grid.move(to: CGPoint(x: gridRect.minX, y: gridRect.minY + o)); grid.line(to: CGPoint(x: gridRect.maxX, y: gridRect.minY + o))
        }
        grid.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.12).setStroke()
        grid.stroke()

        // Crosshair band through the centre row and column, leaving the centre pixel untinted.
        let c = CGFloat(half) * cell
        NSColor.systemBlue.withAlphaComponent(0.3).setFill()
        for band in [CGRect(x: gridRect.minX + c, y: gridRect.minY, width: cell, height: c),
                     CGRect(x: gridRect.minX + c, y: gridRect.minY + c + cell, width: cell, height: c),
                     CGRect(x: gridRect.minX, y: gridRect.minY + c, width: c, height: cell),
                     CGRect(x: gridRect.minX + c + cell, y: gridRect.minY + c, width: c, height: cell)] {
            band.fill(using: .sourceOver)
        }
        let center = CGRect(x: gridRect.minX + c, y: gridRect.minY + c, width: cell, height: cell)
        NSColor.black.setStroke()
        NSBezierPath(rect: center.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: center).stroke()

        // Info rows.
        let hex = colorHex(at: p) ?? "—"
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let tipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
        var y = gridRect.maxY + 7
        func row(_ label: String, _ value: String, swatch: NSColor? = nil) {
            ("\(label)" as NSString).draw(at: CGPoint(x: outer.minX + 8, y: y + 1), withAttributes: labelAttrs)
            let size = (value as NSString).size(withAttributes: valueAttrs)
            var x = outer.maxX - 8 - size.width
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: valueAttrs)
            if let swatch {
                x -= 16
                let r = CGRect(x: x, y: y + 2, width: 11, height: 11)
                swatch.setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                NSColor.white.withAlphaComponent(0.5).setStroke(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).stroke()
            }
            y += 17
        }
        row("坐标", "\(pixel.x), \(pixel.y)")
        let swatch = frozen.srgbPixel(x: pixel.x, y: pixel.y).map {
            NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
        }
        row("色值", hex, swatch: swatch)
        if selection == nil {
            y += 2
            ("按 C 复制色值" as NSString).draw(at: CGPoint(x: outer.minX + 8, y: y), withAttributes: tipAttrs)
            y += 14
            ("单击选窗口 · 拖拽框选" as NSString).draw(at: CGPoint(x: outer.minX + 8, y: y), withAttributes: tipAttrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.7).setStroke()
        NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
    }

    private func drawPill(_ text: String, at origin: CGPoint, fontSize: CGFloat = 12) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: attrs)
    }

    // MARK: - Geometry

    private func handleRect(_ h: Handle, in r: CGRect) -> CGRect {
        let p: CGPoint
        switch h {
        case .topLeft: p = CGPoint(x: r.minX, y: r.minY)
        case .top: p = CGPoint(x: r.midX, y: r.minY)
        case .topRight: p = CGPoint(x: r.maxX, y: r.minY)
        case .right: p = CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: p = CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: p = CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: p = CGPoint(x: r.minX, y: r.maxY)
        case .left: p = CGPoint(x: r.minX, y: r.midY)
        }
        return CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        Handle.allCases.first { handleRect($0, in: r).insetBy(dx: -5, dy: -5).contains(p) }
    }

    private func resized(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func layoutToolbar() {
        guard let sel = selection else { toolbar.isHidden = true; styleBar.isHidden = true; return }
        let size = toolbar.fittingSize
        let margin: CGFloat = 4, gap: CGFloat = 8, barGap: CGFloat = 6
        // The toolbar's place depends on the selection only, never on whether the style bar shows,
        // so picking a tool doesn't make it jump. Below the selection, else above it, else inside
        // its bottom edge (a selection about as tall as the screen).
        let y: CGFloat
        if sel.maxY + gap + size.height <= bounds.height - margin {
            y = sel.maxY + gap
            toolbarPlacement = .below
        } else if sel.minY - gap - size.height >= margin {
            y = sel.minY - gap - size.height
            toolbarPlacement = .above
        } else {
            y = min(sel.maxY, bounds.height - margin) - gap - size.height
            toolbarPlacement = .inside
        }
        // Right-aligned with the selection, kept on screen at the left and right edges.
        let x = min(max(sel.maxX - size.width, margin), bounds.width - size.width - margin)
        toolbar.frame = CGRect(x: x, y: max(y, margin), width: size.width, height: size.height)
        toolbar.isHidden = false
        toolbar.update(selectedTool: currentTool, canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty,
                       canLongCapture: annotations.isEmpty)

        styleBar.isHidden = styleTarget == nil
        guard let target = styleTarget else { return }
        // Right against the toolbar, left edges aligned under the tools: on the side away from the
        // selection, or the other side when the screen edge leaves no room there.
        let barSize = styleBar.fittingSize
        let under = toolbar.frame.maxY + barGap, over = toolbar.frame.minY - barGap - barSize.height
        let fitsUnder = under + barSize.height <= bounds.height - margin, fitsOver = over >= margin
        let barY = toolbarPlacement == .below ? (fitsUnder || !fitsOver ? under : over) : (fitsOver || !fitsUnder ? over : under)
        let barX = min(max(toolbar.frame.minX, margin), bounds.width - barSize.width - margin)
        styleBar.frame = CGRect(x: barX, y: barY, width: barSize.width, height: barSize.height)
        styleBar.update(colorIndex: target == .highlighter ? MarkStyle.highlighterColorIndex : MarkStyle.colorIndex,
                        sizeIndex: MarkStyle.sizeIndex)
    }

    enum ToolbarPlacement { case below, above, inside }
    /// Where the toolbar sits relative to the selection; the size label moves inside when the toolbar takes the space above.
    private(set) var toolbarPlacement = ToolbarPlacement.below

    private enum StyleTarget { case marks, highlighter }

    /// What the style bar would change: the selected mark, the text being typed or the current tool; nil for the mosaic.
    private var styleTarget: StyleTarget? {
        if let i = selectedAnnotation, annotations.indices.contains(i) {
            if case .mosaic = annotations[i] { return nil }
            return annotations[i].isHighlighter ? .highlighter : .marks
        }
        if editingField != nil { return .marks }
        switch currentTool {
        case nil, .mosaic?: return nil
        case .highlighter?: return .highlighter
        default: return .marks
        }
    }

    @objc func pickColor(_ sender: NSButton) { applyStyle(colorIndex: sender.tag, sizeIndex: nil) }
    @objc func pickSize(_ sender: NSButton) { applyStyle(colorIndex: nil, sizeIndex: sender.tag) }

    /// Sets the style for the next marks and restyles the selected mark (undoably) or the text being typed.
    private func applyStyle(colorIndex: Int?, sizeIndex: Int?) {
        // 切换颜色或粗细前先落盘可能处于触控板延迟期的拖拽
        finishActiveDrag()
        guard let target = styleTarget else { return }
        if let colorIndex {
            if target == .highlighter { MarkStyle.highlighterColorIndex = colorIndex } else { MarkStyle.colorIndex = colorIndex }
        }
        if let sizeIndex { MarkStyle.sizeIndex = sizeIndex }
        let newColor = colorIndex.map { StyleBarView.colors[$0].color }
        if let i = selectedAnnotation, annotations.indices.contains(i) {
            recordUndo()
            annotations[i] = annotations[i].restyled(color: newColor, sizeIndex: sizeIndex)
        } else if let field = editingField {
            if let newColor { field.textColor = newColor }
            if sizeIndex != nil {
                field.font = Annotation.textFont(textSize)
                reeditedText?.size = textSize
            }
            if let newColor { reeditedText?.color = newColor }
        }
        layoutToolbar()
        needsDisplay = true
    }

    /// Shift while drawing: squares and circles, arrows at multiples of 45°.
    private func constrained(from start: CGPoint, to q: CGPoint, tool: Tool, in sel: CGRect) -> CGPoint {
        let dx = q.x - start.x, dy = q.y - start.y
        switch tool {
        case .rectangle, .ellipse, .mosaic:
            // The largest square towards the pointer that still fits in the selection.
            let room = min(dx < 0 ? start.x - sel.minX : sel.maxX - start.x, dy < 0 ? start.y - sel.minY : sel.maxY - start.y)
            let side = min(max(abs(dx), abs(dy)), room)
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return clamp(CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length), to: sel)
        case .pen, .highlighter, .text:
            return q
        }
    }

    // MARK: - Mark editing

    /// Handle of the selected mark under `p`, if any.
    private func markGrab(at p: CGPoint) -> MarkGrab? {
        guard let i = selectedAnnotation, annotations.indices.contains(i) else { return nil }
        let mark = annotations[i]
        if case let .arrow(a, b, _, _) = mark {
            if hypot(p.x - b.x, p.y - b.y) <= 8 { return .arrowEnd(isTip: true) }
            if hypot(p.x - a.x, p.y - a.y) <= 8 { return .arrowEnd(isTip: false) }
            return nil
        }
        guard !mark.isText else { return nil }
        // Nearest handle wins, so the handles of a thin mark don't shadow each other.
        let box = mark.bounds
        let hits = Handle.allCases.filter { handleRect($0, in: box).insetBy(dx: -4, dy: -4).contains(p) }
        func distance(_ h: Handle) -> CGFloat {
            let r = handleRect(h, in: box)
            return hypot(r.midX - p.x, r.midY - p.y)
        }
        return hits.min { distance($0) < distance($1) }.map { .box($0) }
    }

    /// Topmost mark under `p`.
    private func mark(at p: CGPoint) -> Int? {
        annotations.lastIndex { $0.hitTest(p) }
    }

    /// Moves a mark but keeps its center inside the selection; outside it would be clipped away and unclickable.
    private func keptInSelection(_ mark: Annotation, moved d: CGVector) -> Annotation {
        guard let sel = selection else { return mark.moved(by: d) }
        let b = mark.bounds
        let c = clamp(CGPoint(x: b.midX + d.dx, y: b.midY + d.dy), to: sel)
        return mark.moved(by: CGVector(dx: c.x - b.midX, dy: c.y - b.midY))
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// A press that barely moved shouldn't leave an invisible mark behind.
    private func isBigEnough(_ mark: Annotation) -> Bool {
        let b = mark.bounds
        switch mark {
        case .rectangle, .ellipse, .mosaic: return b.width >= 3 && b.height >= 3
        default: return max(b.width, b.height) >= 3
        }
    }

    /// 撤销历史栈的最大步数上限，防止单次截图中反复拖动/微调标注导致历史快照无限增长
    private static let maxUndoSteps = 50

    /// Saves the current marks so the next change can be undone.
    private func recordUndo() {
        // 超出最大撤销步数时移除最早的历史快照，控制内存占用
        if undoStack.count >= Self.maxUndoSteps {
            undoStack.removeFirst(undoStack.count - Self.maxUndoSteps + 1)
        }
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    private func deleteSelectedMark() {
        guard let i = selectedAnnotation, annotations.indices.contains(i) else { return }
        recordUndo()
        annotations.remove(at: i)
        selectedAnnotation = nil
        layoutToolbar()
        needsDisplay = true
    }

    private func nudgeSelectedMark(dx: CGFloat, dy: CGFloat) {
        guard let i = selectedAnnotation, annotations.indices.contains(i) else { return }
        recordUndo()
        annotations[i] = keptInSelection(annotations[i], moved: CGVector(dx: dx, dy: dy))
        layoutToolbar()
        needsDisplay = true
    }

    // MARK: - Drag settlement & Trackpad release

    /// 取消未触发的触控板拖拽静止收尾定时器
    private func cancelDragReleaseTimer() {
        dragReleaseWorkItem?.cancel()
        dragReleaseWorkItem = nil
    }

    /// 重置触控板拖拽静止收尾定时器：当连续 65ms 未收到新的 mouseDragged 时，立即进入选中态并显示工具栏
    private func scheduleDragReleaseTimer() {
        cancelDragReleaseTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragReleaseWorkItem = nil
            // 若当前仍在拖拽（系统尚未派发延迟的 mouseUp），提前结算并允许后续无缝续接
            if case .none = self.dragMode { return }
            self.completeDrag(at: self.mouseLocation, latchForContinuation: true)
        }
        dragReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragReleaseDelay, execute: work)
    }

    /// 立即终结任何正在进行或暂存待续接的拖拽（在按下回车/快捷键/点击按钮/导出图片前调用）
    func finishActiveDrag() {
        cancelDragReleaseTimer()
        maxTrackpadTouchesInDrag = 0
        if case .none = dragMode {
            // 若已提前结算在 latchedDrag 中，直接清除暂存即可（标注与选区已在数组中）
            latchedDrag = nil
            return
        }
        completeDrag(at: mouseLocation, latchForContinuation: false)
    }

    /// 结算当前拖拽状态（将选区或绘制中的 draft 立即转为完成/选中态）
    /// - Parameters:
    ///   - location: 松开时的鼠标位置
    ///   - latchForContinuation: 是否保存现场以便在三指拖移宽限期内继续拖动时无缝恢复
    private func completeDrag(at location: CGPoint?, latchForContinuation: Bool) {
        cancelDragReleaseTimer()
        let currentMode = dragMode
        if case .none = currentMode { return }
        // 保存原始草稿和编辑快照以便后续续接时无损回退
        let savedDraft = draft
        let savedSnapshot = markEditSnapshot
        var didCommitDrawing = false
        var didRecordEditUndo = false

        switch currentMode {
        case .creating:
            if let sel = selection, sel.width >= 4, sel.height >= 4 {
                layoutToolbar()
            } else if selection == nil, let snapped = hoverRect {
                // 仅在真正收到 mouseUp 时才将未拖动的点击吸附为窗口选区；提前定时器触发时不抢先吸附
                if !latchForContinuation {
                    selection = snapped
                    hoverRect = nil
                    layoutToolbar()
                } else {
                    return
                }
            } else if !latchForContinuation {
                selection = nil
                if let p = location { updateHover(at: p) }
            } else {
                return
            }
        case .drawing:
            // 松开鼠标或触控板停顿时，若使用画笔工具画出的线条比较直，则自动替换为直线
            let finalized = currentTool == .pen ? draft?.straightenedIfNeeded() : draft
            if let d = finalized, isBigEnough(d) {
                recordUndo()
                annotations.append(d)
                selectedAnnotation = annotations.count - 1 // 新画出的框立即变为选中态（显示虚线框和 8 个控制点）
                didCommitDrawing = true
            } else if latchForContinuation {
                // 还没拖出足够大的图形时不提前结束，等待继续拖动或最终 mouseUp
                return
            }
            draft = nil
            layoutToolbar()
        case .markMoving, .markResizing, .arrowEnd:
            // 仅当标注实际发生位移或尺寸变化时才记录撤销步
            if let before = markEditSnapshot, before.count == annotations.count,
               zip(before, annotations).contains(where: { $0.bounds != $1.bounds }) {
                undoStack.append(before)
                redoStack.removeAll()
                didRecordEditUndo = true
            }
            markEditSnapshot = nil
            layoutToolbar()
        default:
            break
        }

        if latchForContinuation {
            // 记录提前结算前的现场；若三指拖移未真正结束而继续滑动，可无缝恢复拖拽
            latchedDrag = LatchedDrag(
                mode: currentMode,
                rawDraft: savedDraft,
                committedAnnotation: didCommitDrawing,
                markEditSnapshot: savedSnapshot,
                committedMarkEditUndo: didRecordEditUndo
            )
        } else {
            latchedDrag = nil
        }
        dragMode = .none
        needsDisplay = true
    }

    /// 当处于提前结算态但系统尚未派发 mouseUp、且用户又继续滑动鼠标/触控板时，无损恢复原拖拽状态
    private func resumeLatchedDragIfNeeded() {
        guard case .none = dragMode, let latched = latchedDrag else { return }
        latchedDrag = nil
        dragMode = latched.mode
        switch latched.mode {
        case .drawing:
            // 撤回提前提交的临时标注与撤销记录，放回 draft 继续跟随鼠标绘制
            if latched.committedAnnotation {
                if !annotations.isEmpty { annotations.removeLast() }
                _ = undoStack.popLast()
                selectedAnnotation = nil
            }
            draft = latched.rawDraft
        case .markMoving, .markResizing, .arrowEnd:
            // 撤回提前压入的编辑撤销记录，恢复 markEditSnapshot 继续调整
            if latched.committedMarkEditUndo {
                _ = undoStack.popLast()
            }
            markEditSnapshot = latched.markEditSnapshot
        default:
            break
        }
    }

    // MARK: - Trackpad touches

    override func touchesBegan(with event: NSEvent) {
        // 记录拖拽期间触控板上的最大触点数，用于识别单指轻点拖移或三指拖移抬起
        let count = event.touches(matching: [.began, .moved, .stationary], in: self).count
        if count > maxTrackpadTouchesInDrag { maxTrackpadTouchesInDrag = count }
    }

    override func touchesMoved(with event: NSEvent) {
        let count = event.touches(matching: [.began, .moved, .stationary], in: self).count
        if count > maxTrackpadTouchesInDrag { maxTrackpadTouchesInDrag = count }
    }

    override func touchesEnded(with event: NSEvent) {
        // 当正在拖拽且触控板上所有手指均已抬起时，无需等待系统 0.45 秒延迟，立即结算为选中态
        guard maxTrackpadTouchesInDrag > 0 else { return }
        let remaining = event.touches(matching: [.began, .moved, .stationary], in: self).count
        if remaining == 0 {
            maxTrackpadTouchesInDrag = 0
            if case .none = dragMode { return }
            completeDrag(at: mouseLocation, latchForContinuation: true)
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        maxTrackpadTouchesInDrag = 0
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if selection == nil { updateHover(at: p) } else { mouseLocation = p }
        updateCursor()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        guard let p = mouseLocation, (window as? OverlayWindow)?.isSilent != true else { return }
        if let sel = selection {
            if markGrab(at: p) != nil {
                NSCursor.crosshair.set()
            } else if sel.contains(p), mark(at: p) != nil {
                NSCursor.openHand.set()
            } else if currentTool != nil, sel.contains(p) {
                (currentTool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if currentTool == nil, handle(at: p, in: sel) != nil {
                NSCursor.crosshair.set()
            } else if currentTool == nil, sel.contains(p) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 新一轮按下前先清理上一次可能残留的延迟拖拽状态
        finishActiveDrag()
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        commitTextEditing()

        if let sel = selection {
            // Marks come first, PowerPoint-style: the selected mark's handles, then any mark under the pointer.
            if let grab = markGrab(at: p), let i = selectedAnnotation {
                markEditSnapshot = annotations
                switch grab {
                case let .box(h): dragMode = .markResizing(index: i, handle: h, original: annotations[i], box: annotations[i].bounds)
                case let .arrowEnd(isTip): dragMode = .arrowEnd(index: i, isTip: isTip, original: annotations[i])
                }
                return
            }
            if sel.contains(p), let i = mark(at: p) {
                if event.clickCount == 2, annotations[i].isText { editText(at: i); return }
                if event.clickCount < 2 {
                    selectedAnnotation = i
                    markEditSnapshot = annotations
                    dragMode = .markMoving(index: i, start: p, original: annotations[i])
                    layoutToolbar()
                    needsDisplay = true
                    return
                }
            }
            if selectedAnnotation != nil {
                selectedAnnotation = nil
                needsDisplay = true
            }
        }

        if event.clickCount == 2, let sel = selection, sel.contains(p) {
            delegate?.overlay(self, finishWith: .copy)
            return
        }

        if let sel = selection {
            if let tool = currentTool, sel.contains(p) {
                if tool == .text { beginTextEditing(at: p); return }
                dragMode = .drawing(start: p)
                return
            }
            if currentTool == nil, let h = handle(at: p, in: sel) {
                dragMode = .resizing(h)
                return
            }
            if currentTool == nil, sel.contains(p) {
                dragMode = .moving(offset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                return
            }
            // Click outside an annotated selection does nothing, so marks are never lost by accident.
            if !annotations.isEmpty { return }
        }

        // Start a brand-new selection: a plain click takes the window under the pointer, a drag draws freely.
        delegate?.overlayDidBeginSelection(self)
        selection = nil
        currentTool = nil
        toolbar.isHidden = true
        updateHover(at: p)
        dragMode = .creating(start: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        mouseLocation = p
        // 若此前因 65ms 停顿已提前结算为选中态，但用户在三指拖移宽限期内继续滑动，则无缝恢复原拖拽
        resumeLatchedDragIfNeeded()
        switch dragMode {
        case .none:
            return
        case let .creating(start):
            // Small jitter while clicking keeps the window snap; a real drag switches to a free-form selection.
            if selection == nil, hypot(p.x - start.x, p.y - start.y) < 4 { break }
            hoverRect = nil
            selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
            toolbar.isHidden = true
        case let .moving(offset):
            guard let sel = selection else { return }
            var origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            origin.x = min(max(origin.x, 0), bounds.width - sel.width)
            origin.y = min(max(origin.y, 0), bounds.height - sel.height)
            selection = CGRect(origin: origin, size: sel.size)
            layoutToolbar()
        case let .resizing(h):
            guard let sel = selection else { return }
            let r = resized(sel, handle: h, to: p)
            if r.width >= 1, r.height >= 1 { selection = r } // a zero-size selection can't be grabbed or exported
            layoutToolbar()
        case let .markMoving(i, start, original):
            guard annotations.indices.contains(i) else { dragMode = .none; return }
            annotations[i] = keptInSelection(original, moved: CGVector(dx: p.x - start.x, dy: p.y - start.y))
        case let .markResizing(i, h, original, box):
            // Keep a few points of size so the mark stays visible, clickable and resizable again.
            guard annotations.indices.contains(i) else { dragMode = .none; return }
            var target = resized(box, handle: h, to: p)
            if box.width > 0, target.width < 4 { target.size.width = 4 }
            if box.height > 0, target.height < 4 { target.size.height = 4 }
            annotations[i] = original.scaled(from: box, to: target)
        case let .arrowEnd(i, isTip, original):
            guard annotations.indices.contains(i) else { dragMode = .none; return }
            annotations[i] = original.withArrowEnd(isTip, at: selection.map { clamp(p, to: $0) } ?? p)
        case let .drawing(start):
            guard let tool = currentTool, let sel = selection else { return }
            var q = CGPoint(x: min(max(p.x, sel.minX), sel.maxX), y: min(max(p.y, sel.minY), sel.maxY))
            if event.modifierFlags.contains(.shift) { q = constrained(from: start, to: q, tool: tool, in: sel) }
            let rect = CGRect(x: min(start.x, q.x), y: min(start.y, q.y),
                              width: abs(q.x - start.x), height: abs(q.y - start.y))
            switch tool {
            case .rectangle: draft = .rectangle(rect, color, lineWidth)
            case .ellipse: draft = .ellipse(rect, color, lineWidth)
            case .arrow: draft = .arrow(start, q, color, lineWidth)
            case .mosaic: draft = .mosaic(rect)
            case .pen, .highlighter:
                if case let .pen(points, c, w)? = draft { draft = .pen(points + [q], c, w) }
                else if tool == .pen { draft = .pen([start, q], color, lineWidth) }
                else { draft = .pen([start, q], highlighterColor, MarkStyle.highlighterWidths[MarkStyle.sizeIndex]) }
            case .text: break
            }
        }
        // 启动/重置 65ms 静止检测定时器，避免触控板三指拖移抬手后苦等系统 0.45s 延迟才进入选中态
        scheduleDragReleaseTimer()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        cancelDragReleaseTimer()
        maxTrackpadTouchesInDrag = 0
        // 若此前已通过触控板抬手或 65ms 静止定时器提前结算完毕，清空暂存现场即可
        if case .none = dragMode, latchedDrag != nil {
            latchedDrag = nil
            needsDisplay = true
            return
        }
        completeDrag(at: p, latchForContinuation: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        finishActiveDrag()
        // Right click: drop the selection first, exit when there is none (common screenshot-tool convention).
        if selection != nil { clearSelection() } else { delegate?.overlay(self, finishWith: .cancel) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // 按下任何快捷键（如 Return、⌘C、⌘S、Delete、方向键等）前，立即结算正在进行的拖拽或绘制草稿，
        // 彻底避免框选/画框刚结束（处于触控板三指拖移松开延迟期）直接按 Return 时漏画标注或无法完成截图
        finishActiveDrag()
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if isLongCapture {
            switch (event.keyCode, cmd) {
            case (53, _): delegate?.overlay(self, finishWith: .cancel)
            case (36, _), (76, _), (8, true): delegate?.overlay(self, finishWith: .copy) // Return, Enter, ⌘C
            case (1, true): delegate?.overlay(self, finishWith: .save) // ⌘S
            default: super.keyDown(with: event)
            }
            return
        }
        switch (event.keyCode, cmd) {
        case (53, _): // Esc: deselect the mark first, exit on the next press
            if selectedAnnotation != nil { selectedAnnotation = nil; needsDisplay = true }
            else { delegate?.overlay(self, finishWith: .cancel) }
        case (51, false), (117, false): // Delete / Forward Delete
            deleteSelectedMark()
        case (123, false), (124, false), (125, false), (126, false): // Arrow keys nudge the selected mark
            guard selectedAnnotation != nil else { super.keyDown(with: event); return }
            let step: CGFloat = shift ? 10 : 1
            switch event.keyCode {
            case 123: nudgeSelectedMark(dx: -step, dy: 0)
            case 124: nudgeSelectedMark(dx: step, dy: 0)
            case 125: nudgeSelectedMark(dx: 0, dy: step)
            default: nudgeSelectedMark(dx: 0, dy: -step)
            }
        case (36, _), (76, _): // Return / Enter
            if takeHoveredWindow() { delegate?.overlay(self, finishWith: .copy) }
        case (6, true): // Z
            shift ? redo() : undo()
        case (1, true): // S
            if takeHoveredWindow() { delegate?.overlay(self, finishWith: .save) }
        case (8, true): // ⌘C
            if takeHoveredWindow() { delegate?.overlay(self, finishWith: .copy) }
        case (_, false) where selection != nil && !toolbar.isHidden && event.modifierFlags.intersection([.control, .option, .shift]).isEmpty
                && event.charactersIgnoringModifiers.flatMap { Int($0) }.map { (1...9).contains($0) } == true:
            // 1–9: the toolbar's buttons, left to right (the seven tools, then undo and redo).
            if !toolbar.press(Int(event.charactersIgnoringModifiers!)!) { NSSound.beep() }
        case (8, false): // C: copy the color under the pointer and exit
            if selection == nil, let p = mouseLocation, let hex = colorHex(at: p) {
                ImageOutput.pasteboard.clearContents()
                ImageOutput.pasteboard.setString(hex, forType: .string)
                delegate?.overlay(self, finishWith: .cancel)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// True when there is something to export. Before any selection exists, the highlighted window
    /// (or screen) becomes the selection, so Return, ⌘C and ⌘S work without clicking it first.
    private func takeHoveredWindow() -> Bool {
        if selection != nil { return true }
        guard case .none = dragMode, let hover = hoverRect else { return false }
        selection = hover
        hoverRect = nil
        return true
    }

    // MARK: - Text tool

    private func beginTextEditing(at p: CGPoint) {
        beginTextEditing(fieldOrigin: CGPoint(x: p.x, y: p.y - textSize * 0.6), text: "", color: color, size: textSize)
    }

    /// Re-opens a text mark for editing in place; the old mark comes back on undo.
    private func editText(at i: Int) {
        guard case let .text(string, origin, textColor, size) = annotations[i] else { return }
        recordUndo()
        annotations.remove(at: i)
        selectedAnnotation = nil
        reeditedText = (i, textColor, size)
        beginTextEditing(fieldOrigin: CGPoint(x: origin.x - 2, y: origin.y - 4), text: string, color: textColor, size: size)
        needsDisplay = true
    }

    private func beginTextEditing(fieldOrigin: CGPoint, text: String, color: NSColor, size: CGFloat) {
        let field = NSTextField(string: text)
        field.font = Annotation.textFont(size)
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.delegate = self
        field.frame = CGRect(x: fieldOrigin.x, y: fieldOrigin.y,
                             width: max(120, (selection?.maxX ?? fieldOrigin.x) - fieldOrigin.x), height: 28)
        addSubview(field)
        window?.makeFirstResponder(field)
        editingField = field
    }

    private func commitTextEditing() {
        guard let field = editingField else { return }
        editingField = nil
        let text = field.stringValue
        if !text.isEmpty {
            if reeditedText == nil { recordUndo() }
            // NSTextField draws its text with a 2pt inset inside the frame.
            let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY + 4)
            let index = min(reeditedText?.index ?? annotations.count, annotations.count)
            annotations.insert(.text(text, origin, reeditedText?.color ?? field.textColor ?? color,
                                     reeditedText?.size ?? field.font?.pointSize ?? textSize), at: index)
            selectedAnnotation = index
        }
        reeditedText = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        layoutToolbar()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    // MARK: - Toolbar actions

    @objc func selectTool(_ sender: NSButton) {
        finishActiveDrag()
        commitTextEditing()
        let tool = Tool.allCases[sender.tag]
        currentTool = (currentTool == tool) ? nil : tool
        selectedAnnotation = nil
        layoutToolbar()
        needsDisplay = true
    }

    @objc func undo() {
        finishActiveDrag()
        commitTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedAnnotation = nil
        layoutToolbar()
        needsDisplay = true
    }

    @objc func redo() {
        finishActiveDrag()
        commitTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedAnnotation = nil
        layoutToolbar()
        needsDisplay = true
    }

    @objc func pin() { finishActiveDrag(); delegate?.overlay(self, finishWith: .pin) }
    @objc func recognizeText() { finishActiveDrag(); delegate?.overlay(self, finishWith: .recognizeText) }
    @objc func translate() { finishActiveDrag(); delegate?.overlay(self, finishWith: .translate) }
    @objc func longCapture() {
        finishActiveDrag()
        commitTextEditing()
        // Like FloGravity, switching to long capture is only offered before annotating.
        guard selection != nil, annotations.isEmpty else { return }
        delegate?.overlayDidRequestLongCapture(self)
    }

    @objc func recordScreen() {
        finishActiveDrag()
        commitTextEditing()
        guard selection != nil, annotations.isEmpty else { return }
        delegate?.overlayDidRequestRecording(self)
    }

    /// The live screen shows through from now on; the session's window ignores the mouse so the
    /// user can scroll the app underneath.
    func enterLongCaptureMode() {
        cancelDragReleaseTimer()
        latchedDrag = nil
        maxTrackpadTouchesInDrag = 0
        isLongCapture = true
        toolbar.isHidden = true
        hoverRect = nil
        currentTool = nil
        selectedAnnotation = nil
        dragMode = .none
        needsDisplay = true
    }
    @objc func save() { finishActiveDrag(); delegate?.overlay(self, finishWith: .save) }
    @objc func cancel() { finishActiveDrag(); delegate?.overlay(self, finishWith: .cancel) }
    @objc func copyAndClose() { finishActiveDrag(); delegate?.overlay(self, finishWith: .copy) }
}
