import CoreGraphics
import Foundation

/// One captured frame as tightly packed RGBA8 pixels, top row first.
struct PixelFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// - Parameter space: drawing in the image's own colour space keeps pixel values unchanged.
    init?(_ image: CGImage, colorSpace space: CGColorSpace = CGColorSpaceCreateDeviceRGB()) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        width = w
        height = h
        guard drawn else { return nil }
        pixels = buffer
    }

    /// Sum of |ΔR|+|ΔG|+|ΔB| between row `y` here and row `otherY` of `other`, over the sampled columns.
    func rowDistance(_ y: Int, _ other: PixelFrame, _ otherY: Int, columns: [Int]) -> Int {
        var sum = 0
        let a = y * width * 4, b = otherY * other.width * 4
        for x in columns {
            let i = a + x * 4, j = b + x * 4
            sum += abs(Int(pixels[i]) - Int(other.pixels[j]))
                + abs(Int(pixels[i + 1]) - Int(other.pixels[j + 1]))
                + abs(Int(pixels[i + 2]) - Int(other.pixels[j + 2]))
        }
        return sum
    }
}

/// Finds how far the content moved between two frames of the same scrolling region.
///
/// Two rows count as the same content when their mean three-channel L1 distance is below 11,
/// the threshold FloGravity uses for the same comparison. The search itself is our own: a textured
/// strip of the new frame is looked up in the previous frame.
enum OverlapMatcher {
    static let sameRowThreshold = 11

    enum Result: Equatable {
        /// Content moved up by `dy` pixel rows (the user scrolled down); negative when it moved down
        /// (the user scrolled up).
        case moved(Int)
        /// Nothing moved.
        case unchanged
        /// No overlap found, typically because the user scrolled more than a screenful at once.
        case lost
        /// The frame has too little detail (blank or flat areas) to line up with the previous one.
        case featureless
    }

    /// Columns compared in every row: most of the width, skipping the edges where overlay scrollbars
    /// appear while scrolling.
    static func columns(width: Int) -> [Int] {
        let start = width * 4 / 100, end = width * 90 / 100
        let count = min(64, max(1, end - start))
        return (0..<count).map { start + ($0 * (end - start)) / count }
    }

    /// Of `columns`, those that stayed put in (nearly) every row while most others changed: a sticky side
    /// panel, or a blank margin, beside content that scrolls. nil when most columns stayed put (nothing
    /// scrolled, or only a caret or a spinner changed) or none did.
    static func stillColumns(_ a: PixelFrame, _ b: PixelFrame, columns: [Int], rowStride: Int = 3) -> [Bool]? {
        let rows = Array(stride(from: 0, to: a.height, by: rowStride))
        let allowed = rows.count / 200
        let still = columns.map { x -> Bool in
            var changed = 0
            for y in rows {
                let i = (y * a.width + x) * 4
                let d = abs(Int(a.pixels[i]) - Int(b.pixels[i])) + abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1]))
                    + abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))
                if d >= 24 { changed += 1; if changed > allowed { return false } }
            }
            return true
        }
        let moving = still.filter { !$0 }.count
        return moving * 10 >= columns.count * 4 && moving < columns.count ? still : nil
    }

    /// - Parameter ignoringBottom: rows at the bottom known not to scroll (a sticky footer).
    static func offset(from previous: PixelFrame, to current: PixelFrame, ignoringBottom footer: Int = 0) -> Result {
        guard previous.width == current.width, previous.height == current.height else { return .lost }
        let h = current.height
        var cols = columns(width: current.width)
        if (0..<h).allSatisfy({ previous.rowDistance($0, current, $0, columns: cols) < sameRowThreshold * cols.count }) { return .unchanged }
        // Columns that never move (a sticky side panel) would make every shifted row look different.
        if let still = stillColumns(previous, current, columns: cols) { cols = zip(cols, still).filter { !$0.1 }.map(\.0) }
        let limit = sameRowThreshold * cols.count

        // Strips at several heights: one may sit in a sticky header (it never moves) or in a blank area.
        let k = max(8, min(48, h / 8))
        let usable = h - footer
        var candidates: [Int] = []
        // The lower strips are what sees content that moved down (scrolling up).
        for fraction in [15, 35, 55, 75] {
            let y0 = h * fraction / 100
            if y0 + k <= usable { candidates.append(y0) }
        }
        // Rows that changed in place: what a scroll has to explain. Fixed parts and blank areas stay put
        // whatever the shift, and would vote for any of them.
        let changed = stride(from: 0, to: usable, by: 3).filter { previous.rowDistance($0, current, $0, columns: cols) >= limit }
        var sawTexture = false
        var shifts = Set<Int>()
        for y0 in candidates {
            guard texture(current, y0, k, cols) >= limit * k / 4 else { continue }
            sawTexture = true
            let found = locate(current, rows: y0..<(y0 + k), in: previous, searchEnd: usable, columns: cols)
            shifts.formUnion(found.filter { $0 != 0 })
        }
        // A short strip matches wherever the content repeats (lines of text, list rows), up or down. The
        // right shift is the one that explains most of the changed rows. A frame can also change without
        // scrolling (a blinking caret, typing, a spinner): then no shift explains much.
        // Within a ±2 px neighbourhood (where different strips found slightly different
        // integer shifts for the same peak), prefer the shift with lower mean pixel error instead of
        // always taking the smaller |dy|, which used to accumulate a downward drift across frames.
        var best: (dy: Int, rows: Int, of: Int, score: Int)?
        let ordered = shifts.sorted { abs($0) != abs($1) ? abs($0) < abs($1) : $0 > $1 }
        for dy in ordered.prefix(60) {
            let overlapping = changed.filter { (0..<usable).contains($0 + dy) }
            var rows = 0, score = 0
            for y in overlapping {
                let d = current.rowDistance(y, previous, y + dy, columns: cols)
                if d < limit { rows += 1; score += d }
            }
            guard rows > 0 else { continue }
            if let b = best {
                let near = abs(dy - b.dy) <= 2
                let betterScore = score * b.rows < b.score * rows
                if near {
                    if rows > b.rows || (rows >= b.rows - 1 && betterScore) {
                        best = (dy, max(rows, b.rows), overlapping.count, score)
                    }
                } else if rows > b.rows {
                    best = (dy, rows, overlapping.count, score)
                }
            } else {
                best = (dy, rows, overlapping.count, score)
            }
        }
        // A wrong shift cannot be taken back, a skipped frame is made up by the next one: take a shift
        // only when it explains a good part of the change where the two frames overlap.
        if let best, best.rows >= max(3, best.of * 3 / 10) { return .moved(best.dy) }
        if changed.count * 10 < usable / 3 { return .unchanged } // a small change in place
        return sawTexture ? .lost : .featureless
    }

    /// How much the strip changes from row to row; blank strips match anywhere and are useless.
    private static func texture(_ f: PixelFrame, _ y0: Int, _ k: Int, _ cols: [Int]) -> Int {
        var sum = 0
        for y in y0..<(y0 + k - 1) { sum += f.rowDistance(y, f, y + 1, columns: cols) }
        return sum
    }

    /// Offsets `dy` such that `strip` of `current` equals rows `strip + dy` of `previous`.
    ///
    /// Positions a row or two off the true one often pass the threshold too, so neighbouring matches are
    /// grouped and each group is represented by its best score. Several groups mean repeating content;
    /// the caller then takes the smallest forward move, since frames are taken often enough that each
    /// move is small.
    private static func locate(_ current: PixelFrame, rows strip: Range<Int>, in previous: PixelFrame,
                               searchEnd: Int, columns cols: [Int]) -> [Int] {
        let limit = sameRowThreshold * cols.count * strip.count
        var groups: [(dy: Int, score: Int, lastDy: Int)] = []
        for y in 0...(searchEnd - strip.count) {
            var score = 0
            for (i, row) in strip.enumerated() {
                score += current.rowDistance(row, previous, y + i, columns: cols)
                if score >= limit { break }
            }
            guard score < limit else { continue }
            let dy = y - strip.lowerBound
            if let g = groups.last, dy - g.lastDy <= 2 {
                groups[groups.count - 1] = score < g.score ? (dy, score, dy) : (g.dy, g.score, dy)
            } else {
                groups.append((dy, score, dy))
            }
        }
        return groups.map(\.dy)
    }
}

