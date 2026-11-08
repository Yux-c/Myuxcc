import AVFoundation
import AppKit
import Translation
import Carbon.HIToolbox
import ServiceManagement
import ScreenCaptureKit

/// `--e2e <dir>`: drives the real capture flow with synthesized events and records screenshots + a report.
/// Runs the long-capture case only; with `--e2e-all` also the cases for features that are settled.
/// Needs Screen Recording permission. Exits when done.
///
/// `--e2e-silent <dir>` runs the cases that don't need the real screen without showing anything: the
/// overlay sits over a synthetic frozen image, is never ordered in and never takes focus, events go
/// straight to its window, and copies go to a private pasteboard. Needs no permission.
@MainActor
final class E2ETest {
    private let app: AppDelegate
    private let dir: URL
    private let silent: Bool
    private var report: [String] = []
    private var failures = 0
    /// Set when a silent run put a window on screen or brought the app to the front.
    private var showedSomething = false
    /// The view a silent run's mouse-down went to; it gets the drags and the mouse-up, as in a window.
    private var pressedView: NSView?

    init(app: AppDelegate, outputDir: String, silent: Bool = false) {
        self.app = app
        self.dir = URL(fileURLWithPath: outputDir)
        self.silent = silent
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func run() async {
        MarkStyle.inMemory = [:] // picking colours in the tests must not change the user's saved choice
        if silent {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("Myuxcc.e2e-silent"))
            ImageOutput.pasteboard = pasteboard
            let folder = dir.appendingPathComponent("save-folder", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Settings.saveFolderOverride = folder
            // One fake window to snap to, away from the menu bar.
            WindowSnapper.testFrames = [CGRect(x: 160, y: 140, width: 640, height: 420)]
            await caseAnnotateAndCopy()
            await caseEditMarks()
            await caseSave()
            await caseSnapAndLoupe()
            await caseCopyColor()
            await caseNumberKeys()
            await caseMarkStyle()
            await caseToolbarPlacement()
            await caseCancel()
            await caseTextRecognition()
            await caseTranslation()
            await caseImageTranslation()
            await caseShelf()
            await caseRecording()
            caseMigration()
            caseSettingsLayout()
            caseMenuBarIcon()
            check("静默：没有窗口上屏，也没抢走前台", !showedSomething && !NSApp.windows.contains { $0.isVisible })
            pasteboard.releaseGlobally()
            finishRun()
        }
        if CommandLine.arguments.contains("--e2e-settings") {
            await caseSettings()
            finishRun()
        }
        if CommandLine.arguments.contains("--e2e-keys") {
            await caseNumberKeys()
            finishRun()
        }
        if CommandLine.arguments.contains("--e2e-all") {
            await caseAppearsWithoutAnimation()
            await caseAnnotateAndCopy()
            await caseEditMarks()
            await caseSave()
            await casePin()
            await caseSnapAndLoupe()
            await caseCopyColor()
            await caseNumberKeys()
            await caseMarkStyle()
            await caseToolbarPlacement()
            await caseCancel()
        }
        await caseLongCapture()
        if CommandLine.arguments.contains("--e2e-all") { await caseSettings() }
        finishRun()
    }

    private func finishRun() -> Never {
        log("SUMMARY: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Cases

    /// ⌘, opens the settings; the shortcut field takes a new combination and the global hotkey moves to it;
    /// the save folder decides where ⌘S writes. Everything is put back afterwards.
    private func caseSettings() async {
        log("== 设置 ==")
        let oldShortcut = Settings.shortcut
        let oldFolder = UserDefaults.standard.string(forKey: "saveFolder")
        defer {
            Settings.shortcut = oldShortcut
            app.registerHotKey(oldShortcut)
            if let oldFolder { UserDefaults.standard.set(oldFolder, forKey: "saveFolder") } else { UserDefaults.standard.removeObject(forKey: "saveFolder") }
            app.settingsWindow?.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false,
                                     keyCode: UInt16(kVK_ANSI_Comma))!
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: comma) ?? false
        await pause(0.5)
        guard let window = app.settingsWindow else { check("⌘, 打开设置", false); return }
        check("⌘, 打开设置", handled && window.isVisible && window.isKeyWindow, "handled \(handled) visible \(window.isVisible) key \(window.isKeyWindow)")
        log("  登录项状态 \(SMAppService.mainApp.status.rawValue)")
        await windowShot(window, "09-settings")

        // Record ⌃⌥⇧9 in the shortcut field.
        guard let field = Self.find(ShortcutField.self, in: window.contentView) else { check("快捷键输入框", false); return }
        field.performClick(nil)
        await pause(0.2)
        let listening = field.title.contains("按下")
        let combo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "9", charactersIgnoringModifiers: "9",
                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_9))!
        NSApp.sendEvent(combo)
        await pause(0.3)
        let new = Settings.shortcut
        check("录入新快捷键 ⌃⌥⇧9", listening && new.keyCode == UInt32(kVK_ANSI_9)
              && new.modifiers == UInt32(controlKey | optionKey | shiftKey) && field.title == "⌃⌥⇧9", "\(new.display) field \(field.title)")
        // The app now holds the new combination (registering it again fails) and has let go of ⌃A.
        let probeNew = HotKey(keyCode: new.keyCode, modifiers: new.modifiers) {}
        let probeOld = HotKey(keyCode: oldShortcut.keyCode, modifiers: oldShortcut.modifiers) {}
        check("全局热键换成新组合、旧组合已释放", probeNew == nil && probeOld != nil)

        // Save folder.
        let folder = dir.appendingPathComponent("save-folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Settings.saveFolder = folder
        let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let saved = ImageOutput.save(image)
        check("保存到设置的文件夹", saved?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, saved?.path ?? "nil")
    }

    private func writePNG(_ image: CGImage, _ name: String) {
        if let data = ImageOutput.pngData(image) { try? data.write(to: dir.appendingPathComponent("\(name).png")) }
    }

    /// The window as it is on screen, through ScreenCaptureKit.
    private func windowShot(_ window: NSWindow, _ name: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { log("  (window shot \(name) failed)"); return }
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * window.backingScaleFactor)
        config.height = Int(target.frame.height * window.backingScaleFactor)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config),
              let data = ImageOutput.pngData(image) else { log("  (window shot \(name) failed)"); return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// An appear animation scales the overlay in from the center, so the screen edges briefly show the
    /// un-dimmed desktop. Grab several frames right after the overlay appears and expect every one dimmed.
    private func caseAppearsWithoutAnimation() async {
        log("== 启动不抖动 ==")
        // A small fake window around the pointer keeps the screen edges dimmed, whatever is under the pointer.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        WindowSnapper.testFrames = [CGRect(x: pointer.x - 100, y: pointer.y - 100, width: 200, height: 200)]
        defer { WindowSnapper.testFrames = nil }

        // Prepare the capture up front so the first frame is taken as early as possible.
        guard let screen = NSScreen.main, let displayID = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            check("准备首帧截图", false); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        config.showsCursor = false

        var frames: [(ms: Int, image: CGImage)] = []
        var frozen: CGImage?
        var hole: CGRect?
        var done = false
        app.onSessionShown = { session in
            let view = session.views.first { $0.window?.screen == screen } ?? session.views.first
            frozen = view?.frozen
            hole = view?.hoverRect
            let shownAt = Date()
            Task {
                for _ in 0..<5 {
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        frames.append((Int(Date().timeIntervalSince(shownAt) * 1000), image))
                    }
                }
                done = true
            }
        }
        app.startCapture()
        for _ in 0..<80 where !done { await pause(0.05) }
        app.onSessionShown = nil
        guard let frozen, !frames.isEmpty else { check("拿到首帧截图", false); return }
        if let data = ImageOutput.pngData(frames[0].image) { try? data.write(to: dir.appendingPathComponent("00-first-frame.png")) }

        let scale = Double(frozen.width) / Double(screen.frame.width)
        // A 9×9 grid over the screen: an appear animation both leaves the edges un-dimmed and shifts content.
        var samples: [(Int, Int)] = []
        for fy in stride(from: 0.04, through: 0.96, by: 0.115) {
            for fx in stride(from: 0.03, through: 0.97, by: 0.1175) {
                let x = Int(Double(frozen.width) * fx), y = Int(Double(frozen.height) * fy)
                // Skip the bright highlighted window plus the loupe and size label drawn around it.
                if let hole, hole.insetBy(dx: -200, dy: -200).contains(CGPoint(x: Double(x) / scale, y: Double(y) / scale)) { continue }
                if let c = frozen.srgbPixel(x: x, y: y), max(c.r, c.g, c.b) >= 35 { samples.append((x, y)) } // too dark to judge otherwise
            }
        }
        var bad: [String] = []
        for frame in frames {
            let wrong = samples.filter { x, y in
                guard let f = frozen.srgbPixel(x: x, y: y), let p = frame.image.srgbPixel(x: x, y: y) else { return false }
                let expected = Double(max(f.r, f.g, f.b)) * 0.6
                return abs(Double(max(p.r, p.g, p.b)) - expected) > max(8, expected * 0.2)
            }
            if !wrong.isEmpty { bad.append("\(frame.ms)ms: \(wrong.count)/\(samples.count) 点不对") }
        }
        log("  首帧采样：\(samples.count) 个点，截到 \(frames.map { "\($0.ms)ms" }.joined(separator: " "))")
        check("界面出现后各帧边缘都已变暗（没有缩放动画）", samples.count >= 4 && bad.isEmpty, bad.joined(separator: "; "))
        if let window = app.session?.windows.first { await key(window, code: 53, chars: "\u{1b}") }
    }

    private func caseAnnotateAndCopy() async {
        log("== 框选 / 调整 / 移动 / 标注 / 撤销重做 / 复制 ==")
        guard let (window, view) = await beginCapture() else { return }
        await snapshot("01-overlay")

        await drag(window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 500))
        check("框选 500×300", view.selection == CGRect(x: 200, y: 200, width: 500, height: 300), "\(String(describing: view.selection))")
        check("工具栏出现", !view.toolbar.isHidden)

        await drag(window, from: CGPoint(x: 700, y: 500), to: CGPoint(x: 760, y: 540))
        check("右下手柄放大到 560×340", view.selection?.size == CGSize(width: 560, height: 340), "\(String(describing: view.selection))")

