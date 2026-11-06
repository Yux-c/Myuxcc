import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Scrolling capture of a locked region: while the user scrolls the app underneath, frames of the
/// region are captured continuously and stitched into one tall image.
@MainActor
final class LongCaptureController: NSObject {
    /// Region in the screen's top-left coordinates, in points.
    let selection: CGRect
    private let screen: NSScreen
    private weak var overlay: NSWindow?
    private let hud: NSPanel
    private let preview: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewView = LongCapturePreviewView()
    private let onFinish: (FinishAction, CGImage?) -> Void
    private var capture: LongCaptureStream?
    private var snapshot: PreviewSnapshot?
    private var loop: Task<Void, Never>?
    /// An explicit phase: one Bool could not tell "still starting" from "failed" from "already done",
    /// which used to leave a failed session in a dead end showing "还没截到画面，请稍候" forever.
    private enum Phase { case starting, running, failed, finishing, finished }
    private var phase: Phase = .starting
    /// Esc / Return / ⌘S as hotkeys while capturing: once the user clicks the app being scrolled,
    /// the overlay is no longer the key window and would miss them.
    private var hotKeys: [HotKey] = []

    /// Latest hint shown to the user; also read by the e2e test.
    private(set) var status = "慢慢上下滚动，内容会自动拼接"
    var stitchedHeight: Int { snapshot?.height ?? 0 }
    /// Frames captured so far; read by the e2e test.
    var frameCount: Int { capture?.frameCount ?? 0 }
    var hudWindow: NSWindow { hud }
    var previewWindow: NSWindow { preview }

    init(screen: NSScreen, selection: CGRect, overlay: NSWindow, onFinish: @escaping (FinishAction, CGImage?) -> Void) {
        self.screen = screen
        self.selection = selection
        self.overlay = overlay
        self.onFinish = onFinish
        hud = Self.panel(ignoresMouse: false)
        preview = Self.panel(ignoresMouse: true)
        super.init()
        buildHUD()
        preview.contentView = previewView
    }