struct PreviewTile {
    let image: CGImage
    let top: Int
    let rows: Int
}

/// A whole screen of `rows` canvas rows at canvas row `top`, shown on `bands` (screen rows) across the
/// full width, and on `partialBands` only across `columns` (pixels); on `fillBands` the other columns,
/// `stillColumns`, repeat the screen's last row.
struct PreviewOverlay {
    let image: CGImage
    let top: Int
    let rows: Int
    let bands: [Range<Int>]
    var partialBands: [Range<Int>] = []
    var columns: [Range<Int>] = []
    var fillBands: [Range<Int>] = []
    var stillColumns: [Range<Int>] = []
    /// Flat background colour for still columns below the first screen.
    /// Stretching one screen row used to turn a few scrollbar/divider pixels into
    /// vertical stripes running down the whole long image.
    var fillColor: CGColor?
}

/// What the live preview shows, taken from the stitcher so it can be drawn on another thread.
struct PreviewSnapshot {
    var tiles: [PreviewTile] = []
    var overlays: [PreviewOverlay] = []
    /// Canvas rows of the latest frame; the preview scrolls to keep them in view.
    var focus: Range<Int> = 0..<0
    var width = 1
    var height = 0
}

/// Builds a long image from successive frames of one scrolling region.
///
/// The image is a canvas of document rows. Each frame is written at its scroll offset, row by row:
/// - a row whose content followed the scroll is clean; the first clean copy of a document row is kept;
/// - a row holding pixels that stayed put while the content moved (a floating button, a sticky footer)
///   is only provisional: it fills an empty row, and a clean copy replaces it later.
/// Scrolling either way works: moving above the canvas adds rows at its top, moving back over rows
/// already captured only fills in rows that were provisional. Content passes clean through some part of
/// the view before fixed elements can cover it. Finishing lays the lowest screen reached over the rows
/// never seen clean, so a footer or floating element appears once, at the end.
///
/// Every frame is lined up with the one before it, but only key frames, `keySpacing` rows apart, are
/// written, each judged against frames at least `evidenceShift` rows away on both sides: over a shift of a
/// few rows, as a fast stream sees a smooth scroll, a button on a plain background looks the same as the
/// content around it. A key frame is written once a frame that far away arrives: a flat-coloured element
/// overlapping its own shifted copy gives itself away only at its edges, the lower ones against the
/// earlier frame and the upper ones against the later.
final class ScrollStitcher {
    enum Status: Equatable {
        case appended(Int), unchanged, lost, featureless, full
        /// The frame size changed (display resolution / scaling). No shift can ever match it again.
        case sizeMismatch
        /// The overlap was lost for too many frames in a row: a new segment was started after the
        /// canvas, so the capture continues instead of freezing forever.
        case restarted
    }

    /// Size limits of the long image. Finishing holds the canvas and the image made from it at once,
    /// so 30 M pixels peaks around 250 MB.
    static let maxHeight = 32_000
    static let maxPixels = 30_000_000
    /// Width in pixels of the thumbnails kept for the live preview.
    static let previewWidth = 280

    let width: Int
    let frameHeight: Int
    var heightLimit: Int { min(Self.maxHeight, Self.maxPixels / max(1, width)) }
    /// Rows of the canvas so far.
    private(set) var height: Int
    /// Sticky header rows at the top (window title bar / toolbar), symmetric to `footer`.
    private(set) var header = 0
    private(set) var footer = 0
    private(set) var isFull = false
    /// Downscaled copies of the canvas regions written by each frame, `top` and `rows` in canvas pixels;
    /// drawn in order they show the canvas as it is now.
    private(set) var tiles: [PreviewTile] = []

    private let colorSpace: CGColorSpace
    private var canvas: [UInt8] = []
    private enum RowState: UInt8 { case empty, provisional, clean }
    private var rowStates: [RowState] = []
    /// The latest frame, not yet written, at `offset`; the frame before it with the scroll between them,
    /// and the row kinds of that pair.
    private var last: PixelFrame
    /// Canvas row of `last`'s top.
    private var offset = 0
    private struct Placed { let frame: PixelFrame; var offset: Int }
    /// Key frames not written yet, oldest first, and the latest few written.
    private var pending: [Placed] = []
    private var written: [Placed] = []
    /// Screen rows the latest written key frame had fixed elements on.
    private var writtenFixed: [Bool]?
    private var stillColumns: [Bool]?
    /// Columns that stayed put in every key frame pair so far (a sticky side panel, blank margins). The
    /// panel shows once, as on the highest screen; on the rows below that screen these columns repeat the
    /// screen's last row (usually the background under the panel), since new rows arrive at the bottom of
    /// the screen, where a slice of the panel (a card's edge) would otherwise come along. A rewrite of a
    /// row with a clean copy leaves them alone.
    private var evidenceShift: Int { max(48, frameHeight / 6) }
    private var keySpacing: Int { evidenceShift / 2 }
    /// The frames furthest up and furthest down so far, with preview thumbnails and their canvas rows.
    private var topmost: (frame: PixelFrame, thumbnail: CGImage?, offset: Int)
    private var deepest: (frame: PixelFrame, thumbnail: CGImage?, offset: Int)
    private var footerKnown = false
    /// Consecutive frames the overlap search failed on. After a few, `last` is too old for any shift
    /// to match again, so a new segment is started instead of leaving the capture frozen forever.
    private var lostStreak = 0
    private static let lostStreakLimit = 3
    /// `finish()` writes into the canvas and overlays whole screens, so it must run at most once.
    private var didFinish = false
    private var finishedImage: CGImage?

