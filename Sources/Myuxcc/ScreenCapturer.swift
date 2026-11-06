import AppKit
import ScreenCaptureKit

/// A frozen frame of one screen, captured before the overlay appears.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage   // full-resolution pixels of the whole display
}

enum ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noPermission
        var errorDescription: String? { "没有屏幕录制权限" }
    }

    /// Captures every connected display at native resolution.
    static func captureAllScreens() async throws -> [FrozenScreen] {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw CaptureError.noPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenScreen(screen: screen, image: image))
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
