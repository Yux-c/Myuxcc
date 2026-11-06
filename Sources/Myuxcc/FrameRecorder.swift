import AppKit
import ImageIO

/// Debug aid: saves every frame a long capture takes, so a capture that went wrong can be replayed
/// offline with `--replay`. Off unless switched on in the menu. The frames show whatever was on
/// screen, so they stay on this Mac, under ~/Library/Caches/Myuxcc/long-capture/, and only the
/// latest few recordings are kept.
final class FrameRecorder {
    static let defaultsKey = "recordLongCaptureFrames"
    static let keptRecordings = 3
    /// Cap one recording so a long session cannot fill the disk or pile up thousands of PNG encodes.
    static let maxFrames = 6000

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Myuxcc/long-capture", isDirectory: true)
    }

    let directory: URL
    private var count = 0
    private let queue = DispatchQueue(label: "Myuxcc.FrameRecorder", qos: .utility)

    /// A new recording folder, or nil when recording is off.
    static func start() -> FrameRecorder? {
        // e2e runs would push the user's own recordings out.
        guard isOn, !CommandLine.arguments.contains("--e2e") else { return nil }
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS" // two captures in the same second must not share a folder
        let dir = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        // Names sort by time: drop all but the latest few.
        let old = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.dropLast(keptRecordings)
        old.forEach { try? fm.removeItem(at: $0) }
        NSLog("Myuxcc: recording long-capture frames to \(dir.path)")
        return FrameRecorder(directory: dir)
    }

    private init(directory: URL) { self.directory = directory }

    /// Saves the frame as `frame-NNNN.png` in the background.
    func save(_ image: CGImage) {
        // Fixed-width names must stay lexicographically sorted for --replay; %04d broke that after
        // frame 9999 (~5.5 min at 30 fps), which silently replayed the frames out of order.
        guard count < Self.maxFrames else { return }
        count += 1
        let url = directory.appendingPathComponent(String(format: "frame-%06d.png", count))
        queue.async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// `--replay <dir> <out.png> [--preview-at N ...]`: runs the stitcher over a recording, prints what it
    /// made of each frame, and writes the long image; the preview panel as it looked after frame N goes to
    /// `<out>.preview-N.png`.
    static func replay(directory: String, output: String) -> Never {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }.sorted()
        func load(_ name: String) -> CGImage? {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let first = files.first, let image = load(first), let stitcher = ScrollStitcher(first: image) else {
            print("replay: no frames in \(directory)"); exit(1)
        }
        print("replay: \(files.count) frames, \(image.width)×\(image.height)")
        let args = CommandLine.arguments
        let previewAt = Set(args.indices.filter { args[$0] == "--preview-at" && $0 + 1 < args.count }.compactMap { Int(args[$0 + 1]) })
        for (i, name) in files.enumerated().dropFirst() {
            guard let frame = load(name) else { print("\(name): unreadable"); continue }
            print("\(name): \(stitcher.add(frame)) height \(stitcher.height)")
            if previewAt.contains(i + 1), let png = LongCapturePreviewView.render(stitcher) {
                try? png.write(to: URL(fileURLWithPath: output + ".preview-\(i + 1).png"))
            }
        }
        guard let result = stitcher.finish(), let data = ImageOutput.pngData(result) else { print("replay: finish failed"); exit(1) }
        try? data.write(to: URL(fileURLWithPath: output))
        print("replay: wrote \(result.width)×\(result.height) to \(output)")
        exit(0)
    }
}