    init?(first image: CGImage) {
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        colorSpace = own ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let frame = PixelFrame(image, colorSpace: colorSpace) else { return nil }
        last = frame
        pending = [Placed(frame: frame, offset: 0)]
        width = frame.width
        frameHeight = frame.height
        height = frame.height
        topmost = (frame, nil, 0)
        deepest = (frame, nil, 0)
        topmost.thumbnail = thumbnail(frame.pixels, rows: frameHeight)
        deepest.thumbnail = topmost.thumbnail
    }

    func add(_ image: CGImage) -> Status {
        guard !isFull else { return .full }
        // A changed frame size (display resolution / scaling, display switch) can never be lined up
        // with the first frame. Report it separately instead of "scrolled too fast" + a dead session.
        guard let frame = PixelFrame(image, colorSpace: colorSpace),
              frame.width == width, frame.height == frameHeight else { return .sizeMismatch }
        switch OverlapMatcher.offset(from: last, to: frame, ignoringBottom: footer) {
        case .unchanged: return .unchanged
        case .featureless: return .featureless
        case .lost:
            // `last` stays put on a lost frame, so every later frame is compared to an ever staler
            // anchor and the search range eventually cannot cover the accumulated shift. Neither a
            // still nor a featureless frame proves the anchor recovered, so only `.moved` clears this.
            lostStreak += 1
            guard lostStreak >= Self.lostStreakLimit else { return .lost }
            restart(with: frame)
            return .restarted
        case let .moved(dy):
            lostStreak = 0
            if !footerKnown {
                // Kept out of the overlap search; the canvas handles the footer like any fixed element.
                // Also record sticky top header rows so short scrolls never duplicate them.
                header = Self.stillRowsAtTop(last, frame)
                footer = Self.stillRowsAtBottom(last, frame)
                footerKnown = true
            }
            var newOffset = offset + dy
            // When a new keyframe is reached, lock its offset directly against the previous
            // keyframe within ±3 px so 1-px frame-to-frame rounding errors cannot accumulate into
            // multi-pixel drift and squish text bubbles when provisional rows are rewritten.
            if let anchor = pending.last ?? written.last, abs(newOffset - anchor.offset) >= keySpacing,
               abs(newOffset - anchor.offset) < frameHeight - header - footer - 16 {
                newOffset = anchor.offset + refineShift(from: anchor.frame, to: frame, expected: newOffset - anchor.offset)
            }
            if max(height, newOffset + frameHeight) - min(0, newOffset) > heightLimit { isFull = true; return .full }
            offset = newOffset
            if offset < 0 { prepend(rows: -offset) }
            height = max(height, offset + frameHeight)
            last = frame
            let placed = Placed(frame: frame, offset: offset)
            if let key = pending.last ?? written.last, abs(offset - key.offset) >= keySpacing { pending.append(placed) }
            while let key = pending.first, abs(offset - key.offset) >= evidenceShift {
                writeKey(key, neighbours: [placed] + written)
                pending.removeFirst()
            }
            if offset <= topmost.offset || offset >= deepest.offset {
                let small = thumbnail(frame.pixels, rows: frameHeight)
                if offset <= topmost.offset { topmost = (frame, small, offset) }
                if offset >= deepest.offset { deepest = (frame, small, offset) }
            }
            return .appended(dy)
        }
    }

    /// Starts a new segment right after the canvas when the overlap has been lost for too many
    /// frames. The frames in between are missing (the HUD says so out loud), but the capture keeps
    /// going instead of freezing: the current frame is written as a provisional screen, and later
    /// frames append to it normally.
    private func restart(with frame: PixelFrame) {
        lostStreak = 0
        // Flush key frames whose later neighbour never arrived, so they are not silently dropped.
        for key in pending { writeKey(key, neighbours: written) }
        pending.removeAll()
        written.removeAll()
        writtenFixed = nil
        let top = height
        offset = top
        last = frame
        let placed = Placed(frame: frame, offset: top)
        pending = [placed]
        write(frame, at: top, clean: [Bool](repeating: false, count: frameHeight))
        height = max(height, top + frameHeight)
        deepest = (frame, thumbnail(frame.pixels, rows: frameHeight), top)
    }

    /// Canvas rows the latest frame covers.
    var activeRows: Range<Int> { offset..<(offset + frameHeight) }

    /// Screen rows of a screen at canvas row `top` that the canvas has no clean copy of.
    private func unclean(_ top: Int) -> (Int) -> Bool {
        { [rowStates] y in top + y >= rowStates.count || rowStates[top + y] != .clean }
    }

    /// Screen rows the lowest screen shows in the finished image: those not seen clean, and the fixed
    /// elements on its lower half (a floating button over content that had passed clean higher up the
    /// screen), which so appear once, at the end.
    /// When topmost and deepest overlap (short scroll < 1 screen), split the overlap at its
    /// canvas midpoint `mid` and exclude the top `header` rows so deepest never draws a second window
    /// title bar over the upper part of the image.
    private var finalRows: (Int) -> Bool {
        let base = unclean(deepest.offset), fixed = writtenFixed, half = frameHeight / 2
        let top = deepest.offset, first = topmost.offset, h = frameHeight, hdr = header
        let mid = (first + top + h) / 2
        return { y in
            (top == first || (top + y >= mid && y >= hdr)) && (base(y) || (y >= half && fixed?[y] == true))
        }
    }

