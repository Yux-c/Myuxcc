import AppKit

// A worker process for text recognition when the app's own engine has wedged; see TextRecognitionWorker.
if CommandLine.arguments.contains("--ocr-worker") {
    TextRecognitionWorker.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--replay"), i + 2 < CommandLine.arguments.count {
    FrameRecorder.replay(directory: CommandLine.arguments[i + 1], output: CommandLine.arguments[i + 2])
}

if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    SelfTest.run(output: CommandLine.arguments[i + 1])
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() } // top-level code runs on the main thread
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
