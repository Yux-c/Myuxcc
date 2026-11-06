import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var shelfHotKey: HotKey?
    private var shotItem: NSMenuItem!
    private var shelfItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private lazy var settings: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.applyShortcut = { [weak self] kind, shortcut in
            switch kind {
            case .capture: return self?.registerHotKey(shortcut) ?? false
            case .shelf: return self?.registerShelfHotKey(shortcut) ?? false
            }
        }
        controller.suspendShortcut = { [weak self] kind, suspended in
            guard suspended else { return }
            switch kind {
            case .capture: self?.hotKey = nil
            case .shelf: self?.shelfHotKey = nil
            }
        }
        controller.recordingChanged = { [weak self] in self?.recordItem.state = FrameRecorder.isOn ? .on : .off }
        controller.shakeSettingsChanged = { [weak self] in self?.shake.start() }
        controller.clipboardRecordingChanged = { [weak self] in self?.applyClipboardRecording() }
        return controller
    }()
    /// The shelf: files, screenshots and copies kept for pasting or dragging into other apps.
    private(set) lazy var shelf = ShelfPanel()
    private let shake = ShakeDetector()
    private let clipboardWatcher = ClipboardWatcher()
    private(set) var session: CaptureSession?
    /// The screen recording in progress; the capture shortcut stops it.
    private(set) var recording: RecordingController?
    /// Replaces starting a real recording; set by the e2e test.
    var recordingPresenter: ((NSScreen, CGRect) -> Void)?
    private var capturing = false
    /// Called right after the overlay appears; used by the e2e test to sample the very first frames.
    var onSessionShown: ((CaptureSession) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Silent e2e: no menu bar icon, no hotkey, no window on screen; needs no permission.
        if let i = CommandLine.arguments.firstIndex(of: "--e2e-silent"), i + 1 < CommandLine.arguments.count {
            let test = E2ETest(app: self, outputDir: CommandLine.arguments[i + 1], silent: true)
            Task { @MainActor in await test.run() }
            return
        }
        // Before anything reads settings or the shelf: carry over what the app had as ScshootDemo.
        if !CommandLine.arguments.contains("--e2e") {
            // Terminate any previously running Myuxcc instance so the newly built binary takes over the global hotkey.
            let myPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.yuxccu.myuxcc")
                .filter { $0.processIdentifier != myPID }
            if !existing.isEmpty {
                for old in existing {
                    if !old.terminate() { old.forceTerminate() }
                }
                Thread.sleep(forTimeInterval: 0.25)
                for old in existing where !old.isTerminated {
                    old.forceTerminate()
                }
            }
            LegacyMigration.run()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()

        // Left or right click on the icon opens this menu.
        let menu = NSMenu()
        shotItem = NSMenuItem(title: "截图", action: #selector(startCapture), keyEquivalent: "")
        shotItem.target = self
        menu.addItem(shotItem)
        shelfItem = NSMenuItem(title: "剪贴中转板", action: #selector(toggleShelf), keyEquivalent: "")
        shelfItem.target = self
        menu.addItem(shelfItem)
        menu.addItem(.separator())
        recordItem = NSMenuItem(title: "记录长截图帧（调试）", action: #selector(toggleRecording(_:)), keyEquivalent: "")
        recordItem.target = self
        recordItem.state = FrameRecorder.isOn ? .on : .off
        menu.addItem(recordItem)
        let show = NSMenuItem(title: "打开记录文件夹", action: #selector(showRecordings), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(settingsItem())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        // The app shows no menu bar of its own, but its key equivalents still work while it is in front:
        // ⌘, opens the settings, ⌘Q quits, ⌘W closes the settings window.
        let appMenu = NSMenu()
        appMenu.addItem(settingsItem())
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main

        if !registerHotKey(Settings.shortcut) {
            NSLog("Myuxcc: hotkey \(Settings.shortcut.display) is taken by another app")
            settings.setShortcutTaken(true)
        }
        // A test instance runs beside the user's own; it must not take ⌃X, watch the pointer or record copies.
        if !CommandLine.arguments.contains("--e2e") {
            if !registerShelfHotKey(Settings.shelfShortcut) {
                NSLog("Myuxcc: shelf hotkey \(Settings.shelfShortcut.display) is taken by another app")
                settings.setShelfShortcutTaken(true)
            }
            startShelf()
            TextRecognizer.warmUp()
            TextRecognizer.warmUpWorker()
        }
        if CommandLine.arguments.contains("--settings") { openSettings() }

        if CommandLine.arguments.contains("--capture-now") { startCapture() }
        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), i + 1 < CommandLine.arguments.count {
            let test = E2ETest(app: self, outputDir: CommandLine.arguments[i + 1])
            Task { @MainActor in await test.run() }
        }
    }

    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        item.target = self
        return item
    }

    /// The settings window once opened; read by the e2e test.
    var settingsWindow: NSWindow? { settings.window }

    @objc func openSettings() {
        guard session == nil else { return } // the capture overlay would cover the window
        settings.show()
    }

    /// Registers the capture shortcut in place of the current one; false when another app holds it.
    @discardableResult
    func registerHotKey(_ shortcut: Settings.Shortcut) -> Bool {
        hotKey = nil
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.startCapture() }
        if let (key, flags) = shortcut.menuKey, hotKey != nil {
            shotItem.keyEquivalent = key
            shotItem.keyEquivalentModifierMask = flags
        } else {
            shotItem.keyEquivalent = ""
        }
        return hotKey != nil
    }

    /// Registers the shortcut that opens or closes the shelf; false when another app holds it.
    @discardableResult
    func registerShelfHotKey(_ shortcut: Settings.Shortcut) -> Bool {
        shelfHotKey = nil
        shelfHotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.toggleShelf() }
        if let (key, flags) = shortcut.menuKey, shelfHotKey != nil {
            shelfItem.keyEquivalent = key
            shelfItem.keyEquivalentModifierMask = flags
        } else {
            shelfItem.keyEquivalent = ""
        }
        return shelfHotKey != nil
    }

    /// Shaking the pointer while dragging opens the shelf beside it, shaking again closes it;
    /// screenshots sent to the shelf open it beside the selection.
    private func startShelf() {
        ShelfStorage.shared.adoptMacFileRelayFiles()
        ShelfPanel.openSettings = { [weak self] in self?.openSettings() }
        shake.onShake = { [weak self] point in
            guard let self else { return }
            if shelf.isShelfVisible {
                if Settings.shelfShakeCloses { shelf.hideShelf() }
            } else {
                shelf.showNear(point: point)
            }
        }
        shake.allowsShakeWithoutDrag = { [weak self] in
            MainActor.assumeIsolated { self?.shelf.isShelfVisible == true && Settings.shelfShakeCloses }
        }
        shake.start()
        applyClipboardRecording()
    }

    private func applyClipboardRecording() {
        if Settings.shelfRecordsClipboard { clipboardWatcher.start() } else { clipboardWatcher.stop() }
    }

    @objc func toggleShelf() { shelf.toggleShelf() }

    @objc private func toggleRecording(_ item: NSMenuItem) {
        FrameRecorder.isOn.toggle()
        item.state = FrameRecorder.isOn ? .on : .off
    }

    @objc private func showRecordings() {
        try? FileManager.default.createDirectory(at: FrameRecorder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FrameRecorder.root)
    }

    @objc func startCapture() {
        if let recording { recording.stop(); return }
        guard session == nil, !capturing else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let frozen = try await ScreenCapturer.captureAllScreens()
                guard !frozen.isEmpty else { return }
                let s = beginSession(frozen)
                s.show()
                onSessionShown?(s)
            } catch ScreenCapturer.CaptureError.noPermission {
                showPermissionAlert()
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    /// A session over `frozen`, not yet shown.
    @MainActor
    func beginSession(_ frozen: [FrozenScreen]) -> CaptureSession {
        let s = CaptureSession(frozen: frozen) { _ in self.session = nil }
        s.onRecord = { [weak self] screen, region in self?.startRecording(screen: screen, region: region) }
        session = s
        return s
    }

    private func startRecording(screen: NSScreen, region: CGRect) {
        if let recordingPresenter { recordingPresenter(screen, region); return }
        let controller = RecordingController(screen: screen, selection: region) { [weak self] _ in
            self?.recording = nil
            self?.updateRecordingIndicator()
        }
        recording = controller
        updateRecordingIndicator()
        controller.start()
    }

    /// While recording, the menu bar icon turns red and its first item stops the recording.
    private func updateRecordingIndicator() {
        guard let button = statusItem?.button else { return }
        let on = recording != nil
        button.image = on ? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "录屏中") : MenuBarIcon.image()
        button.contentTintColor = on ? .systemRed : nil
        shotItem?.title = on ? "停止录屏" : "截图"
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」中允许 Myuxcc，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
