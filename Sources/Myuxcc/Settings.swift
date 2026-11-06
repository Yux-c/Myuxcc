import AppKit
import Carbon.HIToolbox

/// User preferences, kept in UserDefaults.
enum Settings {
    /// A global shortcut: virtual key code, Carbon modifier flags, and how it reads in menus (⌃A).
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String

        static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey), display: "⌃A")
        static let shelfDefault = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey), display: "⌃X")

        /// From a key press; nil without ⌃, ⌥ or ⌘ (a bare key or ⇧-key would be taken from every app's typing).
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
            var carbon = 0
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            if flags.contains(.command) { carbon |= cmdKey }
            let key = Self.keyName(event)
            guard !key.isEmpty else { return nil }
            self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon), display: Self.symbols(carbon) + key)
        }

        init(keyCode: UInt32, modifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }

        /// The key alone as a menu key equivalent, when it is a plain character.
        var menuKey: (String, NSEvent.ModifierFlags)? {
            let key = String(display.drop { "⌃⌥⇧⌘".contains($0) })
            guard key.count == 1, let c = key.first, c.isLetter || c.isNumber || c.isPunctuation else { return nil }
            var flags: NSEvent.ModifierFlags = []
            if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            return (key.lowercased(), flags)
        }

        private static func symbols(_ carbon: Int) -> String {
            (carbon & controlKey != 0 ? "⌃" : "") + (carbon & optionKey != 0 ? "⌥" : "")
                + (carbon & shiftKey != 0 ? "⇧" : "") + (carbon & cmdKey != 0 ? "⌘" : "")
        }

        private static func keyName(_ event: NSEvent) -> String {
            let named: [Int: String] = [
                kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
                kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            ]
            if let name = named[Int(event.keyCode)] { return name }
            // The character the key types without modifiers, in the current layout (⌥ and ⌃ change it).
            return (event.charactersIgnoringModifiers ?? "").uppercased().trimmingCharacters(in: .controlCharacters)
        }
    }

    private static let defaults = UserDefaults.standard

    /// Starts a capture.
    static var shortcut: Shortcut {
        get { loadShortcut("hotKey", default: .default) }
        set { saveShortcut(newValue, "hotKey") }
    }

    /// Opens or closes the file shelf.
    static var shelfShortcut: Shortcut {
        get { loadShortcut("shelfHotKey", default: .shelfDefault) }
        set { saveShortcut(newValue, "shelfHotKey") }
    }

    private static func loadShortcut(_ key: String, default value: Shortcut) -> Shortcut {
        guard defaults.object(forKey: key + "Code") != nil, let display = defaults.string(forKey: key + "Display") else { return value }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: key + "Code")),
                        modifiers: UInt32(defaults.integer(forKey: key + "Modifiers")), display: display)
    }

    private static func saveShortcut(_ shortcut: Shortcut, _ key: String) {
        defaults.set(Int(shortcut.keyCode), forKey: key + "Code")
        defaults.set(Int(shortcut.modifiers), forKey: key + "Modifiers")
        defaults.set(shortcut.display, forKey: key + "Display")
    }

    /// Most items the shelf keeps; beyond this the oldest are deleted directly.
    static var shelfMaxItems: Int {
        get {
            let value = defaults.integer(forKey: "shelfMaxItems")
            return value == 0 ? ShelfStorage.defaultMaxItems : min(max(value, ShelfStorage.maxItemsRange.lowerBound), ShelfStorage.maxItemsRange.upperBound)
        }
        set { defaults.set(min(max(newValue, ShelfStorage.maxItemsRange.lowerBound), ShelfStorage.maxItemsRange.upperBound), forKey: "shelfMaxItems") }
    }

    /// Whether copied text, images and files are put on the shelf.
    static var shelfRecordsClipboard: Bool {
        get { defaults.object(forKey: "shelfRecordsClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shelfRecordsClipboard") }
    }

    /// Whether the shelf shows the selected item large on its left.
    static var shelfShowsPreview: Bool {
        get { defaults.object(forKey: "shelfShowsPreview") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "shelfShowsPreview") }
    }

    /// Whether shaking the pointer while dragging opens the shelf.
    static var shelfShakeEnabled: Bool {
        get { defaults.object(forKey: "shelfShakeEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shelfShakeEnabled") }
    }

    /// Whether shaking again while the shelf is open closes it.
    static var shelfShakeCloses: Bool {
        get { defaults.object(forKey: "shelfShakeCloses") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shelfShakeCloses") }
    }

    static var shelfShakeSensitivity: Int {
        get { min(max(defaults.object(forKey: "shelfShakeSensitivity") as? Int ?? 3, ShakeSensitivity.range.lowerBound), ShakeSensitivity.range.upperBound) }
        set { defaults.set(newValue, forKey: "shelfShakeSensitivity") }
    }

    static var desktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

    /// Where ⌘S saves screenshots; the Desktop unless chosen otherwise, and when the chosen folder is gone.
    /// Replaces the saved choice for this process only; used by the silent e2e test.
    static var saveFolderOverride: URL?

    static var saveFolder: URL {
        get {
            if let saveFolderOverride { return saveFolderOverride }
            guard let path = defaults.string(forKey: "saveFolder") else { return desktop }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                ? URL(fileURLWithPath: path, isDirectory: true) : desktop
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }

    /// Where screen recordings go unless chosen otherwise: a folder of their own in Movies, made on first use.
    static var defaultRecordingFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Myuxcc 录屏", isDirectory: true)
    }

    /// Replaces the saved choice for this process only; used by the silent e2e test.
    static var recordingFolderOverride: URL?

    /// Where screen recordings are saved; the default folder when the chosen one is gone.
    static var recordingFolder: URL {
        get {
            if let recordingFolderOverride { return recordingFolderOverride }
            guard let path = defaults.string(forKey: "recordingFolder") else { return defaultRecordingFolder }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                ? URL(fileURLWithPath: path, isDirectory: true) : defaultRecordingFolder
        }
        set { defaults.set(newValue.path, forKey: "recordingFolder") }
    }
}