    func start() {
        layoutPanels()
        hud.orderFrontRegardless()
        let keys: [(Int, Int, FinishAction)] = [(kVK_Escape, 0, .cancel), (kVK_Return, 0, .copy),
                                                (kVK_ANSI_KeypadEnter, 0, .copy), (kVK_ANSI_S, cmdKey, .save)]
        hotKeys = keys.compactMap { code, mods, action in
            HotKey(keyCode: UInt32(code), modifiers: UInt32(mods)) { [weak self] in self?.finish(action) }
        }
        if hotKeys.count != keys.count {
            // Carbon registration can fail (another app owns the combination). Say so instead of
            // silently losing Esc / Return / cmd-S with no way to tell why.
            status = "慢慢上下滚动（部分快捷键被占用，请用 HUD 按钮结束）"
            statusLabel.stringValue = status
            layoutPanels()
        }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Ends the capture; `.copy` and `.save` hand over the stitched image. Without an image to hand over
    /// the capture stays open and says why.
    func finish(_ action: FinishAction) {
        guard phase != .finished, phase != .finishing else { return }
        // Cancel must work in every phase, including a failed or half-started capture.
        if action == .cancel { end(action, nil); return }
        guard phase == .running, snapshot != nil, let capture else {
            setStatus(phase == .failed
                      ? "截图未成功，请按 Esc 退出后重试"
                      : "还在准备画面，请稍候或按 Esc 退出")
            return
        }
        phase = .finishing
        capture.stop()
        guard let result = capture.finish() else {
            // The stream has stopped and ScrollStitcher.finish() is once-only now, so retrying this
            // action cannot succeed: send the user to Esc instead of a "please wait" dead end.
            phase = .failed
            setStatus("长图生成失败（内存不足），请按 Esc 退出后缩小选区重试")
            return
        }
        end(action, result)
    }

    private func end(_ action: FinishAction, _ image: CGImage?) {
        phase = .finished
        loop?.cancel()
        capture?.stop()
        hotKeys.removeAll()
        hud.orderOut(nil)
        preview.orderOut(nil)
        onFinish(action, image)
    }

    @objc private func copyTapped() { finish(.copy) }
    @objc private func saveTapped() { finish(.save) }
    @objc private func cancelTapped() { finish(.cancel) }

    // MARK: - Capture loop

    private func run() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                phase = .failed
                setStatus("找不到当前屏幕，请按 Esc 退出后重试"); return
            }
            // The whole app is excluded so the overlay, HUD and preview never appear in the region;
            // panels not on screen yet stay out too. Re-including our *other* windows (pinned images,
            // the shelf panel, a settings window) would stitch them into the long image, so only the
            // e2e harness asks for its test page back.
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == pid }
            guard !ownApps.isEmpty else {
                // Without this entry nothing is excluded at all and our own UI gets captured.
                phase = .failed
                setStatus("无法排除本应用窗口，请按 Esc 退出后重试"); return
            }
            let ownIDs = Set([overlay, hud, preview].compactMap { $0.map { CGWindowID($0.windowNumber) } })
            let excepting: [SCWindow] = CommandLine.arguments.contains("--e2e")
                ? content.windows.filter { $0.owningApplication?.processID == pid && !ownIDs.contains($0.windowID) }
                : []
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: excepting)
            let config = SCStreamConfiguration()
            config.sourceRect = selection
            let scale = screen.backingScaleFactor
            config.width = Int((selection.width * scale).rounded())
            config.height = Int((selection.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            guard !Task.isCancelled else { return }
            let capture = LongCaptureStream(filter: filter, configuration: config, recorder: FrameRecorder.start(),
                                            onUpdate: { [weak self] in self?.handle($0) },
                                            onError: { [weak self] in self?.failed($0) })
            self.capture = capture
            try await capture.start()
            // The session may have ended or failed while startCapture() was in flight.
            if phase != .starting, phase != .running { capture.stop() }
        } catch {
            failed(error)
        }
    }

    private func failed(_ error: Error) {
        guard phase != .finished, phase != .finishing else { return }
        phase = .failed
        capture?.stop() // don't leave a live SCStream behind after an error
        setStatus("截图失败：\(error.localizedDescription)（按 Esc 退出重试）")
    }

    private func handle(_ update: LongCaptureStream.Update) {
        guard phase != .finished, phase != .finishing else { return }
        if phase == .starting { phase = .running } // first frame: there is now an image to hand over
        snapshot = update.preview
        guard let result = update.status else { refreshPreview(); return }
        switch result {
        case .appended:
            // One layout pass per frame; setStatus() and refreshPreview() used to each run one.
            status = "拼接中 · 已截 \(update.preview.height) px"
            statusLabel.stringValue = status
            previewView.show(update.preview)
            layoutPanels()
        case .unchanged:
            break
        case .lost:
            setStatus("滚动太快，请回滑到上一位置再放慢（连续丢失会自动另起一段）")
        case .restarted:
            setStatus("已重新对齐：中间可能缺一段，建议按 Esc 取消后重截")
        case .featureless:
            setStatus("这一段内容太少，难以对齐，请慢一点滚")
        case .sizeMismatch:
            phase = .failed
            setStatus("选区尺寸已变化，已停止抓帧，请按 Esc 退出重新开始")
        case .full:
            setStatus("已达最大长度，已停止抓帧，可复制或保存")
        }
    }

    private func setStatus(_ text: String) {
        status = text
        statusLabel.stringValue = text
        layoutPanels()
    }

    private func refreshPreview() {
        guard let snapshot else { return }
        previewView.show(snapshot)
        layoutPanels()
    }

    // MARK: - Panels

    private static func panel(ignoresMouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) // above the overlay
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = ignoresMouse
        return p
    }

    private func buildHUD() {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8

        statusLabel.stringValue = status
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .labelColor
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        let done = ToolbarView.button("checkmark", "复制并关闭 ↩", self, #selector(copyTapped))
        done.contentTintColor = .systemGreen
        let cancel = ToolbarView.button("xmark", "取消 Esc", self, #selector(cancelTapped))
        cancel.contentTintColor = .systemRed
        let stack = NSStackView(views: [
            statusLabel,
            cancel,
            ToolbarView.button("square.and.arrow.down", "保存到桌面 ⌘S", self, #selector(saveTapped)),
            done,
        ])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        hud.contentView = bg
    }

    /// HUD under the region (above it, or inside its bottom edge, when there is no room);
    /// preview to its right (or left).
    private func layoutPanels() {
        let frame = screen.frame, visible = screen.visibleFrame
        // Top-left region → AppKit's bottom-left global coordinates.
        let region = CGRect(x: frame.minX + selection.minX, y: frame.maxY - selection.maxY,
                            width: selection.width, height: selection.height)

        let size = hud.contentView?.fittingSize ?? CGSize(width: 320, height: 36)
        var origin = CGPoint(x: region.maxX - size.width, y: region.minY - 8 - size.height)
        if origin.y < visible.minY { origin.y = region.maxY + 8 }
        if origin.y + size.height > visible.maxY { origin.y = region.minY + 8 }
        origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
        hud.setFrame(CGRect(origin: origin, size: size), display: true)

        // The preview grows with the stitched image up to this height, then scrolls to its newest part.
        let width: CGFloat = 140, maxHeight = min(region.height, 480)
        var x = region.maxX + 8
        if x + width > frame.maxX { x = region.minX - 8 - width }
        guard let snapshot, x >= frame.minX else {
            preview.orderOut(nil) // nothing captured yet, or no room on either side
            return
        }
        let height = min(maxHeight, CGFloat(snapshot.height) * width / CGFloat(snapshot.width)).rounded()
        preview.setFrame(CGRect(x: x, y: region.maxY - height, width: width, height: height), display: true)
        if !preview.isVisible { preview.orderFrontRegardless() }
    }
}

/// Thumbnail of the stitched image, scaled to fit the width and scrolled to its newest part.
final class LongCapturePreviewView: NSView {
    /// Canvas tiles, then the top and bottom screens on rows not yet seen clean, drawn over them as the
    /// finished image has them.
    private var snapshot = PreviewSnapshot()

    func show(_ snapshot: PreviewSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    /// The preview as the panel would show it for `stitcher`, at `maxHeight` points at most; for replays.
    static func render(_ stitcher: ScrollStitcher, width: CGFloat = 140, maxHeight: CGFloat = 480) -> Data? {
        let height = min(maxHeight, (CGFloat(stitcher.height) * width / CGFloat(stitcher.width)).rounded())
        let view = LongCapturePreviewView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.show(stitcher.snapshot)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        shape.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, !snapshot.overlays.isEmpty || !snapshot.tiles.isEmpty else { return }
        let focus = snapshot.focus
        shape.addClip()
        let scale = bounds.width / CGFloat(snapshot.width)
        // Scrolled off the top: the latest frame's middle stays centred where the thumbnail is longer than
        // the panel, which at the bottom of the image is the bottom, as when scrolling down.
        let overflow = max(0, CGFloat(snapshot.height) * scale - bounds.height)
        let hidden = min(overflow, max(0, CGFloat(focus.lowerBound + focus.upperBound) / 2 * scale - bounds.height / 2))
        ctx.interpolationQuality = .medium
        // Later tiles cover earlier ones where they overlap, as later frames did on the canvas.
        func rect(top: Int, rows: Int) -> CGRect {
            let h = CGFloat(rows) * scale
            return CGRect(x: 0, y: bounds.height - (CGFloat(top) * scale - hidden) - h, width: bounds.width, height: h)
        }
        for tile in snapshot.tiles {
            let r = rect(top: tile.top, rows: tile.rows)
            if r.intersects(bounds) { ctx.draw(tile.image, in: r) }
        }
        for overlay in snapshot.overlays {
            let r = rect(top: overlay.top, rows: overlay.rows)
            guard r.intersects(bounds) else { continue }
            ctx.saveGState()
            // Rows already on the canvas only across its moving columns: still columns (a sticky side
            // panel) keep what was written first, as in the finished image.
            let full = overlay.bands.map { rect(top: overlay.top + $0.lowerBound, rows: $0.count) }
            let partial = overlay.partialBands.flatMap { band in
                overlay.columns.map { run in
                    let row = rect(top: overlay.top + band.lowerBound, rows: band.count)
                    return CGRect(x: CGFloat(run.lowerBound) * scale, y: row.minY, width: CGFloat(run.count) * scale, height: row.height)
                }
            }
            if !(full + partial).isEmpty {
                ctx.clip(to: full + partial)
                ctx.draw(overlay.image, in: r)
            }
            ctx.restoreGState()
            // Still columns of rows below the first screen: one flat background colour.
            // Stretching a screen row left scrollbar pixels as vertical stripes.
            if let fillColor = overlay.fillColor {
                for band in overlay.fillBands {
                    // A point of overlap with the rows above: abutting edges leave an antialiased seam.
                    let row = rect(top: overlay.top + band.lowerBound, rows: band.count).insetBy(dx: 0, dy: -1)
                    ctx.saveGState()
                    ctx.clip(to: overlay.stillColumns.map {
                        CGRect(x: CGFloat($0.lowerBound) * scale, y: row.minY, width: CGFloat($0.count) * scale, height: row.height)
                    })
                    ctx.setFillColor(fillColor)
                    ctx.fill(row)
                    ctx.restoreGState()
                }
            }
        }
        NSColor.white.withAlphaComponent(0.3).setStroke()
        shape.stroke()
    }
}
