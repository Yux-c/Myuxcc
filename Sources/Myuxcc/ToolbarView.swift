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
        layer?.cornerRadius = 8 // 收紧圆角，贴合主流桌面截图栏的利落矩形感
        layer?.borderWidth = 1 // 增加细微高光外描边，在深色窗口背景上依然层次分明
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

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

        // 第一段：7 个标注工具（矩形、椭圆、画笔、箭头、荧光笔、文字、马赛克）
        for (i, tool) in Tool.allCases.enumerated() {
            let b = Self.button(Self.icon(for: .tool(tool)), tool.title, target, #selector(OverlayView.selectTool(_:)))
            b.setButtonType(.pushOnPushOff)
            b.tag = i
            toolButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(Self.separator())
        // 第二段：撤销与重做
        undoButton = Self.button(Self.icon(for: .undo), "撤销 ⌘Z", target, #selector(OverlayView.undo))
        redoButton = Self.button(Self.icon(for: .redo), "重做 ⇧⌘Z", target, #selector(OverlayView.redo))
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        stack.addArrangedSubview(Self.separator())
        // 第三段：扩展能力（长截图、录屏、OCR、翻译）
        longCaptureButton = Self.button(Self.icon(for: .longCapture), "长截图（滚动拼接）", target, #selector(OverlayView.longCapture))
        stack.addArrangedSubview(longCaptureButton)
        recordButton = Self.button(Self.icon(for: .record), "录屏", target, #selector(OverlayView.recordScreen))
        stack.addArrangedSubview(recordButton)
        stack.addArrangedSubview(Self.button(Self.icon(for: .ocr), "识别文字（OCR）", target, #selector(OverlayView.recognizeText)))
        stack.addArrangedSubview(Self.button(Self.icon(for: .translate), "截图翻译", target, #selector(OverlayView.translate)))
        stack.addArrangedSubview(Self.separator())
        // 第四段：输出动作（钉图、保存、取消、完成）
        stack.addArrangedSubview(Self.button(Self.icon(for: .pin), "钉在桌面", target, #selector(OverlayView.pin)))
        stack.addArrangedSubview(Self.button(Self.icon(for: .save), "保存 ⌘S", target, #selector(OverlayView.save)))
        let cancel = Self.button(Self.icon(for: .cancel), "取消 Esc", target, #selector(OverlayView.cancel))
        cancel.contentTintColor = NSColor(srgbRed: 1.0, green: 0.35, blue: 0.33, alpha: 1) // 醒目红叉
        stack.addArrangedSubview(cancel)
        let done = Self.button(Self.icon(for: .done), "复制并关闭 ↩", target, #selector(OverlayView.copyAndClose))
        done.contentTintColor = NSColor(srgbRed: 0.16, green: 0.82, blue: 0.44, alpha: 1) // 清透绿勾
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
        // 选中工具使用明亮清透的天蓝色，避免标准 systemBlue 在深色 HUD 上发暗
        let activeTint = NSColor(srgbRed: 0.28, green: 0.68, blue: 1.0, alpha: 1)
        for (i, b) in toolButtons.enumerated() {
            let on = Tool.allCases[i] == selectedTool
            b.state = on ? .on : .off
            b.contentTintColor = on ? activeTint : nil
            (b as? ToolbarButton)?.isActiveTool = on
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        longCaptureButton.isEnabled = canLongCapture
        longCaptureButton.toolTip = canLongCapture ? "长截图（滚动拼接）" : "长截图（标注后不可用）"
        // Annotations are drawn on the frozen image, so they cannot be part of a live recording either.
        recordButton.isEnabled = canLongCapture
        recordButton.toolTip = canLongCapture ? "录屏" : "录屏（标注后不可用）"
    }

    /// 兼容按符号名创建工具栏按钮（长截图 HUD 与录屏控制栏复用），对常见动作自动映射为统一风格矢量图标
    static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image: NSImage
        switch symbol {
        case "checkmark": image = icon(for: .done)
        case "xmark": image = icon(for: .cancel)
        case "square.and.arrow.down": image = icon(for: .save)
        default:
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? NSImage()
        }
        return button(image, tip, target, action)
    }

    static func button(_ image: NSImage, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = ToolbarButton(image: image, target: target, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.toolTip = tip
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    /// 创建精致的居中细竖线分组分隔符（外框 9×24pt，内部居中 1×15pt 圆角半透明竖线）
    private static func separator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 9).isActive = true
        container.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        line.layer?.cornerRadius = 0.5
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 15),
        ])
        return container
    }

    // MARK: - 统一设计语言的自定义矢量工具栏图标体系

    /// 工具栏全部图标枚举：统一采用 20×20 视口、1.55pt 圆头圆角匀线与清晰几何造型
    enum IconKind {
        case tool(Tool)
        case undo, redo, longCapture, record, ocr, translate, pin, save, cancel, done
    }

    /// 生成统一设计语言的矢量模板图标（`isTemplate = true`，自动适配 HUD 亮暗及选中态高亮着色）
    static func icon(for kind: IconKind) -> NSImage {
        let size = CGSize(width: 20, height: 20)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let strokeWidth: CGFloat = 1.55 // 现代轻盈匀线基准线宽

            /// 创建带统一线宽与圆角端点的路径
            func makePath(_ width: CGFloat = strokeWidth) -> NSBezierPath {
                let p = NSBezierPath()
                p.lineWidth = width
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                return p
            }

            switch kind {
            case .tool(.rectangle):
                // 矩形：参考图一，采用视觉方正、小圆角的几何方框，体量与圆形工具严格齐平
                let p = NSBezierPath(roundedRect: CGRect(x: 3.3, y: 3.3, width: 13.4, height: 13.4), xRadius: 1.8, yRadius: 1.8)
                p.lineWidth = strokeWidth
                p.stroke()

            case .tool(.ellipse):
                // 椭圆/圆形：参考图一正圆轮廓（14.4pt 直径做 1pt 视觉补偿，与方形工具重心完全一致）
                let p = NSBezierPath(ovalIn: CGRect(x: 2.8, y: 2.8, width: 14.4, height: 14.4))
                p.lineWidth = strokeWidth
                p.stroke()

            case .tool(.pen):
                // 画笔（第 3 位）：参考图一/图二，45° 斜置修长铅笔轮廓 + 右下角标志性水平书写底线
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 9.6, yBy: 10.0)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -9.6, yBy: -10.0)
                xf.concat()

                // 一体化闭合修长笔身：锥形笔尖 + 垂直笔杆 + 圆角笔帽
                let body = makePath(1.5)
                body.move(to: CGPoint(x: 9.6, y: 2.7))
                body.line(to: CGPoint(x: 7.7, y: 6.2))
                body.line(to: CGPoint(x: 7.7, y: 15.6))
                body.curve(to: CGPoint(x: 9.1, y: 17.0), controlPoint1: CGPoint(x: 7.7, y: 16.5), controlPoint2: CGPoint(x: 8.2, y: 17.0))
                body.line(to: CGPoint(x: 10.1, y: 17.0))
                body.curve(to: CGPoint(x: 11.5, y: 15.6), controlPoint1: CGPoint(x: 11.0, y: 17.0), controlPoint2: CGPoint(x: 11.5, y: 16.5))
                body.line(to: CGPoint(x: 11.5, y: 6.2))
                body.close()
                body.stroke()

                // 笔帽与笔杆的分界环线
                let cap = makePath(1.4)
                cap.move(to: CGPoint(x: 7.8, y: 13.9))
                cap.line(to: CGPoint(x: 11.4, y: 13.9))
                cap.stroke()
                NSGraphicsContext.restoreGraphicsState()

                // 右下角水平书写轨迹短线（参考图二画笔图标）
                let line = makePath(strokeWidth)
                line.move(to: CGPoint(x: 9.4, y: 3.4))
                line.line(to: CGPoint(x: 16.4, y: 3.4))
                line.stroke()

            case .tool(.arrow):
                // 箭头（第 4 位）：参考图一/图二，45° 利落长杆配严格对齐水平/垂直轴的直角翼
                let p = makePath(1.6)
                p.move(to: CGPoint(x: 4.2, y: 4.2))
                p.line(to: CGPoint(x: 15.5, y: 15.5))
                p.move(to: CGPoint(x: 8.0, y: 15.8))
                p.line(to: CGPoint(x: 15.8, y: 15.8))
                p.line(to: CGPoint(x: 15.8, y: 8.0))
                p.stroke()

            case .tool(.highlighter):
                // 荧光笔：45° 斜置现代宽杆马克笔 + 半透明斜切扁刀头
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 10, yBy: 10)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -10, yBy: -10)
                xf.concat()

                // 斜切扁刀笔头（半透明填充体现荧光墨水质感）
                let nib = makePath(1.5)
                nib.move(to: CGPoint(x: 8.1, y: 6.8))
                nib.line(to: CGPoint(x: 8.1, y: 3.0))
                nib.line(to: CGPoint(x: 11.9, y: 4.3))
                nib.line(to: CGPoint(x: 11.9, y: 6.8))
                nib.close()
                NSColor.black.withAlphaComponent(0.28).setFill()
                nib.fill()
                nib.stroke()

                // 宽圆角笔杆与笔身短装饰横纹
                let barrel = NSBezierPath(roundedRect: CGRect(x: 6.9, y: 6.8, width: 6.2, height: 9.8), xRadius: 1.7, yRadius: 1.7)
                barrel.lineWidth = strokeWidth
                barrel.stroke()

                let slot = makePath(1.35)
                slot.move(to: CGPoint(x: 8.5, y: 13.6))
                slot.line(to: CGPoint(x: 11.5, y: 13.6))
                slot.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .tool(.text):
                // 文字：参考图二，轻盈干净的几何线性衬线「T」，去掉沉重的全黑填充块
                let p = makePath(1.6)
                // 顶部横梁及左右垂耳
                p.move(to: CGPoint(x: 4.4, y: 13.6))
                p.line(to: CGPoint(x: 4.4, y: 16.0))
                p.line(to: CGPoint(x: 15.6, y: 16.0))
                p.line(to: CGPoint(x: 15.6, y: 13.6))
                // 中轴竖干
                p.move(to: CGPoint(x: 10.0, y: 16.0))
                p.line(to: CGPoint(x: 10.0, y: 4.0))
                // 底部短衬线基座
                p.move(to: CGPoint(x: 7.2, y: 4.0))
                p.line(to: CGPoint(x: 12.8, y: 4.0))
                p.stroke()

            case .tool(.mosaic):
                // 马赛克：参考图一，圆角方框 + 内部紧贴对角的双透明度 3×3 像素棋盘块
                let frame = NSBezierPath(roundedRect: CGRect(x: 3.1, y: 3.1, width: 13.8, height: 13.8), xRadius: 2.4, yRadius: 2.4)
                frame.lineWidth = strokeWidth
                frame.stroke()
                let cell: CGFloat = 2.9, start: CGFloat = 5.65
                for r in 0..<3 {
                    for c in 0..<3 where (r + c) % 2 == 0 {
                        // 中心像素全实填充，四角像素略淡，呈现真实马赛克分层像素感
                        let alpha: CGFloat = (r == 1 && c == 1) ? 1.0 : 0.68
                        NSColor.black.withAlphaComponent(alpha).setFill()
                        let rect = CGRect(x: start + CGFloat(c) * cell, y: start + CGFloat(r) * cell, width: cell, height: cell)
                        NSBezierPath(roundedRect: rect, xRadius: 0.3, yRadius: 0.3).fill()
                    }
                }

            case .undo:
                // 撤销：圆润舒展的左向回弯箭头
                let p = makePath(strokeWidth)
                p.move(to: CGPoint(x: 4.6, y: 12.4))
                p.line(to: CGPoint(x: 12.0, y: 12.4))
                p.appendArc(withCenter: CGPoint(x: 12.0, y: 8.4), radius: 4.0, startAngle: 90, endAngle: -90, clockwise: true)
                p.line(to: CGPoint(x: 6.4, y: 4.4))
                p.move(to: CGPoint(x: 7.8, y: 15.5))
                p.line(to: CGPoint(x: 4.4, y: 12.4))
                p.line(to: CGPoint(x: 7.8, y: 9.3))
                p.stroke()

            case .redo:
                // 重做：与撤销严格镜像对称的右向回弯箭头
                let p = makePath(strokeWidth)
                p.move(to: CGPoint(x: 15.4, y: 12.4))
                p.line(to: CGPoint(x: 8.0, y: 12.4))
                p.appendArc(withCenter: CGPoint(x: 8.0, y: 8.4), radius: 4.0, startAngle: 90, endAngle: 270, clockwise: false)
                p.line(to: CGPoint(x: 13.6, y: 4.4))
                p.move(to: CGPoint(x: 12.2, y: 15.5))
                p.line(to: CGPoint(x: 15.6, y: 12.4))
                p.line(to: CGPoint(x: 12.2, y: 9.3))
                p.stroke()

            case .longCapture:
                // 长截图：现代右下开口取景页面框 + 右下角向下滚动延长箭头
                let frame = makePath(strokeWidth)
                frame.move(to: CGPoint(x: 9.0, y: 3.8))
                frame.line(to: CGPoint(x: 6.2, y: 3.8))
                frame.curve(to: CGPoint(x: 4.2, y: 5.8), controlPoint1: CGPoint(x: 5.0, y: 3.8), controlPoint2: CGPoint(x: 4.2, y: 4.6))
                frame.line(to: CGPoint(x: 4.2, y: 14.4))
                frame.curve(to: CGPoint(x: 6.2, y: 16.4), controlPoint1: CGPoint(x: 4.2, y: 15.6), controlPoint2: CGPoint(x: 5.0, y: 16.4))
                frame.line(to: CGPoint(x: 13.4, y: 16.4))
                frame.curve(to: CGPoint(x: 15.4, y: 14.4), controlPoint1: CGPoint(x: 14.6, y: 16.4), controlPoint2: CGPoint(x: 15.4, y: 15.6))
                frame.line(to: CGPoint(x: 15.4, y: 11.8))
                frame.stroke()

                // 右下角向下滚动箭头
                let arrow = makePath(strokeWidth)
                arrow.move(to: CGPoint(x: 13.8, y: 9.8))
                arrow.line(to: CGPoint(x: 13.8, y: 3.6))
                arrow.move(to: CGPoint(x: 11.1, y: 6.3))
                arrow.line(to: CGPoint(x: 13.8, y: 3.6))
                arrow.line(to: CGPoint(x: 16.5, y: 6.3))
                arrow.stroke()

            case .record:
                // 录屏：圆角摄像机轮廓（与圆形/椭圆工具彻底区分，语义一目了然）
                let body = NSBezierPath(roundedRect: CGRect(x: 2.6, y: 4.4, width: 10.6, height: 11.2), xRadius: 2.3, yRadius: 2.3)
                body.lineWidth = strokeWidth
                body.stroke()
                let lens = makePath(strokeWidth)
                lens.move(to: CGPoint(x: 13.2, y: 8.3))
                lens.line(to: CGPoint(x: 17.0, y: 6.1))
                lens.line(to: CGPoint(x: 17.0, y: 13.9))
                lens.line(to: CGPoint(x: 13.2, y: 11.7))
                lens.stroke()
                // 左上录制指示短横线
                let indicator = makePath(1.4)
                indicator.move(to: CGPoint(x: 5.3, y: 12.4))
                indicator.line(to: CGPoint(x: 7.9, y: 12.4))
                indicator.stroke()

            case .ocr:
                // 识别文字（OCR）：参考图一/图二，四角圆弧扫描取景框 + 居中「A」字
                let scan = makePath(strokeWidth)
                let minC: CGFloat = 3.0, maxC: CGFloat = 17.0, arm: CGFloat = 4.0, r: CGFloat = 1.8
                // 左上角
                scan.move(to: CGPoint(x: minC, y: maxC - arm))
                scan.line(to: CGPoint(x: minC, y: maxC - r))
                scan.curve(to: CGPoint(x: minC + r, y: maxC), controlPoint1: CGPoint(x: minC, y: maxC), controlPoint2: CGPoint(x: minC, y: maxC))
                scan.line(to: CGPoint(x: minC + arm, y: maxC))
                // 右上角
                scan.move(to: CGPoint(x: maxC - arm, y: maxC))
                scan.line(to: CGPoint(x: maxC - r, y: maxC))
                scan.curve(to: CGPoint(x: maxC, y: maxC - r), controlPoint1: CGPoint(x: maxC, y: maxC), controlPoint2: CGPoint(x: maxC, y: maxC))
                scan.line(to: CGPoint(x: maxC, y: maxC - arm))
                // 左下角
                scan.move(to: CGPoint(x: minC, y: minC + arm))
                scan.line(to: CGPoint(x: minC, y: minC + r))
                scan.curve(to: CGPoint(x: minC + r, y: minC), controlPoint1: CGPoint(x: minC, y: minC), controlPoint2: CGPoint(x: minC, y: minC))
                scan.line(to: CGPoint(x: minC + arm, y: minC))
                // 右下角
                scan.move(to: CGPoint(x: maxC - arm, y: minC))
                scan.line(to: CGPoint(x: maxC - r, y: minC))
                scan.curve(to: CGPoint(x: maxC, y: minC + r), controlPoint1: CGPoint(x: maxC, y: minC), controlPoint2: CGPoint(x: maxC, y: minC))
                scan.line(to: CGPoint(x: maxC, y: minC + arm))
                scan.stroke()

                // 居中字母「A」
                let letter = makePath(1.5)
                letter.move(to: CGPoint(x: 7.2, y: 6.4))
                letter.line(to: CGPoint(x: 10.0, y: 13.6))
                letter.line(to: CGPoint(x: 12.8, y: 6.4))
                letter.move(to: CGPoint(x: 8.1, y: 8.7))
                letter.line(to: CGPoint(x: 11.9, y: 8.7))
                letter.stroke()

            case .translate:
                // 截图翻译：饱满舒展的「文 + A」双语对照构图
                let p = makePath(1.5)
                // 左上「文」字（加宽横画与撇捺弧度，视觉重心饱满）
                p.move(to: CGPoint(x: 7.5, y: 17.0))
                p.line(to: CGPoint(x: 7.5, y: 15.0))
                p.move(to: CGPoint(x: 3.0, y: 15.0))
                p.line(to: CGPoint(x: 12.0, y: 15.0))
                p.move(to: CGPoint(x: 10.2, y: 14.8))
                p.curve(to: CGPoint(x: 3.2, y: 6.2), controlPoint1: CGPoint(x: 9.2, y: 10.6), controlPoint2: CGPoint(x: 6.4, y: 7.6))
                p.move(to: CGPoint(x: 4.8, y: 13.8))
                p.curve(to: CGPoint(x: 10.8, y: 6.8), controlPoint1: CGPoint(x: 6.2, y: 10.2), controlPoint2: CGPoint(x: 8.6, y: 7.8))
                // 右下「A」字
                p.move(to: CGPoint(x: 11.4, y: 3.2))
                p.line(to: CGPoint(x: 14.3, y: 10.6))
                p.line(to: CGPoint(x: 17.2, y: 3.2))
                p.move(to: CGPoint(x: 12.3, y: 5.6))
                p.line(to: CGPoint(x: 16.3, y: 5.6))
                p.stroke()

            case .pin:
                // 钉在桌面：参考图一/图二，45° 倾斜流线型铃铛图钉（柔和收腰与弧顶，简洁利落）
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 10, yBy: 10)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -10, yBy: -10)
                xf.concat()

                let p = makePath(strokeWidth)
                // 闭合铃铛形图钉帽身
                p.move(to: CGPoint(x: 6.2, y: 8.6))
                p.line(to: CGPoint(x: 13.8, y: 8.6))
                p.curve(to: CGPoint(x: 12.0, y: 11.2), controlPoint1: CGPoint(x: 12.6, y: 9.6), controlPoint2: CGPoint(x: 12.0, y: 10.2))
                p.line(to: CGPoint(x: 12.0, y: 14.8))
                p.curve(to: CGPoint(x: 10.6, y: 16.0), controlPoint1: CGPoint(x: 12.0, y: 15.6), controlPoint2: CGPoint(x: 11.4, y: 16.0))
                p.line(to: CGPoint(x: 9.4, y: 16.0))
                p.curve(to: CGPoint(x: 8.0, y: 14.8), controlPoint1: CGPoint(x: 8.6, y: 16.0), controlPoint2: CGPoint(x: 8.0, y: 15.6))
                p.line(to: CGPoint(x: 8.0, y: 11.2))
                p.curve(to: CGPoint(x: 6.2, y: 8.6), controlPoint1: CGPoint(x: 8.0, y: 10.2), controlPoint2: CGPoint(x: 7.4, y: 9.6))
                p.close()
                // 底部针尖
                p.move(to: CGPoint(x: 10.0, y: 8.6))
                p.line(to: CGPoint(x: 10.0, y: 3.2))
                p.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .save:
                // 保存：参考图二，浅 U 形托盘 + 垂直下载箭头
                let p = makePath(strokeWidth)
                p.move(to: CGPoint(x: 3.4, y: 6.8))
                p.line(to: CGPoint(x: 3.4, y: 5.2))
                p.curve(to: CGPoint(x: 5.2, y: 3.4), controlPoint1: CGPoint(x: 3.4, y: 4.1), controlPoint2: CGPoint(x: 4.1, y: 3.4))
                p.line(to: CGPoint(x: 14.8, y: 3.4))
                p.curve(to: CGPoint(x: 16.6, y: 5.2), controlPoint1: CGPoint(x: 15.9, y: 3.4), controlPoint2: CGPoint(x: 16.6, y: 4.1))
                p.line(to: CGPoint(x: 16.6, y: 6.8))
                // 居中下落箭头
                p.move(to: CGPoint(x: 10.0, y: 16.4))
                p.line(to: CGPoint(x: 10.0, y: 7.2))
                p.move(to: CGPoint(x: 6.5, y: 10.7))
                p.line(to: CGPoint(x: 10.0, y: 7.2))
                p.line(to: CGPoint(x: 13.5, y: 10.7))
                p.stroke()

            case .cancel:
                // 取消：参考图一/图二，干净利落的红色叉号
                let p = makePath(1.65)
                p.move(to: CGPoint(x: 5.0, y: 5.0))
                p.line(to: CGPoint(x: 15.0, y: 15.0))
                p.move(to: CGPoint(x: 5.0, y: 15.0))
                p.line(to: CGPoint(x: 15.0, y: 5.0))
                p.stroke()

            case .done:
                // 完成：参考图一/图二，舒展轻快的绿色对勾
                let p = makePath(1.75)
                p.move(to: CGPoint(x: 3.8, y: 9.8))
                p.line(to: CGPoint(x: 8.0, y: 5.4))
                p.line(to: CGPoint(x: 16.4, y: 14.2))
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// 工具栏按钮：支持未激活窗口首次点击直接响应，以及工具激活/鼠标悬停态圆角底块反馈
private final class ToolbarButton: NSButton {
    /// 当前是否处于工具选中高亮态
    var isActiveTool = false {
        didSet { refreshAppearance() }
    }
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6 // 按钮悬停/选中底块圆角
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    /// 根据选中与悬停状态刷新按钮背景底块，不改变按钮几何尺寸
    private func refreshAppearance() {
        if isActiveTool {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        } else if isHovered && isEnabled {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            layer?.backgroundColor = nil
        }
    }
}