    /// Rows of the highest screen that may be drawn over the canvas. The fixed footer (composer bar)
    /// is excluded: covering it here put a second composer bar in the *middle* of the long image,
    /// right where the first screen ended. The sticky header is above this range and still shows.
    /// On a short scroll, stop at the overlap midpoint `mid` so topmost never stamps its
    /// bottom composer bar over rows that deepest covers cleanly from its middle.
    private var firstScreenRows: (Int) -> Bool {
        let base = unclean(topmost.offset), bottom = max(0, frameHeight - footer)
        let top = topmost.offset, lastTop = deepest.offset, h = frameHeight
        let mid = (top + lastTop + h) / 2
        return { y in
            y < bottom && (lastTop == top || top + y < mid) && base(y)
        }
    }

    /// What `finish()` would draw over the tiles now: the highest screen, then the lowest, on the rows
    /// not seen clean. Drawn over the tiles they make the preview match the finished image, so fixed
    /// elements show once, at the top and bottom, and never in the middle.
    var overlays: [PreviewOverlay] {
        let moving = movingRuns, still = stillRuns, partial = stillColumns != nil
        let firstScreen = topmost.offset..<(topmost.offset + frameHeight)
        func bands(_ open: (Int) -> Bool) -> [Range<Int>] {
            var bands: [Range<Int>] = []
            var start: Int?
            for y in 0...frameHeight {
                let isOpen = y < frameHeight && open(y)
                if isOpen, start == nil { start = y }
                if !isOpen, let s = start { bands.append(s..<y); start = nil }
            }
            return bands
        }
        return [(topmost, firstScreenRows), (deepest, finalRows)].compactMap { screen, shown in
            guard let image = screen.thumbnail else { return nil }
            let top = screen.offset
            // As `write` and `finish` treat still columns: rows on the canvas keep theirs; rows not written
            // yet show them from this screen on the highest screen, and as its last row below it.
            let written = { [rowStates] (y: Int) in partial && top + y < rowStates.count && rowStates[top + y] != .empty }
            let below = { (y: Int) in partial && !firstScreen.contains(top + y) }
            let full = bands { shown($0) && !written($0) && !below($0) }
            let part = bands { shown($0) && (written($0) || below($0)) }
            let fill = bands { shown($0) && !written($0) && below($0) }
            // The preview fills still columns with the same flat colour as finish().
            let sourceRow = max(0, frameHeight - footer - 1)
            let flatRow = Self.flatFillRow(topmost.frame.pixels, height: frameHeight, row: sourceRow, width: width, columns: still)
            var fillColor: CGColor?
            if let x = still.first?.lowerBound {
                let i = x * 4
                fillColor = CGColor(red: CGFloat(flatRow[i]) / 255, green: CGFloat(flatRow[i + 1]) / 255,
                                    blue: CGFloat(flatRow[i + 2]) / 255, alpha: 1)
            }
            return full.isEmpty && part.isEmpty ? nil
                : PreviewOverlay(image: image, top: top, rows: frameHeight, bands: full, partialBands: part, columns: moving,
                                 fillBands: fill, stillColumns: still, fillColor: fillColor)
        }
    }

    var snapshot: PreviewSnapshot {
        PreviewSnapshot(tiles: tiles, overlays: overlays, focus: activeRows, width: width, height: height)
    }

