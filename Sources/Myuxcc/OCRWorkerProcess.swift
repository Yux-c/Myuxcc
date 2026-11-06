import AppKit

/// Talks to the `--ocr-worker` process (see TextRecognitionWorker).
///
/// Used only after the app's own recogniser has failed with the unrecoverable engine error, so the
/// cost of spawning (a few hundred milliseconds warm, ~14 s the very first time a model is compiled)
/// is only paid on the path that used to end in an error message. The worker is also warmed up in the
/// background at launch so a takeover is immediate.
final class OCRWorkerProcess {
    private var process = Process()
    private var toWorker = Pipe()
    private var fromWorker = Pipe()
    private var buffer = Data()
    /// Set once the worker dies; it is restarted on the next request.
    private(set) var failed = false

    /// Whether a worker process is up and warm.
    var isRunning: Bool { process.isRunning && !failed }

    /// The worker's pid, so the e2e test can kill it and check the restart path.
    var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }

    /// How long a single request may take before the worker is considered wedged. The first request
    /// after a reboot compiles the models (~14 s), so the limit is generous; later ones take <200 ms.
    private let replyTimeout: TimeInterval = 60

    static var executable: URL {
        // Inside the app bundle the executable is in Contents/MacOS; re-exec it in worker mode.
        if let url = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }

    /// Starts a worker if there is none. Fresh pipes every time: a pipe belonging to a dead process
    /// never becomes readable again, so reusing it would block forever.
    private func startIfNeeded() throws {
        if process.isRunning { return }
        toWorker = Pipe()
        fromWorker = Pipe()
        process = Process()
        process.executableURL = Self.executable
        process.arguments = ["--ocr-worker"]
        process.standardInput = toWorker
        process.standardOutput = fromWorker
        process.standardError = FileHandle.nullDevice
        buffer.removeAll()
        failed = false
        try process.run()
        NSLog("Myuxcc: started OCR worker pid \(process.processIdentifier)")
    }

    /// Recognises `image`; throws on a worker error, a crash, a wedged worker, or a protocol surprise.
    func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        try startIfNeeded()
        guard let data = ImageOutput.pngData(image) else {
            throw TextRecognizer.Failure.engineUnavailable("编码失败")
        }
        let header = "OCR \(image.width) \(image.height) \(data.base64EncodedString())\n"
        toWorker.fileHandleForWriting.write(Data(header.utf8))

        var lines: [RecognizedLine] = []
        let deadline = Date().addingTimeInterval(replyTimeout)
        while true {
            guard let reply = try readLine(deadline: deadline) else {
                // The worker exited or stopped answering: replace it next time.
                stop()
                throw TextRecognizer.Failure.engineUnavailable("识别进程无响应")
            }
            if reply == "END" { return TextRecognizer.readingOrder(lines) }
            if reply.hasPrefix("FAIL ") {
                let message = reply.dropFirst(5).description
                let decoded = Data(base64Encoded: message).flatMap { String(data: $0, encoding: .utf8) } ?? "识别进程报错"
                throw TextRecognizer.Failure.engineUnavailable(decoded)
            }
            if reply.hasPrefix("LINE ") {
                // LINE <base64 text> <x> <y> <w> <h>
                let parts = reply.split(separator: " ").map(String.init)
                guard parts.count == 6, let text = Data(base64Encoded: parts[1]).flatMap({ String(data: $0, encoding: .utf8) }),
                      let x = Double(parts[2]), let y = Double(parts[3]),
                      let w = Double(parts[4]), let h = Double(parts[5]) else { continue }
                lines.append(RecognizedLine(text: text, box: CGRect(x: x, y: y, width: w, height: h)))
            }
            // "OK <count>" needs no handling: the LINE rows carry the content.
        }
    }

    /// One newline-terminated reply; nil at end of file or when the deadline passes.
    ///
    /// The read polls before touching the pipe, so a worker that dies without closing it cannot hang
    /// the app, and a wedged worker is given up on instead of blocking the user forever.
    private func readLine(deadline: Date) throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard Date() < deadline else { return nil }
            let handle = fromWorker.fileHandleForReading
            guard isReadable(handle, within: 0.2) else { continue }
            let data = handle.availableData
            if data.isEmpty {
                // End of file: the worker is gone.
                guard !buffer.isEmpty else { return nil }
                let rest = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return rest
            }
            buffer.append(data)
        }
    }

    /// Whether `handle` has bytes (or has hung up) within `timeout`, checked without blocking.
    private func isReadable(_ handle: FileHandle, within timeout: TimeInterval) -> Bool {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeout * 1000))
        return ready > 0
    }

    /// Stops the worker; the next request starts a fresh one.
    func stop() {
        failed = true
        if process.isRunning { process.terminate() }
        try? toWorker.fileHandleForWriting.close()
        // 不要在已启动的 Process 上改 standardInput。terminate() 只是发送 SIGTERM，
        // 进程往往仍在运行，Foundation 会抛 NSInvalidArgumentException ("task already launched")；
        // Swift 捕获不到 ObjC 异常，会直接 abort 闪退（截图翻译走到 OCR worker 回退时必现）。
        // startIfNeeded() 每次都会新建 Process 和 Pipe，旧对象由 ARC 回收，无需在这里置空。
    }

    /// Starts the worker and pays the one-off model-compilation cost before it is needed.
    func warmUp() {
        do {
            try startIfNeeded()
        } catch {
            NSLog("Myuxcc: could not start the OCR worker: \(error)")
            return
        }
        guard let image = Self.warmUpImage() else { return }
        _ = try? recognize(image)
    }

    /// A small image with text in both languages, so the Chinese and Latin models both get loaded.
    private static func warmUpImage() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 420, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 420, height: 96))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "预热 Warm up 123", attributes: [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black,
        ]))
        ctx.textPosition = CGPoint(x: 12, y: 30)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    deinit { if process.isRunning { process.terminate() } }
}
