import AppKit

/// A short message near the pointer that fades away by itself and never takes focus or clicks.
@MainActor
enum Toast {
    private static var window: NSPanel?

    static func show(_ text: String) {
        window?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let size = label.fittingSize
        let frame = CGRect(x: 0, y: 0, width: size.width + 28, height: size.height + 16)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        let background = NSView(frame: frame)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = frame.height / 2
        label.frame = CGRect(x: 14, y: 8, width: size.width, height: size.height)
        background.addSubview(label)
        panel.contentView = background
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: mouse.x - frame.width / 2, y: mouse.y + 24))
        panel.orderFrontRegardless()
        window = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated {
                guard window === panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated {
                        panel.orderOut(nil)
                        if window === panel { window = nil }
                    }
                }
            }
        }
    }
}