        await drag(window, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 450, y: 320))
        check("拖动选区到 (250,220)", view.selection?.origin == CGPoint(x: 250, y: 220), "\(String(describing: view.selection))")
        await pause()
        await snapshot("02-selected")

        let sel = view.selection!
        let tools: [(String, CGPoint, CGPoint)] = [
            ("矩形", CGPoint(x: sel.minX + 20, y: sel.minY + 20), CGPoint(x: sel.minX + 140, y: sel.minY + 100)),
            ("椭圆", CGPoint(x: sel.minX + 170, y: sel.minY + 20), CGPoint(x: sel.minX + 290, y: sel.minY + 100)),
            ("箭头", CGPoint(x: sel.minX + 30, y: sel.maxY - 30), CGPoint(x: sel.minX + 200, y: sel.minY + 150)),
            ("画笔", CGPoint(x: sel.minX + 320, y: sel.minY + 40), CGPoint(x: sel.minX + 420, y: sel.minY + 120)),
            ("荧光笔", CGPoint(x: sel.minX + 250, y: sel.minY + 200), CGPoint(x: sel.minX + 450, y: sel.minY + 200)),
            ("马赛克", CGPoint(x: sel.maxX - 120, y: sel.maxY - 100), CGPoint(x: sel.maxX - 20, y: sel.maxY - 20)),
        ]
        for (i, (name, from, to)) in tools.enumerated() {
            await clickToolbarButton(window, view, tooltip: name)
            await drag(window, from: from, to: to, steps: 8)
            check("\(name) 已添加", view.annotations.count == i + 1, "count=\(view.annotations.count)")
        }

        await clickToolbarButton(window, view, tooltip: "文字")
        await click(window, at: CGPoint(x: sel.minX + 40, y: sel.minY + 130))
        await pause()
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("测试文字 Test", replacementRange: editor.selectedRange())
            await key(window, code: 36, chars: "\r") // Return commits the text
        }
        check("文字已添加", view.annotations.count == tools.count + 1, "count=\(view.annotations.count)")
        await pause()
        await snapshot("03-annotated")

        let before = view.annotations.count
        await key(window, code: 6, chars: "z", flags: .command)
        check("⌘Z 撤销", view.annotations.count == before - 1)
        await key(window, code: 6, chars: "z", flags: [.command, .shift])
        check("⇧⌘Z 重做", view.annotations.count == before)

        // Back to selection mode, then copy with Return.
        await clickToolbarButton(window, view, tooltip: "文字")
        let pixelScale = CGFloat(view.frozen.width) / view.bounds.width
        let expectedPixels = CGSize(width: sel.width * pixelScale, height: sel.height * pixelScale)
        ImageOutput.pasteboard.clearContents()
        await key(window, code: 36, chars: "\r")
        await pause()
        check("↩ 后覆盖窗关闭", app.session == nil)
        if let data = ImageOutput.pasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: data) {
            check("剪贴板 PNG 尺寸 \(Int(expectedPixels.width))×\(Int(expectedPixels.height))",
                  CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) == expectedPixels,
                  "\(rep.pixelsWide)×\(rep.pixelsHigh)")
            try? data.write(to: dir.appendingPathComponent("04-clipboard.png"))
        } else {
            check("剪贴板有 PNG", false)
        }
    }

    /// Marks behave like PowerPoint objects: select, move, resize, nudge, delete, re-edit text, all undoable.
    private func caseEditMarks() async {
        log("== 标注选中 / 移动 / 缩放 / 微调 / 删除 / 文字重编辑 ==")
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 500))

        await clickToolbarButton(window, view, tooltip: "矩形")
        await drag(window, from: CGPoint(x: 240, y: 240), to: CGPoint(x: 340, y: 300), steps: 6)
        check("新画的矩形自动选中", view.selectedAnnotation == 0, "\(String(describing: view.selectedAnnotation))")
        let original = view.annotations[0].bounds

        // The rectangle tool is still active, but a press on the outline grabs the mark instead of drawing.
        await drag(window, from: CGPoint(x: 240, y: 252), to: CGPoint(x: 290, y: 272), steps: 6) // clear of the left-edge handle
        check("拖动边框移动标注（不新画）", view.annotations.count == 1 && view.annotations[0].bounds == original.offsetBy(dx: 50, dy: 20),
              "count=\(view.annotations.count) \(view.annotations.first.map { "\($0.bounds)" } ?? "")")
        let moved = view.annotations[0].bounds

        await drag(window, from: CGPoint(x: moved.maxX, y: moved.maxY), to: CGPoint(x: moved.maxX + 40, y: moved.maxY + 30), steps: 6)
        let resized = view.annotations[0].bounds
        check("右下手柄缩放标注", resized.origin == moved.origin && resized.size == CGSize(width: moved.width + 40, height: moved.height + 30), "\(resized)")
        await pause()
        await snapshot("05-mark-selected")

        await key(window, code: 53, chars: "\u{1b}")
        check("Esc 先取消标注选中、不退出", view.selectedAnnotation == nil && app.session != nil)

        await clickToolbarButton(window, view, tooltip: "矩形") // back to selection mode
        await click(window, at: CGPoint(x: resized.minX, y: resized.midY))
        check("单击边框重新选中", view.selectedAnnotation == 0)
        await key(window, code: 124, chars: "\u{F703}", flags: .shift)
        await key(window, code: 125, chars: "\u{F701}")
        check("⇧→ 右移 10、↓ 下移 1", view.annotations[0].bounds == resized.offsetBy(dx: 10, dy: 1), "\(view.annotations[0].bounds)")
        await key(window, code: 6, chars: "z", flags: .command)
        await key(window, code: 6, chars: "z", flags: .command)
        check("⌘Z 撤销两次微调", view.annotations[0].bounds == resized, "\(view.annotations[0].bounds)")
        await key(window, code: 6, chars: "z", flags: .command)
        check("⌘Z 撤销缩放", view.annotations[0].bounds == moved, "\(view.annotations[0].bounds)")
        await key(window, code: 6, chars: "z", flags: [.command, .shift])
        check("⇧⌘Z 重做缩放", view.annotations[0].bounds == resized, "\(view.annotations[0].bounds)")

        await click(window, at: CGPoint(x: resized.minX, y: resized.midY))
        await key(window, code: 51, chars: "\u{7f}")
        check("⌫ 删除选中标注", view.annotations.isEmpty && app.session != nil)
        await key(window, code: 6, chars: "z", flags: .command)
        check("⌘Z 恢复删除", view.annotations.count == 1)

        // Arrow: drag the tip handle.
        await clickToolbarButton(window, view, tooltip: "箭头")
        await drag(window, from: CGPoint(x: 300, y: 450), to: CGPoint(x: 450, y: 400), steps: 6)
        await drag(window, from: CGPoint(x: 450, y: 400), to: CGPoint(x: 500, y: 350), steps: 6)
        if case let .arrow(a, b, _, _) = view.annotations.last! {
            check("拖动箭头尖端", a == CGPoint(x: 300, y: 450) && b == CGPoint(x: 500, y: 350), "\(a) → \(b)")
        } else {
            check("箭头已添加", false)
        }

        // Text: double-click re-opens it with its contents.
        await clickToolbarButton(window, view, tooltip: "文字")
        await click(window, at: CGPoint(x: 560, y: 260))
        await pause()
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("旧文字", replacementRange: editor.selectedRange())
            await key(window, code: 36, chars: "\r")
        }
        let count = view.annotations.count
        guard let textBox = view.annotations.last?.bounds else { return }
        await doubleClick(window, at: CGPoint(x: textBox.midX, y: textBox.midY))
        await pause()
        if let editor = window.firstResponder as? NSTextView {
            check("双击文字进入编辑并带出原文", editor.string == "旧文字", editor.string)
            editor.selectAll(nil)
            editor.insertText("新文字", replacementRange: editor.selectedRange())
            await key(window, code: 36, chars: "\r")
        } else {
            check("双击文字进入编辑", false)
        }
        if case let .text(string, _, _, _) = view.annotations.last {
            check("文字改为「新文字」且数量不变", string == "新文字" && view.annotations.count == count, "\(string) count=\(view.annotations.count)")
        } else {
            check("重编辑后文字仍在", false)
        }
        await key(window, code: 6, chars: "z", flags: .command)
        if case let .text(string, _, _, _) = view.annotations.last {
            check("⌘Z 撤销重编辑回到「旧文字」", string == "旧文字", string)
        } else {
            check("⌘Z 撤销重编辑", false)
        }
        // A 1pt jitter with a tool must not leave an invisible mark.
        await clickToolbarButton(window, view, tooltip: "矩形")
        let before = view.annotations.count
        await drag(window, from: CGPoint(x: 600, y: 450), to: CGPoint(x: 601, y: 451), steps: 2)
        check("手抖 1pt 不产生标注", view.annotations.count == before, "count=\(view.annotations.count)")

        // Dragging a mark far outside stops with its center on the selection edge.
        await drag(window, from: CGPoint(x: resized.minX, y: resized.minY + 15), to: CGPoint(x: 1500, y: resized.minY + 15), steps: 6)
        let sel = view.selection!
        check("标注拖不出选区", abs(view.annotations[0].bounds.midX - sel.maxX) < 0.5, "\(view.annotations[0].bounds) sel=\(sel)")
        await clickToolbarButton(window, view, tooltip: "矩形")

        await pause()
        await snapshot("06-marks-edited")

        await key(window, code: 53, chars: "\u{1b}")
        await key(window, code: 53, chars: "\u{1b}")
        await pause()
        check("再按 Esc 退出", app.session == nil)
    }

    /// Scrolls a test window with a sticky header and footer under a long capture, including one jump
    /// that loses the overlap, and expects the copied image to be exactly header + document + footer.
    private func caseLongCapture() async {
        log("== 长截图 ==")
        let doc = CGSize(width: 500, height: 3000), visible: CGFloat = 500, bar: CGFloat = 50
        let screenFrame = NSScreen.main!.frame
        let content = CGRect(x: 300, y: 150, width: doc.width, height: visible + 2 * bar) // top-left view coords
        let window = NSWindow(contentRect: CGRect(x: screenFrame.minX + content.minX, y: screenFrame.maxY - content.maxY,
                                                  width: content.width, height: content.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(origin: .zero, size: content.size))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: bar, width: doc.width, height: visible))
        scroll.hasVerticalScroller = false
        scroll.documentView = TestDocumentView(frame: CGRect(origin: .zero, size: doc))
        root.addSubview(scroll)
        root.addSubview(TestBarView(frame: CGRect(x: 0, y: bar + visible, width: doc.width, height: bar), title: "吸顶栏 Header", color: .systemBlue))
        root.addSubview(TestBarView(frame: CGRect(x: 0, y: 0, width: doc.width, height: bar), title: "底栏 Footer", color: .systemGreen))
        // A floating "scroll to latest" button over the scrolling content, with a soft shadow, as in chat apps.
        let floating = CGRect(x: 420, y: bar + 16, width: 48, height: 48) // AppKit coords in the window
        root.addSubview(TestFloatingButton(frame: floating))
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func scrollTo(_ y: CGFloat) async {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(0.35)
        }
        await scrollTo(0)

        guard let (overlay, view) = await beginCapture() else { return }
        await drag(overlay, from: content.origin, to: CGPoint(x: content.maxX, y: content.maxY))
        check("长截图选区", view.selection == content, "\(String(describing: view.selection))")
        await clickToolbarButton(overlay, view, tooltip: "长截图")
        await pause(0.8)
        guard let long = app.session?.longCapture else { check("进入长截图", false); return }
        check("进入长截图：覆盖窗不拦鼠标", overlay.ignoresMouseEvents && view.isLongCapture)
        check("HUD 出现", long.hudWindow.isVisible)
        let scale = overlay.backingScaleFactor
        check("首帧 \(Int(content.height * scale)) px", long.stitchedHeight == Int(content.height * scale), "\(long.stitchedHeight)")

        let firstPreview = long.previewWindow.frame.height
        for y in stride(from: 120, through: 600, by: 120) { await scrollTo(CGFloat(y)) }
        check("预览框随长度变高", long.previewWindow.isVisible && long.previewWindow.frame.height > firstPreview + 50,
              "\(firstPreview) → \(long.previewWindow.frame.height)")
        let before = long.stitchedHeight
        await scrollTo(1300) // more than a screenful at once
        await pause(0.3)
        check("滚太快提示回滑", long.status.contains("回滑") && long.stitchedHeight == before, "\(long.status) \(long.stitchedHeight)")
        await scrollTo(900)
        await pause(0.3)
        check("回滑后恢复拼接", long.status.contains("拼接中") && long.stitchedHeight > before, "\(long.status)")
        let beforeUp = long.stitchedHeight
        await scrollTo(780) // a little up, over rows already captured
        await scrollTo(900)
        check("往上滑一点再往下：高度不变、仍在拼接", long.stitchedHeight == beforeUp && long.status.contains("拼接中"),
              "\(long.stitchedHeight) vs \(beforeUp) \(long.status)")
        // The rest in a smooth scroll, 8 pt every 16 ms as a trackpad does: frames must keep up.
        let framesBefore = long.frameCount, start = Date()
        var y: CGFloat = 900
        while y < doc.height - visible {
            y = min(y + 8, doc.height - visible)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(0.016)
        }
        let fps = Double(long.frameCount - framesBefore) / Date().timeIntervalSince(start)
        check(String(format: "连续滚动帧率 %.1f fps（≥ 20）", fps), fps >= 20)
        await pause(0.4)
        await snapshot("07-long-capture")
        check("预览框高度封顶 \(Int(min(content.height, 480))) pt", long.previewWindow.frame.height == min(content.height, 480),
              "\(long.previewWindow.frame.height)")

        ImageOutput.pasteboard.clearContents()
        await key(overlay, code: 36, chars: "\r")
        await pause()
        check("↩ 后长截图结束", app.session == nil && !long.hudWindow.isVisible)
        let expected = CGSize(width: doc.width * scale, height: (doc.height + 2 * bar) * scale)
        if let data = ImageOutput.pasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: data) {
            check("长图尺寸 \(Int(expected.width))×\(Int(expected.height))（顶栏 + 全文 + 底栏）",
                  CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) == expected, "\(rep.pixelsWide)×\(rep.pixelsHigh)")
            try? data.write(to: dir.appendingPathComponent("08-long-capture.png"))
            // The floating button must appear once, at the end: count magenta runs down a column left of its arrow.
            let x = Int(((floating.minX + 10) * scale).rounded())
            var runs = 0, inRun = false
            for y in 0..<rep.pixelsHigh {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let magenta = (c?.redComponent ?? 0) > 0.8 && (c?.greenComponent ?? 1) < 0.35 && (c?.blueComponent ?? 0) > 0.8
                if magenta && !inRun { runs += 1 }
                inRun = magenta
            }
            check("悬浮按钮只出现一次", runs == 1, "\(runs) 处")
        } else {
            check("剪贴板有长图", false)
        }
    }

    private func caseSave() async {
        log("== ⌘S 保存 ==")
        guard let (window, _) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 500, y: 400))
        let started = Date()
        await key(window, code: 1, chars: "s", flags: .command)
        await pause()
        check("⌘S 后覆盖窗关闭", app.session == nil)
        let folder = Settings.saveFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let saved = files.first {
            $0.lastPathComponent.hasPrefix("截图 ") && $0.pathExtension == "png" &&
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >= started.addingTimeInterval(-1)
        }
        check("保存位置生成 截图 *.png", saved != nil, saved?.lastPathComponent ?? "none")
        if let saved {
            // Move the test output out of the user's save folder.
            // A file left by an earlier run into the same directory would make the move fail.
            let target = dir.appendingPathComponent("05-saved.png")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: saved, to: target)
        }
    }

    private func casePin() async {
        log("== 钉图 ==")
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 600, y: 450))
        await clickToolbarButton(window, view, tooltip: "钉在桌面")
        await pause()
        check("钉图后覆盖窗关闭", app.session == nil)
        guard let pin = PinWindowController.open.last else { check("钉图窗口存在", false); return }
        let pinWindow = pin.window
        check("钉图窗口可见且置顶", pinWindow.isVisible && pinWindow.level == .floating)
        check("钉图尺寸 300×200", pinWindow.frame.size == CGSize(width: 300, height: 200), "\(pinWindow.frame.size)")
        await snapshot("06-pinned")

        pin.zoom(by: 0.5)
        check("缩放到 450×300", pinWindow.frame.size == CGSize(width: 450, height: 300), "\(pinWindow.frame.size)")
        pin.adjustOpacity(by: -0.5)
        check("透明度 0.5", abs(pinWindow.alphaValue - 0.5) < 0.01, "\(pinWindow.alphaValue)")
        await pause()
        await snapshot("07-pinned-zoomed")

        let center = CGPoint(x: pinWindow.frame.width / 2, y: pinWindow.frame.height / 2)
        // A single click starts a window drag (nested loop); send only the double-click's second press.
        pinWindow.sendEvent(mouseEvent(.leftMouseDown, pinWindow, windowPoint: center, clickCount: 2))
        await pause()
        check("双击关闭钉图", !pinWindow.isVisible && PinWindowController.open.isEmpty)
    }

    private func caseSnapAndLoupe() async {
        log("== 窗口吸附 / 放大镜 ==")
        guard let (window, view) = await beginCapture() else { return }
        guard let (p, expected) = pointInsideWindow(view) else { check("屏幕上找到可吸附的窗口", false); return }
        await move(window, to: p)
        check("悬停高亮光标下的窗口", view.hoverRect == expected, "\(String(describing: view.hoverRect)) vs \(expected)")
        await snapshot("08-hover-loupe")

        let menuBarPoint = CGPoint(x: view.bounds.midX, y: 4)
        if view.windowFrameAt?(menuBarPoint) == nil {
            await move(window, to: menuBarPoint)
            check("无窗口处回退为整屏", view.hoverRect == view.bounds, "\(String(describing: view.hoverRect))")
            await move(window, to: p)
        }

        await click(window, at: p)
        check("单击吸附选中窗口", view.selection == expected, "\(String(describing: view.selection))")
        check("吸附后出现工具栏", !view.toolbar.isHidden)
        await snapshot("09-snapped")

        await rightClick(window, at: p)
        check("右键清除选区", view.selection == nil)
        await drag(window, from: p, to: CGPoint(x: p.x + 2, y: p.y + 2), steps: 2)
        check("点击时轻微抖动仍按窗口吸附", view.selection == expected, "\(String(describing: view.selection))")

        await rightClick(window, at: p)
        await drag(window, from: p, to: CGPoint(x: p.x + 120, y: p.y + 80))
        check("拖拽取消吸附改为手动框选", view.selection == CGRect(x: p.x, y: p.y, width: 120, height: 80),
              "\(String(describing: view.selection))")
        await key(window, code: 53, chars: "\u{1b}")

        // Return while a window is highlighted copies that window without clicking it first.
        guard let (window2, view2) = await beginCapture() else { return }
        await move(window2, to: p)
        let pixelScale = CGFloat(view2.frozen.width) / view2.bounds.width
        let expectedPixels = CGSize(width: (expected.width * pixelScale).rounded(), height: (expected.height * pixelScale).rounded())
        ImageOutput.pasteboard.clearContents()
        await key(window2, code: 36, chars: "\r")
        await pause()
        let rep = ImageOutput.pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
        check("高亮窗口时直接按 ↩：覆盖窗关闭，复制的就是这个窗口",
              app.session == nil && rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } == expectedPixels,
              "\(rep.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "无 PNG") vs \(Int(expectedPixels.width))×\(Int(expectedPixels.height))")
    }

    private func caseCopyColor() async {
        log("== 按 C 复制色值 ==")
        guard let (window, view) = await beginCapture() else { return }
        let p = CGPoint(x: view.bounds.midX + 37, y: view.bounds.midY + 23)
        await move(window, to: p)
        let scale = CGFloat(view.frozen.width) / view.bounds.width
        let expected = view.frozen.srgbPixel(x: Int(p.x * scale), y: Int(p.y * scale))
            .map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) }
        ImageOutput.pasteboard.clearContents()
        await key(window, code: 8, chars: "c")
        let copied = ImageOutput.pasteboard.string(forType: .string)
        check("剪贴板是光标处像素色值", copied != nil && copied == expected, "\(copied ?? "nil") vs \(expected ?? "nil")")
        check("复制色值后退出截图", app.session == nil)
    }

    /// First point on a coarse grid that lies inside a snappable window, with that window's frame.
    private func pointInsideWindow(_ view: OverlayView) -> (CGPoint, CGRect)? {
        for y in stride(from: 120.0, to: view.bounds.height - 120, by: 90) {
            for x in stride(from: 120.0, to: view.bounds.width - 120, by: 90) {
                let p = CGPoint(x: x, y: y)
                if let frame = view.windowFrameAt?(p), frame.width > 200, frame.height > 150 { return (p, frame) }
            }
        }
        return nil
    }

    /// While capturing, 1–9 press the toolbar's buttons from the left: the seven tools, then undo and redo.
    private func caseNumberKeys() async {
        log("== 数字键选工具 ==")
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 700, y: 600))
        let buttons = view.toolbar.buttons
        func on() -> [Int] { buttons.prefix(7).enumerated().filter { $0.element.state == .on }.map { $0.offset + 1 } }
        func digit(_ n: Int) async { await key(window, code: [18, 19, 20, 21, 23, 22, 26, 28, 25][n - 1], chars: "\(n)") }
        await digit(1)
        check("按 1 选中第一个工具（矩形）", on() == [1], "\(on())")
        await digit(3)
        check("按 3 换成第三个工具（箭头）", on() == [3], "\(on())")
        await digit(3)
        check("再按 3 取消工具", on().isEmpty, "\(on())")
        await digit(1)
        await drag(window, from: CGPoint(x: 350, y: 350), to: CGPoint(x: 450, y: 420))
        let drawn = buttons[7].isEnabled
        await digit(8)
        let undone = !buttons[7].isEnabled && buttons[8].isEnabled
        await digit(9)
        check("画一个矩形后按 8 撤销、按 9 重做", drawn && undone && buttons[7].isEnabled && !buttons[8].isEnabled)
        let tips = buttons.prefix(9).enumerated().allSatisfy { $0.element.toolTip?.hasSuffix("·  \($0.offset + 1)") == true }
        check("前 9 个按钮的提示里有编号", tips, buttons.prefix(9).map { $0.toolTip ?? "" }.joined(separator: " | "))
        await key(window, code: 53, chars: "\u{1b}")
        await key(window, code: 53, chars: "\u{1b}")
        await pause()
        check("数字键用例结束后覆盖窗关闭", app.session == nil)
    }

    /// The style bar under the toolbar sets colour and size for new marks and restyles the selected one;
    /// Shift draws squares and 45° arrows.
    private func caseMarkStyle() async {
        log("== 标注颜色 / 粗细 / Shift 约束 ==")
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 800, y: 600))
        check("没选工具时不显示样式条", view.styleBar.isHidden)
        await clickToolbarButton(window, view, tooltip: "矩形")
        check("选了矩形后出现样式条", !view.styleBar.isHidden)
        let blue = StyleBarView.colors[4].color
        await clickButton(window, view.styleBar.colorButtons[4], "蓝色")
        await drag(window, from: CGPoint(x: 240, y: 240), to: CGPoint(x: 340, y: 300), steps: 6)
        if case let .rectangle(_, c, w)? = view.annotations.last {
            check("新矩形用选的蓝色、中等粗细", c == blue && w == MarkStyle.shapeWidths[1], "\(c) \(w)")
        } else {
            check("画出矩形", false)
        }
        await clickButton(window, view.styleBar.sizeButtons[2], "粗")
        if case let .rectangle(_, _, w)? = view.annotations.last {
            check("选中的矩形改成粗线", w == MarkStyle.shapeWidths[2], "\(w)")
        }
        let bar = view.styleBar
        check("选中的颜色和粗细都只用底块标出，粗细按钮不着色",
              bar.colorButtons.map(StyleBarView.isMarked) == (0..<8).map { $0 == 4 }
              && bar.sizeButtons.map(StyleBarView.isMarked) == [false, false, true]
              && bar.sizeButtons.allSatisfy { $0.contentTintColor == nil })
        await key(window, code: 6, chars: "z", flags: .command)
        if case let .rectangle(_, _, w)? = view.annotations.last {
            check("⌘Z 撤销改粗细", w == MarkStyle.shapeWidths[1] && view.annotations.count == 1, "\(w)")
        }

        // Shift: a square, whichever way the pointer goes.
        await drag(window, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 520, y: 340), steps: 6, flags: .shift)
        let square = view.annotations.last?.bounds ?? .null
        check("按住 Shift 画出正方形", view.annotations.count == 2 && square.width == 120 && square.height == 120, "\(square)")
        await clickToolbarButton(window, view, tooltip: "箭头")
        await drag(window, from: CGPoint(x: 300, y: 500), to: CGPoint(x: 420, y: 470), steps: 6, flags: .shift)
        if case let .arrow(a, b, _, _)? = view.annotations.last {
            check("按住 Shift 箭头吸附到水平", abs(b.y - a.y) < 0.5 && b.x > a.x, "\(a) → \(b)")
        } else {
            check("画出箭头", false)
        }

        // The highlighter keeps a colour of its own, drawn translucent.
        await clickToolbarButton(window, view, tooltip: "荧光笔")
        await clickButton(window, view.styleBar.colorButtons[3], "绿色")
        await drag(window, from: CGPoint(x: 250, y: 550), to: CGPoint(x: 450, y: 550), steps: 6)
        if case let .pen(_, c, _)? = view.annotations.last, let got = c.usingColorSpace(.sRGB),
           let green = StyleBarView.colors[3].color.usingColorSpace(.sRGB) {
            let same = abs(got.redComponent - green.redComponent) + abs(got.greenComponent - green.greenComponent)
                + abs(got.blueComponent - green.blueComponent) < 0.01
            check("荧光笔用绿色半透明，其他工具仍是蓝色", same && got.alphaComponent < 1 && MarkStyle.colorIndex == 4, "\(c)")
        } else {
            check("画出荧光笔", false)
        }
        await clickToolbarButton(window, view, tooltip: "马赛克")
        check("马赛克不显示样式条", view.styleBar.isHidden)
        await key(window, code: 53, chars: "\u{1b}")
        await key(window, code: 53, chars: "\u{1b}")
        await pause()
        check("样式用例结束后覆盖窗关闭", app.session == nil)
    }

    /// The toolbar stays put when the style bar appears, and the style bar sits right against it,
    /// left edges aligned, for selections in the middle, at the bottom and right edges, and full screen.
    private func caseToolbarPlacement() async {
        log("== 工具栏 / 样式条位置 ==")
        guard let (window, view) = await beginCapture() else { return }
        let w = view.bounds.width, h = view.bounds.height
        let cases: [(String, CGPoint, CGPoint, OverlayView.ToolbarPlacement)] = [
            ("屏幕中间", CGPoint(x: 200, y: 200), CGPoint(x: 800, y: 500), .below),
            ("贴底边", CGPoint(x: 200, y: h - 300), CGPoint(x: 800, y: h - 10), .above),
            ("贴右边", CGPoint(x: w - 300, y: 200), CGPoint(x: w - 2, y: 400), .below),
            ("贴右下角", CGPoint(x: w - 260, y: h - 200), CGPoint(x: w - 1, y: h - 1), .above),
            ("全屏", CGPoint(x: 0, y: 0), CGPoint(x: w, y: h), .inside),
        ]
        let screen = view.bounds.insetBy(dx: 3.5, dy: 3.5)
        for (i, (name, from, to, expected)) in cases.enumerated() {
            // Right click drops the previous selection (with none it would end the capture).
            if i > 0 { await rightClick(window, at: CGPoint(x: w / 2, y: h / 2)) }
            await drag(window, from: from, to: to)
            guard let sel = view.selection else { check("\(name)：框选", false); continue }
            let before = view.toolbar.frame
            await key(window, code: 18, chars: "1") // rectangle tool: the style bar appears
            let tb = view.toolbar.frame, bar = view.styleBar.frame
            let adjacent = abs(bar.minY - (tb.maxY + 6)) < 0.5 || abs(bar.maxY - (tb.minY - 6)) < 0.5
            // Away from the selection when there is room: below a toolbar under it, above one over or inside it.
            let outward = expected == .below ? bar.minY > tb.maxY : bar.maxY < tb.minY
            check("\(name)：工具栏\(["below": "在选区下方", "above": "在选区上方", "inside": "在选区内底部"]["\(expected)"]!)，出现样式条时不移动",
                  view.toolbarPlacement == expected && tb == before, "\(view.toolbarPlacement) \(before) → \(tb) sel \(sel)")
            check("\(name)：样式条紧贴工具栏、左边对齐、都在屏幕内", !view.styleBar.isHidden && adjacent && outward
                  && abs(bar.minX - tb.minX) < 0.5 && screen.contains(tb) && screen.contains(bar) && !bar.intersects(tb),
                  "toolbar \(tb) bar \(bar)")
            if expected != .inside {
                check("\(name)：工具栏和样式条不挡选区", !tb.intersects(sel) && !bar.intersects(sel), "sel \(sel) toolbar \(tb) bar \(bar)")
            }
            await key(window, code: 18, chars: "1") // tool off again
            check("\(name)：取消工具后样式条收起、工具栏不动", view.styleBar.isHidden && view.toolbar.frame == before)
        }
        await key(window, code: 53, chars: "\u{1b}")
        await pause()
        check("位置用例结束后覆盖窗关闭", app.session == nil)
    }

    private static let ocrSample = "Screenshot 识别测试 2026"

    /// Line merging rules, Vision on a rendered image, then the toolbar button through to copying the text.
    private func caseTextRecognition() async {
        log("== 识别文字（OCR） ==")
        func line(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> RecognizedLine {
            RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: 20))
        }
        let wrapped = [line("This is a long line that", 0, 0, 400), line("wraps here.", 0, 24, 150),
                       line("新段落的第一行", 0, 70, 400), line("接着写完。", 0, 94, 100)]
        check("合并换行：折行接回一段，空行处分段，中文不加空格",
              TextRecognizer.mergingLines(wrapped) == "This is a long line that wraps here.\n新段落的第一行接着写完。",
              TextRecognizer.mergingLines(wrapped))
        check("保留换行：一行一行原样输出", TextRecognizer.keepingLines(wrapped) == wrapped.map(\.text).joined(separator: "\n"))
        let columns = TextRecognizer.readingOrder([line("右栏", 300, 2, 80), line("左栏", 0, 0, 80), line("下一行", 0, 30, 80)])
        check("同一行的两栏先左后右，用 Tab 隔开", TextRecognizer.keepingLines(columns) == "左栏\t右栏\n下一行",
              TextRecognizer.keepingLines(columns))

        // Vision on text drawn at 2×, English and Chinese.
        let ctx = CGContext(data: nil, width: 1200, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 260))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("Hello OCR 12345" as NSString).draw(at: CGPoint(x: 40, y: 150), withAttributes: attrs)
        ("截图里的中文也能识别" as NSString).draw(at: CGPoint(x: 40, y: 50), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let started = Date()
        let found = (try? await TextRecognizer.recognize(ctx.makeImage()!)) ?? []
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log("  识别 2 行用时 \(ms) ms：\(found.map(\.text))")
        check("识别英文和数字", found.first?.text == "Hello OCR 12345", found.first?.text ?? "nil")
        // Vision now and then drops a character such as 的, so only key words are required.
        check("识别中文，且按从上到下排序", found.count == 2 && found[1].text.contains("中文也能识别"), found.map(\.text).joined(separator: " | "))

        // Screen captures carry no colour space name and a padded row stride; both are redrawn first.
        let captured = Self.textImage([(Self.ocrSample, 30)])
        let padded = Self.padded(captured, extraBytesPerRow: 12160 - captured.width * 4)
        let plain = TextRecognizer.normalized(padded)
        check("截图那种行带宽带填充的图先重画成紧凑的 sRGB 位图",
              plain.bytesPerRow == plain.width * 4 && plain.colorSpace?.name == CGColorSpace.sRGB as CFString,
              "row \(plain.bytesPerRow) of \(plain.width * 4), cs \(String(describing: plain.colorSpace?.name))")
        let rereadCaptured = ((try? await TextRecognizer.recognize(padded)) ?? []).map(\.text).joined(separator: " ")
        check("归一化后仍能识别出文字", rereadCaptured.contains("Screenshot"), rereadCaptured)

        // A 1 × 1 selection (a stray click) used to end in a raw Vision NSError.
        let tiny = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        var tinyFailure = ""
        do { _ = try await TextRecognizer.recognize(tiny) } catch { tinyFailure = error.localizedDescription }
        check("1×1 的选区给出中文提示，不是系统 NSError",
              tinyFailure.contains("选区太小") && !tinyFailure.contains("CRImageReader"), tinyFailure)

        // The Vision engine can wedge inside a process for good (E5RT code 13, surfacing as
        // CRImageReaderError 1); that cannot be provoked on demand, so the in-process attempts are
        // skipped instead to exercise the path that matters: a separate worker process takes over.
        let sample = Self.textImage([(Self.ocrSample, 30)])
        TextRecognizer.pretendEngineIsWedged = true
        defer { TextRecognizer.pretendEngineIsWedged = false }
        let startedWorker = Date()
        let fromWorker = (try? await TextRecognizer.recognize(sample)) ?? []
        let workerMS = Int(Date().timeIntervalSince(startedWorker) * 1000)
        log("  识别进程接管：\(workerMS) ms，\(fromWorker.map(\.text))")
        check("进程内引擎卡住时由识别进程接手，照样识别出文字",
              fromWorker.map(\.text).joined().contains("Screenshot"), fromWorker.map(\.text).joined(separator: " | "))
        // Boxes travel through the pipe, so they must come back in image pixels like the in-process ones.
        check("识别进程返回的文字位置以图片像素为单位",
              fromWorker.first.map { $0.box.width > 100 && $0.box.minY >= 0 && $0.box.maxY <= CGFloat(sample.height) } == true,
              String(describing: fromWorker.first?.box))
        let second = (try? await TextRecognizer.recognize(sample)) ?? []
        check("识别进程被复用，第二次也能识别", !second.isEmpty, "\(second.count) 行")

        // A wedged or killed worker must be replaced rather than poisoning every later recognition.
        if let pid = TextRecognizer.workerPID {
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let afterKill = (try? await TextRecognizer.recognize(sample)) ?? []
            check("识别进程被杀掉后自动换一个新的，仍能识别", !afterKill.isEmpty, "\(afterKill.count) 行")
            check("换过之后是新的进程号", TextRecognizer.workerPID != nil && TextRecognizer.workerPID != pid,
                  "旧 \(pid) 新 \(String(describing: TextRecognizer.workerPID))")
        } else {
            check("能拿到识别进程的进程号", false)
        }

        // The toolbar button: the capture closes and the result comes up with the selection's text.
        var result: TextRecognitionController?
        TextRecognitionController.testPresenter = { result = $0 }
        defer { TextRecognitionController.testPresenter = nil }
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 900, y: 300))
        await clickToolbarButton(window, view, tooltip: "识别文字")
        check("点「识别文字」后截图界面关闭", app.session == nil)
        for _ in 0..<200 where result?.lines == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let result, result.lines != nil else { check("拿到识别结果", false); return }
        // Vision drops the space between Chinese and digits, so spaces are not compared.
        let squeezed = { (s: String) in s.filter { !$0.isWhitespace } }
        check("识别出选区里的文字", squeezed(result.text) == squeezed(Self.ocrSample), result.text)
        let edited = result.text + "（改过）"
        result.textView.string = edited
        result.copyAll()
        check("复制的是窗口里改过的文字", ImageOutput.pasteboard.string(forType: .string) == edited)
        check("结果窗口没有上屏", !result.window.isVisible)
        result.close()
        check("关闭后不再保留", TextRecognitionController.open.isEmpty)
    }

    /// Language detection and the target rules, translation that keeps the layout, and the toolbar's
    /// translate button through to copying the translation. Needs the English and Chinese packs.
    private func caseTranslation() async {
        log("== 截图翻译 ==")
        let zh = ScreenTranslator.detect("这是一段中文文字"), en = ScreenTranslator.detect("This is some English text")
        check("识别原文语言", zh.languageCode == .chinese && en.languageCode == .english, "\(zh.minimalIdentifier) \(en.minimalIdentifier)")
        let mixed = ["Myuxcc识别测试2026", "点 Settings 打开设置", "Open Myuxcc"].map { ScreenTranslator.detect($0).minimalIdentifier }
        check("中英混排按汉字占比判断：以中文为主算中文", mixed == ["zh", "zh", "en"], mixed.joined(separator: " "))
        let auto1 = try? ScreenTranslator.languages(for: "这是一段中文文字", target: .auto)
        let auto2 = try? ScreenTranslator.languages(for: "This is some English text", target: .auto)
        check("自动：中文译成英文、英文译成中文", auto1?.target.languageCode == .english && auto2?.target.languageCode == .chinese)
        var same = ""
        do { _ = try ScreenTranslator.languages(for: "这是一段中文文字", target: .chinese) } catch { same = error.localizedDescription }
        check("原文已是目标语言时提示", same == "原文已经是简体中文", same)
        guard #available(macOS 26, *) else { check("系统支持翻译（macOS 26+）", false); return }
        let status = await LanguageAvailability().status(from: ScreenTranslator.english, to: ScreenTranslator.chinese)
        guard status == .installed else { check("中英翻译语言包已下载", false, "\(status)"); return }

        let source = "Copy the text\tSave the file\n\nClose the window"
        let started = Date()
        let out = (try? await ScreenTranslator.translate(source, from: ScreenTranslator.english, to: ScreenTranslator.chinese)) ?? ""
        log("  翻译 3 段用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms：\(out.debugDescription)")
        let rows = out.components(separatedBy: "\n")
        check("逐行翻译：行数、空行、Tab 分栏都保留", rows.count == 3 && rows[1].isEmpty && rows[0].components(separatedBy: "\t").count == 2, out.debugDescription)
        check("译文是中文", out.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) } && !out.contains("Copy"), out)

        // The text window in translate mode: OCR then translation of the Chinese sample into English.
        var result: TextRecognitionController?
        TextRecognitionController.testPresenter = { result = $0 }
        defer { TextRecognitionController.testPresenter = nil }
        TextRecognitionController.present(Self.textImage([(Self.ocrSample, 30)]), near: nil, translating: true)
        for _ in 0..<300 where result?.lines == nil || result?.translationRunning != false { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let result, let english = result.translation else {
            check("拿到译文", false, result?.translationFailure ?? "超时"); return
        }
        log("  原文 \(result.text.debugDescription) → 译文 \(english.debugDescription)")
        check("窗口是翻译模式，原文是图里的中文", result.window.title == "截图翻译" && result.text.contains("测试"), result.text)
        check("译成英文（中文原文自动译成英文）", english.contains("2026") && !english.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) }, english)
        result.copyAll()
        check("「复制译文」复制的是译文", ImageOutput.pasteboard.string(forType: .string) == english)

        // Editing the text and translating again uses the edited text; another target replaces the translation.
        result.textView.string = "打开设置窗口"
        result.translateNow()
        for _ in 0..<200 where result.translationRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("改过原文再点「翻译」，按改过的翻", (result.translation ?? "").lowercased().contains("setting"), result.translation ?? result.translationFailure ?? "nil")
        result.targetPopup.selectItem(at: ScreenTranslator.Target.chinese.rawValue)
        result.targetPopup.sendAction(result.targetPopup.action, to: result.targetPopup.target)
        for _ in 0..<200 where result.translationRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("选「译成简体中文」后提示原文已是中文", result.translation == nil && result.translationFailure == "原文已经是简体中文",
              result.translationFailure ?? "nil")
        check("结果窗口没有上屏", !result.window.isVisible)
        result.window.makeFirstResponder(result.textView)
        result.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        result.window.sendEvent(keyEvent(code: 53, chars: "\u{1B}"))
        check("输入法正在拼字时 Esc 只取消拼字，不关窗口", TextRecognitionController.open.contains { $0 === result })
        result.textView.unmarkText()
        result.window.sendEvent(keyEvent(code: 53, chars: "\u{1B}"))
        check("按 Esc 关闭翻译窗口", TextRecognitionController.open.isEmpty, "\(TextRecognitionController.open.count) 个还开着")
    }

    /// Lines grouped into paragraphs, the translation drawn over the text in the text's colours, and the
    /// toolbar's translate button through a pin that switches between translation and original.
    private func caseImageTranslation() async {
        log("== 截图上覆盖译文 ==")
        func line(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 20) -> RecognizedLine {
            RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h))
        }
        let grouped = ImageTranslator.blocks([line("This is a long line that", 0, 0, 400), line("wraps here.", 0, 24, 150),
                                              line("Title", 0, 70, 100, 40), line("右边的按钮", 600, 72, 100),
                                              line("Another paragraph", 0, 130, 300)])
        check("分段：折行合成一段，字号不同、离得远、另一栏的各自成段", grouped.map(\.text) == ["This is a long line that wraps here.", "Title", "右边的按钮", "Another paragraph"],
              grouped.map(\.text).joined(separator: " | "))

        // English on a dark background with light text, into Chinese.
        let dark = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 1), ink = NSColor(srgbRed: 0.95, green: 0.85, blue: 0.4, alpha: 1)
        let english = Self.textImage([("Open the settings window and choose", 26), ("a folder for your screenshots.", 26), ("", 14), ("Copy the result", 34)],
                                     background: dark, ink: ink)
        let started = Date()
        guard let (zh, pair) = try? await ImageTranslator.translate(english, target: .auto) else { check("英文截图译成中文", false); return }
        log("  覆盖翻译用时 \(Int(Date().timeIntervalSince(started) * 1000)) ms，\(pair)")
        writePNG(english, "30-translate-en-before")
        writePNG(zh, "31-translate-en-after")
        let reread = ((try? await TextRecognizer.recognize(zh)) ?? []).map(\.text).joined(separator: " ")
        log("  再识别译图：\(reread)")
        check("译图上是中文，原来的英文盖掉了", reread.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) } && !reread.contains("settings") && !reread.contains("Copy"), reread)
        check("盖字的底色取自原背景", Self.pixel(zh, 4, 4).map { Self.close($0, dark) } == true && Self.pixel(zh, zh.width / 3, 40).map { Self.close($0, dark) } == true,
              "\(String(describing: Self.pixel(zh, zh.width / 3, 40)))")
        check("译文用原来的字色", Self.countPixels(zh) { Self.close($0, ink, tolerance: 0.12) } > 200)

        // The toolbar button: the pin shows the translated selection and T switches back.
        var pin: PinWindowController?
        PinWindowController.testPresenter = { pin = $0 }
        defer { PinWindowController.testPresenter = nil }
        guard let (window, view) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 900, y: 300))
        await clickToolbarButton(window, view, tooltip: "截图翻译")
        check("点「截图翻译」后截图界面关闭、出现钉图", app.session == nil && pin != nil)
        for _ in 0..<300 where pin?.translationRunning != false { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let pin, let translated = pin.translated else { check("钉图拿到译图", false, pin?.translationFailure ?? "超时"); return }
        writePNG(translated, "32-translate-pin")
        let text = ((try? await TextRecognizer.recognize(translated)) ?? []).map(\.text).joined(separator: " ")
        log("  钉图译图识别：\(text)")
        check("钉图显示译图：中文样例变成英文", pin.showingTranslation && text.contains("2026") && !text.contains("测试"), text)
        // The status line ("英语 → 简体中文 · 0.2 秒 · T 切换原文") used to be drawn inside the image and
        // covered the translation it was reporting.
        let status = pin.statusFrame
        log("  钉图 \(pin.window.frame)，状态条 \(String(describing: status))，文字 \(pin.statusText ?? "nil")")
        check("语言和用时的提示在图片外面，不压住译文",
              status.map { !$0.intersects(pin.window.frame) } == true && (pin.statusText ?? "").contains("→"),
              "\(String(describing: status)) vs image \(pin.window.frame)")
        // Zooming and moving the pin keep the status line outside it.
        pin.zoom(by: 0.5)
        let zoomed = pin.statusFrame
        check("缩放后提示仍在图片外面",
              zoomed.map { !$0.intersects(pin.window.frame) } == true, "\(String(describing: zoomed)) vs \(pin.window.frame)")
        pin.resetZoom()
        pin.copyImage()
        check("复制的是译图", ImageOutput.pasteboard.data(forType: .png) != nil || ImageOutput.pasteboard.data(forType: .tiff) != nil)
        pin.translate()
        check("再按一次（T）显示原图", !pin.showingTranslation && pin.image === pin.original)
        pin.translate()
        check("再按回到译图", pin.showingTranslation && pin.image === translated)
        check("钉图没有上屏", !pin.window.isVisible)
        check("钉图的图片视图接收键盘", pin.window.firstResponder is PinImageView, "\(String(describing: pin.window.firstResponder))")
        pin.window.sendEvent(keyEvent(code: 53, chars: "\u{1B}"))
        check("在钉图上按 Esc 关闭", !PinWindowController.open.contains { $0 === pin })
        if PinWindowController.open.contains(where: { $0 === pin }) { pin.close() }
    }

    /// Lines of text drawn on a plain background at 2×, `size` in points.
    private static func textImage(_ lines: [(String, CGFloat)], background: NSColor = .white, ink: NSColor = .black) -> CGImage {
        let width = 1300, height = lines.reduce(40) { $0 + Int($1.1 * 3.2) }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var y = CGFloat(height) - 20
        for (text, size) in lines {
            y -= size * 3.2
            (text as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size * 2), .foregroundColor: ink])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// The image rebuilt with a wider row stride and no colour space name, like a ScreenCaptureKit
    /// capture; `extraBytesPerRow` is how much padding to add.
    private static func padded(_ image: CGImage, extraBytesPerRow: Int) -> CGImage {
        let row = image.width * 4 + extraBytesPerRow
        var bytes = [UInt8](repeating: 0, count: row * image.height)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        // No colour space: what `SCScreenshotManager.captureImage` hands back.
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buf
    }

    /// The colour at (x, y), y from the top.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor? {
        guard x < image.width, y < image.height else { return nil }
        let b = rgba(image), i = (y * image.width + x) * 4
        return NSColor(srgbRed: CGFloat(b[i]) / 255, green: CGFloat(b[i + 1]) / 255, blue: CGFloat(b[i + 2]) / 255, alpha: 1)
    }

    private static func countPixels(_ image: CGImage, _ test: (NSColor) -> Bool) -> Int {
        let b = rgba(image)
        return stride(from: 0, to: b.count, by: 4).filter {
            test(NSColor(srgbRed: CGFloat(b[$0]) / 255, green: CGFloat(b[$0 + 1]) / 255, blue: CGFloat(b[$0 + 2]) / 255, alpha: 1))
        }.count
    }

    private static func close(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.06) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// The file shelf in the output folder: adding and rotating files, drops from a private pasteboard,
    /// the shake gesture, and screenshots sent from the toolbar and a pin. Nothing comes on screen.
    private func caseShelf() async {
        log("== 剪贴中转板 ==")
        let folder = dir.appendingPathComponent("shelf", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let storage = ShelfStorage(folder: folder, discard: { try FileManager.default.removeItem(at: $0) }, limit: 5)
        let previous = ShelfStorage.shared
        ShelfStorage.shared = storage
        ShelfPanel.silent = true
        defer { ShelfStorage.shared = previous; ShelfPanel.silent = false }
        func add(_ sources: [ShelfImport]) async -> [URL] {
            await withCheckedContinuation { c in storage.importItems(sources) { c.resume(returning: $0) } }
        }

        let source = dir.appendingPathComponent("shelf-source", isDirectory: true)
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var names: [String] = []
        for i in 1...7 {
            let url = source.appendingPathComponent("文件\(i).txt")
            try? "内容 \(i)".write(to: url, atomically: true, encoding: .utf8)
            names.append(url.lastPathComponent)
            _ = await add([.file(url, move: false)])
        }
        check("放进 7 个、最多留 5 个：最早的两个被移走，新的在最前", storage.items.map(\.name) == names.suffix(5).reversed(),
              storage.items.map(\.name).joined(separator: " "))
        check("复制进来，原文件还在", FileManager.default.fileExists(atPath: source.appendingPathComponent("文件1.txt").path))
        let again = await add([.file(source.appendingPathComponent("文件7.txt"), move: false)])
        check("同名文件自动改名", again.first?.lastPathComponent == "文件7 1.txt", again.first?.lastPathComponent ?? "nil")

        // Drops, read from a private pasteboard.
        let pb = NSPasteboard(name: NSPasteboard.Name("Myuxcc.e2e-shelf"))
        defer { pb.releaseGlobally() }
        func drop(_ write: (NSPasteboard) -> Void) async -> [URL]? {
            pb.clearContents()
            write(pb)
            return await withCheckedContinuation { c in
                if !ShelfDrop.receive(pb, into: storage, completion: { c.resume(returning: $0) }) { c.resume(returning: nil) }
            }
        }
        let png = ImageOutput.pngData(Self.textImage([("拖进来的图", 20)]))!
        let droppedImage = await drop { $0.setData(png, forType: .png) }
        check("拖进图片数据存成 PNG", droppedImage?.first.map { $0.lastPathComponent.hasPrefix("图片 ") && $0.pathExtension == "png" } == true)
        let droppedLink = await drop { $0.writeObjects([URL(string: "https://example.com/docs/page")! as NSURL]) }
        check("拖进网页链接存成 .webloc", droppedLink?.first?.lastPathComponent == "example.com - page.webloc", droppedLink?.first?.lastPathComponent ?? "nil")
        let droppedText = await drop { $0.setString("只是文字", forType: .string) }
        check("纯文字不收", droppedText == nil)
        // 验证从中转板内部拖出的文件再次落回中转板时被忽略，不会自我克隆
        if let internalItem = storage.items.first {
            let selfDropped = await drop { $0.writeObjects([internalItem.url as NSURL]) }
            check("中转板内部文件拖回自身不产生克隆副本", selfDropped == nil)
        }
        // 验证文件夹递归计算真实总字节数，不再显示 0 字节
        let subFolder = source.appendingPathComponent("测试文件夹", isDirectory: true)
        try? FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 2048).write(to: subFolder.appendingPathComponent("inner.bin"))
        _ = await add([.file(subFolder, move: false)])
        check("拖入文件夹递归统计真实大小（非 0 KB）", (storage.items.first?.fileSize ?? 0) >= 2048, "\(storage.items.first?.fileSize ?? -1)")

        // The shake gesture: fast swings while dragging content count, slow ones or a plain drag don't.
        let shake = ShakeDetector()
        // Each try starts well after the previous one, past the pause that follows a shake.
        var clock = Date().timeIntervalSinceReferenceDate
        func swings(interval: TimeInterval, contentDrag: Bool) -> Bool {
            shake.reset()
            clock += 10
            var t = clock
            var hit = false
            for i in 0..<10 { hit = shake.track(x: i % 2 == 0 ? 500 : 560, at: t, contentDrag: contentDrag) || hit; t += interval }
            return hit
        }
        check("拖着文件快速左右晃：打开", swings(interval: 0.04, contentDrag: true))
        check("没拖文件时晃：不算", !swings(interval: 0.04, contentDrag: false))
        check("晃得太慢：不算", !swings(interval: 0.4, contentDrag: true))
        shake.allowsShakeWithoutDrag = { true }
        check("剪贴中转板开着时空手晃：关闭", swings(interval: 0.04, contentDrag: false))

        // The shelf window lists the files without coming on screen.
        let window = ShelfPanel()
        window.showNear(point: CGPoint(x: 400, y: 400))
        let rows = Self.allViews(in: window.contentView!).compactMap { $0 as? ShelfRowView }
        check("剪贴中转板列出全部文件，最新的在最上面", window.isShelfVisible && rows.count == storage.items.count && rows.first?.item.url == storage.items.first?.url,
              "\(rows.count) 行 / \(storage.items.count) 个")
        check("剪贴中转板没有上屏", !window.isVisible)
        // Pressing anywhere on a row (icon, name, empty space) must start a file drag, not move the panel.
        let movers = rows.flatMap { row -> [String] in
            [0.05, 0.3, 0.6, 0.95].compactMap { fraction in
                let point = row.convert(CGPoint(x: row.bounds.width * fraction, y: row.bounds.midY), to: window.contentView!)
                let hit = window.contentView!.hitTest(point)
                return hit == nil || hit!.mouseDownCanMoveWindow ? "\(row.item.name)@\(fraction): \(hit.map { String(describing: type(of: $0)) } ?? "nil")" : nil
            }
        }
        check("按住行的任何位置拖动不会移动面板", !rows.isEmpty && movers.isEmpty, movers.joined(separator: ", "))
        window.hideShelf()

        await caseShelfClipboard()
    }

    /// The toolbar's 录屏 button hands the selection over; the video writer and a short real recording of a
    /// region (nothing shown on screen) produce playable MP4 files of the right size and length.
    private func caseRecording() async {
        log("== 录屏 ==")
        var requested: (NSScreen, CGRect)?
        app.recordingPresenter = { requested = ($0, $1) }
        defer { app.recordingPresenter = nil }
        guard let (capture, view) = await beginCapture() else { return }
        let tips = allButtons(in: view.toolbar).compactMap(\.toolTip)
        check("工具栏去掉了「放入剪贴中转板」，有「录屏」", !tips.contains { $0.hasPrefix("放入剪贴中转板") } && tips.contains { $0.hasPrefix("录屏") },
              tips.joined(separator: " | "))
        await drag(capture, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 900, y: 300))
        let selection = view.selection
        await clickToolbarButton(capture, view, tooltip: "录屏")
        check("点「录屏」：截图界面关闭，按选区和所在屏幕开始录屏", app.session == nil && requested?.1 == selection && requested?.0 == capture.screen,
              "\(String(describing: requested?.1)) / \(String(describing: selection))")

        guard let (capture2, view2) = await beginCapture() else { return }
        await drag(capture2, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 900, y: 400))
        view2.toolbar.press(1)
        await drag(capture2, from: CGPoint(x: 220, y: 230), to: CGPoint(x: 400, y: 330))
        let record = allButtons(in: view2.toolbar).first { $0.toolTip?.hasPrefix("录屏") == true }
        check("标注后录屏按钮不可用", record?.isEnabled == false && record?.toolTip?.hasPrefix("录屏（标注后不可用）") == true)
        requested = nil
        view2.recordScreen()
        check("标注后不会开始录屏", requested == nil && app.session != nil)
        view2.cancel()

        // The writer: odd sizes rounded to even, the last frame held until the stop time.
        let url = dir.appendingPathComponent("50-writer.mp4")
        guard let writer = try? VideoFileWriter(url: url, width: 641, height: 361, framesPerSecond: 30) else {
            check("创建视频文件", false); return
        }
        var written = 0
        for i in 0..<30 {
            guard let buffer = Self.pixelBuffer(width: 641, height: 361, gray: UInt8(i * 8)) else { continue }
            while !writer.append(buffer, at: CMTime(value: CMTimeValue(i), timescale: 30)) && written < 1000 {
                written += 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let ok = await withCheckedContinuation { c in writer.finish(at: CMTime(value: 2, timescale: 1)) { c.resume(returning: $0) } }
        let info = await Self.videoInfo(url)
        check("视频写入：30 帧，尺寸取偶数 640×360，静止的结尾保留到停止时刻（2 秒）",
              ok && writer.framesWritten == 30 && info?.size == CGSize(width: 640, height: 360) && info.map { abs($0.seconds - 2) < 0.05 } == true
                && info?.frames == 30,
              "\(ok) \(writer.framesWritten) 帧 \(String(describing: info))")
        let empty = dir.appendingPathComponent("50-empty.mp4")
        let emptyWriter = try? VideoFileWriter(url: empty, width: 100, height: 100, framesPerSecond: 30)
        let emptyOK = await withCheckedContinuation { c in emptyWriter?.finish(at: nil) { c.resume(returning: $0) } ?? c.resume(returning: true) }
        check("一帧都没录到：不留文件", !emptyOK && !FileManager.default.fileExists(atPath: empty.path))
        check("录屏计时显示", RecordingController.elapsedText(65.7) == "01:05" && RecordingController.elapsedText(3725) == "1:02:05")

        // Saving: moved into the recording folder as 录屏 <time>.mp4.
        check("录屏默认存到「影片/Myuxcc 录屏」", Settings.defaultRecordingFolder.path == NSHomeDirectory() + "/Movies/Myuxcc 录屏")
        let recordings = dir.appendingPathComponent("recording-folder", isDirectory: true)
        Settings.recordingFolderOverride = recordings
        defer { Settings.recordingFolderOverride = nil }
        let temporary = dir.appendingPathComponent("50-temp.mp4")
        try? FileManager.default.copyItem(at: url, to: temporary)
        let saved = RecordingController.moveToSaveFolder(temporary)
        check("录好的视频移到录屏位置（没有就新建），名为「录屏 时间.mp4」", saved?.deletingLastPathComponent().standardizedFileURL == recordings.standardizedFileURL
              && saved?.lastPathComponent.hasPrefix("录屏 ") == true && saved?.pathExtension == "mp4" && !FileManager.default.fileExists(atPath: temporary.path),
              saved?.path ?? "nil")

        // A real recording of a small region; nothing appears on screen.
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main, let id = screen.displayID else {
            log("SKIP 没有屏幕录制权限，跳过实录"); return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { check("找到屏幕", false); return }
            let region = CGRect(x: 100, y: 100, width: 321, height: 200)
            let config = SCStreamConfiguration()
            config.sourceRect = region
            config.width = Int(region.width * screen.backingScaleFactor)
            config.height = Int(region.height * screen.backingScaleFactor)
            let live = dir.appendingPathComponent("51-region.mp4")
            let recorder = try RegionRecorder(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, to: live) { _ in }
            try await recorder.start()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let liveOK = await withCheckedContinuation { c in recorder.stop { c.resume(returning: $0) } }
            let liveInfo = await Self.videoInfo(live)
            let expected = CGSize(width: VideoFileWriter.evenSize(config.width), height: VideoFileWriter.evenSize(config.height))
            check("实录 1.2 秒选区：生成 MP4，尺寸 \(Int(expected.width))×\(Int(expected.height))，时长约 1.2 秒",
                  liveOK && liveInfo?.size == expected && liveInfo.map { $0.seconds > 1.0 && $0.seconds < 1.6 && $0.frames >= 1 } == true,
                  "\(liveOK) \(String(describing: liveInfo))")
        } catch {
            check("实录选区", false, error.localizedDescription)
        }
    }

    /// The settings window laid out off screen: every row keeps both columns, only section titles span
    /// them, and no two rows overlap.
    private func caseSettingsLayout() {
        log("== 设置窗口布局（不上屏） ==")
        let controller = SettingsWindowController()
        // Light, on white: the snapshot has no window background behind it.
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.refresh()
        guard let grid = controller.grid, let content = controller.window?.contentView else { check("设置窗口建好", false); return }
        content.setFrameSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()
        var merged: [Int] = [], missing: [Int] = []
        var frames: [(Int, CGRect)] = []
        for i in 0..<grid.numberOfRows where !grid.row(at: i).isHidden {
            let first = grid.cell(atColumnIndex: 0, rowIndex: i), second = grid.cell(atColumnIndex: 1, rowIndex: i)
            if first.row === second.row, first.contentView === second.contentView { merged.append(i) }
            for view in [first.contentView, second.contentView].compactMap({ $0 }) where view.superview != nil && view.frame.height > 0 {
                frames.append((i, view.convert(view.bounds, to: content)))
            }
            if let view = second.contentView, view !== first.contentView, view.superview == nil || view.frame.width == 0 { missing.append(i) }
        }
        let headerRows = merged.compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField }.map(\.stringValue)
        check("只有分区标题占两列：通用、保存、长截图、剪贴中转板", headerRows == ["通用", "保存", "长截图", "剪贴中转板"], headerRows.joined(separator: ","))
        check("每一行右栏的内容都在", missing.isEmpty, "\(missing)")
        let overlaps = frames.indices.flatMap { a in frames.indices.filter { $0 > a && frames[a].0 != frames[$0].0 && frames[a].1.insetBy(dx: 1, dy: 1).intersects(frames[$0].1.insetBy(dx: 1, dy: 1)) }.map { "\(frames[a].0)/\(frames[$0].0)" } }
        check("各行互不重叠", overlaps.isEmpty, overlaps.joined(separator: " "))
        let emptyRows = (0..<grid.numberOfRows).filter { i in
            !grid.row(at: i).isHidden && (grid.cell(atColumnIndex: 1, rowIndex: i).contentView as? NSTextField)?.stringValue.isEmpty == true
        }
        check("空的提示行收起，不留空白", emptyRows.isEmpty, emptyRows.map { i in
            "\(i): \((grid.cell(atColumnIndex: 0, rowIndex: max(i - 1, 0)).contentView as? NSTextField)?.stringValue ?? "?") 下面一行" }.joined(separator: ", "))
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let shot = rep.cgImage, let ctx = CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
                ctx.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
                if let flat = ctx.makeImage() { try? ImageOutput.pngData(flat)?.write(to: dir.appendingPathComponent("60-settings.png")) }
            }
        }
    }

    private func caseMenuBarIcon() {
        log("== 菜单栏图标 ==")
        let image = MenuBarIcon.image()
        check("菜单栏图标是模板图（随深浅色变色），18×18 pt", image.isTemplate && image.size == MenuBarIcon.size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // Rep rows run top down. Back pane lower left, front pane upper right; the gap is probed left of
        // the front pane, clear of the cut's rounded corner.
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: 35 - y)?.alphaComponent ?? 0 }
        check("两块板都画出来，交叠处留出缝隙", alpha(5, 5) > 0.9 && alpha(28, 28) > 0.9 && alpha(11, 22) < 0.1 && alpha(1, 34) < 0.1,
              "后 \(alpha(5, 5)) 前 \(alpha(28, 28)) 缝 \(alpha(11, 22)) 角 \(alpha(1, 34))")
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent("70-menubar-icon.png")) }
    }

    /// Settings and folders of the app's ScshootDemo days are carried over once, without overwriting anything.
    private func caseMigration() {
        log("== 从 ScshootDemo 迁移 ==")
        let fm = FileManager.default
        let root = dir.appendingPathComponent("migration", isDirectory: true)
        try? fm.removeItem(at: root)
        let support = root.appendingPathComponent("Application Support"), movies = root.appendingPathComponent("Movies")
        func write(_ text: String, _ path: String, in base: URL) {
            let url = base.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        write("旧中转板", "ScshootDemo/Shelf/a.txt", in: support)
        write("旧剪贴板历史", "ScshootDemo/Clipboard/history.json", in: support)
        write("新中转板", "Myuxcc/Shelf/b.txt", in: support)
        // 构造新旧两份 .clip-texts.json，验证迁移时会合并去重而非丢弃旧记录
        write("[{\"id\":\"old-1\",\"text\":\"旧剪贴文字\",\"addedDate\":100}]", "ScshootDemo/Shelf/.clip-texts.json", in: support)
        write("[{\"id\":\"new-1\",\"text\":\"新剪贴文字\",\"addedDate\":200}]", "Myuxcc/Shelf/.clip-texts.json", in: support)
        write("旧录屏", "ScshootDemo 录屏/录屏 1.mp4", in: movies)
        let oldDomain = "Myuxcc.e2e-migration-old", newDomain = "Myuxcc.e2e-migration-new"
        let defaults = UserDefaults(suiteName: newDomain)!
        defaults.removePersistentDomain(forName: newDomain)
        defaults.setPersistentDomain(["shelfMaxItems": 30, "saveFolder": "/tmp/旧位置"], forName: oldDomain)
        defaults.set("/tmp/新位置", forKey: "saveFolder")
        defer { defaults.removePersistentDomain(forName: oldDomain); defaults.removePersistentDomain(forName: newDomain) }
        let places = LegacyMigration.Places(defaults: defaults, oldDomain: oldDomain, applicationSupport: support, movies: movies)
        LegacyMigration.run(places)
        func read(_ path: String, in base: URL) -> String? { try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
        check("旧设置搬过来，新名字下已有的设置不被覆盖", defaults.integer(forKey: "shelfMaxItems") == 30 && defaults.string(forKey: "saveFolder") == "/tmp/新位置")
        check("中转板文件合并进 Myuxcc 文件夹，旧剪贴板历史保留", read("Myuxcc/Shelf/a.txt", in: support) == "旧中转板" && read("Myuxcc/Shelf/b.txt", in: support) == "新中转板"
              && read("Myuxcc/Clipboard/history.json", in: support) == "旧剪贴板历史" && !fm.fileExists(atPath: support.appendingPathComponent("ScshootDemo").path))
        let mergedClipTexts = read("Myuxcc/Shelf/.clip-texts.json", in: support) ?? ""
        check("新旧 .clip-texts.json 合并保留双方记录", mergedClipTexts.contains("旧剪贴文字") && mergedClipTexts.contains("新剪贴文字"), mergedClipTexts)
        check("录屏文件夹改名为「Myuxcc 录屏」", read("Myuxcc 录屏/录屏 1.mp4", in: movies) == "旧录屏" && !fm.fileExists(atPath: movies.appendingPathComponent("ScshootDemo 录屏").path))
        write("之后又出现的旧文件", "ScshootDemo/Shelf/c.txt", in: support)
        LegacyMigration.run(places)
        check("只迁移一次", read("Myuxcc/Shelf/c.txt", in: support) == nil)
    }

    private static func pixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Size, length and number of frames of a video file.
    private static func videoInfo(_ url: URL) async -> (size: CGSize, seconds: Double, frames: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 } }
        return (size, duration.seconds, frames)
    }

    /// Copies on a private pasteboard land on a shelf in the output folder; clicking a row puts it back
    /// on the (private) clipboard. ⌘V is never pressed.
    private func caseShelfClipboard() async {
        log("== 剪贴中转板里的剪贴板 ==")
        let folder = dir.appendingPathComponent("shelf-clipboard", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let storage = ShelfStorage(folder: folder, discard: { try FileManager.default.removeItem(at: $0) }, limit: 10)
        let previous = ShelfStorage.shared
        ShelfStorage.shared = storage
        ShelfPanel.silent = true
        ShelfPaste.pressesPaste = false
        defer { ShelfStorage.shared = previous; ShelfPanel.silent = false; ShelfPaste.pressesPaste = true }
        let pb = NSPasteboard(name: NSPasteboard.Name("Myuxcc.e2e-shelf-clipboard"))
        defer { pb.releaseGlobally() }
        let watcher = ClipboardWatcher(pasteboard: pb, storage: { storage })
        func copy(_ write: (NSPasteboard) -> Void) async -> URL?? {
            pb.clearContents()
            write(pb)
            return await withCheckedContinuation { c in
                if !watcher.poll(completion: { c.resume(returning: $0) }) { c.resume(returning: nil) }
            }
        }

        let text = "你好 clipboard"
        let first = await copy { $0.setString(text, forType: .string) }
        let item = storage.items.first
        let filesAfterText = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        check("复制文字后剪贴中转板多一条，显示文字本身和字数，不生成 .txt 文件",
              first != nil && item?.isClipText == true && item?.title == text && item?.formattedSize == "12 字" && filesAfterText.isEmpty,
              "\(item?.name ?? "nil") \(item?.title ?? "") \(item?.formattedSize ?? "") files=\(filesAfterText.count)")
        _ = await copy { $0.setString("第一行\n第二行", forType: .string) }
        check("多行文字只显示第一行", storage.items.first?.title == "第一行")
        let count = storage.items.count
        _ = await copy { $0.setString(text, forType: .string) }
        check("同样的文字再复制：不新增，移到最前", storage.items.count == count && storage.items.first?.clipText == text,
              storage.items.map(\.title).joined(separator: " | "))
        check("剪贴板没变化时不重复记录", !watcher.poll())
        let png = ImageOutput.pngData(Self.textImage([("复制的图", 20)]))!
        _ = await copy { $0.setData(png, forType: .png) }
        check("复制图片存成 剪贴板 ….png", storage.items.first.map { $0.isFromClipboard && $0.kind == .image } == true)
        let source = dir.appendingPathComponent("复制的文件.txt")
        try? "文件内容".write(to: source, atomically: true, encoding: .utf8)
        _ = await copy { $0.writeObjects([source as NSURL]) }
        check("访达里复制文件：复制一份进来", storage.items.first?.name == "复制的文件.txt")
        // 验证同一外部文件再次复制时去重置顶，不产生「复制的文件 1.txt」
        let countAfterFirstFile = storage.items.count
        _ = await copy { $0.writeObjects([source as NSURL]) }
        check("访达里重复复制同一未改动文件：去重移到最前，不生成副本",
              storage.items.count == countAfterFirstFile && storage.items.first?.name == "复制的文件.txt")
        let concealed = await copy {
            $0.setString("密码123", forType: .string)
            $0.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        check("密码管理器标记隐私的内容不记录", concealed == nil && !storage.items.contains { $0.clipText == "密码123" })
        let fromShelf = await copy { $0.writeObjects([storage.items[0].url as NSURL]) }
        check("复制剪贴中转板里的文件不会再存一份", fromShelf == nil)

        // Putting items back on the clipboard.
        let out = NSPasteboard(name: NSPasteboard.Name("Myuxcc.e2e-shelf-out"))
        defer { out.releaseGlobally() }
        let textItem = storage.items.first { $0.clipText == text }!
        ShelfPaste.write(textItem, to: out)
        check("文字条目写回成文字", out.string(forType: .string) == text)
        ShelfPaste.write(storage.items.first { $0.isFromClipboard && $0.kind == .image }!, to: out)
        check("图片条目写回：PNG 直接放上，TIFF 只先登记", out.data(forType: .png) == png && out.types?.contains(.tiff) == true)
        check("别的应用要 TIFF 时才现做", out.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide > 0 } == true)
        ShelfPaste.write(storage.items.first { $0.name == "复制的文件.txt" }!, to: out)
        let urls = out.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check("文件条目写回成文件", urls?.first?.lastPathComponent == "复制的文件.txt")

        // Clicking a row pastes, then puts the clipboard back. ⌘V is stood in for by reading the pasteboard.
        let marker = NSPasteboard.PasteboardType("com.yuxccu.myuxcc.e2e-marker")
        func setOriginal() {
            out.clearContents()
            let item = NSPasteboardItem()
            item.setString("原来的剪贴板内容", forType: .string)
            item.setData(Data([1, 2, 3]), forType: marker)
            out.writeObjects([item])
        }
        let restoreDelay = ShelfPaste.restoreDelay
        ShelfPaste.restoreDelay = 0.05
        defer { ShelfPaste.restoreDelay = restoreDelay }
        let outWatcher = ClipboardWatcher(pasteboard: out, storage: { storage })
        setOriginal()
        outWatcher.start()
        outWatcher.stop()
        var pasted: [String?] = []
        ShelfPaste.paste(textItem, pasteboard: out, trusted: true) { pasted.append(out.string(forType: .string)) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("点条目：按 ⌘V 时剪贴板上是条目内容", pasted == [text], "\(pasted)")
        check("粘贴后剪贴板恢复成原来的内容（含所有类型）",
              out.string(forType: .string) == "原来的剪贴板内容" && out.data(forType: marker) == Data([1, 2, 3]))
        check("恢复剪贴板不会被当成新复制记进来", !outWatcher.poll())
        // Two quick clicks: the clipboard goes back to what it was before the first.
        pasted = []
        let fileItem = storage.items.first { $0.name == "复制的文件.txt" }!
        ShelfPaste.paste(textItem, pasteboard: out, trusted: true) { pasted.append(out.string(forType: .string)) }
        ShelfPaste.paste(fileItem, pasteboard: out, trusted: true) { pasted.append(out.string(forType: .string)) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("连点两条：最后恢复的是第一次之前的剪贴板", out.string(forType: .string) == "原来的剪贴板内容" && pasted.count == 2)
        // Something copied between the paste and the restore stays.
        ShelfPaste.restoreDelay = 0.3
        ShelfPaste.paste(textItem, pasteboard: out, trusted: true) {}
        try? await Task.sleep(nanoseconds: 250_000_000)
        out.clearContents()
        out.setString("粘贴后又复制的", forType: .string)
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("粘贴后马上又复制了别的：不覆盖新复制的", out.string(forType: .string) == "粘贴后又复制的")

        // Large images: TIFF converted off the main thread, oversized images skipped, hidden panel not rebuilt.
        let panel = ShelfPanel()
        let rebuilt = panel.reloadCount
        let tiff = NSImage(cgImage: Self.textImage([("TIFF 图", 20)]), size: .zero).tiffRepresentation!
        let fromTIFF = await copy { $0.setData(tiff, forType: .tiff) }
        let tiffItem = storage.items.first
        check("复制 TIFF：转成 PNG 存进来", fromTIFF??.pathExtension == "png" && tiffItem?.kind == .image
              && ThumbnailCache.pixelSize(tiffItem!.url) != nil)
        check("面板隐藏时有新条目也不重建列表", panel.reloadCount == rebuilt, "\(rebuilt) → \(panel.reloadCount)")
        let limit = ClipboardWatcher.pixelLimit
        ClipboardWatcher.pixelLimit = 1000
        let countBefore = storage.items.count
        let tooBig = await copy { $0.setData(tiff, forType: .tiff) }
        let tooBigPNG = await copy { $0.setData(png, forType: .png) }
        ClipboardWatcher.pixelLimit = limit
        check("超过像素上限的图片不收（TIFF 和 PNG）", tooBig == .some(nil) && tooBigPNG == .some(nil) && storage.items.count == countBefore)
        let wide = CGContext(data: nil, width: 2600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        wide.setFillColor(NSColor.systemTeal.cgColor)
        wide.fill(CGRect(x: 0, y: 0, width: 2600, height: 400))
        _ = await copy { $0.setData(ImageOutput.pngData(wide.makeImage()!)!, forType: .png) }
        panel.showNear(point: CGPoint(x: 400, y: 400))
        check("打开面板时补上隐藏期间的新条目", panel.visibleItems.count == storage.items.count && panel.reloadCount > rebuilt)
        let decodes = ThumbnailCache.shared.imageDecodes
        panel.reload()
        panel.reload()
        check("再次刷新列表不重新解码缩略图", ThumbnailCache.shared.imageDecodes == decodes, "\(decodes) → \(ThumbnailCache.shared.imageDecodes)")
        panel.select(panel.visibleItems.firstIndex { ThumbnailCache.pixelSize($0.url)?.width == 2600 } ?? 0)
        panel.togglePreview()
        let previewImage = panel.preview.imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        check("预览大图不解码原图：最长边不超过 \(ShelfPreviewView.previewPixels) 像素，信息里仍是原尺寸",
              previewImage.map { max($0.width, $0.height) <= ShelfPreviewView.previewPixels } == true && panel.preview.infoLabel.stringValue.contains("2600×400"),
              "\(previewImage.map { "\($0.width)×\($0.height)" } ?? "nil") \(panel.preview.infoLabel.stringValue)")
        panel.togglePreview()
        panel.hideShelf()

        // Clicking a row: the shelf closes and the text is on the clipboard, ready for ⌘V.
        let window = ShelfPanel()
        window.showNear(point: CGPoint(x: 400, y: 400))
        guard let row = Self.allViews(in: window.contentView!).compactMap({ $0 as? ShelfRowView }).first(where: { $0.item.clipText == text }) else {
            check("列表里有文字条目", false); return
        }
        ImageOutput.pasteboard.clearContents()
        let p = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        row.mouseDown(with: mouseEvent(.leftMouseDown, window, windowPoint: p))
        row.mouseUp(with: mouseEvent(.leftMouseUp, window, windowPoint: p))
        check("点一下条目：剪贴中转板收起，文字写回剪贴板", !window.isShelfVisible && ImageOutput.pasteboard.string(forType: .string) == text)
        check("剪贴中转板没有上屏", !window.isVisible)

        // Laid out like Maccy and driven from the keyboard.
        var chosen: [ShelvedItem] = []
        window.onChoose = { chosen.append($0) }
        window.showNear(point: CGPoint(x: 400, y: 400), focus: true)
        let shownRows = Self.allViews(in: window.contentView!).compactMap { $0 as? ShelfRowView }
        check("标题是「剪贴中转板」，有搜索框", window.titleLabel.stringValue == "剪贴中转板" && window.searchField.placeholderString == "搜索…")
        check("条目右边不标快捷键，文字一直排到右边", shownRows.allSatisfy { row in
            !Self.allViews(in: row).contains { ($0 as? NSTextField)?.stringValue.hasPrefix("⌘") == true }
                && row.bounds.width - row.titleLabel.frame.maxX <= 10 })
        check("复制来的图片只显示缩略图、行更高", shownRows.first { $0.item.isFromClipboard && $0.item.kind == .image }.map {
            $0.titleLabel.stringValue.isEmpty && $0.frame.height == ShelfRowView.imageHeight } == true)
        check("底部是菜单式操作", window.footerRows.map(\.title) == ["清空", "在访达中打开", "偏好设置…"])
        check("打开时选中第一条（蓝底）", window.selection == 0 && shownRows.first?.isSelected == true)
        let editor = NSTextView()
        _ = window.control(window.searchField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = window.control(window.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check("↓ 再 ↩：粘贴第二条", chosen.last?.url == window.visibleItems[1].url && window.selection == 1)
        let chosenCount = chosen.count
        check("⌘3 不再粘贴条目", !window.handleKey(keyEvent(code: 20, chars: "3", flags: .command)) && chosen.count == chosenCount)
        window.searchField.stringValue = "第一"
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check("打字搜索：只剩匹配的条目", window.visibleItems.map(\.title) == ["第一行"], window.visibleItems.map(\.title).joined(separator: " | "))
        _ = window.control(window.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("Esc 先清空搜索，不关闭", window.searchField.stringValue.isEmpty && window.isShelfVisible && window.visibleItems.count == storage.items.count)
        let showed = Settings.shelfShowsPreview
        Settings.shelfShowsPreview = false

        // The pointer sits at the list's top-left corner, with or without the preview.
        let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let spot = CGPoint(x: area.midX - 100, y: area.midY + 200)
        window.hideShelf()
        window.showNear(point: spot, focus: true)
        let listLeft = { window.frame.minX + (window.preview.isHidden ? 0 : ShelfPanel.previewWidth) }
        check("鼠标在列表左上角（预览栏关着）", abs(listLeft() - (spot.x + 12)) < 1 && window.preview.isHidden, "\(window.frame) / \(spot)")
        Settings.shelfShowsPreview = true
        window.hideShelf()
        window.showNear(point: spot, focus: true)
        check("鼠标在列表左上角（预览栏一直开着），预览栏在鼠标左边", abs(listLeft() - (spot.x + 12)) < 1 && !window.preview.isHidden
              && window.frame.minX < spot.x, "\(window.frame) / \(spot)")
        Settings.shelfShowsPreview = false
        window.hideShelf()
        window.showNear(point: spot, focus: true)

        // Space with the pointer on the selected row shows its preview to the left; the list stays put.
        let narrow = window.frame
        let space = keyEvent(code: 49, chars: " ")
        let textIndex = window.visibleItems.firstIndex { $0.isClipText } ?? 0
        let rowCenter = { (i: Int) in window.rows[i].convert(CGPoint(x: 40, y: window.rows[i].bounds.midY), to: nil) }
        window.pointerInWindow = { CGPoint(x: -50, y: -50) }
        window.select(textIndex)
        check("光标不在条目上：空格照常输入搜索框", !window.handleSpace(space) && window.preview.isHidden)
        window.pointerInWindow = { rowCenter(textIndex == 0 ? 1 : 0) }
        check("光标在别的条目上：空格不打开预览", !window.handleSpace(space) && window.preview.isHidden)
        window.pointerInWindow = { rowCenter(textIndex) }
        check("光标停在选中条目上按空格：预览栏在左边打开，列表位置不动", window.handleSpace(space) && window.peekOpen && !window.preview.isHidden
              && window.frame.width == narrow.width + ShelfPanel.previewWidth && abs(window.frame.maxX - narrow.maxX) < 1
              && !Settings.shelfShowsPreview, "\(narrow) → \(window.frame)")
        check("预览栏显示整段文字", window.preview.textView.string == window.selectedItem?.clipText)
        let imageIndex = window.visibleItems.firstIndex { $0.kind == .image } ?? 0
        window.select(imageIndex)
        check("选中图片：预览大图，识别文字和钉图按钮可用", window.preview.imageView.image != nil && window.preview.recognizeButton.isEnabled && window.preview.pinButton.isEnabled)
        if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("40-shelf-panel.png"))
        }
        window.pointerInWindow = { rowCenter(imageIndex) }
        window.sendEvent(space)
        check("再按空格（经窗口事件分发）：预览栏关闭，列表位置不动", window.preview.isHidden && abs(window.frame.maxX - narrow.maxX) < 1)
        check("⇧空格不当作预览键", !window.handleSpace(keyEvent(code: 49, chars: " ", flags: .shift)))
        _ = window.handleSpace(space)
        window.hideShelf()
        window.showNear(point: spot, focus: true)
        check("空格打开的预览栏随面板关闭，下次打开不显示", window.preview.isHidden && !window.peekOpen)
        window.togglePreview()
        check("按钮打开预览栏会一直显示", Settings.shelfShowsPreview && !window.preview.isHidden)
        // 验证常驻开启预览栏时按空格键仅临时收起，不篡改 Settings.shelfShowsPreview
        window.pointerInWindow = { rowCenter(window.selection) }
        _ = window.handleSpace(space)
        check("常驻预览开启时按空格：仅临时收起，不篡改持久化设置",
              window.preview.isHidden && Settings.shelfShowsPreview)
        window.togglePreview()
        Settings.shelfShowsPreview = showed
        _ = window.control(window.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("搜索为空时 Esc 关闭", !window.isShelfVisible)
    }

    private static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func keyEvent(code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func caseCancel() async {
        log("== Esc 取消 ==")
        guard let (window, _) = await beginCapture() else { return }
        await drag(window, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 500, y: 400))
        ImageOutput.pasteboard.clearContents()
        await key(window, code: 53, chars: "\u{1b}")
        await pause()
        check("Esc 后覆盖窗关闭", app.session == nil)
        check("Esc 不写剪贴板", ImageOutput.pasteboard.data(forType: .png) == nil)
    }

    // MARK: - Helpers

    private func beginCapture() async -> (OverlayWindow, OverlayView)? {
        if silent {
            guard let screen = NSScreen.main, let image = Self.syntheticScreen(screen) else { check("合成冻结画面", false); return nil }
            let session = app.beginSession([FrozenScreen(screen: screen, image: image)])
            guard let window = session.windows.first, let view = window.contentView as? OverlayView else { return nil }
            window.isSilent = true
            window.makeFirstResponder(view)
            check("覆盖窗接收键盘（不上屏）", window.firstResponder === view && !window.isVisible)
            return (window, view)
        }
        app.startCapture()
        for _ in 0..<50 where app.session == nil { await pause(0.1) }
        guard let session = app.session, let window = session.windows.first(where: { $0.screen == NSScreen.main }) ?? session.windows.first,
              let view = window.contentView as? OverlayView else {
            check("截图会话启动（需要屏幕录制权限）", false)
            return nil
        }
        await pause()
        check("覆盖窗是 key window", window.isKeyWindow)
        return (window, view)
    }

    private func clickToolbarButton(_ window: NSWindow, _ view: OverlayView, tooltip: String) async {
        guard let button = allButtons(in: view.toolbar).first(where: { $0.toolTip?.hasPrefix(tooltip) == true }) else {
            check("找到按钮 \(tooltip)", false); return
        }
        await clickButton(window, button, tooltip)
    }

    private func clickButton(_ window: NSWindow, _ button: NSButton, _ name: String) async {
        let p = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        if window.contentView?.hitTest(p) !== button { check("点击位置命中按钮 \(name)", false) }
        // A button's mouse-down tracks the mouse until mouse-up arrives, which a direct send can't feed it.
        if silent { button.performClick(nil); await pause(0.25); return }
        await post([mouseEvent(.leftMouseDown, window, windowPoint: p), mouseEvent(.leftMouseUp, window, windowPoint: p)])
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? allButtons(in: $0) }
    }

    /// Points are in the overlay view's flipped (top-left) coordinates.
    private func drag(_ window: NSWindow, from: CGPoint, to: CGPoint, steps: Int = 4, flags: NSEvent.ModifierFlags = []) async {
        var events = [mouseEvent(.leftMouseDown, window, windowPoint: toWindow(window, from), flags: flags)]
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            events.append(mouseEvent(.leftMouseDragged, window, windowPoint: toWindow(window, p), flags: flags))
        }
        events.append(mouseEvent(.leftMouseUp, window, windowPoint: toWindow(window, to), flags: flags))
        await post(events)
    }

    private func click(_ window: NSWindow, at p: CGPoint) async {
        await post([mouseEvent(.leftMouseDown, window, windowPoint: toWindow(window, p)),
                    mouseEvent(.leftMouseUp, window, windowPoint: toWindow(window, p))])
    }

    private func doubleClick(_ window: NSWindow, at p: CGPoint) async {
        let w = toWindow(window, p)
        await post([mouseEvent(.leftMouseDown, window, windowPoint: w), mouseEvent(.leftMouseUp, window, windowPoint: w),
                    mouseEvent(.leftMouseDown, window, windowPoint: w, clickCount: 2), mouseEvent(.leftMouseUp, window, windowPoint: w, clickCount: 2)])
    }

    private func move(_ window: NSWindow, to p: CGPoint) async {
        await post([mouseEvent(.mouseMoved, window, windowPoint: toWindow(window, p))])
    }

    private func rightClick(_ window: NSWindow, at p: CGPoint) async {
        await post([mouseEvent(.rightMouseDown, window, windowPoint: toWindow(window, p)),
                    mouseEvent(.rightMouseUp, window, windowPoint: toWindow(window, p))])
    }

    /// Goes through the app's normal event queue, like real input, instead of calling window.sendEvent directly.
    /// Silent runs hand each event to the view the window would give it to: a window that is not on
    /// screen drops mouse events in `sendEvent`.
    private func post(_ events: [NSEvent]) async {
        if silent {
            for e in events {
                guard let window = NSApp.windows.first(where: { $0.windowNumber == e.windowNumber }) else { continue }
                switch e.type {
                case .leftMouseDown, .rightMouseDown:
                    pressedView = window.contentView?.hitTest(e.locationInWindow)
                    e.type == .leftMouseDown ? pressedView?.mouseDown(with: e) : pressedView?.rightMouseDown(with: e)
                case .leftMouseDragged: pressedView?.mouseDragged(with: e)
                case .leftMouseUp: pressedView?.mouseUp(with: e); pressedView = nil
                case .rightMouseUp: pressedView?.rightMouseUp(with: e); pressedView = nil
                case .mouseMoved: window.contentView?.mouseMoved(with: e)
                case .keyDown: window.firstResponder?.keyDown(with: e)
                default: window.sendEvent(e)
                }
            }
            if NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible }) { showedSomething = true }
        } else {
            for e in events { NSApp.postEvent(e, atStart: false) }
        }
        await pause(0.25)
    }

    /// A stand-in for a frozen screen: coloured tiles with a grid, so every pixel has a known, varied colour.
    private static func syntheticScreen(_ screen: NSScreen) -> CGImage? {
        let w = Int(screen.frame.width * screen.backingScaleFactor), h = Int(screen.frame.height * screen.backingScaleFactor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tile = 64
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                let i = tx / tile * 7 + ty / tile * 13
                ctx.setFillColor(NSColor(hue: CGFloat(i % 36) / 36, saturation: 0.5, brightness: 0.6 + CGFloat(i % 5) / 12.5, alpha: 1).cgColor)
                ctx.fill(CGRect(x: tx, y: ty, width: tile, height: tile))
            }
        }
        // A line of text on a white strip, for the OCR case: view points (180, 200)–(900, 300).
        let s = screen.backingScaleFactor
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 180 * s, y: CGFloat(h) - 300 * s, width: 720 * s, height: 100 * s))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (Self.ocrSample as NSString).draw(at: CGPoint(x: 200 * s, y: CGFloat(h) - 268 * s),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 30 * s), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func toWindow(_ window: NSWindow, _ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: window.frame.height - p.y)
    }

    private func mouseEvent(_ type: NSEvent.EventType, _ window: NSWindow, windowPoint: CGPoint, clickCount: Int = 1,
                            flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    private func key(_ window: NSWindow, code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) async {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        await post([event])
    }

    private func snapshot(_ name: String) async {
        if silent { return } // screen shots need the real screen
        guard let screens = try? await ScreenCapturer.captureAllScreens(),
              let main = screens.first(where: { $0.screen == NSScreen.main }) ?? screens.first,
              let data = ImageOutput.pngData(main.image) else { log("  (snapshot \(name) failed)"); return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func pause(_ seconds: Double = 0.4) async {
        // Silent runs handle events synchronously; there is nothing on screen to wait for.
        try? await Task.sleep(nanoseconds: UInt64(seconds * (silent ? 0.05 : 1) * 1_000_000_000))
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty || ok ? "" : " — \(detail)")")
    }

    private func log(_ line: String) {
        report.append(line)
        print(line)
    }
}

/// Tall test document: coloured bands with numbered lines, so every stretch of it looks different.
private final class TestDocumentView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 0, i = 0
        while y < bounds.height {
            let h = CGFloat(30 + (i * 37) % 40)
            NSColor(hue: CGFloat((i * 53) % 360) / 360, saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
            CGRect(x: 0, y: y, width: bounds.width, height: h).fill()
            ("第 \(i) 行 · Line \(i) · " + String(repeating: "◆", count: i % 9 + 1) as NSString)
                .draw(at: CGPoint(x: 12 + CGFloat((i * 29) % 120), y: y + 6),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
            y += h; i += 1
        }
    }
}

private final class TestFloatingButton: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor
        layer?.cornerRadius = frame.width / 2
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        ("↓" as NSString).draw(at: CGPoint(x: 16, y: 10), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white])
    }
}

private final class TestBarView: NSView {
    let title: String, color: NSColor
    init(frame: CGRect, title: String, color: NSColor) { self.title = title; self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        (title as NSString).draw(at: CGPoint(x: 16, y: 14), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
    }
}
