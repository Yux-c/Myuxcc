import Foundation

/// The app was called ScshootDemo (bundle ID `com.yuxccu.scshootdemo`) before it became Myuxcc. On the first
/// launch under the new name its settings, its Application Support folder (the clipboard shelf and the old
/// clipboard history) and its recordings folder in Movies are carried over. Nothing is deleted: settings
/// are copied, folders are moved only where the new place does not exist yet.
enum LegacyMigration {
    static let oldDomain = "com.yuxccu.scshootdemo"
    static let doneKey = "migratedFromScshootDemo"

    struct Places {
        var defaults: UserDefaults
        var oldDomain: String
        var applicationSupport: URL
        var movies: URL

        static var standard: Places {
            let fm = FileManager.default
            return Places(defaults: .standard, oldDomain: LegacyMigration.oldDomain,
                          applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                          movies: fm.urls(for: .moviesDirectory, in: .userDomainMask)[0])
        }
    }

    /// Runs once; later launches return right away.
    static func run(_ places: Places = .standard) {
        let defaults = places.defaults
        guard !defaults.bool(forKey: doneKey) else { return }
        // Settings already made under the new name win over the old ones.
        if let old = defaults.persistentDomain(forName: places.oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        merge(places.applicationSupport.appendingPathComponent("ScshootDemo", isDirectory: true),
              into: places.applicationSupport.appendingPathComponent("Myuxcc", isDirectory: true))
        merge(places.movies.appendingPathComponent("ScshootDemo 录屏", isDirectory: true),
              into: places.movies.appendingPathComponent("Myuxcc 录屏", isDirectory: true))
        defaults.set(true, forKey: doneKey)
    }

    /// Moves `old` to `new`; when both exist, moves over the items `new` does not have yet.
    private static func merge(_ old: URL, into new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        do {
            if !fm.fileExists(atPath: new.path) {
                try fm.moveItem(at: old, to: new)
                return
            }
            for item in try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                let target = new.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    // Folders on both sides (Shelf, Clipboard) are merged one level further down.
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        merge(item, into: target)
                    } else if item.lastPathComponent == ".clip-texts.json" {
                        // 新旧目录同时存在 `.clip-texts.json` 时，将旧剪贴板文本记录合并进新文件后删除旧文件
                        mergeClipTexts(from: item, into: target)
                        try? fm.removeItem(at: item)
                    }
                } else {
                    try fm.moveItem(at: item, to: target)
                }
            }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        } catch {
            NSLog("Myuxcc: could not move \(old.path) to \(new.path): \(error)")
        }
    }

    /// 合并旧版与新版的 `.clip-texts.json` 剪贴板文本记录（按文本内容去重并按时间倒序保留）。
    private static func mergeClipTexts(from oldFile: URL, into newFile: URL) {
        guard let oldData = try? Data(contentsOf: oldFile),
              let oldRecords = try? JSONDecoder().decode([ClipTextRecord].self, from: oldData),
              !oldRecords.isEmpty else { return }
        var newRecords = (try? Data(contentsOf: newFile)).flatMap { try? JSONDecoder().decode([ClipTextRecord].self, from: $0) } ?? []
        for record in oldRecords where !newRecords.contains(where: { $0.text == record.text }) {
            newRecords.append(record)
        }
        newRecords.sort { $0.addedDate > $1.addedDate }
        if let merged = try? JSONEncoder().encode(newRecords) {
            try? merged.write(to: newFile, options: .atomic)
        }
    }
}
