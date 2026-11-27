import AppKit
import Darwin
import Translation

/// `--bench-memory`：无界面内存基准测试工具。
/// 依次压测 ScreenTranslator、ImageTranslator + OCR 以及核心 UI/窗口生命周期，
/// 通过 Mach 内核指标 (`phys_footprint` / `resident_size`)、弱引用存活检查及子进程/系统进程 RSS，
/// 输出结构化 `[BENCH]` 数据用于定位内存泄漏与长期驻留问题。
@MainActor
final class MemoryBench {
    /// 弱引用包装盒，用于统计关闭窗口或结束会话后对象是否真正 deinit 释放
    private final class WeakBox {
        weak var ref: AnyObject?
        init(_ obj: AnyObject?) { self.ref = obj }
    }

    /// 进程内存快照（单位：字节）
    private struct MemSnapshot {
        let physFootprint: UInt64
        let residentSize: UInt64
        let internalBytes: UInt64
        let compressedBytes: UInt64

        /// 将字节数格式化为 MB 字符串
        static func mb(_ bytes: UInt64) -> String {
            String(format: "%.2f", Double(bytes) / 1_048_576.0)
        }
    }

    private let app: AppDelegate
    private var failures = 0

    init(app: AppDelegate) {
        self.app = app
    }

    /// 采集当前进程 `task_vm_info` 与 `mach_task_basic_info` 内存指标
    private static func sampleMemory() -> MemSnapshot {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let vmKr = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }

        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let basicKr = withUnsafeMutablePointer(to: &basicInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &basicCount)
            }
        }

        return MemSnapshot(
            physFootprint: vmKr == KERN_SUCCESS ? vmInfo.phys_footprint : 0,
            residentSize: basicKr == KERN_SUCCESS ? basicInfo.resident_size : 0,
            internalBytes: vmKr == KERN_SUCCESS ? vmInfo.internal : 0,
            compressedBytes: vmKr == KERN_SUCCESS ? vmInfo.compressed : 0
        )
    }

    /// 查询外部进程（如 `translationd`、`--ocr-worker`）的常驻内存 RSS（单位：KB）
    private static func queryExternalRSS(processNameSubstr: String, exactPID: Int32? = nil) -> [(pid: Int32, rssKB: UInt64, cmd: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,rss=,args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var matches: [(Int32, UInt64, String)] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let rss = UInt64(parts[1]) else { continue }
            let cmd = String(parts[2])
            if let exactPID, pid == exactPID {
                matches.append((pid, rss, cmd))
            } else if exactPID == nil, cmd.contains(processNameSubstr) {
                matches.append((pid, rss, cmd))
            }
        }
        return matches
    }

    /// 打印格式化的 `[BENCH]` 指标行（同时输出增量变化便于汇总对比）
    private func logBench(scene: String, phase: String, baseline: MemSnapshot, extra: String = "") {
        let cur = Self.sampleMemory()
        let deltaPhys = Int64(cur.physFootprint) - Int64(baseline.physFootprint)
        let deltaRss = Int64(cur.residentSize) - Int64(baseline.residentSize)
        let signPhys = deltaPhys >= 0 ? "+" : "-"
        let signRss = deltaRss >= 0 ? "+" : "-"
        let deltaPhysMB = MemSnapshot.mb(UInt64(abs(deltaPhys)))
        let deltaRssMB = MemSnapshot.mb(UInt64(abs(deltaRss)))
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[BENCH] scene=\(scene) phase=\(phase) phys_footprint_mb=\(MemSnapshot.mb(cur.physFootprint)) resident_size_mb=\(MemSnapshot.mb(cur.residentSize)) delta_phys_mb=\(signPhys)\(deltaPhysMB) delta_rss_mb=\(signRss)\(deltaRssMB) internal_mb=\(MemSnapshot.mb(cur.internalBytes)) compressed_mb=\(MemSnapshot.mb(cur.compressedBytes))\(suffix)")
        fflush(stdout)
    }

    /// 采集并打印 `translationd` 与 `--ocr-worker` 进程的 RSS 状态
    private func logExternalDaemons(scene: String, phase: String) {
        let td = Self.queryExternalRSS(processNameSubstr: "/Translation.framework/translationd")
        let tdSummary = td.isEmpty
            ? "none"
            : td.map { "pid=\($0.pid):rss_mb=\(String(format: "%.2f", Double($0.rssKB) / 1024.0))" }.joined(separator: ",")

        let workerPID = TextRecognizer.workerPID
        let workers = Self.queryExternalRSS(processNameSubstr: "--ocr-worker", exactPID: workerPID)
        let workerSummary = workers.isEmpty
            ? "none"
            : workers.map { "pid=\($0.pid):rss_mb=\(String(format: "%.2f", Double($0.rssKB) / 1024.0))" }.joined(separator: ",")

        print("[BENCH] scene=\(scene) phase=\(phase)_daemons translationd=[\(tdSummary)] ocr_worker=[\(workerSummary)]")
        fflush(stdout)
    }

    /// 让出主线程执行队列并等待异步释放事务与 autorelease 池排空
    private func drainMainLoopAndWait(seconds: Double = 1.0) async {
        // 通过多次 yield 与休眠让主线程 RunLoop 自然完成 AppKit 窗口销毁与 ARC 回收
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    /// 入口：依次执行 3 组基准场景并退出进程
    func run() async -> Never {
        // 隔离剪贴板与标注内存状态，防止干扰用户真实环境
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Myuxcc.bench-memory"))
        ImageOutput.pasteboard = pasteboard
        MarkStyle.inMemory = [:]
        defer {
            pasteboard.releaseGlobally()
            PinWindowController.testPresenter = nil
            TextRecognitionController.testPresenter = nil
        }

        print("[BENCH] start pid=\(ProcessInfo.processInfo.processIdentifier) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        fflush(stdout)

        let globalStart = Self.sampleMemory()
        logBench(scene: "global", phase: "process_start", baseline: globalStart)
        logExternalDaemons(scene: "global", phase: "process_start")

        await runBench1ScreenTranslator()
        await runBench2ImageTranslatorAndOCR()
        await runBench3UILifecycle()

        await drainMainLoopAndWait(seconds: 1.5)
        logBench(scene: "global", phase: "all_done_settled", baseline: globalStart)
        logExternalDaemons(scene: "global", phase: "all_done_settled")

        print("[BENCH] done failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Bench 1: ScreenTranslator

    /// Bench 1：连续执行 36 次中英互译（涵盖 detect + languages + translate），观测 sessions 缓存与 translationd 增长
    private func runBench1ScreenTranslator() async {
        let scene = "bench1_screen_translator"
        guard #available(macOS 26, *) else {
            print("[BENCH] scene=\(scene) status=skipped reason=requires_macOS_26")
            return
        }
        let status = await LanguageAvailability().status(from: ScreenTranslator.english, to: ScreenTranslator.chinese)
        guard status == .installed else {
            print("[BENCH] scene=\(scene) status=skipped reason=language_pack_not_installed(\(status))")
            return
        }

        await drainMainLoopAndWait(seconds: 0.5)
        let base = Self.sampleMemory()
        logBench(scene: scene, phase: "init", baseline: base)
        logExternalDaemons(scene: scene, phase: "init")

        let iterations = 36
        var okCount = 0
        for i in 1...iterations {
            do {
                // 交替使用中文与英文短文本，覆盖双向 TranslationSession 与语言检测路径
                let text = (i % 2 == 1)
                    ? "第 \(i) 次截图翻译基准测试：打开设置窗口，复制并保存识别结果。"
                    : "Benchmark iteration \(i): Open the settings window and save the translated screenshot."
                let (from, to) = try ScreenTranslator.languages(for: text, target: .auto)
                let translated = try await ScreenTranslator.translate(text, from: from, to: to)
                if !translated.isEmpty { okCount += 1 }
            } catch {
                failures += 1
                print("[BENCH] scene=\(scene) iter=\(i) error=\(error.localizedDescription)")
            }

            if i == 10 || i == 20 || i == 30 || i == iterations {
                logBench(scene: scene, phase: "iter_\(i)", baseline: base, extra: "ok=\(okCount)/\(i)")
            }
        }

        // 等待短暂空闲后观测内存是否回落（当前 sessionIdleTimeout 为 300s，此处检验异步 Task/autorelease 回收）
        await drainMainLoopAndWait(seconds: 2.0)
        logBench(scene: scene, phase: "after_wait_2s", baseline: base, extra: "ok=\(okCount)/\(iterations)")
        logExternalDaemons(scene: scene, phase: "after_wait_2s")
    }

    // MARK: - Bench 2: ImageTranslator + OCR

    /// Bench 2：合成含清晰中英文文字的 CGImage，连续执行 20 次 ImageTranslator.translate，记录每 5 次内存与后台进程 RSS
    private func runBench2ImageTranslatorAndOCR() async {
        let scene = "bench2_image_translator"
        guard #available(macOS 26, *) else {
            print("[BENCH] scene=\(scene) status=skipped reason=requires_macOS_26")
            return
        }

        await drainMainLoopAndWait(seconds: 0.5)
        let base = Self.sampleMemory()
        logBench(scene: scene, phase: "init", baseline: base)
        logExternalDaemons(scene: scene, phase: "init")

        let iterations = 20
        var okCount = 0
        for i in 1...iterations {
            do {
                // 每轮在临时作用域内重新生成合成图，模拟真实连续截图场景
                let img: CGImage = autoreleasepool {
                    if i % 2 == 1 {
                        return Self.syntheticTextImage(
                            width: 1440,
                            height: 900,
                            lines: [
                                ("Benchmark sample \(i): Open the settings window", 26),
                                ("and choose a destination folder for screenshots.", 26),
                                ("Click the copy button to put the text on clipboard.", 24),
                                ("Double click to close the pinned preview card.", 24),
                            ],
                            background: NSColor(srgbRed: 0.14, green: 0.17, blue: 0.24, alpha: 1),
                            ink: NSColor(srgbRed: 0.96, green: 0.88, blue: 0.50, alpha: 1)
                        )
                    } else {
                        return Self.syntheticTextImage(
                            width: 1440,
                            height: 900,
                            lines: [
                                ("第 \(i) 轮图文翻译测试：识别图片中的所有文字", 26),
                                ("将识别出的段落自动翻译成英文并回填到原图位置。", 26),
                                ("保持背景颜色和文字前景色自然融合。", 24),
                                ("按下按键可以随时切换查看原文或译文。", 24),
                            ],
                            background: .white,
                            ink: .black
                        )
                    }
                }
                let (resultImage, _) = try await ImageTranslator.translate(img, target: .auto)
                if resultImage.width == img.width && resultImage.height == img.height {
                    okCount += 1
                }
            } catch {
                failures += 1
                print("[BENCH] scene=\(scene) iter=\(i) error=\(error.localizedDescription)")
            }

            if i % 5 == 0 {
                logBench(scene: scene, phase: "iter_\(i)", baseline: base, extra: "ok=\(okCount)/\(i)")
                if i == 10 || i == iterations {
                    logExternalDaemons(scene: scene, phase: "iter_\(i)")
                }
            }
        }

        await drainMainLoopAndWait(seconds: 2.0)
        logBench(scene: scene, phase: "after_wait_2s", baseline: base, extra: "ok=\(okCount)/\(iterations)")
        logExternalDaemons(scene: scene, phase: "after_wait_2s")
    }

    // MARK: - Bench 3: UI Lifecycle

    /// Bench 3：连续执行 15 次 PinWindowController、CaptureSession overlay 与 TextRecognitionController 生命周期，
    /// 检查窗口/大图/View 在关闭后是否真正 deinit 释放以及内存驻留情况
    private func runBench3UILifecycle() async {
        await runBench3aPinWindowLifecycle()
        await runBench3bCaptureSessionLifecycle()
        await runBench3cTextRecognitionControllerLifecycle()
    }

    /// Bench 3a：连续 15 次 PinWindowController 打开 -> 翻译 -> 视图切换 -> 关闭
    private func runBench3aPinWindowLifecycle() async {
        let scene = "bench3a_pin_lifecycle"
        await drainMainLoopAndWait(seconds: 0.5)
        let base = Self.sampleMemory()
        logBench(scene: scene, phase: "init", baseline: base)

        var presentedPins: [WeakBox] = []
        var pinWindows: [WeakBox] = []
        var pinViews: [WeakBox] = []

        PinWindowController.testPresenter = { controller in
            presentedPins.append(WeakBox(controller))
            pinWindows.append(WeakBox(controller.window))
            pinViews.append(WeakBox(controller.view))
        }
        defer { PinWindowController.testPresenter = nil }

        let iterations = 15
        for i in 1...iterations {
            autoreleasepool {
                // 使用 1600x1000 大图（约 6.4 MB 原始像素）放大内存滞留特征
                let img = Self.syntheticTextImage(
                    width: 1600,
                    height: 1000,
                    lines: [
                        ("Pin card lifecycle benchmark \(i)", 28),
                        ("Translate and toggle original view repeatedly.", 26),
                    ],
                    background: .white,
                    ink: .black
                )
                let pin = PinWindowController.pin(
                    img,
                    pointSize: CGSize(width: 800, height: 500),
                    at: CGPoint(x: 120, y: 120),
                    translating: true
                )
                // 把引用留给外层等待翻译完成并切换视图
                _ = pin
            }

            // 等待当前最后一个打开的贴图翻译完成
            if let pin = PinWindowController.open.last {
                for _ in 0..<200 where pin.translationRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // 切换译文 -> 原文 -> 译文，触发 NSImage 重建与显示刷新路径
                if pin.translated != nil {
                    pin.translate()
                    pin.translate()
                }
                pin.close()
            }

            if i % 5 == 0 {
                logBench(scene: scene, phase: "iter_\(i)", baseline: base, extra: "open=\(PinWindowController.open.count)")
            }
        }

        await drainMainLoopAndWait(seconds: 1.5)
        let alivePins = presentedPins.filter { $0.ref != nil }.count
        let aliveWins = pinWindows.filter { $0.ref != nil }.count
        let aliveViews = pinViews.filter { $0.ref != nil }.count
        logBench(
            scene: scene,
            phase: "after_close_settled",
            baseline: base,
            extra: "open=\(PinWindowController.open.count) leaked_ctrl=\(alivePins)/\(iterations) leaked_win=\(aliveWins)/\(iterations) leaked_view=\(aliveViews)/\(iterations)"
        )
    }

    /// Bench 3b：连续 15 次 CaptureSession 全屏 OverlayWindow + OverlayView（含全屏 frozen 大图与标注）创建与关闭
    private func runBench3bCaptureSessionLifecycle() async {
        let scene = "bench3b_capture_session"
        guard let screen = NSScreen.main else {
            print("[BENCH] scene=\(scene) status=skipped reason=no_main_screen")
            return
        }

        await drainMainLoopAndWait(seconds: 0.5)
        let base = Self.sampleMemory()
        logBench(scene: scene, phase: "init", baseline: base)

        var sessions: [WeakBox] = []
        var overlayWindows: [WeakBox] = []
        var overlayViews: [WeakBox] = []

        // 按主屏幕实际 Retina 分辨率或至少 2560x1600 合成全屏冻结帧，模拟真实全屏截图占用
        let pxW = max(Int(screen.frame.width * screen.backingScaleFactor), 2560)
        let pxH = max(Int(screen.frame.height * screen.backingScaleFactor), 1600)

        let iterations = 15
        for i in 1...iterations {
            autoreleasepool {
                let frozen = Self.syntheticTextImage(
                    width: pxW,
                    height: pxH,
                    lines: [
                        ("CaptureSession full-screen frozen frame \(i)", 32),
                        ("Testing OverlayWindow and OverlayView release on close().", 28),
                    ],
                    background: NSColor(srgbRed: 0.92, green: 0.94, blue: 0.97, alpha: 1),
                    ink: .black
                )
                let session = app.beginSession([FrozenScreen(screen: screen, image: frozen)])
                sessions.append(WeakBox(session))
                for w in session.windows {
                    w.isSilent = true
                    overlayWindows.append(WeakBox(w))
                }
                for v in session.views {
                    overlayViews.append(WeakBox(v))
                }
                if let view = session.views.first {
                    // 注入选区和标注，模拟真实用户框选并标注后取消或完成导出
                    view.loadForTesting(
                        selection: CGRect(x: 120, y: 120, width: 640, height: 420),
                        annotations: [
                            .rectangle(CGRect(x: 140, y: 140, width: 220, height: 120), .systemRed, 3),
                            .text("标注测试 \(i)", CGPoint(x: 160, y: 280), .systemBlue, 20),
                        ]
                    )
                    _ = view.renderSelection()
                    view.cancel()
                }
            }

            if i % 5 == 0 {
                logBench(
                    scene: scene,
                    phase: "iter_\(i)",
                    baseline: base,
                    extra: "app_session_nil=\(app.session == nil) nsapp_windows=\(NSApp.windows.count)"
                )
            }
        }

        await drainMainLoopAndWait(seconds: 1.5)
        let aliveSessions = sessions.filter { $0.ref != nil }.count
        let aliveWins = overlayWindows.filter { $0.ref != nil }.count
        let aliveViews = overlayViews.filter { $0.ref != nil }.count
        logBench(
            scene: scene,
            phase: "after_close_settled",
            baseline: base,
            extra: "leaked_session=\(aliveSessions)/\(iterations) leaked_win=\(aliveWins)/\(iterations) leaked_view=\(aliveViews)/\(iterations) nsapp_windows=\(NSApp.windows.count)"
        )
    }

    /// Bench 3c：连续 15 次 TextRecognitionController 打开 -> OCR + 翻译 -> 编辑文本 -> 关闭
    private func runBench3cTextRecognitionControllerLifecycle() async {
        let scene = "bench3c_text_recognition_ctrl"
        await drainMainLoopAndWait(seconds: 0.5)
        let base = Self.sampleMemory()
        logBench(scene: scene, phase: "init", baseline: base)

        var ctrls: [WeakBox] = []
        var windows: [WeakBox] = []
        var textViews: [WeakBox] = []
        var transViews: [WeakBox] = []
        var latestCtrl: TextRecognitionController?

        TextRecognitionController.testPresenter = { ctrl in
            latestCtrl = ctrl
            ctrls.append(WeakBox(ctrl))
            windows.append(WeakBox(ctrl.window))
            textViews.append(WeakBox(ctrl.textView))
            transViews.append(WeakBox(ctrl.translationView))
        }
        defer { TextRecognitionController.testPresenter = nil }

        let iterations = 15
        for i in 1...iterations {
            latestCtrl = nil
            autoreleasepool {
                let img = Self.syntheticTextImage(
                    width: 1600,
                    height: 1000,
                    lines: [
                        ("第 \(i) 次识别窗口生命周期测试", 30),
                        ("验证关闭窗口后大图与 NSTextView 是否彻底释放。", 26),
                    ],
                    background: .white,
                    ink: .black
                )
                TextRecognitionController.present(img, near: nil, translating: true)
            }

            if let ctrl = latestCtrl {
                for _ in 0..<200 where ctrl.lines == nil || ctrl.translationRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // 模拟在文本框内输入编辑（生成 undoManager 记录）后关闭
                ctrl.textView.insertText(" [edited \(i)]", replacementRange: NSRange(location: ctrl.textView.string.count, length: 0))
                ctrl.close()
            }
            latestCtrl = nil

            if i % 5 == 0 {
                logBench(scene: scene, phase: "iter_\(i)", baseline: base, extra: "open=\(TextRecognitionController.open.count)")
            }
        }

        await drainMainLoopAndWait(seconds: 1.5)
        let aliveCtrls = ctrls.filter { $0.ref != nil }.count
        let aliveWins = windows.filter { $0.ref != nil }.count
        let aliveTextViews = textViews.filter { $0.ref != nil }.count
        let aliveTransViews = transViews.filter { $0.ref != nil }.count
        logBench(
            scene: scene,
            phase: "after_close_settled",
            baseline: base,
            extra: "open=\(TextRecognitionController.open.count) leaked_ctrl=\(aliveCtrls)/\(iterations) leaked_win=\(aliveWins)/\(iterations) leaked_tv=\(aliveTextViews)/\(iterations) leaked_trans_tv=\(aliveTransViews)/\(iterations)"
        )
    }

    // MARK: - Helpers

    /// 生成指定尺寸与配色的清晰文字合成图（8-bit sRGB，供 OCR/翻译/UI 生命周期基准使用）
    private static func syntheticTextImage(
        width: Int,
        height: Int,
        lines: [(String, CGFloat)],
        background: NSColor,
        ink: NSColor
    ) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var y = CGFloat(height) - 60
        for (text, size) in lines {
            y -= size * 3.0
            (text as NSString).draw(
                at: CGPoint(x: 56, y: y),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: size * 2),
                    .foregroundColor: ink,
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
