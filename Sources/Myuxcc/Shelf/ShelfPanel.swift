import AppKit
import ImageIO
import QuickLookThumbnailing

/// The clipboard shelf ("剪贴中转板"), laid out like Maccy: a title and search field on top, one row per
/// item (text on one line using the full width, images as thumbnails), menu-style actions at the
/// bottom, and an optional preview on the left. Opened from the keyboard it takes typing for the
/// search without activating the app, so the app in front keeps focus and receives the paste.
@MainActor
final class ShelfPanel: NSPanel, NSWindowDelegate, NSSearchFieldDelegate {
    static let listWidth: CGFloat = 400
    static let previewWidth: CGFloat = 300
    static let headerHeight: CGFloat = 42
    static let footerRowHeight: CGFloat = 24
    static let emptyListHeight: CGFloat = 96

    /// Opens the app's settings; set by the app delegate.
    static var openSettings: () -> Void = {}
    /// Set by the silent e2e test: the panel keeps its state but never comes on screen.
    static var silent = false

    private(set) var isShelfVisible = false
    /// Opened to be used from the keyboard (shortcut, menu): it takes typing and closes when it loses it.
    /// Opened by a shake or a screenshot it leaves the keyboard alone and closes when the pointer leaves.
    private(set) var focused = false
    private(set) var visibleItems: [ShelvedItem] = []
    private(set) var rows: [ShelfRowView] = []
    private(set) var selection = 0
    /// What a click or ↩ does with an item; pastes it into the app in front by default.
    var onChoose: ((ShelvedItem) -> Void)?

    let searchField = NSSearchField()
    let titleLabel = NSTextField(labelWithString: "剪贴中转板")
    let previewButton = NSButton()
    let preview = ShelfPreviewView()
    private(set) var footerRows: [ShelfMenuRow] = []
    private let background = ShelfDropView()
    private let scrollView = NSScrollView()
    private let list = ShelfFlippedView()
    private let emptyLabel = NSTextField(labelWithString: "拖入文件，或复制任何内容")
    private let separator = NSBox()
    private let importSpinner = NSProgressIndicator()
    private var retractTimer: Timer?
    /// Opened with Space on the row under the pointer; closes with the panel.
    private(set) var peekOpen = false
    /// 当用户默认开启常驻预览栏时，按空格键在本轮会话内临时收起预览栏，不覆盖持久化设置
    private var peekClosed = false
    /// The pointer in window coordinates; the silent e2e test sets its own.
    var pointerInWindow: () -> NSPoint = { .zero }
    /// Whether the last layout had the preview, which sits left of the list and moves the panel's left edge.
    private var laidOutWithPreview = false

    /// 结合持久化开关与当前会话内空格键的临时开闭状态计算是否展示预览栏
    var showsPreview: Bool { (Settings.shelfShowsPreview && !peekClosed) || peekOpen }
    /// Where the list's left edge is on screen; the list stays put when the preview opens or closes.
    private var listLeft: CGFloat { frame.minX + (laidOutWithPreview ? Self.previewWidth : 0) }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.listWidth, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        delegate = self
        pointerInWindow = { [unowned self] in mouseLocationOutsideOfEventStream }
        build()
        // While hidden the rows are not rebuilt for every copy; showing the panel reloads them.
        ShelfStorage.shared.onItemsChanged.append { [weak self] in
            MainActor.assumeIsolated { if self?.isShelfVisible == true { self?.reload() } }
        }
        ShelfStorage.shared.onImportStateChanged = { [weak self] busy in
            MainActor.assumeIsolated { busy ? self?.importSpinner.startAnimation(nil) : self?.importSpinner.stopAnimation(nil) }
        }
        onChoose = { [weak self] item in
            self?.hideShelf()
            ShelfPaste.paste(item)
        }
        reload()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Layout

    private func build() {
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        background.panel = self
        contentView = background

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        searchField.placeholderString = "搜索…"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        previewButton.bezelStyle = .accessoryBarAction
        previewButton.isBordered = false
        previewButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "预览栏")
        previewButton.contentTintColor = .secondaryLabelColor
        previewButton.toolTip = "显示 / 隐藏预览栏"
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        importSpinner.style = .spinning
        importSpinner.controlSize = .small
        importSpinner.isDisplayedWhenStopped = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = list
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        separator.boxType = .separator

