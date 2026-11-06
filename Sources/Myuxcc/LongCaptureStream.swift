import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Frames of the capture region from an `SCStream`, stitched on a background queue as they arrive.
///
/// A stream delivers frames continuously, up to `framesPerSecond`, and only when the screen changed, so
/// a still page costs nothing; screenshots one by one took ~100 ms a frame. Stitching off the main
/// thread keeps the HUD and the preview responsive. Everything mutable is touched only on `queue`.
final class LongCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let framesPerSecond = 30

    struct Update {
        /// nil for the first frame.
        let status: ScrollStitcher.Status?
        let preview: PreviewSnapshot
    }

    private let queue = DispatchQueue(label: "Myuxcc.LongCapture", qos: .userInteractive)
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private var stream: SCStream?
    private let recorder: FrameRecorder?
    private var stitcher: ScrollStitcher?
    private var stopped = false
    /// Set when stop() arrives before startCapture() has finished; start() then stops the stream again.
    private var stopRequested = false
    private var frames = 0
    private let onUpdate: @MainActor (Update) -> Void
    private let onError: @MainActor (Error) -> Void

    init(filter: SCContentFilter, configuration base: SCStreamConfiguration, recorder: FrameRecorder?,
         onUpdate: @escaping @MainActor (Update) -> Void, onError: @escaping @MainActor (Error) -> Void) {
        let config = base
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        // Frames waiting for the stitcher; with frame recording on, also those being encoded.
        // Key frames can take longer than one 30 fps interval, so leave enough room to avoid the
        // stream dropping frames (a dropped frame is what makes the overlap search fail).
        config.queueDepth = 16
        config.pixelFormat = kCVPixelFormatType_32BGRA
        self.filter = filter
        self.config = config
        self.recorder = recorder
        self.onUpdate = onUpdate
        self.onError = onError
        super.init()
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        // finish() can call stop() while startCapture() is still in flight, in which case stopCapture
        // ran against a stream that was not running yet. Stop once more so it never leaks a live stream.
        if queue.sync(execute: { self.stopRequested }) { try? await stream.stopCapture() }
    }

    /// Stops delivery; frames already queued are dropped.
    func stop() {
        queue.sync { stopped = true; stopRequested = true }
        stream?.stopCapture { _ in }
    }

    /// The long image; call after `stop()`.
    func finish() -> CGImage? {
        queue.sync { stitcher?.finish() }
    }

    /// Frames received so far; the stream sends one only when the region changed.
    var frameCount: Int { queue.sync { frames } }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let image = Self.image(sampleBuffer) else { return }
        frames += 1
        recorder?.save(image)
        let status: ScrollStitcher.Status?
        if let stitcher {
            status = stitcher.add(image)
            if status == .unchanged { return }
        } else {
            guard let first = ScrollStitcher(first: image) else { return }
            stitcher = first
            status = nil
        }
        guard let stitcher else { return }
        let update = Update(status: status, preview: stitcher.snapshot)
        if status == .full || status == .sizeMismatch { stopped = true; stream.stopCapture { _ in } }
        let onUpdate = self.onUpdate
        DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let onError = self.onError
        DispatchQueue.main.async { MainActor.assumeIsolated { onError(error) } }
    }

    /// A complete frame as a CGImage; nil for frames the stream sends while nothing changed.
    private static func image(_ sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }
}