    /// The finished image. Call once: it writes the highest screen, then the lowest, over the rows never
    /// seen clean, so a header appears once at the top and a footer once at the bottom.
    func finish() -> CGImage? {
        // Writes into the canvas and overlays whole screens: running it twice used to duplicate that
        // work (and could be triggered by a failed "memory low" finish being retried).
        if didFinish { return finishedImage }
        didFinish = true
        let rowBytes = width * 4
        let latest = Placed(frame: last, offset: offset)
        // If the total scroll was shorter than evidenceShift, writeKey() never had a
        // qualified pair to detect stillColumns; detect them from topmost vs deepest directly so
        // a fixed sidebar is not duplicated at the midpoint seam on short scrolls.
        if stillColumns == nil, deepest.offset - topmost.offset >= 16,
           let raw = OverlapMatcher.stillColumns(topmost.frame, deepest.frame, columns: Array(0..<width), rowStride: 2) {
            stillColumns = Self.refineStillColumns(raw, topmost.frame, deepest.frame,
                                                   shift: deepest.offset - topmost.offset,
                                                   header: header, footer: footer)
        }
        for key in pending where key.offset != offset {
            // The last frame is often only a few rows from the last key frame; every other pending
            // key is a candidate too, and writeKey() keeps only those far enough away.
            writeKey(key, neighbours: [latest] + pending.filter { $0.offset != key.offset } + written)
        }
        // The latest frame may be anywhere, its fixed elements included: provisional only.
        write(last, at: offset, clean: [Bool](repeating: false, count: frameHeight))
        pending = []
        if rowStates.count < height {
            canvas.append(contentsOf: repeatElement(0, count: (height - rowStates.count) * rowBytes))
            rowStates.append(contentsOf: repeatElement(.empty, count: height - rowStates.count))
        }
        let moving = movingRuns
        for (screen, shown) in [(topmost, firstScreenRows), (deepest, finalRows)] {
            canvas.withUnsafeMutableBytes { dst in
                screen.frame.pixels.withUnsafeBytes { src in
                    for y in 0..<frameHeight where shown(y) {
                        let to = dst.baseAddress! + (screen.offset + y) * rowBytes, from = src.baseAddress! + y * rowBytes
                        // Like a rewrite: a row already on the canvas keeps its still columns.
                        if rowStates[screen.offset + y] == .empty {
                            to.copyMemory(from: from, byteCount: rowBytes)
                        } else {
                            for run in moving { (to + run.lowerBound * 4).copyMemory(from: from + run.lowerBound * 4, byteCount: run.count * 4) }
                        }
                    }
                }
            }
        }
        // Still columns below the highest screen: one flat background colour.
        let still = stillRuns, firstScreen = topmost.offset..<(topmost.offset + frameHeight)
        if !still.isEmpty {
            // The modal colour of the still columns across the sidebar height, not a single
            // row (which could land on a popup card or scrollbar thumb).
            let fillRow = max(0, frameHeight - footer - 1)
            let flatRow = Self.flatFillRow(topmost.frame.pixels, height: frameHeight, row: fillRow, width: width, columns: still)
            flatRow.withUnsafeBytes { fill in
                canvas.withUnsafeMutableBytes { dst in
                    let bottom = fill.baseAddress!
                    for row in 0..<height where !firstScreen.contains(row) {
                        let to = dst.baseAddress! + row * rowBytes
                        for run in still { (to + run.lowerBound * 4).copyMemory(from: bottom + run.lowerBound * 4, byteCount: run.count * 4) }
                    }
                }
            }
        }
        let data = canvas.withUnsafeBytes { Data($0.prefix(height * rowBytes)) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        finishedImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        // 最终长截图 CGImage 生成完毕后，立即清空底层的中间画布缓冲、行状态与预览切片数组，削减长图导出时的内存峰值
        canvas.removeAll(keepingCapacity: false)
        rowStates.removeAll(keepingCapacity: false)
        tiles.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        written.removeAll(keepingCapacity: false)
        return finishedImage
    }

    // MARK: - Canvas

    /// Makes room for `rows` more rows above the canvas.
    private func prepend(rows n: Int) {
        canvas.insert(contentsOf: repeatElement(0, count: n * width * 4), at: 0)
        rowStates.insert(contentsOf: repeatElement(.empty, count: n), at: 0)
        tiles = tiles.map { PreviewTile(image: $0.image, top: $0.top + n, rows: $0.rows) }
        offset += n
        height += n
        topmost.offset += n
        deepest.offset += n
        for i in pending.indices { pending[i].offset += n }
        for i in written.indices { written[i].offset += n }
    }

    /// Writes a key frame, judged only against frames at least `evidenceShift` rows away on either
    /// side. Over a small shift a flat fixed element looks exactly like scrolling content, so an
    /// unqualified frame is dropped rather than used as a fallback (which used to happen at the very
    /// start of a capture and again in `finish()`). With no pair at all the rows stay provisional and
    /// the last screen covers them, which is safer than a wrong "clean" verdict.
    private func writeKey(_ key: Placed, neighbours candidates: [Placed]) {
        let qualified = candidates.filter { abs($0.offset - key.offset) >= evidenceShift }
        func nearest(_ ahead: Bool) -> Placed? {
            qualified.filter { ahead ? $0.offset > key.offset : $0.offset < key.offset }
                .min { abs($0.offset - key.offset) < abs($1.offset - key.offset) }
        }
        let later = nearest(true), earlier = nearest(false)
        if let other = later ?? earlier,
           let raw = OverlapMatcher.stillColumns(key.frame, other.frame, columns: Array(0..<width), rowStride: 2),
           let still = Self.refineStillColumns(raw, key.frame, other.frame, shift: other.offset - key.offset,
                                               header: header, footer: footer) {
            stillColumns = zip(stillColumns ?? still, still).map { $0 && $1 }
        }
        let moving = movingRuns
        var pairs: [[Kind]] = [], neighbours: [(PixelFrame, Int)] = []
        for other in [later, earlier].compactMap({ $0 }) {
            // Refine the keyframe-to-keyframe shift within ±3 px so sub-step drift does not
            // misalign text edges during pixel-wise fixed/translucent classification.
            let rawShift = other.offset - key.offset
            let refinedShift = refineShift(from: key.frame, to: other.frame, expected: rawShift)
            pairs.append(refinedShift > 0
                ? Self.pairKinds(key.frame, other.frame, shift: refinedShift, moving: moving, knownFixed: writtenFixed)
                : Self.pairKinds(other.frame, key.frame, shift: -refinedShift, moving: moving, knownFixed: writtenFixed))
            neighbours.append((other.frame, -refinedShift))
        }
        var clean = pairs.isEmpty ? [Bool](repeating: false, count: frameHeight)
            : Self.cleanRows(pairs, translucent: Self.translucentRows(of: key.frame, neighbours: neighbours, moving: moving, knownFixed: writtenFixed))
        // The top `header` and bottom `footer` rows are known not to scroll. On a dark, flat-coloured
        // page a title bar or composer bar has too few edges for the pixel-wise fixed-element test, so
        // it was being marked "clean" and stamped into the canvas at *every* scroll position. Keep
        // those rows provisional: topmost draws the header once at the top, and deepest draws the
        // footer once at the end.
        if header > 0 {
            for y in 0..<min(frameHeight, header) { clean[y] = false }
        }
        if footer > 0 {
            for y in max(0, frameHeight - footer)..<frameHeight { clean[y] = false }
        }
        write(key.frame, at: key.offset, clean: clean)
        writtenFixed = clean.map { !$0 }
        written.append(key)
        if written.count > 4 { written.removeFirst() }
    }

    private func write(_ frame: PixelFrame, at top: Int, clean: [Bool]) {
        let rowBytes = width * 4
        let needed = top + frame.height
        if rowStates.count < needed {
            let extra = needed - rowStates.count
            rowStates.append(contentsOf: repeatElement(.empty, count: extra))
            canvas.append(contentsOf: repeatElement(0, count: extra * rowBytes))
        }
        let moving = movingRuns, still = stillRuns, firstScreen = topmost.offset..<(topmost.offset + frameHeight)
        // Flat background colour for the still columns, not a stretched screen row.
        let fillRow = max(0, frame.height - footer - 1)
        let flatRow = Self.flatFillRow(frame.pixels, height: frame.height, row: fillRow, width: width, columns: still)
        flatRow.withUnsafeBytes { fill in
            canvas.withUnsafeMutableBytes { dst in
                frame.pixels.withUnsafeBytes { src in
                    let bottom = fill.baseAddress!
                    for y in 0..<frame.height {
                        let state = rowStates[top + y]
                        guard state == .empty || (state == .provisional && clean[y]) else { continue }
                        let to = dst.baseAddress! + (top + y) * rowBytes, from = src.baseAddress! + y * rowBytes
                        if state == .empty {
                            to.copyMemory(from: from, byteCount: rowBytes)
                            if !firstScreen.contains(top + y) {
                                for run in still { (to + run.lowerBound * 4).copyMemory(from: bottom + run.lowerBound * 4, byteCount: run.count * 4) }
                            }
                        } else {
                            for run in moving { (to + run.lowerBound * 4).copyMemory(from: from + run.lowerBound * 4, byteCount: run.count * 4) }
                        }
                        rowStates[top + y] = clean[y] ? .clean : .provisional
                    }
                }
            }
        }
        if let tile = makeTile(rows: top..<needed) {
            // A tile is a copy of the canvas rows it covers, so one covering an older tile's rows replaces it.
            tiles.removeAll { $0.top >= top && $0.top + $0.rows <= needed }
            tiles.append(PreviewTile(image: tile, top: top, rows: needed - top))
        }
    }

    /// Refines the shift `dy` (where `b` is scrolled `dy` further than `a`) within ±3 px
    /// over the moving columns so accumulated frame-to-frame rounding errors do not misalign keyframes.
    private func refineShift(from a: PixelFrame, to b: PixelFrame, expected dy: Int) -> Int {
        let cols = OverlapMatcher.columns(width: width).filter { stillColumns?[$0] != true }
        guard !cols.isEmpty else { return dy }
        let top = header, bottom = max(top, frameHeight - footer)
        let sampleRows = stride(from: top, to: bottom, by: 3).filter { (top..<bottom).contains($0 + dy) }
        guard sampleRows.count >= 8 else { return dy }
        var bestDy = dy, bestMean = Int.max
        for candidate in (dy - 3)...(dy + 3) where candidate != 0 {
            var score = 0, count = 0
            for y in sampleRows where (top..<bottom).contains(y + candidate) {
                score += b.rowDistance(y, a, y + candidate, columns: cols)
                count += 1
            }
            guard count >= 8 else { continue }
            let mean = score / count
            if candidate == dy {
                if mean < bestMean { bestMean = mean; bestDy = candidate }
            } else if mean + cols.count < bestMean {
                bestMean = mean
                bestDy = candidate
            }
        }
        return bestDy
    }

    /// Refines per-column `stillColumns` so that:
    /// 1) columns in a fixed sidebar where a tooltip, hover or carousel changed in place (without
    ///    scrolling by `dy`) stay marked as still rather than punching a moving strip through the sidebar;
    /// 2) only the exterior left/right sidebars around the single main scrolling viewport are kept as
    ///    still columns (closing any holes inside a sidebar or between text columns);
    /// 3) blank margins of the scrolling viewport that share its background colour are not mistaken
    ///    for a fixed sidebar (which used to lock the first screen's floating widgets in the margin and
    ///    chop off the bottom composer bar's left/right ends).
    private static func refineStillColumns(_ rawStill: [Bool], _ a: PixelFrame, _ b: PixelFrame,
                                           shift dy: Int, header: Int, footer: Int) -> [Bool]? {
        let w = a.width, h = a.height, rowBytes = w * 4
        guard rawStill.count == w, w > 0, h > 0 else { return nil }
        var still = rawStill
        let yTop = max(0, header), yBottom = max(yTop + 1, h - footer)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                func dist(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, _ q: UnsafeBufferPointer<UInt8>, _ j: Int) -> Int {
                    abs(Int(p[i]) - Int(q[j])) + abs(Int(p[i + 1]) - Int(q[j + 1])) + abs(Int(p[i + 2]) - Int(q[j + 2]))
                }
                for x in 0..<w where !still[x] {
                    var fixed = 0, moved = 0
                    let xOff = x * 4
                    for y in stride(from: yTop, to: yBottom, by: 2) {
                        guard (0..<h).contains(y + dy) else { continue }
                        let row = y * rowBytes + xOff, shifted = (y + dy) * rowBytes + xOff
                        let dSame = dist(pb, row, pa, row)
                        let dShift = dist(pb, row, pa, shifted)
                        let dOther = dist(pb, shifted, pa, shifted)
                        if dSame >= 24 {
                            if dShift < 40, dOther >= 24 { moved += 1 }
                        } else if dShift >= 40, dOther >= 24 {
                            fixed += 1
                        }
                    }
                    if fixed > moved * 2 && fixed >= 6 { still[x] = true }
                }
            }
        }
        // Bridge narrow still gaps (e.g. blank spacing between columns of text) inside the scrolling area,
        // then keep the single widest moving span `[contentLeft..<contentRight]`.
        var movingSpans: [Range<Int>] = []
        var x = 0
        while x < w {
            guard !still[x] else { x += 1; continue }
            let start = x
            while x < w, !still[x] { x += 1 }
            if let last = movingSpans.last, start - last.upperBound <= max(24, w / 8) {
                movingSpans[movingSpans.count - 1] = last.lowerBound..<x
            } else {
                movingSpans.append(start..<x)
            }
        }
        guard let mainSpan = movingSpans.max(by: { $0.count < $1.count }),
              mainSpan.count * 10 >= w * 3 else { return nil }
        var contentLeft = mainSpan.lowerBound, contentRight = mainSpan.upperBound