        footerRows = [
            ShelfMenuRow(title: "清空", shortcut: "⌥⌘⌫") { [weak self] in self?.clearAll() },
            ShelfMenuRow(title: "在访达中打开", shortcut: "") { [weak self] in
                self?.hideShelf()
                NSWorkspace.shared.open(ShelfStorage.shared.folder)
            },
            ShelfMenuRow(title: "偏好设置…", shortcut: "⌘,") { [weak self] in
                self?.hideShelf()
                Self.openSettings()
            },
        ]
        preview.panel = self
        for v in [titleLabel, searchField, previewButton, importSpinner, scrollView, emptyLabel, separator, preview] as [NSView] {
            background.addSubview(v)
        }
        footerRows.forEach(background.addSubview)
    }

    /// Sizes the panel to its rows (up to most of the screen) and lays everything out, keeping the top
    /// edge and the list's left edge: the preview grows out to the left.
    private func layoutPanel() {
        let listContent = rows.reduce(8) { $0 + $1.frame.height }
        let footerHeight = CGFloat(footerRows.count) * Self.footerRowHeight + 9
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxList = max(area.height * 0.72 - Self.headerHeight - footerHeight, 120)
        let listHeight = rows.isEmpty ? Self.emptyListHeight : min(listContent, maxList)
        let width = Self.listWidth + (showsPreview ? Self.previewWidth : 0)
        let height = Self.headerHeight + listHeight + footerHeight

        var target = frame
        target.origin.y = frame.maxY - height
        target.origin.x = listLeft - (showsPreview ? Self.previewWidth : 0)
        target.size = CGSize(width: width, height: height)
        target.origin.x = min(max(target.minX, area.minX + 4), area.maxX - width - 4)
        target.origin.y = max(target.minY, area.minY + 4)
        setFrame(target, display: true)
        laidOutWithPreview = showsPreview

        let x0: CGFloat = showsPreview ? Self.previewWidth : 0
        let top = height - Self.headerHeight
        preview.isHidden = !showsPreview
        preview.frame = CGRect(x: 0, y: 0, width: Self.previewWidth, height: height)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = CGPoint(x: x0 + 14, y: top + (Self.headerHeight - titleLabel.frame.height) / 2)
        previewButton.frame = CGRect(x: width - 34, y: top + 9, width: 24, height: 24)
        importSpinner.frame = CGRect(x: width - 54, y: top + 13, width: 16, height: 16)
        let searchX = titleLabel.frame.maxX + 10
        searchField.frame = CGRect(x: searchX, y: top + 9, width: width - 60 - searchX, height: 24)

        scrollView.frame = CGRect(x: x0, y: footerHeight, width: Self.listWidth, height: listHeight)
        list.frame = CGRect(x: 0, y: 0, width: Self.listWidth, height: max(listContent, listHeight))
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.frame = CGRect(x: x0, y: footerHeight + listHeight / 2 - 9, width: Self.listWidth, height: 18)
        separator.frame = CGRect(x: x0 + 10, y: footerHeight - 5, width: Self.listWidth - 20, height: 1)
        for (i, row) in footerRows.enumerated() {
            row.frame = CGRect(x: x0 + 6, y: footerHeight - 9 - CGFloat(i + 1) * Self.footerRowHeight, width: Self.listWidth - 12, height: Self.footerRowHeight)
        }
    }

    // MARK: - Content

    /// How many times the rows were rebuilt; the silent e2e test checks it stays put while hidden.
    private(set) var reloadCount = 0

    /// Rebuilds the rows from the storage and the search text, keeping the selected item when it is still there.
    func reload() {
        reloadCount += 1
        let selected = visibleItems.indices.contains(selection) ? visibleItems[selection].url : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = ShelfStorage.shared.items
        visibleItems = query.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(query) || ($0.clipText?.lowercased().contains(query) ?? false)
        }
        rows.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 4
        rows = visibleItems.map { item in
            let row = ShelfRowView(item: item, width: Self.listWidth - 12)
            row.frame.origin = CGPoint(x: 6, y: y)
            y += row.frame.height
            row.onHover = { [weak self, weak row] in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.select(index, scroll: false)
            }
            row.onChoose = { [weak self] in self?.onChoose?(item) }
            row.onDelete = { ShelfStorage.shared.remove(item) }
            row.onDragStarted = { [weak self] in self?.cancelRetractTimer() }
            list.addSubview(row)
            return row
        }
        let index = selected.flatMap { url in visibleItems.firstIndex { $0.url == url } } ?? 0
        layoutPanel()
        select(index)
    }

    func select(_ index: Int, scroll: Bool = true) {
        selection = rows.isEmpty ? 0 : min(max(index, 0), rows.count - 1)
        for (i, row) in rows.enumerated() { row.isSelected = i == selection }
        if scroll, rows.indices.contains(selection) { list.scrollToVisible(rows[selection].frame.insetBy(dx: 0, dy: -4)) }
        preview.show(visibleItems.indices.contains(selection) ? visibleItems[selection] : nil)
    }

    var selectedItem: ShelvedItem? { visibleItems.indices.contains(selection) ? visibleItems[selection] : nil }

    func chooseSelected() {
        if let item = selectedItem { onChoose?(item) }
    }

    /// The button: closes the preview when it is open (also one opened with Space), otherwise keeps it
    /// open from now on.
    @objc func togglePreview() {
        // 点击顶栏切换按钮时修改用户持久化配置，并清除本轮空格键的临时开闭状态
        if showsPreview {
            Settings.shelfShowsPreview = false
            peekOpen = false
            peekClosed = false
        } else {
            Settings.shelfShowsPreview = true
            peekClosed = false
        }
        layoutPanel()
        preview.show(selectedItem)
    }

    /// Whether the pointer rests on the selected row.
    var pointerOnSelection: Bool {
        guard rows.indices.contains(selection) else { return false }
        let row = rows[selection]
        return !scrollView.isHidden && row.bounds.contains(row.convert(pointerInWindow(), from: nil))
            && scrollView.contentView.bounds.contains(list.convert(pointerInWindow(), from: nil))
    }

    /// Space with the pointer on the selected row shows or hides its preview; anywhere else it is typed
    /// into the search field.
    func handleSpace(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true, pointerOnSelection else { return false }
        // 按空格键仅在本轮会话内临时开闭预览栏，绝不覆盖持久化的 Settings.shelfShowsPreview
        if showsPreview {
            peekOpen = false
            peekClosed = true
        } else {
            peekClosed = false
            peekOpen = true
        }
        layoutPanel()
        preview.show(selectedItem)
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isShelfVisible, handleSpace(event) { return }
        super.sendEvent(event)
    }

    private func clearAll() {
        guard Self.confirmClearAll() else { return }
        ShelfStorage.shared.clearAll()
    }

    /// Asks before deleting everything on the shelf.
    static func confirmClearAll() -> Bool {
        let count = ShelfStorage.shared.items.count
        guard count > 0 else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空剪贴中转板？"
        alert.informativeText = "将彻底删除 \(count) 个条目。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Showing

    /// Opens beside `point` (the pointer, a selection); `focus` makes it take typing for the search.
    func showNear(point: NSPoint, focus: Bool = false) {
        cancelRetractTimer()
        if !isShelfVisible || focus { searchField.stringValue = "" }
        focused = focus || (isShelfVisible && focused)
        ShelfStorage.shared.reload()
        // 每次从隐藏状态重新打开中转板时重置空格键的临时预览状态
        if !isShelfVisible {
            peekOpen = false
            peekClosed = false
        }
        let area = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        // The pointer sits at the list's top-left corner; the preview, when open, extends to its left.
        var left = point.x + 12
        if left + Self.listWidth > area.maxX { left = point.x - Self.listWidth - 12 }
        let y = min(max(point.y - frame.height + 20, area.minY + 4), area.maxY - frame.height - 4)
        setFrameOrigin(CGPoint(x: max(left, area.minX + 4) - (laidOutWithPreview ? Self.previewWidth : 0), y: y))
        reload()
        select(0)

        let wasVisible = isShelfVisible
        isShelfVisible = true
        if Self.silent { return }
        if !wasVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        if focused {
            makeKey()
            makeFirstResponder(searchField)
        }
    }

    func hideShelf() {
        cancelRetractTimer()
        guard isShelfVisible else { return }
        isShelfVisible = false
        focused = false
        peekOpen = false
        peekClosed = false
        // 隐藏中转板时释放预览大图与列表行视图，避免常驻后台持有大量 CALayer 与解码位图
        preview.show(nil)
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        if Self.silent { return }
        orderOut(nil)
    }

    func toggleShelf() {
        if isShelfVisible { hideShelf() } else { showNear(point: NSEvent.mouseLocation, focus: true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else closes it, like a menu.
        if focused { hideShelf() }
    }

    func cancelRetractTimer() {
        retractTimer?.invalidate()
        retractTimer = nil
    }

    /// Opened without the keyboard (a shake, a screenshot), it closes shortly after the pointer leaves.
    func scheduleRetract() {
        guard !focused else { return }
        cancelRetractTimer()
        retractTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideShelf() }
        }
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ obj: Notification) {
        reload()
        select(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(selection - 1)
        case #selector(NSResponder.moveDown(_:)): select(selection + 1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { hideShelf() } else { searchField.stringValue = ""; reload(); select(0) }
        default: return false
        }
        return true
    }

    /// ⌘⌫ deletes the selected one, ⌥⌘⌫ clears, ⌘, opens the settings.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 51, flags == .command, let item = selectedItem {
            ShelfStorage.shared.remove(item)
            return true
        }
        if event.keyCode == 51, flags == [.command, .option] {
            clearAll()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hideShelf()
            Self.openSettings()
            return true
        }
        return false
    }
}

