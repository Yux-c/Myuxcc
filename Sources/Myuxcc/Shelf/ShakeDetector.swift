import AppKit

/// How hard the pointer has to shake: 1 needs big, fast swings, 5 reacts to a small wiggle.
struct ShakeSensitivity {
    static let range = 1...5
    static let names = ["很迟钝", "偏迟钝", "标准", "偏灵敏", "很灵敏"]
    let level: Int

    /// Horizontal distance between two pointer events that counts as a swing.
    var threshold: CGFloat { [36, 24, 16, 11, 7][level - 1] }
    var requiredReversals: Int { [4, 3, 3, 2, 2][level - 1] }
    /// How long the swings may take.
    var timeWindow: TimeInterval { [0.55, 0.50, 0.45, 0.40, 0.35][level - 1] }
}

/// Watches the pointer for a left-right shake while something is being dragged (to open the shelf),
/// or, when allowed, while nothing is (to close it again).
final class ShakeDetector {
    /// Called on the main thread with the pointer location.
    var onShake: ((NSPoint) -> Void)?
    /// Whether a shake without a drag counts (shake to close while the shelf is open).
    var allowsShakeWithoutDrag: () -> Bool = { false }

    private var samples: [(x: CGFloat, time: TimeInterval)] = []
    private var lastDirection = 0
    private var reversals = 0
    private var lastReversal: TimeInterval = 0
    private var lastTrigger: TimeInterval = 0
    /// The drag pasteboard's change count at the last mouse-down: it changes once a real drag of files,
    /// images or links starts, unlike moving a window or selecting text.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []

    func start() {
        stop()
        guard Settings.shelfShakeEnabled else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            reset()
        case .leftMouseDragged:
            let point = NSEvent.mouseLocation
            if track(x: point.x, at: now, contentDrag: NSPasteboard(name: .drag).changeCount != dragChangeCount) {
                DispatchQueue.main.async { [weak self] in self?.onShake?(point) }
            }
        default:
            // Plain pointer movement only matters for shake to close.
            guard allowsShakeWithoutDrag() else { return }
            let point = NSEvent.mouseLocation
            if track(x: point.x, at: now, contentDrag: false) {
                DispatchQueue.main.async { [weak self] in self?.onShake?(point) }
            }
        }
    }

    func reset() {
        samples.removeAll()
        reversals = 0
        lastDirection = 0
    }

    /// Adds a pointer position; true when it completes a shake that counts.
    func track(x: CGFloat, at now: TimeInterval, contentDrag: Bool) -> Bool {
        // A short pause after a shake, so shaking on does not close the shelf it just opened.
        if now - lastTrigger < 0.35 { return false }
        let config = ShakeSensitivity(level: Settings.shelfShakeSensitivity)
        samples.append((x, now))
        samples.removeAll { now - $0.time >= config.timeWindow }
        guard samples.count >= 3 else { return false }

        let dx = samples[samples.count - 1].x - samples[samples.count - 2].x
        if abs(dx) > config.threshold {
            let direction = dx > 0 ? 1 : -1
            if lastDirection != 0, direction != lastDirection {
                reversals += 1
                lastReversal = now
                if reversals >= config.requiredReversals {
                    reset()
                    guard contentDrag || allowsShakeWithoutDrag() else { return false }
                    lastTrigger = now
                    return true
                }
            }
            lastDirection = direction
        }
        if now - lastReversal > config.timeWindow { reversals = 0 }
        return false
    }
}
