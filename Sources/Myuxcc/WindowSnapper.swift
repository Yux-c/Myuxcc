import AppKit

/// Frames of on-screen app windows, front to back, recorded when the screen is frozen
/// so that snapping matches the frozen picture. Uses the window list, which needs no
/// Accessibility permission.
struct WindowSnapper {
    /// Global CoreGraphics coordinates (top-left origin of the primary display), front to back.
    let frames: [CGRect]

    /// Replaces the real window list when set; used by the e2e test to get a predictable highlight.
    static var testFrames: [CGRect]?

    static func capture() -> WindowSnapper {
        if let testFrames { return WindowSnapper(frames: testFrames) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return WindowSnapper(frames: [])
        }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        var frames: [CGRect] = []
        for info in list {
            // Layer 0 is ordinary app windows; menus, the Dock and the menu bar sit on higher layers.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 40, frame.height >= 40 else { continue }
            frames.append(frame)
        }
        return WindowSnapper(frames: frames)
    }

    /// Frontmost window under `point`, both in a display's local top-left coordinates,
    /// clipped to that display.
    func frame(at point: CGPoint, displayBounds: CGRect) -> CGRect? {
        let global = CGPoint(x: point.x + displayBounds.minX, y: point.y + displayBounds.minY)
        guard let hit = frames.first(where: { $0.contains(global) }) else { return nil }
        let local = hit.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        let clipped = local.intersection(CGRect(origin: .zero, size: displayBounds.size))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}
