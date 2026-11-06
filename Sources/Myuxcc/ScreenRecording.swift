import AVFoundation
import AppKit
import ScreenCaptureKit

/// Encodes frames into an H.264 MP4 as they arrive. Frames come only when the screen changed, so the
/// file has a variable frame rate; the session ends at the stop time, so a still screen at the end lasts.
final class VideoFileWriter: @unchecked Sendable {
    let url: URL
    /// Encoded size in pixels; H.264 needs even sides.
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var last = CMTime.invalid
    private(set) var framesWritten = 0

    static func evenSize(_ value: Int) -> Int { max(2, value & ~1) }

    init(url: URL, width: Int, height: Int, framesPerSecond: Int) throws {
        self.url = url
        self.width = Self.evenSize(width)
        self.height = Self.evenSize(height)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitRate = max(2_000_000, self.width * self.height * framesPerSecond / 10)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// Adds a frame shown from `time` on; false when it was dropped (encoder busy, or out of order).
    @discardableResult
    func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        if !started {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard writer.status == .writing, !last.isValid || time > last, input.isReadyForMoreMediaData,
              adaptor.append(buffer, withPresentationTime: time) else { return false }
        last = time
        framesWritten += 1
        return true
    }

    /// Closes the file, holding the last frame until `end`; false when nothing was written or it failed.
    func finish(at end: CMTime?, completion: @escaping (Bool) -> Void) {
        guard started, framesWritten > 0 else {
            if started { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            completion(false)
            return
        }
        input.markAsFinished()
        if let end, end > last { writer.endSession(atSourceTime: end) }
        writer.finishWriting { [writer] in completion(writer.status == .completed) }
    }

    func cancel() {
        if started { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Frames of a screen region from an `SCStream`, written to a video file on a background queue.
final class RegionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let framesPerSecond = 30

    let writer: VideoFileWriter
    private let queue = DispatchQueue(label: "Myuxcc.recording", qos: .userInteractive)
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private var stream: SCStream?
    private var stopped = false
    private let onError: @MainActor (Error) -> Void

    /// `configuration` carries the region (`sourceRect`) and its size in pixels.
    init(filter: SCContentFilter, configuration base: SCStreamConfiguration, to url: URL,
         onError: @escaping @MainActor (Error) -> Void) throws {
        writer = try VideoFileWriter(url: url, width: base.width, height: base.height, framesPerSecond: Self.framesPerSecond)
        let config = base
        // The stream scales the region to exactly the encoded size.
        config.width = writer.width
        config.height = writer.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        self.filter = filter
        self.config = config
        self.onError = onError
        super.init()
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops capturing and closes the file; `completion` gets whether a video was written.
    func stop(completion: @escaping @MainActor (Bool) -> Void) {
        // Stream timestamps are on the host clock: the video lasts until now even if the screen was still.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let finish = { [self] in
            queue.async { [self] in
                stopped = true
                writer.finish(at: end) { ok in DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } } }
            }
        }
        if let stream { stream.stopCapture { _ in finish() } } else { finish() }
    }

    func cancel() {
        stream?.stopCapture { _ in }
        queue.async { [self] in
            stopped = true
            writer.cancel()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        writer.append(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let onError = self.onError
        DispatchQueue.main.async { MainActor.assumeIsolated { onError(error) } }
    }
}

/// Recording of a selected region: a dashed frame marks the region, a small bar beside it shows the
/// time with stop and discard buttons. The capture shortcut (or the menu bar) also stops it.
@MainActor
final class RecordingController: NSObject {
    /// Region in the screen's top-left coordinates, in points.
    let selection: CGRect
    private let screen: NSScreen
    private let border: NSPanel
    private let hud: NSPanel
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSImageView()
    private var recorder: RegionRecorder?
    private var startDate: Date?
    private var timer: Timer?
    private var finished = false
    private let temporaryURL: URL
    private let onFinish: (URL?) -> Void

    init(screen: NSScreen, selection: CGRect, onFinish: @escaping (URL?) -> Void) {
        self.screen = screen
        self.selection = selection
        self.onFinish = onFinish
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("Myuxcc-录屏-\(UUID().uuidString).mp4")
        border = Self.panel(ignoresMouse: true)
        hud = Self.panel(ignoresMouse: false)
        super.init()
        border.contentView = RecordingBorderView()
        buildHUD()
    }

    /// The region in AppKit's global (bottom-left) coordinates.
    private var region: CGRect {
        let frame = screen.frame
        return CGRect(x: frame.minX + selection.minX, y: frame.maxY - selection.maxY, width: selection.width, height: selection.height)
    }

    func start() {
        border.setFrame(region.insetBy(dx: -RecordingBorderView.inset, dy: -RecordingBorderView.inset), display: true)
        border.orderFrontRegardless()
        layoutHUD()
        hud.orderFrontRegardless()
        Task { await run() }
    }

    private func run() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !finished else { return }
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                fail("找不到当前屏幕"); return
            }
            // Our frame and bar stay out even when they overlap the region; pins and other windows of
            // the app are recorded like everything else on screen.
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownIDs = Set([border, hud].map { CGWindowID($0.windowNumber) })
            let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == pid },
                                         exceptingWindows: content.windows.filter {
                                             $0.owningApplication?.processID == pid && !ownIDs.contains($0.windowID)
                                         })
            let config = SCStreamConfiguration()
            config.sourceRect = selection
            let scale = screen.backingScaleFactor
            config.width = Int((selection.width * scale).rounded())
            config.height = Int((selection.height * scale).rounded())
            config.captureResolution = .best
            let recorder = try RegionRecorder(filter: filter, configuration: config, to: temporaryURL) { [weak self] in
                self?.fail("录屏中断：\($0.localizedDescription)")
            }
            self.recorder = recorder
            try await recorder.start()
            guard !finished else { recorder.cancel(); return }
            startDate = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            fail("无法录屏：\(error.localizedDescription)")
        }
    }

    private func tick() {
        guard let startDate else { return }
        timeLabel.stringValue = Self.elapsedText(Date().timeIntervalSince(startDate))
        dot.alphaValue = dot.alphaValue > 0.5 ? 0.3 : 1
    }

    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Stops and saves the video to the recording folder.
    @objc func stop() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        hud.orderOut(nil)
        border.orderOut(nil)
        guard let recorder else { onFinish(nil); return }
        recorder.stop { [temporaryURL, onFinish] ok in
            guard ok, let url = Self.moveToSaveFolder(temporaryURL) else {
                Toast.show("录屏失败，没有录到画面")
                onFinish(nil)
                return
            }
            Toast.show("录屏已保存到「\(url.deletingLastPathComponent().lastPathComponent)」")
            onFinish(url)
        }
    }

    /// Stops without keeping anything.
    @objc func discard() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        hud.orderOut(nil)
        border.orderOut(nil)
        recorder?.cancel()
        onFinish(nil)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        discard()
        Toast.show(message)
    }

    /// Moves a finished recording into the recording folder as `录屏 <time>.mp4`.
    static func moveToSaveFolder(_ temporary: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Settings.recordingFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("录屏 \(formatter.string(from: Date())).mp4")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("录屏 \(formatter.string(from: Date())) \(n).mp4")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: url)
            return url
        } catch {
            NSLog("Myuxcc: could not save the recording: \(error)")
            return nil
        }
    }

    // MARK: - Panels

    private static func panel(ignoresMouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !ignoresMouse
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

        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "录制中")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        dot.contentTintColor = .systemRed
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stop = ToolbarView.button("stop.circle", "停止并保存", self, #selector(stop))
        stop.contentTintColor = .systemRed
        let discard = ToolbarView.button("trash", "放弃录屏", self, #selector(discard))
        let stack = NSStackView(views: [dot, timeLabel, discard, stop])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 4)
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

    /// Under the region's right end; above it, or inside its bottom edge, when there is no room.
    private func layoutHUD() {
        let frame = screen.frame, visible = screen.visibleFrame, region = region
        let size = hud.contentView?.fittingSize ?? CGSize(width: 180, height: 38)
        var origin = CGPoint(x: region.maxX - size.width, y: region.minY - 10 - size.height)
        if origin.y < visible.minY { origin.y = region.maxY + 10 }
        if origin.y + size.height > visible.maxY { origin.y = region.minY + 10 }
        origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
        hud.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// A dashed red frame just outside the recorded region.
private final class RecordingBorderView: NSView {
    static let inset: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
