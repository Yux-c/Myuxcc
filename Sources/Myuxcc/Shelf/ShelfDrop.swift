import AppKit

/// Turns whatever is dropped on the shelf into files: files, file promises (Photos, Mail attachments,
/// browser images), raw image data and web links.
enum ShelfDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// `.copy` while dragging content the shelf can keep over it, nothing otherwise.
    static func operation(for info: NSDraggingInfo) -> NSDragOperation {
        // Dragging a row back onto the shelf would only duplicate it.
        if info.draggingSource is ShelfRowView { return [] }
        return canRead(info.draggingPasteboard) ? .copy : []
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    @discardableResult
    static func receive(_ info: NSDraggingInfo) -> Bool {
        guard operation(for: info) == .copy else { return false }
        return receive(info.draggingPasteboard)
    }

    /// Starts adding what is on `pasteboard`; false when nothing on it can be kept.
    @discardableResult
    static func receive(_ pasteboard: NSPasteboard, into storage: ShelfStorage = .shared, completion: (([URL]) -> Void)? = nil) -> Bool {
        let done: ([URL]) -> Void = { added in
            if !added.isEmpty {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                NSSound(named: "Pop")?.play()
            }
            completion?(added)
        }
        // 1. Real files from Finder and most apps.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            storage.importItems(urls.map { .file($0, move: false) }, completion: done)
            return true
        }
        // 2. File promises: the source app writes the file on demand.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Myuxcc-Promises-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                    if let error { NSLog("Myuxcc: could not receive a promised file: \(error)"); return }
                    DispatchQueue.main.async { storage.importItems([.file(url, move: true)], completion: done) }
                }
            }
            return true
        }
        // 3. Raw image data, e.g. images dragged out of some editors.
        if let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(ClipboardWatcher.pngData) {
            storage.importItems([.data(png, filename: "图片 \(timestamp()).png")], completion: done)
            return true
        }
        // 4. Web links become .webloc files that open in the browser.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let sources: [ShelfImport] = urls.compactMap { url in
                guard url.scheme == "http" || url.scheme == "https",
                      let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                else { return nil }
                return .data(data, filename: "\(weblocName(for: url)).webloc")
            }
            if !sources.isEmpty {
                storage.importItems(sources, completion: done)
                return true
            }
        }
        return false
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private static func weblocName(for url: URL) -> String {
        let host = url.host ?? "链接"
        let last = url.lastPathComponent
        let name = last.isEmpty || last == "/" ? host : "\(host) - \(last)"
        return String(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(80))
    }
}
