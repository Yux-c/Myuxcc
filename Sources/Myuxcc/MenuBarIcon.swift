import AppKit

/// The menu bar icon: the app icon's two overlapping panes as a template image, so the menu bar
/// tints it for light and dark mode. The front pane is cut out of the back one with a thin gap.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let side: CGFloat = 11, radius: CGFloat = 3, gap: CGFloat = 1.5
            let back = CGRect(x: 1, y: 1, width: side, height: side)
            let front = CGRect(x: 6, y: 6, width: side, height: side)
            ctx.setFillColor(.black)
            ctx.addPath(CGPath(roundedRect: back, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            let cut = front.insetBy(dx: -gap, dy: -gap)
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: cut, cornerWidth: radius + gap, cornerHeight: radius + gap, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.addPath(CGPath(roundedRect: front, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Myuxcc"
        return image
    }
}