/// The panel's background: frosted, and a drop target for files, images and links.
final class ShelfDropView: NSVisualEffectView {
    weak var panel: ShelfPanel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfDrop.draggedTypes)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { panel?.cancelRetractTimer() }
        return ShelfDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { ShelfDrop.operation(for: sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { ShelfDrop.receive(sender) }
    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { panel?.cancelRetractTimer() } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { panel?.scheduleRetract() } }
}

final class ShelfFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One item: copied text on one line, images as a thumbnail, files with their icon and name; the
/// selected row is filled with the accent colour. A click pastes it, a drag carries it out.
final class ShelfRowView: NSView, NSDraggingSource {
    static let textHeight: CGFloat = 26
    static let imageHeight: CGFloat = 50

    let item: ShelvedItem
    var onChoose: (() -> Void)?
    var onHover: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { updateColors() } } }
    private var dragged = false
    let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    override var isFlipped: Bool { true }

    init(item: ShelvedItem, width: CGFloat) {
        self.item = item
        let isImage = item.kind == .image
        let height = isImage ? Self.imageHeight : Self.textHeight
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 6

        var x: CGFloat = 10
        if isImage {
            iconView.frame = CGRect(x: x, y: 4, width: 72, height: height - 8)
            iconView.imageScaling = .scaleProportionallyDown
            iconView.imageAlignment = .alignLeft
            iconView.image = ThumbnailCache.shared.imageThumbnail(item.url, maxPixels: 160) ?? item.icon
            x += 80
        } else if !item.isClipText {
            iconView.frame = CGRect(x: x, y: (height - 18) / 2, width: 18, height: 18)
            iconView.image = item.icon
            x += 26
        }
        if iconView.image != nil { addSubview(iconView) }

        // A copied picture is shown by itself, like Maccy; files keep their names.
        titleLabel.stringValue = isImage && item.isFromClipboard ? "" : item.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = item.isClipText ? .byTruncatingTail : .byTruncatingMiddle
        titleLabel.frame = CGRect(x: x, y: (height - 17) / 2, width: width - x - 10, height: 17)
        titleLabel.toolTip = item.clipText.map { String($0.prefix(300)) } ?? item.name
        addSubview(titleLabel)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = isSelected ? .white : .labelColor
    }

    /// The panel never activates the app, so the first click must already count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The panel moves by its background; a row must not, or dragging a file out drags the panel.
    override var mouseDownCanMoveWindow: Bool { false }
    /// The row takes every click itself, also on its icon and labels, so none of them moves the panel.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?() } }
    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseUp(with event: NSEvent) {
        if !dragged, event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { onChoose?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !item.isClipText, !dragged else { return }
        dragged = true
        onDragStarted?()
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        dragItem.setDraggingFrame(CGRect(x: 0, y: 0, width: 32, height: 32), contents: item.icon)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .generic
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        var actions: [(String, Selector)] = [("粘贴到当前应用", #selector(chooseItem)), ("只复制", #selector(copyItem))]
        if !item.isClipText {
            actions += [("打开", #selector(openItem)), ("在访达中显示", #selector(revealItem))]
        }
        actions.append(("删除", #selector(deleteItem)))
        for (title, action) in actions {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func chooseItem() { onChoose?() }
    @objc private func copyItem() { MainActor.assumeIsolated { ShelfPaste.write(item) } }
    @objc private func openItem() { NSWorkspace.shared.open(item.url) }
    @objc private func revealItem() { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    @objc private func deleteItem() { onDelete?() }
}

/// A menu-style action at the bottom of the panel: a title, its shortcut, highlighted under the pointer.
final class ShelfMenuRow: NSView {
    let action: () -> Void
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private var hovered = false { didSet { updateColors() } }

    init(title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.alignment = .right
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String { titleLabel.stringValue }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 10, y: (bounds.height - 17) / 2, width: bounds.width - 100, height: 17)
        shortcutLabel.frame = CGRect(x: bounds.width - 90, y: (bounds.height - 16) / 2, width: 80, height: 16)
    }

    private func updateColors() {
        layer?.backgroundColor = hovered ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = hovered ? .white : .labelColor
        shortcutLabel.textColor = hovered ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        hovered = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// The preview on the left: the selected image, text or file at a large size, with buttons to read the
/// text in an image, pin it to the desktop, or delete the item.
@MainActor
final class ShelfPreviewView: NSView {
    /// The longest side of the preview image: the pane at twice its size.
    static let previewPixels = 1200
    weak var panel: ShelfPanel?
    private(set) var item: ShelvedItem?
    let imageView = NSImageView()
    let textView = NSTextView()
    private let textScroll = NSScrollView()
    let infoLabel = NSTextField(wrappingLabelWithString: "")
    let recognizeButton = ShelfPreviewView.button("text.viewfinder", "识别文字")
    let pinButton = ShelfPreviewView.button("pin", "钉在桌面")
    let deleteButton = ShelfPreviewView.button("trash", "删除 ⌘⌫")
    private let divider = NSBox()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = CGSize(width: 4, height: 4)
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        divider.boxType = .separator
        recognizeButton.target = self
        recognizeButton.action = #selector(recognize)
        pinButton.target = self
        pinButton.action = #selector(pin)
        deleteButton.target = self
        deleteButton.action = #selector(delete)
        for v in [imageView, textScroll, infoLabel, recognizeButton, pinButton, deleteButton, divider] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        for (i, b) in [recognizeButton, pinButton, deleteButton].enumerated() {
            b.frame = CGRect(x: w - 34 - CGFloat(2 - i) * 30, y: 9, width: 24, height: 24)
        }
        let content = CGRect(x: 12, y: ShelfPanel.headerHeight, width: w - 24, height: bounds.height - ShelfPanel.headerHeight - 52)
        imageView.frame = content
        textScroll.frame = content
        textView.frame = CGRect(x: 0, y: 0, width: content.width, height: max(textView.frame.height, content.height))
        textView.textContainer?.containerSize = CGSize(width: content.width - 8, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        infoLabel.frame = CGRect(x: 12, y: bounds.height - 46, width: w - 24, height: 38)
        divider.frame = CGRect(x: w - 1, y: 8, width: 1, height: bounds.height - 16)
    }

    func show(_ item: ShelvedItem?) {
        self.item = item
        let isImage = item?.kind == .image
        imageView.isHidden = item == nil || item?.isClipText == true
        textScroll.isHidden = item?.isClipText != true
        recognizeButton.isEnabled = isImage
        pinButton.isEnabled = isImage
        deleteButton.isEnabled = item != nil
        guard let item, !isHidden else { imageView.image = nil; textView.string = ""; infoLabel.stringValue = ""; return }
        if let clipText = item.clipText {
            textView.string = String(clipText.prefix(20000))
        } else if isImage {
            // Large enough for the pane on a Retina screen, without decoding a huge original.
            imageView.image = ThumbnailCache.shared.imageThumbnail(item.url, maxPixels: Self.previewPixels)
        } else {
            imageView.image = item.icon
            ThumbnailCache.shared.thumbnail(for: item.url, size: 256) { [weak self] image in
                if self?.item?.url == item.url { self?.imageView.image = image }
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        let time = formatter.string(from: item.addedDate)
        if item.isFromClipboard {
            let size = isImage ? ThumbnailCache.pixelSize(item.url).map { "\(Int($0.width))×\(Int($0.height))" } ?? item.formattedSize : item.formattedSize
            infoLabel.stringValue = "复制于 \(time) · \(size)"
        } else {
            infoLabel.stringValue = "\(item.name)\n放入于 \(time) · \(item.formattedSize)"
        }
        needsLayout = true
    }

    private var cgImage: CGImage? {
        item.flatMap { NSImage(contentsOf: $0.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }

    @objc private func recognize() {
        guard let image = cgImage, let item else { return }
        panel?.hideShelf()
        if TextRecognitionController.testPresenter != nil {
            TextRecognitionController.present(image, near: panel?.frame)
        } else {
            // Pin image directly and enable in-place live OCR selection on the image.
            let size = NSImage(contentsOf: item.url)?.size ?? CGSize(width: image.width / 2, height: image.height / 2)
            PinWindowController.pin(image, pointSize: size, at: panel?.frame.origin, recognizing: true)
        }
    }

    @objc private func pin() {
        guard let image = cgImage, let item else { return }
        panel?.hideShelf()
        let size = NSImage(contentsOf: item.url)?.size ?? CGSize(width: image.width / 2, height: image.height / 2)
        PinWindowController.pin(image, pointSize: size, at: nil)
    }

    @objc private func delete() {
        if let item { ShelfStorage.shared.remove(item) }
    }
}

/// Thumbnails per file and size: image rows and the preview made with ImageIO, other files with QuickLook.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    /// How many image thumbnails were decoded; the silent e2e test checks the cache saves work.
    private(set) var imageDecodes = 0

    /// A shelf file never changes in place, but a name can come back for new content after a delete.
    private static func key(_ url: URL, _ size: Int) -> NSString {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.creationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(size)" as NSString
    }

    /// A small version of an image file, made right away (ImageIO reads only what it needs) and kept.
    func imageThumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
        let key = Self.key(url, maxPixels)
        if let image = cache.object(forKey: key) { return image }
        imageDecodes += 1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: CGSize(width: image.width / 2, height: image.height / 2))
        cache.setObject(thumbnail, forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }

    /// An image file's size in pixels, read from its header.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Calls `completion` on the main thread, only when a real thumbnail exists.
    func thumbnail(for url: URL, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        let key = Self.key(url, Int(size))
        if let image = cache.object(forKey: key) { completion(image); return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                // 计算缩略图近似字节开销（宽 × 高 × 4），使 NSCache.totalCostLimit(64MB) 对 QuickLook 缩略图同样生效
                let rep = image.representations.first
                let w = rep?.pixelsWide ?? max(Int(size * 2), 1)
                let h = rep?.pixelsHigh ?? max(Int(size * 2), 1)
                let cost = max(w * h * 4, 1)
                self?.cache.setObject(image, forKey: key, cost: cost)
                completion(image)
            }
        }
    }
}
