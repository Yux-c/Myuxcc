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
    /// Runs the worker loop; returns only when stdin closes or a request cannot be decoded.
    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        var buffer = Data()

        /// Reads one line; nil at end of input.
        func nextLine() -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return Data(line)
                }
                let chunk = input.availableData
                if chunk.isEmpty { return buffer.isEmpty ? nil : buffer }
                buffer.append(chunk)
            }
        }

        func send(_ text: String) {
            output.write(Data((text + "\n").utf8))
        }

        while let line = nextLine() {
            guard let text = String(data: line, encoding: .utf8), !text.isEmpty else { continue }
            let parts = text.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "OCR",
                  let width = Int(parts[1]), let height = Int(parts[2]),
                  let data = Data(base64Encoded: parts[3]),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                send("FAIL " + Data("坏请求".utf8).base64EncodedString())
                continue
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
        }
        exit(0)
    }
}
