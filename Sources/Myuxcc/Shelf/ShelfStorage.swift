import AppKit

/// An item kept on the shelf: a file dropped in or sent from a screenshot, a copied image (`剪贴板 ….png`),
/// or copied text (kept in `.clip-texts.json`, never as a `.txt` file).
struct ShelvedItem: Equatable {
    static let clipPrefix = "剪贴板 "

    let url: URL
    let addedDate: Date
    let fileSize: Int64
    /// Full text when this item is copied text (not stored as an individual file).
    var clipText: String?

    var name: String { url.lastPathComponent }
    var isFromClipboard: Bool { isClipText || name.hasPrefix(Self.clipPrefix) }
    var isClipText: Bool { clipText != nil }
    /// The row's title: the text itself for copied text, the file name otherwise.
    var title: String { clipText.map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 } ?? name }
    var formattedSize: String {
        if let clipText { return "\(clipText.count >= 2000 ? "2000+" : String(clipText.count)) 字" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    var icon: NSImage { isClipText ? NSWorkspace.shared.icon(for: .plainText) : NSWorkspace.shared.icon(forFile: url.path) }
    var kind: FileKind { isClipText ? .document : FileKind(url: url) }
}

struct ClipTextRecord: Codable {
    var id: String
    var text: String
    var addedDate: Date
}

/// Something dropped on the shelf that becomes a file in its folder.
enum ShelfImport {
    /// An existing file; `move` is for temporary files such as received file promises.
    case file(URL, move: Bool)
    /// Raw content (a screenshot, image data, a web link) written to a new file with this name.
    case data(Data, filename: String)
}

/// The shelf's items: a folder holding file copies plus `.clip-texts.json` for copied text, newest first,
/// trimmed to a fixed number by deleting the oldest one by one.
final class ShelfStorage {
    /// Replaced by the silent e2e test with a storage in its output folder.
    static var shared = ShelfStorage(folder: defaultFolder)

    static let maxItemsRange = 5...100
    /// Copies share the list with files, so it keeps more than MacFileRelay's 20.
    static let defaultMaxItems = 50
    /// 单条剪贴板文本最大保留字符数，防止数万行日志或大段 Base64 撑爆 `.clip-texts.json` 造成主线程解码卡顿与常驻内存膨胀。
    static let maxClipTextCharacters = 50_000

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Myuxcc/Shelf", isDirectory: true)
    }

    let folder: URL
    private var textsFile: URL { folder.appendingPathComponent(".clip-texts.json") }
    /// How a file leaves the shelf: deleted directly without cluttering the Trash.
    private let discard: (URL) throws -> Void
    private let fileManager = FileManager.default
    private let importQueue = DispatchQueue(label: "Myuxcc.shelf-import", qos: .userInitiated)

    private(set) var items: [ShelvedItem] = []
    /// Called on the main thread whenever the files change.
    var onItemsChanged: [() -> Void] = []
    var onImportStateChanged: ((Bool) -> Void)?
    private var pendingImports = 0 {
        didSet { onImportStateChanged?(pendingImports > 0) }
    }

    /// A limit of its own instead of the settings', for the test.
    private var fixedLimit: Int?

    init(folder: URL, discard: ((URL) throws -> Void)? = nil, limit: Int? = nil) {
        self.folder = folder
        fixedLimit = limit
        self.discard = discard ?? { try FileManager.default.removeItem(at: $0) }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        migrateLegacyClipTextFiles()
        reload()
    }

    /// Moves the files of the standalone MacFileRelay app over, once, when it left any behind.
    func adoptMacFileRelayFiles() {
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacFileRelay/ShelvedFiles", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
              !files.isEmpty else { return }
        importItems(files.map { .file($0, move: true) })
    }

    /// Most items kept; beyond this the oldest are deleted directly.
    var maxItems: Int {
        get { fixedLimit ?? Settings.shelfMaxItems }
        set {
            if fixedLimit != nil { fixedLimit = newValue } else { Settings.shelfMaxItems = newValue }
            let limit = maxItems
            importQueue.async {
                if self.trim(to: limit) > 0 { DispatchQueue.main.async { self.reload() } }
            }
        }
    }

    var totalFormattedSize: String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.fileSize }, countStyle: .file)
    }

    private func textURL(for id: String) -> URL {
        folder.appendingPathComponent(".clip-text-\(id)")
    }

    private func loadTextRecords() -> [ClipTextRecord] {
        guard let data = try? Data(contentsOf: textsFile),
              let records = try? JSONDecoder().decode([ClipTextRecord].self, from: data) else { return [] }
        return records
    }

    private func saveTextRecords(_ records: [ClipTextRecord]) {
        if records.isEmpty {
            try? fileManager.removeItem(at: textsFile)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: textsFile, options: .atomic)
        }
    }

    /// Absorbs any old `剪贴板 ….txt` files into `.clip-texts.json` and deletes those `.txt` files directly.
    private func migrateLegacyClipTextFiles() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let legacy = urls.filter { $0.lastPathComponent.hasPrefix(ShelvedItem.clipPrefix) && $0.pathExtension == "txt" }
        guard !legacy.isEmpty else { return }
        var records = loadTextRecords()
        for url in legacy {
            if let text = Self.readText(url, limit: 20000), !text.isEmpty {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? values?.creationDate ?? Date()
                if !records.contains(where: { $0.text == text }) {
                    records.append(ClipTextRecord(id: UUID().uuidString, text: text, addedDate: date))
                }
            }
            try? fileManager.removeItem(at: url)
        }
        saveTextRecords(records)
    }

    func reload() {
        // 同时读取 isDirectoryKey：普通文件直接取 fileSize，文件夹或 .app 包递归统计真实体积，避免显示为 0 KB
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let fileItems = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.isDirectory == true ? ClipboardWatcher.size(of: url) : Int64(values?.fileSize ?? 0)
            return ShelvedItem(url: url, addedDate: values?.contentModificationDate ?? values?.creationDate ?? Date(),
                               fileSize: size)
        }
        let textItems = loadTextRecords().map { record in
            ShelvedItem(url: textURL(for: record.id), addedDate: record.addedDate,
                        fileSize: Int64(record.text.utf8.count), clipText: record.text)
        }
        items = (fileItems + textItems).sorted { $0.addedDate > $1.addedDate }
        onItemsChanged.forEach { $0() }
    }

    /// Writes the sources on a background queue, trims to `maxItems`, then reloads on the main thread.
    /// `completion` receives the files added, in order.
    func importItems(_ sources: [ShelfImport], completion: (([URL]) -> Void)? = nil) {
        guard !sources.isEmpty else { completion?([]); return }
        pendingImports += 1
        let limit = maxItems
        importQueue.async {
            let added = sources.compactMap { self.write($0) }
            if !added.isEmpty { self.trim(to: limit) }
            DispatchQueue.main.async {
                self.pendingImports -= 1
                if !added.isEmpty { self.reload() }
                completion?(added)
            }
        }
    }

    /// Adds a copy unless the shelf already holds the same content: then that one moves to the top.
    /// `completion` gets the file and whether it was already there.
    func importCopy(_ source: ShelfImport, sameAs: @escaping (URL) -> Bool, completion: ((URL?, Bool) -> Void)? = nil) {
        pendingImports += 1
        let limit = maxItems
        importQueue.async {
            let files = (try? self.fileManager.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var result: (URL?, Bool)
            if let existing = files.first(where: sameAs) {
                try? self.fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: existing.path)
                result = (existing, true)
            } else {
                result = (self.write(source), false)
                if result.0 != nil { self.trim(to: limit) }
            }
            DispatchQueue.main.async {
                self.pendingImports -= 1
                if result.0 != nil { self.reload() }
                completion?(result.0, result.1)
            }
        }
    }

    /// Records copied text in `.clip-texts.json` without creating a `.txt` file on disk.
    /// Copying the same text again moves it to the top.
    func importText(_ text: String, completion: ((URL?, Bool) -> Void)? = nil) {
        pendingImports += 1
        let limit = maxItems
        // 对超长文本按上限截断，避免将数十 MB 的巨型文本写入同一个 JSON 文件
        let storedText = text.count > Self.maxClipTextCharacters ? String(text.prefix(Self.maxClipTextCharacters)) : text
        importQueue.async {
            var records = self.loadTextRecords()
            let now = Date()
            let result: (URL, Bool)
            if let index = records.firstIndex(where: { $0.text == storedText }) {
                records[index].addedDate = now
                self.saveTextRecords(records)
                result = (self.textURL(for: records[index].id), true)
            } else {
                let record = ClipTextRecord(id: UUID().uuidString, text: storedText, addedDate: now)
                records.append(record)
                self.saveTextRecords(records)
                self.trim(to: limit)
                result = (self.textURL(for: record.id), false)
            }
            DispatchQueue.main.async {
                self.pendingImports -= 1
                self.reload()
                completion?(result.0, result.1)
            }
        }
    }

    /// Up to `limit` characters of a UTF-8 text file.
    static func readText(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit * 4)) ?? Data()
        // A cut may split a character; drop the broken tail.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\u{FFFD}") { text.removeLast() }
        return String(text.prefix(limit))
    }

    /// Runs on `importQueue`.
    private func write(_ source: ShelfImport) -> URL? {
        do {
            let destination: URL
            switch source {
            case .file(let url, let move):
                destination = uniqueURL(for: url.lastPathComponent)
                if move { try fileManager.moveItem(at: url, to: destination) } else { try fileManager.copyItem(at: url, to: destination) }
            case .data(let data, let filename):
                destination = uniqueURL(for: filename)
                try data.write(to: destination, options: .withoutOverwriting)
            }
            // The added time is the modification date, so copied files sort by when they arrived.
            let now = Date()
            try? fileManager.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: destination.path)
            return destination
        } catch {
            NSLog("Myuxcc: could not add to the shelf: \(error)")
            return nil
        }
    }

    /// Discards the oldest items (files or text records) one by one until at most `limit` remain. Runs on `importQueue`.
    @discardableResult
    private func trim(to limit: Int) -> Int {
        enum Entry {
            case file(URL, Date)
            case text(String, Date)
            var date: Date {
                switch self {
                case .file(_, let d), .text(_, let d): return d
                }
            }
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var records = loadTextRecords()
        let entries: [Entry] = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return .file(url, values?.contentModificationDate ?? values?.creationDate ?? .distantPast)
        } + records.map { .text($0.id, $0.addedDate) }
        guard entries.count > limit else { return 0 }
        var removed = 0
        var removedTextIDs: Set<String> = []
        for entry in entries.sorted(by: { $0.date < $1.date }).prefix(entries.count - limit) {
            switch entry {
            case .file(let url, _):
                do { try discard(url); removed += 1 } catch { NSLog("Myuxcc: could not remove \(url.lastPathComponent) from the shelf: \(error)") }
            case .text(let id, _):
                removedTextIDs.insert(id)
                removed += 1
            }
        }
        if !removedTextIDs.isEmpty {
            records.removeAll { removedTextIDs.contains($0.id) }
            saveTextRecords(records)
        }
        return removed
    }

    func remove(_ item: ShelvedItem) {
        // 统一在 importQueue 中串行执行删除，避免与后台导入或 trim 产生并发文件竞争
        importQueue.sync {
            if item.isClipText {
                var records = self.loadTextRecords()
                records.removeAll { self.textURL(for: $0.id) == item.url || $0.text == item.clipText }
                self.saveTextRecords(records)
            } else {
                try? self.discard(item.url)
            }
        }
        reload()
    }

    func clearAll() {
        // 统一在 importQueue 中清理文本记录与磁盘文件，确保线程安全
        importQueue.sync {
            try? self.fileManager.removeItem(at: self.textsFile)
            let urls = (try? self.fileManager.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in urls { try? self.discard(url) }
        }
        reload()
    }

    private func uniqueURL(for filename: String) -> URL {
        let name = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
        var url = folder.appendingPathComponent(filename)
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)")
            counter += 1
        }
        return url
    }
}