        // Trim blank margins of the scrolling viewport that share its modal background colour in the
        // upper-middle scrolling band (above any bottom-half floating widgets or composer box).
        let bandStart = max(header, h / 6)
        let bandEnd = max(bandStart + 8, min(h - footer, h * 2 / 3))
        let bandRows = Array(stride(from: bandStart, to: bandEnd, by: max(1, (bandEnd - bandStart) / 48)))
        if !bandRows.isEmpty {
            var bgCounts: [UInt32: Int] = [:]
            let sampleCols = (0..<min(32, mainSpan.count)).map { contentLeft + ($0 * mainSpan.count) / min(32, mainSpan.count) }
            var totalSamples = 0
            for y in bandRows {
                let rowBase = y * rowBytes
                for cx in sampleCols {
                    let i = rowBase + cx * 4
                    let key = UInt32(a.pixels[i]) << 16 | UInt32(a.pixels[i + 1]) << 8 | UInt32(a.pixels[i + 2])
                    bgCounts[key, default: 0] += 1
                    totalSamples += 1
                }
            }
            if let (bgKey, bgHits) = bgCounts.max(by: { $0.value < $1.value }), bgHits * 10 >= totalSamples * 2 {
                let bgR = Int((bgKey >> 16) & 0xff), bgG = Int((bgKey >> 8) & 0xff), bgB = Int(bgKey & 0xff)
                func isBlankContentMargin(_ col: Int) -> Bool {
                    var matches = 0
                    for y in bandRows {
                        let i = (y * w + col) * 4
                        let d = abs(Int(a.pixels[i]) - bgR) + abs(Int(a.pixels[i + 1]) - bgG) + abs(Int(a.pixels[i + 2]) - bgB)
                        if d < 12 { matches += 1 }
                    }
                    return matches * 10 >= bandRows.count * 9
                }
                while contentLeft > 0, isBlankContentMargin(contentLeft - 1) { contentLeft -= 1 }
                while contentRight < w, isBlankContentMargin(contentRight) { contentRight += 1 }
                // A narrow strip left over at the very right edge (< 1.5% of width) is an overlay scrollbar,
                // not a fixed side panel.
                if w - contentRight > 0, w - contentRight <= max(16, w / 70) {
                    contentRight = w
                }
            }
        }
        guard contentLeft > 0 || contentRight < w else { return nil }
        return (0..<w).map { $0 < contentLeft || $0 >= contentRight }
    }

    /// A copy of one screen row whose still columns are set to their background colour.
    /// Computes the modal background colour per still run across the height of the panel
    /// (rather than from a single row that might cross a popup card or button), while keeping any
    /// full-height vertical divider line (such as a 2-px sidebar border) at its own modal colour.
    private static func flatFillRow(_ pixels: [UInt8], height: Int, row: Int, width: Int, columns: [Range<Int>]) -> [UInt8] {
        let rowBytes = width * 4
        var flat = Array(pixels[row * rowBytes..<(row + 1) * rowBytes])
        let maxRow = max(0, min(height - 1, row))
        let step = max(1, (maxRow + 1) / 64)
        var sampleRows = Array(stride(from: 0, through: maxRow, by: step))
        // Weight the bottom content area so a 3/4-height sticky panel (stickyPanelTest) still yields to
        // the page background below it, while a full-height sidebar yields to its true background colour
        // rather than a floating promo card near the bottom.
        let bottomStart = maxRow * 3 / 4
        for y in stride(from: bottomStart, through: maxRow, by: max(1, step / 2)) {
            sampleRows.append(y)
        }
        for run in columns where !run.isEmpty {
            var runCounts: [UInt32: Int] = [:]
            let xStep = max(1, run.count / 64)
            for y in sampleRows {
                let base = y * rowBytes
                for x in stride(from: run.lowerBound, to: run.upperBound, by: xStep) {
                    let i = base + x * 4
                    let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                    runCounts[key, default: 0] += 1
                }
            }
            guard let runBest = runCounts.max(by: { $0.value < $1.value })?.key else { continue }
            let runR = UInt8((runBest >> 16) & 0xff), runG = UInt8((runBest >> 8) & 0xff), runB = UInt8(runBest & 0xff)
            for x in run {
                var colCounts: [UInt32: Int] = [:]
                for y in sampleRows {
                    let i = y * rowBytes + x * 4
                    let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                    colCounts[key, default: 0] += 1
                }
                let i = x * 4
                if let (colBest, hits) = colCounts.max(by: { $0.value < $1.value }), hits * 10 >= sampleRows.count * 7 {
                    flat[i] = UInt8((colBest >> 16) & 0xff)
                    flat[i + 1] = UInt8((colBest >> 8) & 0xff)
                    flat[i + 2] = UInt8(colBest & 0xff)
                } else {
                    flat[i] = runR; flat[i + 1] = runG; flat[i + 2] = runB
                }
            }
        }
        return flat
    }

    /// Runs of columns a rewrite of a row already on the canvas may change: all but `stillColumns`.
    private var movingRuns: [Range<Int>] { runs(where: false) }
    private var stillRuns: [Range<Int>] { runs(where: true) }

    private func runs(where wanted: Bool) -> [Range<Int>] {
        guard let still = stillColumns else { return wanted ? [] : [0..<width] }
        var runs: [Range<Int>] = []
        var x = 0
        while x < width {
            guard still[x] == wanted else { x += 1; continue }
            let start = x
            while x < width, still[x] == wanted { x += 1 }
            runs.append(start..<x)
        }
        return runs
    }

    private enum Kind { case fixed, content, flat }

    /// Rows of a frame free of fixed elements, from the row kinds of the pairs it is in and the rows its
    /// translucent elements cover. Flat rows next to a fixed row belong to the same element (the plain
    /// middle of a sticky bar or button); a small margin covers soft edges.
    private static func cleanRows(_ pairs: [[Kind]], translucent: [Bool]) -> [Bool] {
        let h = translucent.count
        var kinds = (0..<h).map { y -> Kind in
            translucent[y] || pairs.contains { $0[y] == .fixed } ? .fixed : pairs.contains { $0[y] == .content } ? .content : .flat
        }
        var y = 0
        while y < h {
            guard kinds[y] == .flat else { y += 1; continue }
            var end = y
            while end < h, kinds[end] == .flat { end += 1 }
            let touchesFixed = (y > 0 && kinds[y - 1] == .fixed) || (end < h && kinds[end] == .fixed)
            if touchesFixed { for k in y..<end { kinds[k] = .fixed } }
            y = end
        }
        var clean = [Bool](repeating: true, count: h)
        for y in 0..<h where kinds[y] == .fixed {
            for k in max(0, y - 3)...min(h - 1, y + 3) { clean[k] = false }
        }
        return clean
    }

    /// Screen row kinds of a pair of frames, `b` scrolled `dy` further than `a`, as far as opaque fixed
    /// elements go. These sit on the same screen rows in both frames, so each frame's evidence counts for
    /// the other: the lower part of a flat button shows up against `a`, the upper part against `b`.
    private static func pairKinds(_ a: PixelFrame, _ b: PixelFrame, shift dy: Int,
                                  moving: [Range<Int>], knownFixed: [Bool]?) -> [Kind] {
        zip(kinds(of: a, other: b, shift: -dy, moving: moving, knownFixed: knownFixed),
            kinds(of: b, other: a, shift: dy, moving: moving, knownFixed: knownFixed)).map { x, y in
            x == .fixed || y == .fixed ? .fixed : x == .content || y == .content ? .content : .flat
        }
    }

    /// Row kinds of `b` judged against the neighbouring frame `a`, in which the same content sits `shift`
    /// rows further down.
    ///
    /// Per pixel: unchanged in place but not matching the scrolling content at its shifted position means
    /// something opaque fixed on screen (a shifted position out of view, or not scrolling because another
    /// fixed element covers it, tells nothing: plain content can match itself in place by chance); changed
    /// in place and matching scrolling content at its shifted position means content. A row with a few
    /// fixed pixels is fixed, one with a few content pixels is content. Flat rows show neither (a solid
    /// bar looks the same in place and shifted).
    /// Restricts scanning to `moving` columns (so a fixed sidebar cannot mark scrolling rows as
    /// `.fixed`) and ignores shifted positions covered by `knownFixed` in the neighbour.
    private static func kinds(of b: PixelFrame, other a: PixelFrame, shift dy: Int,
                              moving: [Range<Int>], knownFixed: [Bool]?) -> [Kind] {
        let w = b.width, h = b.height, rowBytes = w * 4
        let movingWidth = max(1, moving.reduce(0) { $0 + $1.count })
        let enough = max(3, movingWidth / 200)
        var kinds = [Kind](repeating: .flat, count: h)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                func distance(_ i: Int, _ j: Int) -> Int {
                    abs(Int(pb[i]) - Int(pa[j])) + abs(Int(pb[i + 1]) - Int(pa[j + 1])) + abs(Int(pb[i + 2]) - Int(pa[j + 2]))
                }
                for y in 0..<h {
                    var fixed = 0, moved = 0
                    let row = y * rowBytes, shifted = (y + dy) * rowBytes
                    let inView = (0..<h).contains(y + dy) && knownFixed?[y + dy] != true
                    let coveredByNeighbourFixed = (0..<h).contains(y + dy) && knownFixed?[y + dy] == true && knownFixed?[y] == false
                    outer: for run in moving {
                        for x in stride(from: run.lowerBound * 4, to: run.upperBound * 4, by: 4) {
                            if distance(row + x, row + x) >= 24 {
                                // Changed, and found again where the scroll took it, among content that is
                                // scrolling there too: content. A spinner or a caret changes in place as well,
                                // and on a dark page can look like a still dark spot by chance.
                                if inView, distance(row + x, shifted + x) < 40, distance(shifted + x, shifted + x) >= 24 {
                                    moved += 1
                                } else if coveredByNeighbourFixed {
                                    moved += 1
                                }
                                continue
                            }
                            guard inView, distance(row + x, shifted + x) >= 40 else { continue }
                            // A floating widget (mascot / badge) over a flat background margin has
                            // `distance(shifted, shifted) == 0` because the background at `y + dy` is flat in both
                            // frames; its own stationary horizontal edges at `row` still give it away.
                            let shiftedMoved = distance(shifted + x, shifted + x) >= 24
                            let stationaryEdge = x > run.lowerBound * 4 && distance(row + x - 4, row + x - 4) < 24
                                && abs(Int(pb[row + x]) - Int(pb[row + x - 4]))
                                 + abs(Int(pb[row + x + 1]) - Int(pb[row + x - 3]))
                                 + abs(Int(pb[row + x + 2]) - Int(pb[row + x - 2])) >= 24
                            guard shiftedMoved || stationaryEdge else { continue }
                            fixed += 1
                            if fixed >= enough { break outer }
                        }
                    }
                    kinds[y] = fixed >= enough ? .fixed : moved >= enough ? .content : .flat
                }
            }
        }
        return kinds
    }

    /// Rows of `b` covered by a translucent fixed element (a blurred bar, a shadow), judged against its
    /// neighbours, each with the shift at which the same content sits in it.
    ///
    /// Such a pixel changes with the content underneath but never matches it: it misses the scrolling
    /// content at its shifted position in every neighbour where that is visible. Missing it can also be
    /// the neighbour's own element covering the content there instead, so rows known to hold a fixed element
    /// count for nothing as shifted positions; with nothing else to judge by, such a row stays fixed.
    private static func translucentRows(of b: PixelFrame, neighbours: [(PixelFrame, Int)],
                                        moving: [Range<Int>], knownFixed: [Bool]?) -> [Bool] {
        let w = b.width, h = b.height, rowBytes = w * 4
        let movingWidth = max(1, moving.reduce(0) { $0 + $1.count })
        let enough = max(3, movingWidth / 200)
        func distance(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, _ q: UnsafeBufferPointer<UInt8>, _ j: Int) -> Int {
            abs(Int(p[i]) - Int(q[j])) + abs(Int(p[i + 1]) - Int(q[j + 1])) + abs(Int(p[i + 2]) - Int(q[j + 2]))
        }
        var rows = [Bool](repeating: false, count: h)
        // At most two neighbours; their pixels are copied out once rather than borrowed per pixel.
        let others = neighbours.map { (pixels: $0.0.pixels, dy: $0.1) }
        b.pixels.withUnsafeBufferPointer { pb in
            others.withUnsafeBufferPointer { list in
                for y in 0..<h {
                    var count = 0
                    let ownFixed = knownFixed?[y] ?? false
                    outer: for run in moving {
                        pixels: for x in stride(from: run.lowerBound * 4, to: run.upperBound * 4, by: 4) {
                            let i = y * rowBytes + x
                            var seen = false
                            for n in list {
                                let missed = n.pixels.withUnsafeBufferPointer { pf -> Bool? in
                                    if distance(pb, i, pf, i) < 24 { return false } // stayed put: not translucent
                                    guard (0..<h).contains(y + n.dy), knownFixed?[y + n.dy] != true else { return nil } // out of view, covered
                                    let j = (y + n.dy) * rowBytes + x
                                    guard distance(pb, j, pf, j) >= 24 else { return nil } // not scrolling there
                                    return distance(pb, i, pf, j) >= 40
                                }
                                if missed == false { continue pixels }
                                if missed == true { seen = true }
                            }
                            // Nothing to judge by: a row that held a fixed element in the previous frame still does.
                            if seen || ownFixed { count += 1; if count >= enough { rows[y] = true; break outer } }
                        }
                    }
                }
            }
        }
        return rows
    }

    private func makeTile(rows: Range<Int>) -> CGImage? {
        canvas.withUnsafeBytes { thumbnail(UnsafeRawBufferPointer(rebasing: $0[(rows.lowerBound * width * 4)...]), rows: rows.count) }
    }

    private func thumbnail(_ pixels: [UInt8], rows: Int) -> CGImage? {
        pixels.withUnsafeBytes { thumbnail($0, rows: rows) }
    }

    /// `rows` rows of canvas-format pixels, scaled down to the preview width. Reads `pixels` only here.
    private func thumbnail(_ pixels: UnsafeRawBufferPointer, rows: Int) -> CGImage? {
        let rowBytes = width * 4
        guard rows > 0, let base = pixels.baseAddress,
              let source = CGContext(data: UnsafeMutableRawPointer(mutating: base), width: width, height: rows, bitsPerComponent: 8,
                                     bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let region = source.makeImage() else { return nil }
        let tw = min(width, Self.previewWidth)
        let th = max(1, rows * tw / width)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    /// Symmetric to `stillRowsAtBottom` — detects a fixed window title bar or sticky header.
    private static func stillRowsAtTop(_ a: PixelFrame, _ b: PixelFrame) -> Int {
        let cols = OverlapMatcher.columns(width: a.width)
        let limit = OverlapMatcher.sameRowThreshold * cols.count
        var n = 0
        while n < a.height / 2, a.rowDistance(n, b, n, columns: cols) < limit { n += 1 }
        return n
    }

    private static func stillRowsAtBottom(_ a: PixelFrame, _ b: PixelFrame) -> Int {
        let cols = OverlapMatcher.columns(width: a.width)
        let limit = OverlapMatcher.sameRowThreshold * cols.count
        var n = 0
        while n < a.height / 2, a.rowDistance(a.height - 1 - n, b, b.height - 1 - n, columns: cols) < limit { n += 1 }
        return n
    }

    /// Copies rows into their own image.
    static func copyRows(_ image: CGImage, _ rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty, let crop = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return ctx.makeImage()
    }
}
