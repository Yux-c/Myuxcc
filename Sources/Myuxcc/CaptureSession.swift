import AppKit

/// Borderless full-screen panel. Non-activating, so it can take keyboard focus even when
/// macOS's cooperative activation refuses to bring this background app to the front.
final class OverlayWindow: NSPanel {
    /// Set by the silent e2e test: the window is never shown and never takes focus from the user's app.
    var isSilent = false
    override var canBecomeKey: Bool { !isSilent }
    override var canBecomeMain: Bool { !isSilent }
}

/// One screenshot from hotkey press to copy/save/pin/cancel.
@MainActor
final class CaptureSession: OverlayViewDelegate {
    private(set) var windows: [OverlayWindow] = []
    private(set) var views: [OverlayView] = []
    private(set) var longCapture: LongCaptureController?
    private let onFinish: (CaptureSession) -> Void
    /// Starts recording a region (in the screen's top-left points); set by the app delegate.
    var onRecord: ((NSScreen, CGRect) -> Void)?

    init(frozen: [FrozenScreen], onFinish: @escaping (CaptureSession) -> Void) {
        self.onFinish = onFinish
        // Recorded before any overlay is on screen, so our own windows are never in the list.
        let snapper = WindowSnapper.capture()
        for item in frozen {
            let frame = item.screen.frame
            let window = OverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = true
            window.hasShadow = false
            // Panels zoom in from the center by default, which shows up as a visible shrink-then-grow jolt.
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size), frozen: item.image)
            view.delegate = self
            if let id = item.screen.displayID {
                let displayBounds = CGDisplayBounds(id)
                view.windowFrameAt = { snapper.frame(at: $0, displayBounds: displayBounds) }
            }
            window.contentView = view
            window.setFrame(frame, display: false)
            windows.append(window)
            views.append(view)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        // Focus the screen under the mouse so keyboard shortcuts work right away.
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        // Show the window highlight and loupe immediately, before the first mouse move.
        if let target, let view = target.contentView as? OverlayView {
            view.updateHover(at: view.convert(target.convertPoint(fromScreen: mouse), from: nil))
        }
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
    }

    func overlayDidBeginSelection(_ view: OverlayView) {
        // Only one screen holds a selection at a time.
        for v in views where v !== view { v.clearSelection() }
        view.window?.makeKey()
    }

    func overlayDidRequestLongCapture(_ view: OverlayView) {
        guard longCapture == nil, let sel = view.selection, let window = view.window as? OverlayWindow,
              let screen = window.screen else { return }
        for w in windows where w !== window { w.orderOut(nil) }
        // The live screen shows through, and scrolling reaches the app underneath.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        view.enterLongCaptureMode()
        let controller = LongCaptureController(screen: screen, selection: sel, overlay: window) { [weak self] action, image in
            self?.finishLongCapture(action, image, pointWidth: sel.width)
        }
        longCapture = controller
        controller.start()
    }

    func overlayDidRequestRecording(_ view: OverlayView) {
        guard longCapture == nil, let sel = view.selection, let screen = view.window?.screen else { return }
        // The overlay goes first: the recording shows the live screen.
        close()
        onRecord?(screen, sel)
    }

    private func finishLongCapture(_ action: FinishAction, _ image: CGImage?, pointWidth: CGFloat) {
        longCapture = nil
        close()
        guard let image else { return }
        switch action {
        case .copy:
            // Point size from the selection, not the backing scale, so fractional selections stay exact.
            let ratio = pointWidth / CGFloat(image.width)
            ImageOutput.copyToPasteboard(image, pointSize: CGSize(width: pointWidth, height: CGFloat(image.height) * ratio))
        case .save: ImageOutput.save(image, prefix: "长截图")
        case .pin, .recognizeText, .translate, .cancel: break
        }
    }

    func overlay(_ view: OverlayView, finishWith action: FinishAction) {
        if let longCapture {
            longCapture.finish(action)
            return
        }
        let image = action == .cancel ? nil : view.renderSelection()
        let selectionOnScreen: CGRect? = view.selection.flatMap { sel in
            guard let win = view.window else { return nil }
            // Flipped view rect → AppKit global (bottom-left) screen rect.
            return CGRect(x: win.frame.minX + sel.minX, y: win.frame.maxY - sel.maxY,
                          width: sel.width, height: sel.height)
        }
        close()

        guard let image else { return }
        let size = selectionOnScreen?.size ?? CGSize(width: image.width, height: image.height)
        switch action {
        case .copy:
            ImageOutput.copyToPasteboard(image, pointSize: size)
        case .save:
            ImageOutput.save(image)
        case .pin:
            PinWindowController.pin(image, pointSize: size, at: selectionOnScreen?.origin)
        case .recognizeText:
            // Pin the image directly in place and enable live OCR text selection on the original image,
            // while preserving TextRecognitionController.testPresenter for headless E2E tests.
            if TextRecognitionController.testPresenter != nil {
                TextRecognitionController.present(image, near: selectionOnScreen)
            } else {
                PinWindowController.pin(image, pointSize: size, at: selectionOnScreen?.origin, recognizing: true)
            }
        case .translate:
            PinWindowController.pin(image, pointSize: size, at: selectionOnScreen?.origin, translating: true)
        case .cancel:
            break
        }
    }

    private func close() {
        guard !windows.isEmpty else { return } // already closed
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        onFinish(self)
    }
}
