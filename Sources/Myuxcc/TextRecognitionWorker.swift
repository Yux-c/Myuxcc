import AppKit
import Vision

/// `--ocr-worker`: a small process that does the recognising for the app when the app's own Vision
/// engine has wedged.
///
/// Vision's text recogniser runs on the neural engine through E5RT, and that engine can fail inside a
/// process for good: every request then answers `CRImageReaderError 1` with
/// `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options ... Code: 13`
/// until the process exits. Retrying in the same process never helps; a fresh process always works.
/// So when the app sees that error it starts one of these, and the worker can be restarted as often as
/// needed without taking the whole app (and the user's pinned screenshots) down with it.
///
/// Protocol, one request per line on stdin, one reply per line on stdout, base64 so no byte can be
/// mistaken for a separator:
///
///     request:  OCR <width> <height> <base64 png>
///     reply:    OK <count>
///               LINE <base64 text> <x> <y> <width> <height>     (once per line, y from the top)
///               END
///     or:       FAIL <base64 message>
enum TextRecognitionWorker {
    /// 行读取缓冲区收缩阈值（64 KB），超过该大小的请求处理完成后释放底层大容量内存
    private static let maxRetainedBufferCapacity = 64 * 1024

    /// Runs the worker loop; returns only when stdin closes or a request cannot be decoded.
    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        var buffer = Data()
        var bufferNeedsShrink = false

        /// Reads one line; nil at end of input.
        func nextLine() -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    // 读完大消息后若缓冲区为空或剩余量低于阈值，重建 Data 释放超大底层缓冲，防止常驻内存膨胀
                    if buffer.isEmpty {
                        if bufferNeedsShrink {
                            buffer = Data()
                            bufferNeedsShrink = false
                        }
                    } else if bufferNeedsShrink, buffer.count <= maxRetainedBufferCapacity {
                        buffer = Data(buffer)
                        bufferNeedsShrink = false
                    }
                    return line
                }
                // 分片读取标准输入时也包裹 autoreleasepool，避免超大图片分多次读取时 NSData 临时对象堆积
                let chunk = autoreleasepool { input.availableData }
                if chunk.isEmpty {
                    guard !buffer.isEmpty else {
                        buffer = Data()
                        bufferNeedsShrink = false
                        return nil
                    }
                    let rest = Data(buffer)
                    buffer = Data()
                    bufferNeedsShrink = false
                    return rest
                }
                buffer.append(chunk)
                if buffer.count > maxRetainedBufferCapacity {
                    bufferNeedsShrink = true
                }
            }
        }

        func send(_ text: String) {
            output.write(Data((text + "\n").utf8))
        }

        // CLI worker 进程没有 RunLoop，每轮请求必须包裹 autoreleasepool 及时回收 base64、CGImage 与 Vision 自动释放对象
        while true {
            let shouldContinue: Bool = autoreleasepool {
                guard let line = nextLine() else { return false }
                guard let text = String(data: line, encoding: .utf8), !text.isEmpty else { return true }
                let parts = text.split(separator: " ", maxSplits: 3).map(String.init)
                guard parts.count == 4, parts[0] == "OCR",
                      let width = Int(parts[1]), let height = Int(parts[2]),
                      let data = Data(base64Encoded: parts[3]),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    send("FAIL " + Data("坏请求".utf8).base64EncodedString())
                    return true
                }
                _ = width; _ = height // the image itself is authoritative
                do {
                    let lines = try TextRecognizer.recognizeSynchronously(image)
                    send("OK \(lines.count)")
                    for line in lines {
                        send("LINE \(Data(line.text.utf8).base64EncodedString()) \(line.box.minX) \(line.box.minY) \(line.box.width) \(line.box.height)")
                    }
                    send("END")
                } catch {
                    send("FAIL " + Data(error.localizedDescription.utf8).base64EncodedString())
                }
                return true
            }
            if !shouldContinue { break }
        }
        exit(0)
    }
}
