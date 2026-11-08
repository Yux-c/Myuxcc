import AppKit
import Vision

/// One line of text found in an image; `box` is in image pixels with a top-left origin.
struct RecognizedLine: Equatable {
    let text: String
    let box: CGRect
}

/// On-device OCR with Vision (`VNRecognizeTextRequest`): simplified and traditional Chinese, English.
enum TextRecognizer {
    static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Vision rejects an image whose every dimension is not more than 2 pixels, so a stray click that
    /// leaves a 1–2 pixel selection is reported before the request is even made.
    static let minimumSide = 3

    /// What can go wrong, said in terms the user can act on. Vision's own errors are English NSErrors
    /// such as `TextRecognition.CRImageReaderError error 1`, which mean nothing in a toast; that code
    /// goes to the log instead, so the message itself stays short enough for the one-line toast.
    enum Failure: LocalizedError {
        case tooSmall(width: Int, height: Int)
        case engineUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .tooSmall(let w, let h):
                return "选区太小（\(w) × \(h)），框住要识别的文字再试"
            case .engineUnavailable(let detail):
                return "系统文字识别引擎暂时不可用（\(detail)），请重试；一直失败就退出并重新打开 Myuxcc"
            }
        }
    }

    /// Lines in reading order: top to bottom, and left to right within a row.
    ///
    /// The recogniser can wedge inside a process: every request then answers `CRImageReaderError 1`
    /// (`e5rt_..._create_precompiled_compute_operation ... Code: 13`) until the process restarts, and
    /// retrying in-process never helps. So after one in-process retry the work moves to a separate
    /// `--ocr-worker` process, which gets restarted as often as needed while the app keeps running and
    /// the user's pinned screenshots stay on screen.
    static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        guard image.width >= minimumSide, image.height >= minimumSide else {
            throw Failure.tooSmall(width: image.width, height: image.height)
        }
        let prepared = normalized(image)
        if !pretendEngineIsWedged {
            do {
                return try await recognizeOnce(prepared)
            } catch {
                guard isTransient(error) else { throw engineFailure(error) }
            }
            // Second try in-process: a fresh request on a known-good bitmap sometimes goes through.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let lines = try? await recognizeOnce(prepared) { return lines }
        }
        // The engine stays broken in this process; hand the image to a worker process instead.
        NSLog("Myuxcc: in-process text recognition is wedged, switching to the worker process")
        do {
            return try await recognizeInWorker(prepared)
        } catch {
            throw engineFailure(error)
        }
    }

    /// Set by `--e2e-ocr-wedged`: skips the in-process attempts so the worker fallback can be tested
    /// without actually breaking Vision. The wedged engine itself cannot be provoked on demand.
    nonisolated(unsafe) static var pretendEngineIsWedged = false

    /// The fallback recogniser: one lazily started process, never touched on the happy path. Its pipe
    /// I/O blocks, so it runs off the caller's thread.
    private static func recognizeInWorker(_ image: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            workerQueue.async {
                // 每次使用兜底子进程时重置空闲回收计时器，避免子进程闲置后永久驻留后台
                scheduleWorkerIdleStop()
                do { continuation.resume(returning: try worker.recognize(image)) }
                catch {
                    // A dead or wedged worker is replaced next time; do not keep a broken one around.
                    worker.stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let worker = OCRWorkerProcess()
    /// Serialises the worker's request/response conversation.
    private static let workerQueue = DispatchQueue(label: "Myuxcc.ocrWorker", qos: .userInitiated)
    /// 兜底 OCR 子进程空闲超时任务（闲置 120 秒后自动终止子进程释放内存）
    nonisolated(unsafe) private static var workerIdleWorkItem: DispatchWorkItem?
    /// 兜底 OCR 子进程的最大空闲保活时长（秒）
    private static let workerIdleTimeout: TimeInterval = 120

    /// 在 workerQueue 上重置子进程空闲自动退出计时器
    private static func scheduleWorkerIdleStop() {
        workerIdleWorkItem?.cancel()
        let item = DispatchWorkItem {
            worker.stop()
        }
        workerIdleWorkItem = item
        workerQueue.asyncAfter(deadline: .now() + workerIdleTimeout, execute: item)
    }

    /// The worker's pid, for the e2e test to kill it and check that a dead worker is replaced.
    static var workerPID: Int32? { worker.processIdentifier }

    /// Gets the worker process up and its models loaded ahead of time, in the background, so that if the
    /// in-process engine ever wedges the takeover is immediate instead of a ~14 s first-run stall.
    static func warmUpWorker() {
        guard !CommandLine.arguments.contains("--e2e") else { return }
        workerQueue.async {
            guard !worker.isRunning else { return }
            worker.warmUp()
            scheduleWorkerIdleStop()
        }
    }

    /// The message shown to the user is deliberately short; the underlying code goes to the log.
    private static func engineFailure(_ error: Error) -> Failure {
        NSLog("Myuxcc: text recognition failed: \(error)")
        return .engineUnavailable(code(of: error))
    }

    /// One `VNRecognizeTextRequest`; the boxes come back in image pixels with a top-left origin.
    /// Also used by the out-of-process worker (`--ocr-worker`), which does no retrying of its own.
    static func recognizeSynchronously(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let lines = (request.results ?? []).compactMap { o -> RecognizedLine? in
            guard let text = o.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let b = o.boundingBox
            return RecognizedLine(text: text, box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
        return readingOrder(lines)
    }

    /// One `VNRecognizeTextRequest`, unchanged.
    private static func recognizeOnce(_ image: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    let lines = (request.results ?? []).compactMap { o -> RecognizedLine? in
                        guard let text = o.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                        // Vision boxes are normalised with a bottom-left origin.
                        let b = o.boundingBox
                        return RecognizedLine(text: text, box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
                    }
                    continuation.resume(returning: readingOrder(lines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The image redrawn as an ordinary 8-bit sRGB bitmap. A ScreenCaptureKit capture has a padded row
    /// stride and a colour space without a name, and 16-bit or wide-gamut captures are possible too,
    /// while the recogniser is happiest with the plain format every other code path here already uses.
    /// Images that are already like that (and every image in the self tests) come back untouched.
    static func normalized(_ image: CGImage) -> CGImage {
        let plain = image.bitsPerComponent == 8 && image.bitsPerPixel == 32
            && image.bytesPerRow == image.width * 4
            && image.colorSpace?.name == CGColorSpace.sRGB
        guard !plain else { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// `CRImageReaderError 1` (the CoreRecognition reader failing to run) and Vision's generic failures
    /// are worth another try; being out of memory or a cancelled request is not.
    private static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain.contains("CRImageReader") { return true }
        return ns.domain == "com.apple.Vision" && ns.code == 1
    }

    /// Just enough of the underlying error to tell two kinds of failure apart.
    private static func code(of error: Error) -> String {
        let ns = error as NSError
        return ns.domain.components(separatedBy: ".").last.map { "\($0) \(ns.code)" } ?? "\(ns.code)"
    }

    /// The first recognition after the app is built (or updated) compiles Vision's models, about 13 s on
    /// an M5; later ones take ~40 ms, also after relaunching. Doing that once in the background shortly
    /// after launch keeps the user's first OCR fast.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            // The text models are only loaded when there is text to read.
            guard let ctx = CGContext(data: nil, width: 320, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 64))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "预热 Warm up", attributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black,
            ]))
            ctx.textPosition = CGPoint(x: 10, y: 20)
            CTLineDraw(line, ctx)
            guard let image = ctx.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    /// Rows top to bottom (lines whose vertical centres are within half a line height share a row),
    /// left to right within each row.
    static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last?.last, abs(line.box.midY - last.box.midY) < max(line.box.height, last.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// The lines as they are laid out: one per line, columns of a row separated by a tab.
    static func keepingLines(_ lines: [RecognizedLine]) -> String {
        var out = "", previous: RecognizedLine?
        for line in lines {
            if let p = previous {
                out += abs(line.box.midY - p.box.midY) < max(line.box.height, p.box.height) / 2 ? "\t" : "\n"
            }
            out += line.text
            previous = line
        }
        return out
    }

    /// Wrapped lines joined back into paragraphs. A paragraph ends at a vertical gap wider than
    /// most of a line, or after a line that stops well short of the widest one on a full stop.
    static func mergingLines(_ lines: [RecognizedLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let widest = lines.map(\.box.width).max() ?? 0
        var out = lines[0].text
        for (p, line) in zip(lines, lines.dropFirst()) {
            let gap = line.box.minY - p.box.maxY
            let lineHeight = max(p.box.height, line.box.height)
            let endsSentence = p.text.last.map { "。！？.!?:：".contains($0) } ?? false
            if gap > lineHeight * 0.8 || (endsSentence && p.box.width < widest * 0.7) || line.box.minY < p.box.minY + lineHeight / 2 {
                out += "\n" + line.text // new paragraph, or another column of the same row
            } else if out.hasSuffix("-"), line.text.first?.isLowercase == true {
                out.removeLast() // a word hyphenated across the break
                out += line.text
            } else {
                out += (isCJK(out.last) || isCJK(line.text.first) ? "" : " ") + line.text
            }
        }
        return out
    }

    private static func isCJK(_ c: Character?) -> Bool {
        guard let scalar = c?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}

/// Closes on Esc. The text view would otherwise take Esc for word completion; while an input method
/// is composing, Esc still goes to it to cancel the composition.
final class RecognitionWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            close()
            return
        }
        super.sendEvent(event)
    }
}

/// The window with the recognised text: editable, copied in one click, wrapped lines merged on request,
/// and translated into a second pane below it.
@MainActor
final class TextRecognitionController: NSObject, NSWindowDelegate {
    private(set) static var open: [TextRecognitionController] = []
    /// Set by the silent e2e test: receives the controller instead of the window being shown.
    static var testPresenter: ((TextRecognitionController) -> Void)?

    let image: CGImage
    private(set) var lines: [RecognizedLine]?
    private(set) var failure: String?
    private(set) var elapsed: TimeInterval = 0
    let window: NSWindow
    private(set) var textView: NSTextView!
    private(set) var translationView: NSTextView!
    private var translationScroll: NSScrollView!
    let mergeBox = NSButton(checkboxWithTitle: "合并换行", target: nil, action: nil)
    let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "正在识别…")
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制全部", target: nil, action: nil)
    /// Whether the translation pane is showing; once shown it follows the text and the target language.
    private(set) var translating: Bool
    /// The translation once finished, nil while it runs or after it failed.
    private(set) var translation: String?
    private(set) var translationFailure: String?
    private(set) var translationRunning = false
    private var translationRun = 0

    /// Recognises `image` and shows the result; `near` is the selection on screen, for placing the window.
    /// With `translating` the text is translated as soon as it is read.
    static func present(_ image: CGImage, near: CGRect?, translating: Bool = false) {
        let controller = TextRecognitionController(image: image, translating: translating)
        open.append(controller)
        if let testPresenter {
            testPresenter(controller)
        } else {
            controller.show(near: near)
        }
        controller.start()
    }

    private init(image: CGImage, translating: Bool) {
        self.image = image
        self.translating = translating
        window = RecognitionWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: translating ? 460 : 340),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = translating ? "截图翻译" : "识别文字"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 480, height: 200)
        window.delegate = self
        build()
    }

    private static func textPane() -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 14)
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = CGSize(width: 6, height: 8)
        return (scroll, text)
    }

    private func build() {
        let (scroll, text) = Self.textPane()
        textView = text
        let (tScroll, tText) = Self.textPane()
        translationScroll = tScroll
        translationView = tText
        tScroll.isHidden = !translating
        let panes = NSStackView(views: [scroll, tScroll])
        panes.orientation = .vertical
        panes.distribution = .fillEqually
        panes.spacing = 1

        mergeBox.target = self
        mergeBox.action = #selector(mergeChanged)
        mergeBox.state = Self.mergesLines ? .on : .off
        mergeBox.toolTip = "把折行接回整段文字"
        targetPopup.addItems(withTitles: ScreenTranslator.Target.allCases.map(\.title))
        targetPopup.selectItem(at: (Self.testPresenter == nil ? ScreenTranslator.target : .auto).rawValue)
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.controlSize = .small
        targetPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        translateButton.bezelStyle = .rounded
        translateButton.target = self
        translateButton.action = #selector(translateNow)
        translateButton.toolTip = "翻译上面的文字（改过的也行）"
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = .command
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSView()
        for v in [panes, mergeBox, status, targetPopup, translateButton, copyButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            panes.topAnchor.constraint(equalTo: content.topAnchor),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),
            mergeBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            mergeBox.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: mergeBox.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: targetPopup.leadingAnchor, constant: -10),
            targetPopup.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            targetPopup.trailingAnchor.constraint(equalTo: translateButton.leadingAnchor, constant: -6),
            translateButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            translateButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        updateCopyButton()
    }

    var text: String { textView.string }

    private func show(near selection: CGRect?) {
        // Beside the selection when there is room, else centred on its screen.
        let screen = NSScreen.screens.first { selection.map($0.frame.intersects) ?? false } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            var frame = window.frame
            if let s = selection, s.maxX + 16 + frame.width <= area.maxX {
                frame.origin = CGPoint(x: s.maxX + 16, y: min(max(s.maxY - frame.height, area.minY), area.maxY - frame.height))
            } else if let s = selection, s.minX - 16 - frame.width >= area.minX {
                frame.origin = CGPoint(x: s.minX - 16 - frame.width, y: min(max(s.maxY - frame.height, area.minY), area.maxY - frame.height))
            } else {
                frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            }
            window.setFrame(frame, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func start() {
        let started = Date()
        Task { @MainActor in
            do {
                lines = try await TextRecognizer.recognize(image)
            } catch {
                failure = error.localizedDescription
                lines = []
            }
            elapsed = Date().timeIntervalSince(started)
            fill()
        }
    }

    private func fill() {
        guard let lines else { return }
        textView.string = mergeBox.state == .on ? TextRecognizer.mergingLines(lines) : TextRecognizer.keepingLines(lines)
        showRecognitionStatus()
        translateButton.isEnabled = !lines.isEmpty
        window.makeFirstResponder(textView)
        if translating { translateNow() }
    }

    private func showRecognitionStatus() {
        guard let lines else { return }
        if let failure {
            status.stringValue = "识别失败：\(failure)"
        } else if lines.isEmpty {
            status.stringValue = "没有识别到文字"
        } else {
            status.stringValue = String(format: "%d 行 · %.1f 秒", lines.count, elapsed)
        }
    }

    /// Translates the text as it is in the upper pane, edits included.
    @objc func translateNow() {
        let source = text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !translating {
            translating = true
            translationScroll.isHidden = false
            if Self.testPresenter == nil, window.frame.height < 420 {
                var frame = window.frame
                frame.origin.y -= 460 - frame.height
                frame.size.height = 460
                window.setFrame(frame, display: true, animate: true)
            }
        }
        translationRun += 1
        let run = translationRun
        translation = nil
        translationFailure = nil
        translationRunning = true
        translationView.string = ""
        status.stringValue = "正在翻译…"
        updateCopyButton()
        let started = Date()
        let target = ScreenTranslator.Target(rawValue: targetPopup.indexOfSelectedItem) ?? .auto
        Task { @MainActor in
            do {
                let (from, to) = try ScreenTranslator.languages(for: source, target: target)
                let result = try await ScreenTranslator.translate(source, from: from, to: to)
                guard run == translationRun else { return } // a newer translation has started
                translation = result
                translationView.string = result
                status.stringValue = String(format: "%@ → %@ · %.1f 秒", ScreenTranslator.name(of: from), ScreenTranslator.name(of: to),
                                            Date().timeIntervalSince(started))
            } catch {
                guard run == translationRun else { return }
                translationFailure = error.localizedDescription
                translationView.string = error.localizedDescription
                status.stringValue = "翻译失败"
            }
            translationRunning = false
            updateCopyButton()
        }
    }

    private func updateCopyButton() {
        copyButton.title = translating ? "复制译文" : "复制全部"
        copyButton.toolTip = translating ? "复制译文 ⌘↩" : "复制全部文字 ⌘↩"
        copyButton.isEnabled = translating ? translation != nil : !(lines ?? []).isEmpty
    }

    /// Remembered between results.
    static var mergesLines: Bool {
        get { UserDefaults.standard.bool(forKey: "ocrMergesLines") }
        set { UserDefaults.standard.set(newValue, forKey: "ocrMergesLines") }
    }

    @objc private func mergeChanged() {
        if Self.testPresenter == nil { Self.mergesLines = mergeBox.state == .on }
        fill()
    }

    @objc private func targetChanged() {
        if Self.testPresenter == nil, let t = ScreenTranslator.Target(rawValue: targetPopup.indexOfSelectedItem) { ScreenTranslator.target = t }
        if translating { translateNow() }
    }

    /// Copies the translation once the pane is showing, else the recognised text; edits included.
    @objc func copyAll() {
        let copied = translating ? translationView.string : text
        let pb = ImageOutput.pasteboard
        pb.clearContents()
        pb.setString(copied, forType: .string)
        if Self.testPresenter == nil { Toast.show("已复制 \(copied.count) 个字") }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    func close() {
        window.close()
        Self.open.removeAll { $0 === self }
    }
}
