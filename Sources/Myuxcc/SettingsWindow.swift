import AppKit
import ApplicationServices
import ServiceManagement

/// 设置窗口：使用 macOS 原生偏好设置工具栏分为「通用」「截图与录屏」「剪贴中转板」三类，
/// 并以分组卡片形式组织开关、快捷键录制与路径选择等控件。可通过 ⌘, 或菜单栏入口打开。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum ShortcutKind { case capture, shelf }

    /// 设置页签分类。
    enum Pane: String, CaseIterable {
        case general
        case capture
        case shelf

        var title: String {
            switch self {
            case .general: return "通用"
            case .capture: return "截图与录屏"
            case .shelf: return "剪贴中转板"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .capture: return "camera.viewfinder"
            case .shelf: return "tray.full"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("MyuxccSettings.\(rawValue)")
        }
    }

    static let windowWidth: CGFloat = 560

    /// Registers a new shortcut; false when another app holds it.
    var applyShortcut: (ShortcutKind, Settings.Shortcut) -> Bool = { _, _ in true }
    /// Called with true while a shortcut field listens, so the current shortcut can be pressed too.
    var suspendShortcut: (ShortcutKind, Bool) -> Void = { _, _ in }
    var recordingChanged: () -> Void = {}
    var shakeSettingsChanged: () -> Void = {}
    var clipboardRecordingChanged: () -> Void = {}

    private(set) var activePane: Pane = .general

    private let containerView = SettingsContainerView()
    private var paneViews: [Pane: NSView] = [:]
    private var paneCards: [Pane: [SettingsCardView]] = [:]
    private var activePaneConstraints: [NSLayoutConstraint] = []

    // MARK: - 通用控件
    private let loginSwitch = SettingsWindowController.makeSwitch()
    private let loginNoticeRow = SettingsNoticeRow(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, actionTitle: "打开设置…")
    private let recorder = ShortcutField()
    private let resetShortcutButton = SettingsWindowController.smallButton("恢复默认")
    private let shortcutNoticeRow = SettingsNoticeRow(symbol: "exclamationmark.triangle.fill", tint: .systemRed)
    private let shelfRecorder = ShortcutField()
    private let resetShelfShortcutButton = SettingsWindowController.smallButton("恢复默认")
    private let shelfShortcutNoticeRow = SettingsNoticeRow(symbol: "exclamationmark.triangle.fill", tint: .systemRed)
    private var generalCardStartup: SettingsCardView!
    private var generalCardShortcuts: SettingsCardView!

    // MARK: - 截图与录屏控件
    private let saveFolderBadge = PathCapsuleView()
    private let recordingFolderBadge = PathCapsuleView()
    private let recordSwitch = SettingsWindowController.makeSwitch()

    // MARK: - 剪贴中转板控件
    private let clipboardSwitch = SettingsWindowController.makeSwitch()
    private let maxItemsLabel = NSTextField(labelWithString: "")
    private let maxItemsStepper = NSStepper()
    private let hoverPreviewSwitch = SettingsWindowController.makeSwitch()
    private let accessibilityRow = SettingsRowView(title: "点击条目直接粘贴", subtitle: "")
    private let accessibilityBadge = StatusBadgeView(title: "已授权", symbol: "checkmark.circle.fill", tint: .systemGreen)
    private let accessibilityButton = SettingsWindowController.smallButton("允许辅助功能…")
    private let accessibilityAccessory = NSStackView()
    private let shakeSwitch = SettingsWindowController.makeSwitch()
    private let shakeCloseSwitch = SettingsWindowController.makeSwitch()
    private var shakeCloseRow: SettingsRowView!
    private let sensitivitySlider = NSSlider(value: 3, minValue: 1, maxValue: 5, target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private var sensitivityRow: SettingsRowView!
    private let shelfDataRow = SettingsRowView(title: "暂存内容与目录", subtitle: "")
    private let clearShelfButton = SettingsWindowController.smallButton("清空…")

    private var isShortcutTaken = false
    private var isShelfShortcutTaken = false

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: Self.windowWidth, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Myuxcc 设置"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
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

    /// 切换当前显示的设置分类，并按需平滑调整窗口高度（保持窗口左上角锚点不动）。
    func selectPane(_ pane: Pane, animate: Bool = true) {
        recorder.stopListening()
        shelfRecorder.stopListening()
        activePane = pane
        window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier

        guard let nextView = paneViews[pane] else { return }
        // 移除旧页面并清理旧约束，确保各分类互不干扰
        containerView.subviews.forEach { $0.removeFromSuperview() }
        NSLayoutConstraint.deactivate(activePaneConstraints)

        nextView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(nextView)

        // 底部约束使用较高但非强制优先级，避免窗口高度动画插值时触发 Auto Layout 冲突日志
        let bottom = nextView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        bottom.priority = .defaultHigh
        let width = nextView.widthAnchor.constraint(equalToConstant: Self.windowWidth)
        width.priority = .init(999)
        activePaneConstraints = [
            nextView.topAnchor.constraint(equalTo: containerView.topAnchor),
            nextView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bottom,
            width,
        ]
        NSLayoutConstraint.activate(activePaneConstraints)

        refresh()
        resizeWindowToFitCurrentPane(animate: animate)
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        loginSwitch.state = status == .enabled || status == .requiresApproval ? .on : .off
        let needsApproval = status == .requiresApproval
        loginNoticeRow.message = needsApproval ? "需要在「系统设置 › 通用 › 登录项」中允许 Myuxcc" : ""
        generalCardStartup.setRow(loginNoticeRow, hidden: !needsApproval)

        recorder.shortcut = Settings.shortcut
        resetShortcutButton.isEnabled = Settings.shortcut != .default
        generalCardShortcuts.setRow(shortcutNoticeRow, hidden: !isShortcutTaken)

        shelfRecorder.shortcut = Settings.shelfShortcut
        resetShelfShortcutButton.isEnabled = Settings.shelfShortcut != .shelfDefault
        generalCardShortcuts.setRow(shelfShortcutNoticeRow, hidden: !isShelfShortcutTaken)

        saveFolderBadge.setPath(Settings.saveFolder.path)
        recordingFolderBadge.setPath(Settings.recordingFolder.path)
        recordSwitch.state = FrameRecorder.isOn ? .on : .off

        maxItemsStepper.integerValue = Settings.shelfMaxItems
        maxItemsLabel.stringValue = "\(Settings.shelfMaxItems) 个"
        hoverPreviewSwitch.state = Settings.shelfShowsPreview ? .on : .off
        clipboardSwitch.state = Settings.shelfRecordsClipboard ? .on : .off

        let trusted = AXIsProcessTrusted()
        accessibilityRow.subtitle = trusted
            ? "已允许辅助功能：点一下条目就直接粘贴到正在用的应用"
            : "替你按 ⌘V 需要辅助功能权限；没允许时点击只复制，再自己按 ⌘V"
        accessibilityBadge.isHidden = !trusted
        accessibilityButton.isHidden = trusted

        let shakeEnabled = Settings.shelfShakeEnabled
        shakeSwitch.state = shakeEnabled ? .on : .off
        shakeCloseSwitch.state = Settings.shelfShakeCloses ? .on : .off
        sensitivitySlider.integerValue = Settings.shelfShakeSensitivity
        sensitivityLabel.stringValue = ShakeSensitivity.names[Settings.shelfShakeSensitivity - 1]
        shakeCloseSwitch.isEnabled = shakeEnabled
        sensitivitySlider.isEnabled = shakeEnabled
        shakeCloseRow.setEnabled(shakeEnabled)
        sensitivityRow.setEnabled(shakeEnabled)

        let shelfItems = ShelfStorage.shared.items
        shelfDataRow.subtitle = shelfItems.isEmpty
            ? "当前暂无暂存条目"
            : "当前共 \(shelfItems.count) 项 · \(ShelfStorage.shared.totalFormattedSize)"
        clearShelfButton.isEnabled = !shelfItems.isEmpty

        if window?.isVisible == true {
            resizeWindowToFitCurrentPane(animate: false)
        }
    }

    /// Shows whether the shelf shortcut could be registered.
    func setShelfShortcutTaken(_ taken: Bool) {
        isShelfShortcutTaken = taken
        shelfShortcutNoticeRow.message = taken ? "这个组合已被其他应用占用，请换一个" : ""
        generalCardShortcuts.setRow(shelfShortcutNoticeRow, hidden: !taken)
        if activePane == .general { resizeWindowToFitCurrentPane(animate: false) }
    }

    /// Shows whether the current shortcut could be registered.
    func setShortcutTaken(_ taken: Bool) {
        isShortcutTaken = taken
        shortcutNoticeRow.message = taken ? "这个组合已被其他应用占用，快捷键暂时不可用，请换一个" : ""
        generalCardShortcuts.setRow(shortcutNoticeRow, hidden: !taken)
        if activePane == .general { resizeWindowToFitCurrentPane(animate: false) }
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopListening()
        shelfRecorder.stopListening()
    }

    /// The app may have been allowed in System Settings meanwhile.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    /// 供自测与布局校验读取当前分类下的卡片列表。
    func cards(for pane: Pane) -> [SettingsCardView] { paneCards[pane] ?? [] }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }),
              pane != activePane else { return }
        selectPane(pane, animate: true)
    }

    // MARK: - Layout

    private func build() {
        configureControls()

        let toolbar = NSToolbar(identifier: "MyuxccSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .preference

        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true
        containerView.onSwitchTabCommand = { [weak self] index in
            guard let self, !self.recorder.isListening, !self.shelfRecorder.isListening,
                  Pane.allCases.indices.contains(index) else { return false }
            self.selectPane(Pane.allCases[index], animate: true)
            return true
        }
        window?.contentView = containerView

        paneViews[.general] = buildGeneralPane()
        paneViews[.capture] = buildCapturePane()
        paneViews[.shelf] = buildShelfPane()

        // 当中转板条目发生变化时，同步更新设置页里的计数与大小提示
        ShelfStorage.shared.onItemsChanged.append { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }
        }

        selectPane(.general, animate: false)
    }

    private func configureControls() {
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        loginNoticeRow.onAction = { [weak self] in self?.openLoginItemsSettings() }

        recorder.onBegin = { [weak self] in self?.suspendShortcut(.capture, true) }
        recorder.onEnd = { [weak self] new in
            guard let self else { return }
            if let new { Settings.shortcut = new }
            self.suspendShortcut(.capture, false)
            self.setShortcutTaken(!self.applyShortcut(.capture, Settings.shortcut))
            self.recorder.shortcut = Settings.shortcut
            self.resetShortcutButton.isEnabled = Settings.shortcut != .default
        }
        resetShortcutButton.target = self
        resetShortcutButton.action = #selector(resetShortcut)
        resetShortcutButton.toolTip = "恢复为默认快捷键 \(Settings.Shortcut.default.display)"

        shelfRecorder.onBegin = { [weak self] in self?.suspendShortcut(.shelf, true) }
        shelfRecorder.onEnd = { [weak self] new in
            guard let self else { return }
            if let new { Settings.shelfShortcut = new }
            self.suspendShortcut(.shelf, false)
            self.setShelfShortcutTaken(!self.applyShortcut(.shelf, Settings.shelfShortcut))
            self.shelfRecorder.shortcut = Settings.shelfShortcut
            self.resetShelfShortcutButton.isEnabled = Settings.shelfShortcut != .shelfDefault
        }
        resetShelfShortcutButton.target = self
        resetShelfShortcutButton.action = #selector(resetShelfShortcutPressed)
        resetShelfShortcutButton.toolTip = "恢复为默认快捷键 \(Settings.Shortcut.shelfDefault.display)"

        recordSwitch.target = self
        recordSwitch.action = #selector(toggleRecording)

        clipboardSwitch.target = self
        clipboardSwitch.action = #selector(toggleClipboard)

        maxItemsLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        maxItemsLabel.textColor = .secondaryLabelColor
        maxItemsLabel.alignment = .right
        maxItemsLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        maxItemsStepper.controlSize = .small
        maxItemsStepper.minValue = Double(ShelfStorage.maxItemsRange.lowerBound)
        maxItemsStepper.maxValue = Double(ShelfStorage.maxItemsRange.upperBound)
        maxItemsStepper.increment = 5
        maxItemsStepper.valueWraps = false
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(maxItemsChanged)

        hoverPreviewSwitch.target = self
        hoverPreviewSwitch.action = #selector(toggleHoverPreview)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        accessibilityAccessory.orientation = .horizontal
        accessibilityAccessory.alignment = .centerY
        accessibilityAccessory.spacing = 6
        accessibilityAccessory.detachesHiddenViews = true
        accessibilityAccessory.addArrangedSubview(accessibilityBadge)
        accessibilityAccessory.addArrangedSubview(accessibilityButton)

        for control in [shakeSwitch, shakeCloseSwitch, sensitivitySlider] as [NSControl] {
            control.target = self
            control.action = #selector(shakeChanged)
        }
        sensitivitySlider.controlSize = .small
        sensitivitySlider.numberOfTickMarks = 5
        sensitivitySlider.allowsTickMarkValuesOnly = true
        sensitivitySlider.widthAnchor.constraint(equalToConstant: 132).isActive = true

        sensitivityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sensitivityLabel.textColor = .secondaryLabelColor
        sensitivityLabel.alignment = .right
        sensitivityLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        clearShelfButton.target = self
        clearShelfButton.action = #selector(clearShelfPressed)
        clearShelfButton.title = "清空…"
    }

    private func buildGeneralPane() -> NSView {
        let loginRow = SettingsRowView(
            title: "登录时自动打开 Myuxcc",
            subtitle: "开机进入桌面后在菜单栏静默待命",
            accessory: loginSwitch
        )
        generalCardStartup = SettingsCardView(rows: [loginRow, loginNoticeRow])

        let captureShortcutControls = Self.horizontalStack([recorder, resetShortcutButton], spacing: 8)
        let captureShortcutRow = SettingsRowView(
            title: "截图 / 停止录屏",
            subtitle: "在任意界面按下即可框选截图或结束录屏",
            accessory: captureShortcutControls
        )

        let shelfShortcutControls = Self.horizontalStack([shelfRecorder, resetShelfShortcutButton], spacing: 8)
        let shelfShortcutRow = SettingsRowView(
            title: "打开 / 收起剪贴中转板",
            subtitle: "随时呼出剪贴板历史与文件暂存架",
            accessory: shelfShortcutControls
        )
        generalCardShortcuts = SettingsCardView(rows: [
            captureShortcutRow,
            shortcutNoticeRow,
            shelfShortcutRow,
            shelfShortcutNoticeRow,
        ])

        paneCards[.general] = [generalCardStartup, generalCardShortcuts]

        return Self.paneStack([
            SettingsSectionView(title: "启动", card: generalCardStartup),
            SettingsSectionView(
                title: "全局快捷键",
                card: generalCardShortcuts,
                footer: "点击快捷键框后按下新组合键，须包含 ⌃、⌥ 或 ⌘；按 Esc 取消"
            ),
        ])
    }

    private func buildCapturePane() -> NSView {
        let chooseSave = Self.smallButton("选择…", #selector(chooseFolder), self)
        let revealSave = Self.iconButton("arrow.up.forward.square", toolTip: "在访达中显示", #selector(revealFolder), self)
        let saveRow = SettingsRowView(
            title: "截图与长截图",
            subtitle: "按 ⌘S 或保存长截图时存入此目录",
            accessory: Self.horizontalStack([saveFolderBadge, chooseSave, revealSave], spacing: 6)
        )

        let chooseRecording = Self.smallButton("选择…", #selector(chooseRecordingFolder), self)
        let revealRecording = Self.iconButton("arrow.up.forward.square", toolTip: "在访达中显示", #selector(revealRecordingFolder), self)
        let recordingRow = SettingsRowView(
            title: "区域录屏",
            subtitle: "录屏存成「录屏 时间.mp4」",
            accessory: Self.horizontalStack([recordingFolderBadge, chooseRecording, revealRecording], spacing: 6)
        )
        let storageCard = SettingsCardView(rows: [saveRow, recordingRow])

        let debugToggleRow = SettingsRowView(
            title: "记录长截图的每一帧",
            subtitle: "排查拼接问题用；只保留最近 3 次（含屏幕内容，用完记得关）",
            accessory: recordSwitch
        )
        let openRecordings = Self.smallButton("打开记录文件夹", #selector(showRecordings), self)
        let debugFolderRow = SettingsRowView(
            title: "调试帧记录",
            subtitle: "查看每次长截图捕获的原始帧图像",
            accessory: openRecordings
        )
        let debugCard = SettingsCardView(rows: [debugToggleRow, debugFolderRow])

        paneCards[.capture] = [storageCard, debugCard]

        return Self.paneStack([
            SettingsSectionView(title: "文件保存位置", card: storageCard),
            SettingsSectionView(title: "长截图调试", card: debugCard),
        ])
    }

    private func buildShelfPane() -> NSView {
        let clipboardRow = SettingsRowView(
            title: "自动收录剪贴板内容",
            subtitle: "复制的文字、图片和文件也会放进剪贴中转板",
            accessory: clipboardSwitch
        )
        let maxItemsRow = SettingsRowView(
            title: "最多保留条目",
            subtitle: "超出上限时最早放进来的条目会自动删除",
            accessory: Self.horizontalStack([maxItemsLabel, maxItemsStepper], spacing: 6)
        )
        let storageCard = SettingsCardView(rows: [clipboardRow, maxItemsRow])

        let previewRow = SettingsRowView(
            title: "一直在左边显示预览栏",
            subtitle: "关闭时，鼠标停在选中的条目上按空格打开 / 关闭预览",
            accessory: hoverPreviewSwitch
        )
        accessibilityRow.setAccessory(accessibilityAccessory)
        let previewCard = SettingsCardView(rows: [previewRow, accessibilityRow])

        let shakeOpenRow = SettingsRowView(
            title: "拖着文件左右晃动鼠标打开",
            subtitle: "拖拽文件时就在鼠标指针旁即时打开",
            accessory: shakeSwitch
        )
        shakeCloseRow = SettingsRowView(
            title: "打开时再晃一下就关闭",
            accessory: shakeCloseSwitch
        )
        sensitivityRow = SettingsRowView(
            title: "晃动灵敏度",
            accessory: Self.horizontalStack([sensitivitySlider, sensitivityLabel], spacing: 8)
        )
        let shakeCard = SettingsCardView(rows: [shakeOpenRow, shakeCloseRow, sensitivityRow])

        let openShelf = Self.smallButton("在访达中打开", #selector(showShelfFolder), self)
        shelfDataRow.setAccessory(Self.horizontalStack([openShelf, clearShelfButton], spacing: 8))
        let dataCard = SettingsCardView(rows: [shelfDataRow])

        paneCards[.shelf] = [storageCard, previewCard, shakeCard, dataCard]

        return Self.paneStack([
            SettingsSectionView(title: "收集与容量", card: storageCard),
            SettingsSectionView(title: "预览与粘贴", card: previewCard),
            SettingsSectionView(title: "拖拽晃动呼出", card: shakeCard),
            SettingsSectionView(title: "数据管理", card: dataCard),
        ])
    }

    private func resizeWindowToFitCurrentPane(animate: Bool) {
        guard let window, let activeView = paneViews[activePane] else { return }
        containerView.layoutSubtreeIfNeeded()
        let contentHeight = ceil(activeView.fittingSize.height)
        let contentSize = CGSize(width: Self.windowWidth, height: max(contentHeight, 120))
        let frameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let current = window.frame
        let target = CGRect(
            x: current.origin.x,
            y: current.maxY - frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )
        guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }
        window.setFrame(target, display: true, animate: animate && window.isVisible)
    }

    // MARK: - Helpers

    private static func makeSwitch() -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        return toggle
    }

    private static func smallButton(_ title: String, _ action: Selector? = nil, _ target: AnyObject? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private static func iconButton(_ symbol: String, toolTip: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = target
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private static func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private static func paneStack(_ sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return wrapper
    }

    // MARK: - Actions

    @objc private func toggleLogin() {
        do {
            if loginSwitch.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
        refresh()
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetShortcut() {
        recorder.stopListening()
        Settings.shortcut = .default
        setShortcutTaken(!applyShortcut(.capture, .default))
        recorder.shortcut = .default
        resetShortcutButton.isEnabled = false
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
        FrameRecorder.isOn = recordSwitch.state == .on
        recordingChanged()
    }

    @objc private func maxItemsChanged() {
        ShelfStorage.shared.maxItems = maxItemsStepper.integerValue
        refresh()
    }

    @objc private func toggleClipboard() {
        Settings.shelfRecordsClipboard = clipboardSwitch.state == .on
        clipboardRecordingChanged()
    }

    @objc private func requestAccessibility() {
        // Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        refresh()
    }

    @objc private func toggleHoverPreview() { Settings.shelfShowsPreview = hoverPreviewSwitch.state == .on }

    @objc private func shakeChanged() {
        Settings.shelfShakeEnabled = shakeSwitch.state == .on
        Settings.shelfShakeCloses = shakeCloseSwitch.state == .on
        Settings.shelfShakeSensitivity = sensitivitySlider.integerValue
        shakeSettingsChanged()
        refresh()
    }

    @objc private func resetShelfShortcutPressed() {
        shelfRecorder.stopListening()
        Settings.shelfShortcut = .shelfDefault
        setShelfShortcutTaken(!applyShortcut(.shelf, .shelfDefault))
        shelfRecorder.shortcut = .shelfDefault
        resetShelfShortcutButton.isEnabled = false
    }

    @objc private func clearShelfPressed() {
        guard ShelfPanel.confirmClearAll() else { return }
        ShelfStorage.shared.clearAll()
        refresh()
    }

    @objc private func showShelfFolder() { NSWorkspace.shared.open(ShelfStorage.shared.folder) }

    @objc private func showRecordings() {
        try? FileManager.default.createDirectory(at: FrameRecorder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FrameRecorder.root)
    }
}

// MARK: - Supporting UI Components

/// 容器视图：响应 ⌘1 / ⌘2 / ⌘3 快速切换分类标签。
private final class SettingsContainerView: NSView {
    var onSwitchTabCommand: ((Int) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...3).contains(digit) {
            if onSwitchTabCommand?(digit - 1) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 分组区块：上方标题 + 圆角分组卡片 + 可选底部辅助说明。
private final class SettingsSectionView: NSView {
    init(title: String, card: SettingsCardView, footer: String? = nil) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = NSTextField(labelWithString: title)
        headerLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        headerLabel.textColor = .labelColor
        let headerWrap = Self.indented(headerLabel, inset: 10)
        stack.addArrangedSubview(headerWrap)
        stack.addArrangedSubview(card)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerWrap.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        if let footer {
            let footerLabel = NSTextField(wrappingLabelWithString: footer)
            footerLabel.font = .systemFont(ofSize: 11)
            footerLabel.textColor = .secondaryLabelColor
            let footerWrap = Self.indented(footerLabel, inset: 10)
            stack.addArrangedSubview(footerWrap)
            footerWrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func indented(_ view: NSView, inset: CGFloat) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
        ])
        return box
    }
}

/// macOS 原生分组卡片容器：圆角矩形、浅深色自适应表面填充与精细内部分隔线。
final class SettingsCardView: NSView {
    private let stack = NSStackView()
    private(set) var rows: [NSView] = []
    private var dividers: [SettingsDividerView] = []

    init(rows: [NSView]) {
        super.init(frame: .zero)
        self.rows = rows
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = SettingsDividerView()
                dividers.append(divider)
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refreshDividers()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        if isDark {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        }
    }

    /// 显隐指定行，并自动清理相邻的冗余分隔线。
    func setRow(_ row: NSView, hidden: Bool) {
        row.isHidden = hidden
        refreshDividers()
    }

    /// 保证每条分隔线仅在前后均有可见行时显示，避免卡片顶部/底部残余横线或双线。
    private func refreshDividers() {
        for (index, divider) in dividers.enumerated() {
            let hasVisibleBefore = rows[0...index].contains { !$0.isHidden }
            let hasVisibleAfter = rows[(index + 1)...].contains { !$0.isHidden }
            divider.isHidden = !(hasVisibleBefore && hasVisibleAfter)
        }
    }
}

/// 卡片内带左右缩进的 1pt 细分隔线。
private final class SettingsDividerView: NSView {
    private let line = NSView()

    init() {
        super.init(frame: .zero)
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// 单行设置项：左侧主标题与可选副标题，右侧垂直居中的交互控件。
final class SettingsRowView: NSView {
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let textStack = NSStackView()
    private var accessoryContainer = NSView()
    private var accessoryConstraints: [NSLayoutConstraint] = []

    var subtitle: String {
        get { subtitleLabel.stringValue }
        set {
            subtitleLabel.stringValue = newValue
            subtitleLabel.isHidden = newValue.isEmpty
        }
    }

    init(title: String, subtitle: String? = nil, accessory: NSView? = nil) {
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(wrappingLabelWithString: subtitle ?? "")
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.detachesHiddenViews = true
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(accessoryContainer)

        let minHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        // 低优先级紧凑高度确保多行副标题展开后容器仍紧密贴合内容高度
        let hugHeight = heightAnchor.constraint(equalToConstant: 42)
        hugHeight.priority = .init(100)

        NSLayoutConstraint.activate([
            minHeight,
            hugHeight,
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryContainer.leadingAnchor, constant: -16),

            accessoryContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            accessoryContainer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            accessoryContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),
            accessoryContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if let accessory { setAccessory(accessory) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAccessory(_ view: NSView) {
        NSLayoutConstraint.deactivate(accessoryConstraints)
        accessoryContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessoryContainer.addSubview(view)
        accessoryConstraints = [
            view.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
        ]
        NSLayoutConstraint.activate(accessoryConstraints)
    }

    func setEnabled(_ enabled: Bool) {
        titleLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
        subtitleLabel.textColor = enabled ? .secondaryLabelColor : .quaternaryLabelColor
    }
}

/// 卡片内条件告警/提示行：带图标与可选快捷操作按钮，无消息时收起不占高度。
final class SettingsNoticeRow: NSView {
    private let tintColor: NSColor
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var actionButton: NSButton?
    var onAction: (() -> Void)?

    var message: String {
        get { messageLabel.stringValue }
        set { messageLabel.stringValue = newValue }
    }

    init(symbol: String, tint: NSColor, actionTitle: String? = nil) {
        self.tintColor = tint
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = tint
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(messageLabel)

        var constraints: [NSLayoutConstraint] = [
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]

        if let actionTitle {
            let button = NSButton(title: actionTitle, target: self, action: #selector(handleAction))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(button)
            actionButton = button
            constraints += [
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
            ]
        } else {
            constraints.append(messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tintColor.withAlphaComponent(0.08).cgColor
    }

    @objc private func handleAction() { onAction?() }
}

/// 紧凑的路径胶囊：显示文件夹图标与中间截断的路径文本，悬停展示完整路径。
private final class PathCapsuleView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 176),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func setPath(_ fullPath: String) {
        label.stringValue = (fullPath as NSString).abbreviatingWithTildeInPath
        toolTip = fullPath
    }
}

/// 权限状态小胶囊徽章（如「已授权」）。
private final class StatusBadgeView: NSView {
    private let tintColor: NSColor

    init(title: String, symbol: String, tint: NSColor) {
        self.tintColor = tint
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.backgroundColor = tintColor.withAlphaComponent(0.14).cgColor
        layer?.borderColor = tintColor.withAlphaComponent(0.35).cgColor
    }
}

/// A field that shows a shortcut and, once clicked, takes the next key press with ⌃, ⌥ or ⌘ as the new one.
final class ShortcutField: NSButton {
    var shortcut = Settings.Shortcut.default {
        didSet {
            if monitor == nil {
                title = shortcut.display
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    var isListening: Bool { monitor != nil }
    var onBegin: () -> Void = {}
    /// The new shortcut, or nil when cancelled.
    var onEnd: (Settings.Shortcut?) -> Void = { _ in }
    private var monitor: Any?
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.pushOnPushOff)
        title = shortcut.display
        font = .systemFont(ofSize: 12.5, weight: .medium)
        toolTip = "点击后按下新快捷键"
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let measured = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 12.5, weight: .medium)]).width
        return NSSize(width: max(108, ceil(measured) + 24), height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if monitor != nil {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            let baseFill = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.textBackgroundColor
            baseFill.setFill()
            path.fill()
            if isHovered {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
                path.fill()
            }
            let border = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)
            border.setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let textColor = monitor != nil ? NSColor.controlAccentColor : NSColor.labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let textRect = CGRect(x: 6, y: (bounds.height - textSize.height) / 2 - 0.5, width: bounds.width - 12, height: textSize.height)
        (title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    @objc private func clicked() {
        if monitor != nil { finish(nil); return }
        onBegin()
        state = .on
        title = "按下新组合…"
        invalidateIntrinsicContentSize()
        needsDisplay = true
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
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onEnd(new)
    }
}
