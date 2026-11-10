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
            let b = Self.button(Self.icon(for: .tool(tool)), tool.title, target, #selector(OverlayView.selectTool(_:)))
            b.setButtonType(.pushOnPushOff)
            b.tag = i
            toolButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(Self.separator())
        undoButton = Self.button(Self.icon(for: .undo), "撤销 ⌘Z", target, #selector(OverlayView.undo))
        redoButton = Self.button(Self.icon(for: .redo), "重做 ⇧⌘Z", target, #selector(OverlayView.redo))
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        stack.addArrangedSubview(Self.separator())
        longCaptureButton = Self.button(Self.icon(for: .longCapture), "长截图（滚动拼接）", target, #selector(OverlayView.longCapture))
        stack.addArrangedSubview(longCaptureButton)
        recordButton = Self.button(Self.icon(for: .record), "录屏", target, #selector(OverlayView.recordScreen))
        stack.addArrangedSubview(recordButton)
        stack.addArrangedSubview(Self.button(Self.icon(for: .ocr), "识别文字（OCR）", target, #selector(OverlayView.recognizeText)))
        stack.addArrangedSubview(Self.button(Self.icon(for: .translate), "截图翻译", target, #selector(OverlayView.translate)))
        stack.addArrangedSubview(Self.button(Self.icon(for: .pin), "钉在桌面", target, #selector(OverlayView.pin)))
        stack.addArrangedSubview(Self.button(Self.icon(for: .save), "保存 ⌘S", target, #selector(OverlayView.save)))
        let cancel = Self.button(Self.icon(for: .cancel), "取消 Esc", target, #selector(OverlayView.cancel))
        cancel.contentTintColor = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.34, alpha: 1)
        stack.addArrangedSubview(cancel)
        let done = Self.button(Self.icon(for: .done), "复制并关闭 ↩", target, #selector(OverlayView.copyAndClose))
        done.contentTintColor = NSColor(srgbRed: 0.22, green: 0.84, blue: 0.44, alpha: 1)
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

    private static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    // MARK: - 统一设计语言的自定义矢量工具栏图标体系

    /// 工具栏全部图标枚举：统一采用 20×20 视口、1.65pt 圆头圆角描边、45° 倾斜基准线与一致的视觉重心
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
            let strokeWidth: CGFloat = 1.65

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
                // 圆角矩形：与椭圆保持完全一致的视觉宽高比
                let p = NSBezierPath(roundedRect: CGRect(x: 2.5, y: 4.2, width: 15.0, height: 11.6), xRadius: 2.2, yRadius: 2.2)
                p.lineWidth = strokeWidth
                p.stroke()

            case .tool(.ellipse):
                // 椭圆：与矩形等高等宽的横向椭圆，摒弃原先过高过大的正圆图标
                let p = NSBezierPath(ovalIn: CGRect(x: 2.3, y: 4.0, width: 15.4, height: 12.0))
                p.lineWidth = strokeWidth
                p.stroke()

            case .tool(.arrow):
                // 箭头：修长舒展的 45° 斜向长柄箭头，加长箭杆并收敛箭头翼展，使整体比例挺拔协调
                let p = makePath(1.7)
                let tail = CGPoint(x: 3.4, y: 3.4)
                let tip = CGPoint(x: 16.4, y: 16.4)
                p.move(to: tail)
                p.line(to: tip)
                // 箭头双翼（夹角约 35°，翼长 5.2pt，与 18.4pt 长柄形成黄金比例）
                p.move(to: CGPoint(x: 11.2, y: 16.1))
                p.line(to: tip)
                p.line(to: CGPoint(x: 16.1, y: 11.2))
                p.stroke()

            case .tool(.pen):
                // 蜡笔（Crayon）：45° 斜置经典蜡笔造型——阶梯式钝圆蜡质锥头 + 圆柱卷纸笔身 + 标志性双道波纹护套环
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 10, yBy: 10)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -10, yBy: -10)
                xf.concat()

                // 蜡笔卷纸护套中段柔光底色，凸显蜡笔纸套层次感
                NSColor.black.withAlphaComponent(0.16).setFill()
                NSBezierPath(rect: CGRect(x: 7.3, y: 9.0, width: 5.4, height: 5.0)).fill()
                NSColor.black.setFill()

                // 蜡笔圆柱卷纸笔身（带顶部圆角笔尾与底部护套口）
                let body = NSBezierPath(roundedRect: CGRect(x: 7.3, y: 6.8, width: 5.4, height: 10.6), xRadius: 1.3, yRadius: 1.3)
                body.lineWidth = 1.55
                body.stroke()

                // 阶梯内收的圆润锥形蜡笔头（比笔身略窄一圈后收拢至圆头笔尖，区别于普通削尖铅笔）
                let tip = makePath(1.55)
                tip.move(to: CGPoint(x: 7.85, y: 6.8))
                tip.line(to: CGPoint(x: 9.3, y: 2.7))
                tip.curve(to: CGPoint(x: 10.7, y: 2.7), controlPoint1: CGPoint(x: 9.6, y: 2.0), controlPoint2: CGPoint(x: 10.4, y: 2.0))
                tip.line(to: CGPoint(x: 12.15, y: 6.8))
                tip.stroke()

                // 蜡笔卷纸上的标志性上下双道装饰横纹
                let bands = makePath(1.35)
                for y in [9.0, 14.0] as [CGFloat] {
                    bands.move(to: CGPoint(x: 7.4, y: y))
                    bands.line(to: CGPoint(x: 12.6, y: y))
                }
                bands.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .tool(.highlighter):
                // 荧光笔：与蜡笔同属 45° 斜置笔具家族，采用宽扁笔杆 + 斜切扁平刀头（带半透明填充）
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 10, yBy: 10)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -10, yBy: -10)
                xf.concat()

                // 斜切荧光笔头（半透明填充体现荧光墨水感）
                let nib = makePath(1.5)
                nib.move(to: CGPoint(x: 8.0, y: 6.2))
                nib.line(to: CGPoint(x: 8.0, y: 2.8))
                nib.line(to: CGPoint(x: 12.0, y: 4.1))
                nib.line(to: CGPoint(x: 12.0, y: 6.2))
                nib.close()
                NSColor.black.withAlphaComponent(0.32).setFill()
                nib.fill()
                nib.stroke()

                // 宽扁荧光笔杆与笔颈环
                let barrel = makePath(1.55)
                barrel.move(to: CGPoint(x: 7.0, y: 6.2))
                barrel.line(to: CGPoint(x: 13.0, y: 6.2))
                barrel.line(to: CGPoint(x: 13.0, y: 15.5))
                barrel.curve(to: CGPoint(x: 11.4, y: 17.0), controlPoint1: CGPoint(x: 13.0, y: 16.4), controlPoint2: CGPoint(x: 12.3, y: 17.0))
                barrel.line(to: CGPoint(x: 8.6, y: 17.0))
                barrel.curve(to: CGPoint(x: 7.0, y: 15.5), controlPoint1: CGPoint(x: 7.7, y: 17.0), controlPoint2: CGPoint(x: 7.0, y: 16.4))
                barrel.close()
                barrel.stroke()

                let ring = makePath(1.3)
                ring.move(to: CGPoint(x: 7.1, y: 8.6))
                ring.line(to: CGPoint(x: 12.9, y: 8.6))
                ring.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .tool(.text):
                // 文字：古典宋体/衬线体英文大写「T」，带优雅的顶部垂露衬线角（bracketed serifs）与底部衬线基座
                let tPath = NSBezierPath()
                // 顶部横梁与左右下垂衬线及内弧过渡
                tPath.move(to: CGPoint(x: 3.8, y: 16.5))
                tPath.line(to: CGPoint(x: 16.2, y: 16.5))
                tPath.line(to: CGPoint(x: 16.6, y: 12.6))
                tPath.line(to: CGPoint(x: 15.4, y: 12.6))
                tPath.curve(to: CGPoint(x: 13.4, y: 15.0), controlPoint1: CGPoint(x: 15.2, y: 14.3), controlPoint2: CGPoint(x: 14.6, y: 15.0))
                tPath.line(to: CGPoint(x: 11.1, y: 15.0))
                // 中轴主干右侧向下至底部衬线基座
                tPath.line(to: CGPoint(x: 11.1, y: 5.2))
                tPath.curve(to: CGPoint(x: 13.4, y: 4.3), controlPoint1: CGPoint(x: 11.1, y: 4.5), controlPoint2: CGPoint(x: 11.8, y: 4.3))
                tPath.line(to: CGPoint(x: 13.4, y: 3.3))
                tPath.line(to: CGPoint(x: 6.6, y: 3.3))
                tPath.line(to: CGPoint(x: 6.6, y: 4.3))
                tPath.curve(to: CGPoint(x: 8.9, y: 5.2), controlPoint1: CGPoint(x: 8.2, y: 4.3), controlPoint2: CGPoint(x: 8.9, y: 4.5))
                // 中轴主干左侧向上回接左侧顶部衬线
                tPath.line(to: CGPoint(x: 8.9, y: 15.0))
                tPath.line(to: CGPoint(x: 6.6, y: 15.0))
                tPath.curve(to: CGPoint(x: 4.6, y: 12.6), controlPoint1: CGPoint(x: 5.4, y: 15.0), controlPoint2: CGPoint(x: 4.8, y: 14.3))
                tPath.line(to: CGPoint(x: 3.4, y: 12.6))
                tPath.close()
                tPath.fill()

            case .tool(.mosaic):
                // 马赛克：圆角方框 + 内部清晰错落的 3×3 像素棋盘块，块面干脆不杂乱
                let frame = NSBezierPath(roundedRect: CGRect(x: 3.2, y: 3.2, width: 13.6, height: 13.6), xRadius: 2.3, yRadius: 2.3)
                frame.lineWidth = strokeWidth
                frame.stroke()
                let cell: CGFloat = 3.2, start: CGFloat = 5.2
                for r in 0..<3 {
                    for c in 0..<3 where (r + c) % 2 == 0 {
                        let rect = CGRect(x: start + CGFloat(c) * cell, y: start + CGFloat(r) * cell, width: cell, height: cell)
                        NSBezierPath(roundedRect: rect.insetBy(dx: 0.15, dy: 0.15), xRadius: 0.6, yRadius: 0.6).fill()
                    }
                }

            case .undo:
                // 撤销：圆润舒展的左向回弯箭头
                let p = makePath()
                p.move(to: CGPoint(x: 4.8, y: 12.8))
                p.line(to: CGPoint(x: 12.2, y: 12.8))
                p.appendArc(withCenter: CGPoint(x: 12.2, y: 9.1), radius: 3.7, startAngle: 90, endAngle: -90, clockwise: true)
                p.line(to: CGPoint(x: 6.8, y: 5.4))
                p.move(to: CGPoint(x: 7.9, y: 15.7))
                p.line(to: CGPoint(x: 4.5, y: 12.8))
                p.line(to: CGPoint(x: 7.9, y: 9.9))
                p.stroke()

            case .redo:
                // 重做：与撤销完全镜像对称的右向回弯箭头
                let p = makePath()
                p.move(to: CGPoint(x: 15.2, y: 12.8))
                p.line(to: CGPoint(x: 7.8, y: 12.8))
                p.appendArc(withCenter: CGPoint(x: 7.8, y: 9.1), radius: 3.7, startAngle: 90, endAngle: 270, clockwise: false)
                p.line(to: CGPoint(x: 13.2, y: 5.4))
                p.move(to: CGPoint(x: 12.1, y: 15.7))
                p.line(to: CGPoint(x: 15.5, y: 12.8))
                p.line(to: CGPoint(x: 12.1, y: 9.9))
                p.stroke()

            case .longCapture:
                // 长截图：竖向修长的圆角长方形外框 + 顶部文本横线 + 向下滚动拼接箭头
                let frame = NSBezierPath(roundedRect: CGRect(x: 4.6, y: 2.0, width: 10.8, height: 16.0), xRadius: 2.2, yRadius: 2.2)
                frame.lineWidth = strokeWidth
                frame.stroke()
                let inner = makePath(1.5)
                // 页面顶部两条内容横线
                inner.move(to: CGPoint(x: 7.3, y: 14.8))
                inner.line(to: CGPoint(x: 12.7, y: 14.8))
                inner.move(to: CGPoint(x: 7.3, y: 12.4))
                inner.line(to: CGPoint(x: 11.3, y: 12.4))
                // 竖向长箭杆与向下箭头
                inner.move(to: CGPoint(x: 10.0, y: 9.8))
                inner.line(to: CGPoint(x: 10.0, y: 4.8))
                inner.move(to: CGPoint(x: 7.8, y: 7.0))
                inner.line(to: CGPoint(x: 10.0, y: 4.6))
                inner.line(to: CGPoint(x: 12.2, y: 7.0))
                inner.stroke()

            case .record:
                // 录屏：外环 + 实心录制圆心，线宽与其他图标严格统一
                let outer = NSBezierPath(ovalIn: CGRect(x: 2.8, y: 2.8, width: 14.4, height: 14.4))
                outer.lineWidth = strokeWidth
                outer.stroke()
                NSBezierPath(ovalIn: CGRect(x: 6.8, y: 6.8, width: 6.4, height: 6.4)).fill()

            case .ocr:
                // 识别文字（OCR）：四角取景框 + 居中对齐的两行扫描文本线
                let corners = makePath()
                let minC: CGFloat = 3.0, maxC: CGFloat = 17.0, arm: CGFloat = 3.8
                // 左上角
                corners.move(to: CGPoint(x: minC, y: maxC - arm))
                corners.line(to: CGPoint(x: minC, y: maxC))
                corners.line(to: CGPoint(x: minC + arm, y: maxC))
                // 右上角
                corners.move(to: CGPoint(x: maxC - arm, y: maxC))
                corners.line(to: CGPoint(x: maxC, y: maxC))
                corners.line(to: CGPoint(x: maxC, y: maxC - arm))
                // 左下角
                corners.move(to: CGPoint(x: minC, y: minC + arm))
                corners.line(to: CGPoint(x: minC, y: minC))
                corners.line(to: CGPoint(x: minC + arm, y: minC))
                // 右下角
                corners.move(to: CGPoint(x: maxC - arm, y: minC))
                corners.line(to: CGPoint(x: maxC, y: minC))
                corners.line(to: CGPoint(x: maxC, y: minC + arm))
                // 内部文字扫描线
                corners.move(to: CGPoint(x: 6.4, y: 11.6))
                corners.line(to: CGPoint(x: 13.6, y: 11.6))
                corners.move(to: CGPoint(x: 6.4, y: 8.4))
                corners.line(to: CGPoint(x: 11.6, y: 8.4))
                corners.stroke()

            case .translate:
                // 截图翻译：精炼的「文 ⇄ A」双语对照构图，替代原先笨重的单字符气泡
                let p = makePath(1.5)
                // 左上「文」字
                p.move(to: CGPoint(x: 6.8, y: 17.2))
                p.line(to: CGPoint(x: 6.8, y: 15.4))
                p.move(to: CGPoint(x: 3.2, y: 15.4))
                p.line(to: CGPoint(x: 10.4, y: 15.4))
                p.move(to: CGPoint(x: 8.9, y: 15.2))
                p.curve(to: CGPoint(x: 3.4, y: 9.6), controlPoint1: CGPoint(x: 8.0, y: 12.4), controlPoint2: CGPoint(x: 5.8, y: 10.6))
                p.move(to: CGPoint(x: 4.7, y: 14.8))
                p.curve(to: CGPoint(x: 10.0, y: 9.6), controlPoint1: CGPoint(x: 5.8, y: 12.2), controlPoint2: CGPoint(x: 7.8, y: 10.6))
                // 右下「A」字
                p.move(to: CGPoint(x: 11.0, y: 3.0))
                p.line(to: CGPoint(x: 13.9, y: 10.4))
                p.line(to: CGPoint(x: 16.8, y: 3.0))
                p.move(to: CGPoint(x: 11.9, y: 5.4))
                p.line(to: CGPoint(x: 15.9, y: 5.4))
                p.stroke()

            case .pin:
                // 钉在桌面：45° 倾斜几何图钉，与箭头、蜡笔、荧光笔保持统一的 45° 视觉韵律
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 10, yBy: 10)
                xf.rotate(byDegrees: -45)
                xf.translateX(by: -10, yBy: -10)
                xf.concat()

                let p = makePath(1.6)
                // 图钉顶帽
                p.move(to: CGPoint(x: 7.2, y: 16.2))
                p.line(to: CGPoint(x: 12.8, y: 16.2))
                // 收腰钉身与宽底托盘
                p.move(to: CGPoint(x: 8.0, y: 16.2))
                p.line(to: CGPoint(x: 7.6, y: 10.8))
                p.line(to: CGPoint(x: 6.2, y: 9.0))
                p.line(to: CGPoint(x: 13.8, y: 9.0))
                p.line(to: CGPoint(x: 12.4, y: 10.8))
                p.line(to: CGPoint(x: 12.0, y: 16.2))
                // 底部针尖
                p.move(to: CGPoint(x: 10.0, y: 9.0))
                p.line(to: CGPoint(x: 10.0, y: 3.2))
                p.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .save:
                // 保存：底部圆角托盘 + 居中垂直下落箭头
                let p = makePath()
                p.move(to: CGPoint(x: 3.5, y: 8.8))
                p.line(to: CGPoint(x: 3.5, y: 5.4))
                p.curve(to: CGPoint(x: 5.5, y: 3.4), controlPoint1: CGPoint(x: 3.5, y: 4.1), controlPoint2: CGPoint(x: 4.2, y: 3.4))
                p.line(to: CGPoint(x: 14.5, y: 3.4))
                p.curve(to: CGPoint(x: 16.5, y: 5.4), controlPoint1: CGPoint(x: 15.8, y: 3.4), controlPoint2: CGPoint(x: 16.5, y: 4.1))
                p.line(to: CGPoint(x: 16.5, y: 8.8))
                // 垂直下载箭头
                p.move(to: CGPoint(x: 10.0, y: 16.5))
                p.line(to: CGPoint(x: 10.0, y: 7.8))
                p.move(to: CGPoint(x: 6.8, y: 11.0))
                p.line(to: CGPoint(x: 10.0, y: 7.6))
                p.line(to: CGPoint(x: 13.2, y: 11.0))
                p.stroke()

            case .cancel:
                // 取消：比例克制、圆头收笔的叉号
                let p = makePath(1.85)
                p.move(to: CGPoint(x: 5.4, y: 5.4))
                p.line(to: CGPoint(x: 14.6, y: 14.6))
                p.move(to: CGPoint(x: 5.4, y: 14.6))
                p.line(to: CGPoint(x: 14.6, y: 5.4))
                p.stroke()

            case .done:
                // 完成：舒展利落的对勾
                let p = makePath(1.95)
                p.move(to: CGPoint(x: 4.2, y: 9.8))
                p.line(to: CGPoint(x: 8.4, y: 5.4))
                p.line(to: CGPoint(x: 16.0, y: 14.4))
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Reacts to the first click even when the overlay is not yet the key window.
private final class ToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
