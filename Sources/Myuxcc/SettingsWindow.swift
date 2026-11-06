import AppKit
import ApplicationServices
import ServiceManagement

/// The settings window: launch at login, the capture shortcut, the save folder, long-capture frame
/// recording and the file shelf. Opened with ⌘, while the app is in front, or from the menu bar icon's menu.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum ShortcutKind { case capture, shelf }
    /// Registers a new shortcut; false when another app holds it.
    var applyShortcut: (ShortcutKind, Settings.Shortcut) -> Bool = { _, _ in true }
    /// Called with true while a shortcut field listens, so the current shortcut can be pressed too.
    var suspendShortcut: (ShortcutKind, Bool) -> Void = { _, _ in }
    var recordingChanged: () -> Void = {}
    var shakeSettingsChanged: () -> Void = {}
    var clipboardRecordingChanged: () -> Void = {}

    private let loginBox = NSButton(checkboxWithTitle: "登录时自动打开 Myuxcc", target: nil, action: nil)
    private let loginNote = SettingsWindowController.note("")
    private let recorder = ShortcutField()
    private let shortcutNote = SettingsWindowController.note("")
    private let folderLabel = NSTextField(labelWithString: "")
    private let recordingFolderLabel = NSTextField(labelWithString: "")
    private let recordBox = NSButton(checkboxWithTitle: "记录长截图的每一帧（排查问题用）", target: nil, action: nil)
    private let shelfRecorder = ShortcutField()
    private let shelfShortcutNote = SettingsWindowController.note("")
    private let maxItemsLabel = NSTextField(labelWithString: "")
    private let maxItemsStepper = NSStepper()
    private let clipboardBox = NSButton(checkboxWithTitle: "复制的文字、图片和文件也放进剪贴中转板", target: nil, action: nil)
    private let accessibilityNote = SettingsWindowController.note("")
    private let accessibilityButton = NSButton(title: "允许辅助功能…", target: nil, action: nil)
    private let hoverPreviewBox = NSButton(checkboxWithTitle: "一直在左边显示预览栏", target: nil, action: nil)
    private let previewNote = SettingsWindowController.note("不勾选时，鼠标停在选中的条目上按空格打开 / 关闭预览")
    private let shakeBox = NSButton(checkboxWithTitle: "拖着文件左右晃动鼠标，就在鼠标旁打开", target: nil, action: nil)
    private let shakeCloseBox = NSButton(checkboxWithTitle: "打开时再晃一下就关闭", target: nil, action: nil)
    private let sensitivitySlider = NSSlider(value: 3, minValue: 1, maxValue: 5, target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private(set) var grid: NSGridView?

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Myuxcc 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        loginBox.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginNote.stringValue = status == .requiresApproval ? "需要在「系统设置 › 通用 › 登录项」中允许 Myuxcc" : ""
        setRow(of: loginNote, hidden: loginNote.stringValue.isEmpty)
        // The grid shows a row's views whenever it shows the row, so the note's own isHidden is no guide.
        setRow(of: shelfShortcutNote, hidden: shelfShortcutNote.stringValue.isEmpty)
        recorder.shortcut = Settings.shortcut
        folderLabel.stringValue = (Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = Settings.saveFolder.path
        recordingFolderLabel.stringValue = (Settings.recordingFolder.path as NSString).abbreviatingWithTildeInPath
        recordingFolderLabel.toolTip = Settings.recordingFolder.path
        recordBox.state = FrameRecorder.isOn ? .on : .off
        shelfRecorder.shortcut = Settings.shelfShortcut
        maxItemsStepper.integerValue = Settings.shelfMaxItems
        maxItemsLabel.stringValue = "\(Settings.shelfMaxItems) 个"
        hoverPreviewBox.state = Settings.shelfShowsPreview ? .on : .off
        clipboardBox.state = Settings.shelfRecordsClipboard ? .on : .off
        let trusted = AXIsProcessTrusted()
        accessibilityNote.stringValue = trusted ? "已允许辅助功能：点一下条目就直接粘贴到正在用的应用"
            : "点条目时要替你按 ⌘V，需要辅助功能权限；没允许时只复制，再自己按 ⌘V"
        accessibilityButton.isHidden = trusted
        shakeBox.state = Settings.shelfShakeEnabled ? .on : .off
        shakeCloseBox.state = Settings.shelfShakeCloses ? .on : .off
        sensitivitySlider.integerValue = Settings.shelfShakeSensitivity
        sensitivityLabel.stringValue = ShakeSensitivity.names[Settings.shelfShakeSensitivity - 1]
        for control in [shakeCloseBox, sensitivitySlider] as [NSControl] { control.isEnabled = Settings.shelfShakeEnabled }
    }

    /// Shows whether the shelf shortcut could be registered.
    func setShelfShortcutTaken(_ taken: Bool) {
        shelfShortcutNote.stringValue = taken ? "这个组合已被其他应用占用，请换一个" : ""
        shelfShortcutNote.textColor = .systemRed
        shelfShortcutNote.isHidden = !taken
        setRow(of: shelfShortcutNote, hidden: !taken)
    }

    /// Shows whether the current shortcut could be registered.
    func setShortcutTaken(_ taken: Bool) {
        shortcutNote.stringValue = taken ? "这个组合已被其他应用占用，快捷键暂时不可用，请换一个" : ""
        shortcutNote.textColor = taken ? .systemRed : .secondaryLabelColor
        shortcutNote.isHidden = !taken
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopListening()
        shelfRecorder.stopListening()
    }

    /// The app may have been allowed in System Settings meanwhile.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: - Layout

    private func build() {
        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        shortcutNote.isHidden = true
        recordBox.target = self
        recordBox.action = #selector(toggleRecording)
        recorder.onBegin = { [weak self] in self?.suspendShortcut(.capture, true) }
        recorder.onEnd = { [weak self] new in
            guard let self else { return }
            if let new { Settings.shortcut = new }
            self.suspendShortcut(.capture, false)
            self.setShortcutTaken(!self.applyShortcut(.capture, Settings.shortcut))
            self.recorder.shortcut = Settings.shortcut
        }
        shelfRecorder.onBegin = { [weak self] in self?.suspendShortcut(.shelf, true) }
        shelfRecorder.onEnd = { [weak self] new in
            guard let self else { return }
            if let new { Settings.shelfShortcut = new }
            self.suspendShortcut(.shelf, false)
            self.setShelfShortcutTaken(!self.applyShortcut(.shelf, Settings.shelfShortcut))
            self.shelfRecorder.shortcut = Settings.shelfShortcut
        }
        shelfShortcutNote.isHidden = true
        maxItemsStepper.minValue = Double(ShelfStorage.maxItemsRange.lowerBound)
        maxItemsStepper.maxValue = Double(ShelfStorage.maxItemsRange.upperBound)
        maxItemsStepper.increment = 5
        maxItemsStepper.valueWraps = false
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(maxItemsChanged)
        hoverPreviewBox.target = self
        hoverPreviewBox.action = #selector(toggleHoverPreview)
        clipboardBox.target = self
        clipboardBox.action = #selector(toggleClipboard)
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        for control in [shakeBox, shakeCloseBox, sensitivitySlider] as [NSControl] {
            control.target = self
            control.action = #selector(shakeChanged)
        }
        sensitivitySlider.numberOfTickMarks = 5
        sensitivitySlider.allowsTickMarkValuesOnly = true
        sensitivitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recordingFolderLabel.lineBreakMode = .byTruncatingMiddle
        recordingFolderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reset = Self.button("恢复 ⌃A", #selector(resetShortcut), self)
        let choose = Self.button("选择…", #selector(chooseFolder), self)
        let reveal = Self.button("在访达中显示", #selector(revealFolder), self)
        let chooseRecording = Self.button("选择…", #selector(chooseRecordingFolder), self)
        let revealRecording = Self.button("在访达中显示", #selector(revealRecordingFolder), self)
        let openRecordings = Self.button("打开记录文件夹", #selector(showRecordings), self)
        let resetShelfShortcut = Self.button("恢复 ⌃X", #selector(resetShelfShortcutPressed), self)
        let clearShelf = Self.button("清空剪贴中转板", #selector(clearShelfPressed), self)
        let openShelf = Self.button("在访达中打开", #selector(showShelfFolder), self)
        shelfRecorder.widthAnchor.constraint(equalToConstant: 140).isActive = true

        // Section titles span both columns; found by identity, so adding rows never shifts them.
        var headers: [NSView] = []
        func header(_ text: String) -> NSView {
            let view = Self.header(text)
            headers.append(view)
            return view
        }
        let rows: [[NSView]] = [
            [header("通用"), NSGridCell.emptyContentView],
            [Self.label("启动："), Self.stack([loginBox])],
            [NSGridCell.emptyContentView, loginNote],
            [Self.label("截图快捷键："), Self.stack([recorder, reset])],
            [NSGridCell.emptyContentView, Self.stack([Self.note("点一下输入框再按新组合，须含 ⌃、⌥ 或 ⌘；Esc 取消"), shortcutNote], vertical: true)],
            [header("保存"), NSGridCell.emptyContentView],
            [Self.label("保存位置："), Self.stack([folderLabel, choose, reveal])],
            [NSGridCell.emptyContentView, Self.note("⌘S 和长截图保存都存到这里")],
            [Self.label("录屏位置："), Self.stack([recordingFolderLabel, chooseRecording, revealRecording])],
            [NSGridCell.emptyContentView, Self.note("录屏存成「录屏 时间.mp4」")],
            [header("长截图"), NSGridCell.emptyContentView],
            [Self.label("调试："), Self.stack([recordBox])],
            [NSGridCell.emptyContentView, Self.stack([openRecordings, Self.note("只保留最近 3 次，帧里是屏幕内容，用完记得关")])],
            [header("剪贴中转板"), NSGridCell.emptyContentView],
            [Self.label("打开/收起："), Self.stack([shelfRecorder, resetShelfShortcut])],
            [NSGridCell.emptyContentView, shelfShortcutNote],
            [Self.label("最多保留："), Self.stack([maxItemsLabel, maxItemsStepper, Self.note("超出时最早放进来的自动删除")])],
            [Self.label("剪贴板："), Self.stack([clipboardBox])],
            [Self.label("点击条目："), Self.stack([accessibilityNote, accessibilityButton])],
            [Self.label("预览："), Self.stack([hoverPreviewBox, previewNote], vertical: true)],
            [Self.label("晃动打开："), Self.stack([shakeBox])],
            [NSGridCell.emptyContentView, Self.stack([shakeCloseBox])],
            [Self.label("灵敏度："), Self.stack([sensitivitySlider, sensitivityLabel])],
            [NSGridCell.emptyContentView, Self.stack([clearShelf, openShelf])],
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        for row in rows.indices where headers.contains(where: { $0 === rows[row][0] }) {
            grid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
            grid.row(at: row).topPadding = row == 0 ? 0 : 10
        }
        self.grid = grid
        grid.column(at: 1).width = 360
        recorder.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        window?.contentView = content
    }

    /// Hides the grid row holding `view`, so an empty note leaves no gap.
    private func setRow(of view: NSView, hidden: Bool) {
        guard let grid else { return }
        for i in 0..<grid.numberOfRows where (0..<grid.numberOfColumns).contains(where: { grid.cell(atColumnIndex: $0, rowIndex: i).contentView === view }) {
            grid.row(at: i).isHidden = hidden
        }
    }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func button(_ title: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private static func stack(_ views: [NSView], vertical: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .firstBaseline
        stack.spacing = vertical ? 2 : 8
        return stack
    }

    // MARK: - Actions

    @objc private func toggleLogin() {
        do {
            if loginBox.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
        refresh()
    }

    @objc private func resetShortcut() {
        recorder.stopListening()
        Settings.shortcut = .default
        setShortcutTaken(!applyShortcut(.capture, .default))
        recorder.shortcut = .default
    }

    @objc private func chooseFolder() {
        pickFolder(from: Settings.saveFolder) { Settings.saveFolder = $0 }
    }

    @objc private func chooseRecordingFolder() {
        pickFolder(from: Settings.recordingFolder) { Settings.recordingFolder = $0 }
    }

    private func pickFolder(from current: URL, _ apply: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = "选择"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            apply(url)
            self?.refresh()
        }
    }

    @objc private func revealFolder() { NSWorkspace.shared.open(Settings.saveFolder) }

    @objc private func revealRecordingFolder() {
        try? FileManager.default.createDirectory(at: Settings.recordingFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.recordingFolder)
    }

    @objc private func toggleRecording() {
        FrameRecorder.isOn = recordBox.state == .on
        recordingChanged()
    }

    @objc private func maxItemsChanged() {
        ShelfStorage.shared.maxItems = maxItemsStepper.integerValue
        refresh()
    }

    @objc private func toggleClipboard() {
        Settings.shelfRecordsClipboard = clipboardBox.state == .on
        clipboardRecordingChanged()
    }

    @objc private func requestAccessibility() {
        // Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        refresh()
    }

    @objc private func toggleHoverPreview() { Settings.shelfShowsPreview = hoverPreviewBox.state == .on }

    @objc private func shakeChanged() {
        Settings.shelfShakeEnabled = shakeBox.state == .on
        Settings.shelfShakeCloses = shakeCloseBox.state == .on
        Settings.shelfShakeSensitivity = sensitivitySlider.integerValue
        shakeSettingsChanged()
        refresh()
    }

    @objc private func resetShelfShortcutPressed() {
        shelfRecorder.stopListening()
        Settings.shelfShortcut = .shelfDefault
        setShelfShortcutTaken(!applyShortcut(.shelf, .shelfDefault))
        shelfRecorder.shortcut = .shelfDefault
    }

    @objc private func clearShelfPressed() {
        guard ShelfPanel.confirmClearAll() else { return }
        ShelfStorage.shared.clearAll()
    }

    @objc private func showShelfFolder() { NSWorkspace.shared.open(ShelfStorage.shared.folder) }

    @objc private func showRecordings() {
        try? FileManager.default.createDirectory(at: FrameRecorder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FrameRecorder.root)
    }
}

/// A field that shows a shortcut and, once clicked, takes the next key press with ⌃, ⌥ or ⌘ as the new one.
final class ShortcutField: NSButton {
    var shortcut = Settings.Shortcut.default { didSet { if monitor == nil { title = shortcut.display } } }
    var onBegin: () -> Void = {}
    /// The new shortcut, or nil when cancelled.
    var onEnd: (Settings.Shortcut?) -> Void = { _ in }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.pushOnPushOff)
        title = shortcut.display
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        if monitor != nil { finish(nil); return }
        onBegin()
        state = .on
        title = "按下新组合…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finish(nil); return nil } // Esc
            if let new = Settings.Shortcut(event: event) { self.finish(new) } else { NSSound.beep() }
            return nil
        }
    }

    func stopListening() { if monitor != nil { finish(nil) } }

    private func finish(_ new: Settings.Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = .off
        title = shortcut.display
        onEnd(new)
    }
}
