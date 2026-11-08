import AppKit

/// `--selftest <out.png>`: renders a synthetic screen with every tool, no screen-recording permission needed.
enum SelfTest {
    static func run(output: String) {
        guard penStraightenTest(), stitchTest() else { exit(1) }
        let size = CGSize(width: 400, height: 300), scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top half blue, bottom half yellow in screen orientation (CGContext origin is bottom-left).
        ctx.setFillColor(NSColor.systemYellow.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
        ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x: 0, y: 300, width: 800, height: 300))
        // Checker pattern in the top-left so the mosaic has something to pixelate.
        for i in 0..<20 { for j in 0..<10 where (i + j) % 2 == 0 {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: i * 8, y: 600 - (j + 1) * 8, width: 8, height: 8))
        } }
        let frozen = ctx.makeImage()!

        let view = OverlayView(frame: CGRect(origin: .zero, size: size), frozen: frozen)
        view.loadForTesting(selection: CGRect(x: 0, y: 0, width: 300, height: 200), annotations: [
            .mosaic(CGRect(x: 0, y: 0, width: 80, height: 40)),
            .rectangle(CGRect(x: 100, y: 20, width: 80, height: 50), .systemRed, 3),
            .ellipse(CGRect(x: 200, y: 20, width: 80, height: 50), .systemGreen, 3),
            .arrow(CGPoint(x: 20, y: 180), CGPoint(x: 150, y: 110), .systemRed, 3),
            .pen([CGPoint(x: 180, y: 180), CGPoint(x: 220, y: 140), CGPoint(x: 260, y: 180)], .magenta, 3),
            .pen([CGPoint(x: 100, y: 140), CGPoint(x: 160, y: 140)], NSColor.systemYellow.withAlphaComponent(0.4), 16),
            .text("Top-left 文字", CGPoint(x: 100, y: 80), .black, 20),
        ])
        guard let image = view.renderSelection(), let data = ImageOutput.pngData(image) else {
            print("selftest: render failed"); exit(1)
        }
        try! data.write(to: URL(fileURLWithPath: output))
        print("selftest: wrote \(image.width)x\(image.height) to \(output)")
        exit(0)
    }

    /// 验证画笔工具的直线自动识别：带轻微手抖的近似直线应被替换为首尾两点，明显弯曲的曲线应保留原轨迹。
    static func penStraightenTest() -> Bool {
        // 带有手抖偏移的近似直线（长度 200pt，最大偏移 6pt）
        let wobblyLine: [CGPoint] = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 150, y: 104),
            CGPoint(x: 200, y: 95),
            CGPoint(x: 250, y: 106),
            CGPoint(x: 300, y: 102),
        ]
        let straightened = Annotation.straightenedPenPoints(wobblyLine)
        let lineOK = straightened == [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 102)]

        // 明显的折线/曲线（V 字形，偏移 40pt）不应被拉直
        let curvePoints: [CGPoint] = [
            CGPoint(x: 180, y: 180),
            CGPoint(x: 220, y: 140),
            CGPoint(x: 260, y: 180),
        ]
        let preserved = Annotation.straightenedPenPoints(curvePoints)
        let curveOK = preserved == curvePoints

        let pass = lineOK && curveOK
        print("selftest: pen straighten \(pass ? "OK" : "FAILED") (line=\(straightened.count) pts, curve=\(preserved.count) pts)")
        return pass
    }

    /// Scrolls a synthetic document under a window with a sticky header and footer, including a jump
    /// that loses the overlap and a scroll back, and expects the stitched image to match exactly.
    static func stitchTest() -> Bool {
        let w = 600, docHeight = 4000, viewport = 1000, bar = 80
        let content = viewport - 2 * bar
        let doc = syntheticDocument(width: w, height: docHeight)
        let header = solid(w, bar, r: 40, g: 90, b: 200), footer = solid(w, bar, r: 30, g: 160, b: 90)

        func frame(at offset: Int) -> CGImage {
            compose(w, [header, ScrollStitcher.copyRows(doc, offset..<(offset + content))!, footer])
        }

        let maxOffset = docHeight - content
        // 1400 jumps past a screenful (lost); 480 scrolls back up a little.
        var offsets = [0, 0, 150, 300, 500, 480, 520, 1400, 900, 1200]
        var o = 1200
        while o < maxOffset { o = min(o + 250, maxOffset); offsets.append(o) }

        guard let stitcher = ScrollStitcher(first: frame(at: offsets[0])) else { print("stitchtest: init failed"); return false }
        var statuses: [ScrollStitcher.Status] = []
        for offset in offsets.dropFirst() { statuses.append(stitcher.add(frame(at: offset))) }
        let expectedStatuses: [ScrollStitcher.Status] = [.unchanged, .appended(150), .appended(150), .appended(200),
                                                         .appended(-20), .appended(40), .lost, .appended(380), .appended(300)]
        var ok = Array(statuses.prefix(expectedStatuses.count)) == expectedStatuses
        print("stitchtest: statuses \(ok ? "OK" : "MISMATCH") \(statuses.prefix(expectedStatuses.count))")
        print("stitchtest: footer=\(stitcher.footer) (expected \(bar))")
        ok = ok && stitcher.footer == bar

        guard let result = stitcher.finish(), let got = PixelFrame(result),
              let want = PixelFrame(compose(w, [header, doc, footer])) else { print("stitchtest: finish failed"); return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: differing rows \(differingRows(got, want))") }
        print("stitchtest: result \(got.width)×\(got.height), expected \(want.width)×\(want.height), pixels \(same ? "identical" : "DIFFER")")
        let floating = [floatingTest(alpha: 1), floatingTest(alpha: 0.6), // opaque, and translucent like a blurred bar
                        floatingTest(alpha: 1, smooth: 16), floatingTest(alpha: 1, smooth: 32)].allSatisfy { $0 }
        return ok && same && repeatingTest() && floating && sidebarTest() && stickyPanelTest() && upwardTest() && textLikeTest() && composerTest()
            && restartTest() && sizeMismatchTest() && darkChatTest()
            && shortScrollTest() && sidebarTooltipAndMarginTest() && darkBubbleSubstepTest()
    }

    /// Losing the overlap for several frames in a row used to freeze the capture forever, because
    /// `last` was never updated and every later frame was measured against an ever staler anchor.
    /// A new segment must start, scrolling must resume, and finish() must not leave black rows.
    private static func restartTest() -> Bool {
        let w = 600, viewport = 1000, bar = 80
        let doc = syntheticDocument(width: w, height: 9000)
        func frame(_ o: Int) -> CGImage {
            compose(w, [solid(w, bar, r: 40, g: 90, b: 200),
                        ScrollStitcher.copyRows(doc, o..<(o + viewport - 2 * bar))!,
                        solid(w, bar, r: 30, g: 160, b: 90)])
        }
        guard let st = ScrollStitcher(first: frame(0)) else { return false }
        let statuses = [100, 200, 300, 1500, 1600, 1700, 1800, 1900].map { st.add(frame($0)) }
        let restarts = statuses.filter { if case .restarted = $0 { return true } else { return false } }.count
        let resumed = statuses.suffix(2).allSatisfy { if case .appended = $0 { return true } else { return false } }
        guard let result = st.finish(), let px = PixelFrame(result) else {
            print("stitchtest: lost recovery FAILED (finish returned nil)"); return false
        }
        var longestBlack = 0, streak = 0
        for y in 0..<px.height {
            let i = y * px.width * 4 + 200 * 4
            let black = px.pixels[i] == 0 && px.pixels[i + 1] == 0 && px.pixels[i + 2] == 0
            streak = black ? streak + 1 : 0
            longestBlack = max(longestBlack, streak)
        }
        let pass = restarts == 1 && resumed && px.height >= 2 * viewport && longestBlack < 20
        print("stitchtest: lost recovery \(pass ? "OK" : "FAILED") (restarted \(restarts)x, height \(px.height), longest black run \(longestBlack))")
        return pass
    }

    /// A frame whose size changed (display resolution / scaling) must not be reported as "scrolled
    /// too fast": that used to send the user into the same dead end as a lost overlap.
    private static func sizeMismatchTest() -> Bool {
        let w = 600, viewport = 1000, bar = 80
        let doc = syntheticDocument(width: w, height: 4000)
        func frame(_ o: Int) -> CGImage {
            compose(w, [solid(w, bar, r: 40, g: 90, b: 200),
                        ScrollStitcher.copyRows(doc, o..<(o + viewport - 2 * bar))!,
                        solid(w, bar, r: 30, g: 160, b: 90)])
        }
        guard let st = ScrollStitcher(first: frame(0)) else { return false }
        _ = st.add(frame(100))
        let changed = st.add(solid(w + 1, viewport, r: 10, g: 10, b: 10))
        let ok = changed == .sizeMismatch
        print("stitchtest: size mismatch \(ok ? "OK" : "FAILED") (\(changed))")
        return ok
    }

    /// A dark chat window: fixed side columns, a low-texture composer bar fixed at the bottom, and
    /// dark scrolling content. Regression for the reported "fixed elements break the long image":
    /// the still columns below the first screen were filled from the *last* screen row, which is the
    /// composer bar, so the whole lower half turned the bar's grey (and the bar appeared mid-image).
    private static func darkChatTest() -> Bool {
        let w = 600, viewport = 1000, bar = 80, sidebar = 140, right = 520
        let content = viewport - bar, docHeight = 2000
        func box(_ c: CGContext, _ x: Int, _ y: Int, _ cw: Int, _ ch: Int,
                 _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            c.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
            c.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cw), height: CGFloat(ch)))
        }
        let d = rgbContext(w, docHeight)
        box(d, 0, 0, w, docHeight, 24, 24, 26)
        var seed: UInt32 = 4242
        func next() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12345; return CGFloat((seed >> 16) & 0xff) / 255 }
        var y = 0
        while y < docHeight {
            let band = 46 + Int(next() * 34)
            box(d, sidebar + 14, docHeight - y - band + 8, 60 + Int(next() * 250), 9, 190, 190, 200)
            y += band
        }
        let doc = d.makeImage()!
        func frame(_ off: Int) -> CGImage {
            let c = rgbContext(w, viewport)
            box(c, 0, 0, w, viewport, 24, 24, 26)
            c.saveGState()
            c.clip(to: CGRect(x: CGFloat(sidebar), y: CGFloat(bar),
                              width: CGFloat(right - sidebar), height: CGFloat(content)))
            c.draw(ScrollStitcher.copyRows(doc, off..<(off + content))!,
                   in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(viewport)))
            c.restoreGState()
            box(c, 0, 0, sidebar, viewport, 32, 32, 36) // fixed left conversation list
            for i in 0..<8 { box(c, 12, viewport - 70 - i * 96, 22, 22, 90, 90, 100) }
            box(c, right, 0, w - right, viewport, 36, 36, 40) // fixed right column
            box(c, 0, 0, w, bar, 60, 60, 72) // fixed composer bar, almost no texture
            return c.makeImage()!
        }
        guard let st = ScrollStitcher(first: frame(0)) else { return false }
        for off in [40, 80, 120, 160, 200, 240, 280] { _ = st.add(frame(off)) }
        guard let result = st.finish(), let px = PixelFrame(result) else { return false }
        func colour(_ x: Int, _ yy: Int) -> (Int, Int, Int) {
            let i = yy * px.width * 4 + x * 4
            return (Int(px.pixels[i]), Int(px.pixels[i + 1]), Int(px.pixels[i + 2]))
        }
        let left = colour(20, px.height - 200), rightCol = colour(560, px.height - 200)
        // Before the fix these were (60,60,72), the composer bar colour smeared down every column.
        let stillClean = left.1 < 50 && rightCol.1 < 50
        var bars = 0, run = 0
        for yy in 0..<px.height {
            let c = colour(300, yy)
            let hit = abs(c.0 - 60) < 10 && abs(c.1 - 60) < 10 && abs(c.2 - 72) < 10
            if hit { run += 1 } else { if run >= 40 { bars += 1 }; run = 0 }
        }
        if run >= 40 { bars += 1 }
        let pass = stillClean && bars == 1
        print("stitchtest: dark chat fixed elements \(pass ? "OK" : "FAILED") (still columns \(left)/\(rightCol), full composer bars \(bars), height \(px.height))")
        return pass
    }

    /// Short scroll (< 1/4 screen and < evidenceShift) with a sticky header, sticky footer,
    /// and fixed left sidebar. Regression for issue 3.1: deepest's whole-screen overlay used to stamp
    /// a second window title bar right below the first and duplicate the sidebar at the seam.
    private static func shortScrollTest() -> Bool {
        let w = 600, viewport = 1000, headerH = 80, footerH = 120, sidebarW = 140, totalScroll = 80
        let contentH = viewport - headerH - footerH
        let doc = syntheticDocument(width: w - sidebarW, height: contentH + totalScroll + 200)
        func frame(_ off: Int) -> CGImage {
            let c = rgbContext(w, viewport)
            // Scrolling content on the right
            c.draw(ScrollStitcher.copyRows(doc, off..<(off + contentH))!,
                   in: CGRect(x: CGFloat(sidebarW), y: CGFloat(footerH), width: CGFloat(w - sidebarW), height: CGFloat(contentH)))
            // Sticky top title bar across the content pane
            c.setFillColor(red: 40 / 255, green: 90 / 255, blue: 200 / 255, alpha: 1)
            c.fill(CGRect(x: sidebarW, y: viewport - headerH, width: w - sidebarW, height: headerH))
            // Sticky bottom composer bar across the content pane
            c.setFillColor(red: 30 / 255, green: 160 / 255, blue: 90 / 255, alpha: 1)
            c.fill(CGRect(x: sidebarW, y: 0, width: w - sidebarW, height: footerH))
            // Fixed left sidebar with a distinct avatar block near the bottom
            c.setFillColor(red: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: sidebarW, height: viewport))
            c.setFillColor(red: 220 / 255, green: 80 / 255, blue: 80 / 255, alpha: 1)
            c.fill(CGRect(x: 20, y: 30, width: 40, height: 30))
            return c.makeImage()!
        }
        guard let st = ScrollStitcher(first: frame(0)) else { return false }
        for off in [10, 22, 36, 48, 64, 80] { _ = st.add(frame(off)) }
        guard let result = st.finish(), let px = PixelFrame(result) else { return false }
        func countRuns(x: Int, r: Int, g: Int, b: Int, minRun: Int) -> Int {
            var runs = 0, cur = 0
            for y in 0..<px.height {
                let i = (y * px.width + x) * 4
                let hit = abs(Int(px.pixels[i]) - r) < 8 && abs(Int(px.pixels[i + 1]) - g) < 8 && abs(Int(px.pixels[i + 2]) - b) < 8
                if hit { cur += 1 } else { if cur >= minRun { runs += 1 }; cur = 0 }
            }
            if cur >= minRun { runs += 1 }
            return runs
        }
        let headers = countRuns(x: 300, r: 40, g: 90, b: 200, minRun: 40)
        let footers = countRuns(x: 300, r: 30, g: 160, b: 90, minRun: 60)
        let avatars = countRuns(x: 30, r: 220, g: 80, b: 80, minRun: 15)
        let pass = px.height == viewport + totalScroll && headers == 1 && footers == 1 && avatars == 1
        print("stitchtest: short scroll fixed elements \(pass ? "OK" : "FAILED") (headers=\(headers), footers=\(footers), avatars=\(avatars), height=\(px.height))")
        return pass
    }

    /// Fixed left sidebar with a promo card + in-place tooltip mid-scroll, a 2-px divider,
    /// and a dark chat area whose floating composer bar and mascot extend into the blank chat margins.
    /// Regression for issue 3.2: an in-place tooltip inside the sidebar used to punch a moving strip
    /// through the middle of the sidebar, the promo card colour hijacked the sidebar fill below the
    /// first screen, and blank chat margins were mistaken for still columns.
    private static func sidebarTooltipAndMarginTest() -> Bool {
        let w = 800, viewport = 1000, sidebarW = 180, headerH = 60, footerH = 140
        let contentH = viewport - headerH - footerH, docHeight = 2000
        func box(_ c: CGContext, _ x: Int, _ y: Int, _ cw: Int, _ ch: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            c.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
            c.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cw), height: CGFloat(ch)))
        }
        let d = rgbContext(w, docHeight)
        box(d, 0, 0, w, docHeight, 20, 20, 20)
        var seed: UInt32 = 9001
        func next() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12345; return CGFloat((seed >> 16) & 0xff) / 255 }
        var y = 0
        while y < docHeight {
            let band = 40 + Int(next() * 30)
            // Indented text lines: x in (sidebarW + 40)..<680, leaving blank (20,20,20) margins on both sides
            box(d, sidebarW + 40, docHeight - y - band + 8, 120 + Int(next() * 320), 10, 200, 200, 210)
            y += band
        }
        let doc = d.makeImage()!
        func frame(_ off: Int, tooltip: Bool) -> CGImage {
            let c = rgbContext(w, viewport)
            box(c, 0, 0, w, viewport, 20, 20, 20)
            c.saveGState()
            c.clip(to: CGRect(x: CGFloat(sidebarW + 2), y: CGFloat(footerH), width: CGFloat(w - sidebarW - 2), height: CGFloat(contentH)))
            c.draw(ScrollStitcher.copyRows(doc, off..<(off + contentH))!, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(viewport)))
            c.restoreGState()
            // Top header & bottom composer bar (extending into the blank margins at sidebarW + 14 ..< w - 14)
            box(c, sidebarW + 2, viewport - headerH, w - sidebarW - 2, headerH, 28, 28, 30)
            box(c, sidebarW + 14, 16, w - sidebarW - 28, footerH - 24, 52, 52, 60)
            // Floating mascot in the right blank margin just above the composer bar
            box(c, w - 70, footerH + 10, 44, 50, 180, 140, 90)
            for k in 0..<5 { box(c, w - 66 + k * 8, footerH + 20, 4, 30, 240, 210, 160) }
            // Fixed left sidebar (31,31,31) + 2px divider (36,36,36) + static list items + purple promo card
            box(c, 0, 0, sidebarW, viewport, 31, 31, 31)
            box(c, sidebarW, 0, 2, viewport, 36, 36, 36)
            for i in 0..<6 { box(c, 20, viewport - 120 - i * 80, 130, 12, 180, 180, 190) }
            box(c, 12, 90, sidebarW - 24, 180, 43, 45, 58) // purple promo card covering the fillRow height
            if tooltip {
                box(c, 60, 40, 60, 36, 90, 95, 110) // in-place tooltip appearing mid-scroll inside the sidebar
            }
            return c.makeImage()!
        }
        guard let st = ScrollStitcher(first: frame(0, tooltip: false)) else { return false }
        for (i, off) in [60, 130, 210, 290, 370, 450, 520].enumerated() {
            _ = st.add(frame(off, tooltip: i >= 2))
        }
        guard let result = st.finish(), let px = PixelFrame(result) else { return false }
        func colour(_ x: Int, _ yy: Int) -> (Int, Int, Int) {
            let i = (yy * px.width + x) * 4
            return (Int(px.pixels[i]), Int(px.pixels[i + 1]), Int(px.pixels[i + 2]))
        }
        // Below the first screen (y = viewport + 200), the entire sidebar (including x=80 where the tooltip
        // appeared) must be flat (31,31,31), the divider at x=sidebarW must be (36,36,36), and the floating
        // mascot in the right margin must appear only once (at the bottom).
        let sideLeft = colour(30, viewport + 200), sideMid = colour(80, viewport + 200), div = colour(sidebarW, viewport + 200)
        let sidebarOK = sideLeft == (31, 31, 31) && sideMid == (31, 31, 31) && div == (36, 36, 36)
        var mascots = 0, run = 0
        for yy in 0..<px.height {
            let c = colour(w - 50, yy)
            if c.0 > 150 { run += 1 } else { if run >= 20 { mascots += 1 }; run = 0 }
        }
        if run >= 20 { mascots += 1 }
        // Left end cap of composer bar at x = sidebarW + 20 must appear only at the bottom, not mid-image.
        var leftCaps = 0; run = 0
        for yy in 0..<px.height {
            let c = colour(sidebarW + 20, yy)
            if abs(c.0 - 52) < 6 { run += 1 } else { if run >= 40 { leftCaps += 1 }; run = 0 }
        }
        if run >= 40 { leftCaps += 1 }
        let pass = sidebarOK && mascots == 1 && leftCaps == 1
        print("stitchtest: sidebar tooltip & margin \(pass ? "OK" : "FAILED") (sidebar=\(sideLeft)/\(sideMid), div=\(div), mascots=\(mascots), composerCaps=\(leftCaps))")
        return pass
    }

    /// Dark low-texture chat window with 2-line chat bubbles scrolled in small steps.
    /// Regression for issue 3.3: 1-2 px inter-strip rounding drift and neighbour fixed-row echoes used
    /// to split a 2-line bubble across provisional/clean rewrites and squish its first line of text.
    private static func darkBubbleSubstepTest() -> Bool {
        let w = 600, viewport = 900, headerH = 60, footerH = 100
        let contentH = viewport - headerH - footerH, docHeight = 2200
        func box(_ c: CGContext, _ x: Int, _ y: Int, _ cw: Int, _ ch: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            c.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
            c.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cw), height: CGFloat(ch)))
        }
        let d = rgbContext(w, docHeight)
        box(d, 0, 0, w, docHeight, 20, 20, 22)
        // Place 2-line chat bubbles every 140 rows down the dark document.
        var bubbleTops: [Int] = []
        for top in stride(from: 80, to: docHeight - 100, by: 140) {
            bubbleTops.append(top)
            let by = docHeight - top - 64
            box(d, 50, by, 320, 64, 34, 34, 38)
            // Line 1 (height 12) and Line 2 (height 12), separated by 12 px gap
            for k in 0..<8 {
                box(d, 68 + k * 34, by + 38, 24, 12, 215, 215, 225)
                box(d, 68 + k * 30, by + 14, 20, 12, 205, 205, 215)
            }
        }
        let doc = d.makeImage()!
        let header = solid(w, headerH, r: 32, g: 32, b: 36)
        let footer = solid(w, footerH, r: 48, g: 48, b: 56)
        func frame(_ off: Int) -> CGImage {
            compose(w, [header, ScrollStitcher.copyRows(doc, off..<(off + contentH))!, footer])
        }
        let maxOff = docHeight - contentH
        var offsets: [Int] = [0], cur = 0, stepIdx = 0
        let steps = [18, 24, 31, 19, 27, 35, 22, 16, 29, 33]
        while cur < maxOff {
            cur = min(maxOff, cur + steps[stepIdx % steps.count])
            offsets.append(cur)
            stepIdx += 1
        }
        guard let st = ScrollStitcher(first: frame(0)) else { return false }
        for off in offsets.dropFirst() { _ = st.add(frame(off)) }
        guard let result = st.finish(), let got = PixelFrame(result),
              let want = PixelFrame(compose(w, [header, doc, footer])) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        print("stitchtest: dark bubble substep \(same ? "OK" : "FAILED") (\(got.width)×\(got.height), want \(want.height))")
        return same
    }

    /// Starting in the middle of a document, scrolling up to its top (rows are added above the first
    /// frame), then wiggling and scrolling down to the end gives the whole document exactly once.
    private static func upwardTest() -> Bool {
        let w = 600, docHeight = 4000, viewport = 1000, bar = 80
        let content = viewport - 2 * bar
        let doc = syntheticDocument(width: w, height: docHeight)
        let header = solid(w, bar, r: 40, g: 90, b: 200), footer = solid(w, bar, r: 30, g: 160, b: 90)
        func frame(at offset: Int) -> CGImage {
            compose(w, [header, ScrollStitcher.copyRows(doc, offset..<(offset + content))!, footer])
        }
        let maxOffset = docHeight - content
        var offsets = [1500]
        var o = 1500
        // Steps both larger and smaller than the header: small ones leave rows under the header that
        // the next frame still hides.
        while o > 0 { o = max(o - [200, 30, 50, 120, 20][offsets.count % 5], 0); offsets.append(o) }
        offsets += [120, 60, 0, 90] // wiggle at the top
        o = 90
        while o < maxOffset { o = min(o + 250, maxOffset); offsets.append(o) }
        offsets.append(maxOffset - 100) // and a little back at the end, which must not end the image
        offsets.append(maxOffset)
        guard let stitcher = ScrollStitcher(first: frame(at: offsets[0])) else { return false }
        let statuses = offsets.dropFirst().map { stitcher.add(frame(at: $0)) }
        let allMoved = statuses.allSatisfy { if case .appended = $0 { return true } else { return false } }
        guard let result = stitcher.finish(), let got = PixelFrame(result),
              let want = PixelFrame(compose(w, [header, doc, footer])) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: upward differing rows \(differingRows(got, want))") }
        print("stitchtest: scrolling up first \(allMoved && same ? "OK" : "FAILED") (\(got.width)×\(got.height), want \(want.height), \(statuses.prefix(12)))")
        return allMoved && same
    }

    /// Like a chat app: a tall static composer with image thumbnails at the bottom, and under it a status
    /// row whose spinner changes every frame, also between scroll steps. Both must appear once, at the end.
    private static func composerTest() -> Bool {
        let w = 600, docHeight = 3000, viewport = 1000, header = 60, composer = 240, status = 50
        let content = viewport - header - composer - status
        let doc = syntheticDocument(width: w, height: docHeight)
        let top = solid(w, header, r: 40, g: 40, b: 46)
        // Thumbnails: textured, so its rows are anything but flat.
        let box = syntheticDocument(width: composer, height: w) // rotated stripes
        func composerImage() -> CGImage {
            let c = rgbContext(w, composer)
            c.setFillColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: w, height: composer))
            c.saveGState(); c.translateBy(x: 40 + 140, y: 60); c.rotate(by: .pi / 2)
            c.draw(box, in: CGRect(x: 0, y: 0, width: 140, height: 140)); c.restoreGState()
            c.draw(box, in: CGRect(x: 200, y: 60, width: 130, height: 140))
            return c.makeImage()!
        }
        let composerPart = composerImage()
        func statusRow(_ n: Int) -> CGImage {
            let c = rgbContext(w, status)
            c.setFillColor(red: 0.1, green: 0.1, blue: 0.11, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: w, height: status))
            c.setFillColor(gray: 0.8, alpha: 1)
            c.fill(CGRect(x: 20, y: 18, width: 60, height: 14)) // "自动"
            c.fill(CGRect(x: 420, y: 18, width: 110, height: 14)) // model name
            c.setFillColor(gray: 0.9, alpha: 1)
            let a = CGFloat(n) * .pi / 4 // spinner: a dot going round
            c.fillEllipse(in: CGRect(x: 560 + 7 * cos(a) - 3, y: 25 + 7 * sin(a) - 3, width: 6, height: 6))
            return c.makeImage()!
        }
        var n = 0
        func frame(at offset: Int) -> CGImage {
            n += 1
            return compose(w, [top, ScrollStitcher.copyRows(doc, offset..<(offset + content))!, composerPart, statusRow(n)])
        }
        var offsets = [0], o = 0, k = 0
        while o < docHeight - content { o = min(docHeight - content, o + [40, 90, 160, 25, 120][k % 5]); k += 1; offsets.append(o) }
        guard let stitcher = ScrollStitcher(first: frame(at: 0)) else { return false }
        var bad = 0
        for (i, o) in offsets.enumerated().dropFirst() {
            let status = stitcher.add(frame(at: offsets[i - 1])) // only the spinner moved
            if status != .unchanged { bad += 1; print("stitchtest: composer spinner-only frame judged \(status)") }
            let moved = stitcher.add(frame(at: o))
            if moved != .appended(o - offsets[i - 1]) { bad += 1; print("stitchtest: composer step \(offsets[i - 1])→\(o) judged \(moved)") }
        }
        let last = statusRow(n)
        guard let result = stitcher.finish(), let got = PixelFrame(result),
              let want = PixelFrame(compose(w, [top, doc, composerPart, last])) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: composer differing rows \(differingRows(got, want).prefix(8))") }
        print("stitchtest: composer and spinner \(bad == 0 && same ? "OK" : "FAILED") (\(got.height) rows, want \(want.height))")
        return bad == 0 && same
    }

    /// Text-like content on a dark page: a few line patterns repeat all over, so a short strip matches many
    /// places. Scrolling with uneven steps, up and down, must still give the document exactly.
    private static func textLikeTest() -> Bool {
        let w = 700, docHeight = 5000, viewport = 900
        var seed: UInt32 = 777
        func next() -> Int { seed = seed &* 1_103_515_245 &+ 12345; return Int((seed >> 16) & 0x7fff) }
        let ctx = rgbContext(w, docHeight)
        ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: docHeight))
        // Line patterns: (indent, word widths); 8 patterns reused at random, 26 px lines.
        let patterns: [(Int, [Int])] = [(40, [60, 90, 40]), (40, [120, 80]), (60, [50, 50, 50, 50]), (40, [200]),
                                        (80, [70, 30, 110]), (40, [90, 90, 90]), (100, [40, 160]), (40, [30])]
        var y = 20
        while y < docHeight - 30 {
            if next() % 9 == 0 { // a card: unique colour and size
                let h = 60 + next() % 80
                ctx.setFillColor(red: CGFloat(next() % 100) / 255 + 0.1, green: CGFloat(next() % 100) / 255 + 0.1, blue: CGFloat(next() % 100) / 255 + 0.15, alpha: 1)
                ctx.fill(CGRect(x: 30, y: docHeight - y - h, width: w - 100, height: h))
                y += h + 12
                continue
            }
            let (indent, words) = patterns[next() % patterns.count]
            var x = indent
            ctx.setFillColor(gray: 0.85, alpha: 1)
            for width in words { ctx.fill(CGRect(x: x, y: docHeight - y - 14, width: width, height: 14)); x += width + 14 }
            y += 26
        }
        guard let doc = ctx.makeImage() else { return false }
        func frame(at offset: Int) -> CGImage { ScrollStitcher.copyRows(doc, offset..<(offset + viewport))! }
        // Uneven steps like an inertial scroll: fast, then slowing; first down, then up to the top.
        var offsets = [2000]
        var o = 2000
        for step in [140, 120, 100, 80, 60, 40, 20] { o += step; offsets.append(o) }
        while o > 0 { o = max(0, o - [30, 70, 110, 150, 190, 110, 60, 20][offsets.count % 8]); offsets.append(o) }
        while o < docHeight - viewport { o = min(docHeight - viewport, o + [25, 80, 160, 210, 120, 50][offsets.count % 6]); offsets.append(o) }
        guard let stitcher = ScrollStitcher(first: frame(at: offsets[0])) else { return false }
        // A frame may be skipped (too little detail in the strips); a shift that is judged must be right
        // relative to the last frame taken.
        // Between some steps the frame changes in place only (a caret blinks, a counter ticks): that is
        // no scroll, however many places the repeating lines would also match.
        func blinking(_ image: CGImage, _ n: Int) -> CGImage {
            let c = rgbContext(image.width, image.height)
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            c.setFillColor(red: 1, green: CGFloat(n % 7) / 7, blue: 0.3, alpha: 1)
            c.fill(CGRect(x: image.width - 120, y: 40, width: 90, height: 18))
            return c.makeImage()!
        }
        var wrong = 0, skipped = 0, accepted = offsets[0], blinks = 0
        for (i, o) in offsets.dropFirst().enumerated() {
            if i % 5 == 0 {
                let status = stitcher.add(blinking(frame(at: accepted), i))
                if status != .unchanged { blinks += 1; print("stitchtest: text-like in-place change at \(accepted) judged \(status)") }
            }
            switch stitcher.add(frame(at: o)) {
            case let .appended(dy):
                if dy != o - accepted { wrong += 1; print("stitchtest: text-like step \(accepted)→\(o) judged \(dy)") }
                accepted = o
            case .unchanged: break
            default: skipped += 1
            }
        }
        guard let result = stitcher.finish(), let got = PixelFrame(result), let want = PixelFrame(doc) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: text-like differing rows \(differingRows(got, want).prefix(6))") }
        print("stitchtest: text-like content \(wrong == 0 && blinks == 0 && same ? "OK" : "FAILED") (\(got.height) rows, want \(want.height); \(wrong) steps misjudged, \(skipped) skipped)")
        return wrong == 0 && blinks == 0 && same
    }

    /// A button floating over the content near the bottom (like a chat's "scroll to latest") must not be
    /// stamped into the image at every step; it appears once, where the last screen shows it.
    /// - Parameter smooth: scroll this many rows per frame, as a stream sees a trackpad scroll, over a page of
    ///   plain bands with a little text at their left: the button mostly sits on flat colour.
    private static func floatingTest(alpha: CGFloat, smooth: Int? = nil) -> Bool {
        let w = 600, docHeight = 3000, viewport = 1000, bar = 80
        let content = viewport - 2 * bar
        let doc = smooth == nil ? syntheticDocument(width: w, height: docHeight) : plainDocument(width: w, height: docHeight)
        let header = solid(w, bar, r: 40, g: 90, b: 200), footer = solid(w, bar, r: 30, g: 160, b: 90)
        let button = CGRect(x: 260, y: 780, width: 80, height: 70) // top-left frame coordinates, just above the footer
        func withButton(_ image: CGImage, top: Int) -> CGImage {
            let ctx = rgbContext(image.width, image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: alpha)
            ctx.fillEllipse(in: CGRect(x: button.minX, y: CGFloat(image.height - top) - button.maxY, width: button.width, height: button.height))
            return ctx.makeImage()!
        }
        func frame(at offset: Int) -> CGImage {
            withButton(compose(w, [header, ScrollStitcher.copyRows(doc, offset..<(offset + content))!, footer]), top: 0)
        }
        let maxOffset = docHeight - content
        var offsets = [0, 40, 200, 230, 800] // small steps, then one of 570 rows
        var o = 800
        while o < maxOffset { o = min(o + 300, maxOffset); offsets.append(o) }
        if let smooth { offsets = Array(stride(from: 0, to: maxOffset, by: smooth)) + [maxOffset] }
        guard let stitcher = ScrollStitcher(first: frame(at: 0)) else { return false }
        let frames = offsets.dropFirst().map { frame(at: $0) }
        let started = Date()
        let statuses = frames.map { stitcher.add($0) }
        let perFrame = Date().timeIntervalSince(started) / Double(frames.count)
        print("stitchtest: floating \(w)×\(viewport) frames take \(Int(perFrame * 1000)) ms each")
        let allAppended = statuses.allSatisfy { if case .appended = $0 { return true } else { return false } }
        if !allAppended { print("stitchtest: floating statuses \(statuses.enumerated().filter { if case .appended = $0.1 { return false } else { return true } }.map { "\(offsets[$0.0 + 1]): \($0.1)" })") }
        guard let result = stitcher.finish(), let got = PixelFrame(result),
              let want = PixelFrame(withButton(compose(w, [header, doc, footer]), top: maxOffset)) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: floating (alpha \(alpha)) differing rows \(differingRows(got, want))") }
        print("stitchtest: floating button alpha \(alpha)\(smooth.map { ", \($0) rows a frame" } ?? "") \(allAppended && same ? "OK" : "FAILED") (\(got.width)×\(got.height), button once at the end)")
        return allAppended && same
    }

    /// A fixed sidebar with varied texture down the whole left edge: every row has pixels that stay put, yet
    /// the content beside it must still be stitched exactly.
    private static func sidebarTest() -> Bool {
        let w = 600, side = 60, docHeight = 2400, viewport = 800
        let doc = syntheticDocument(width: w, height: docHeight)
        let sidebar = syntheticDocument(width: viewport, height: side) // rotated stripes: varies down the edge
        func frame(at offset: Int) -> CGImage {
            let ctx = rgbContext(w, viewport)
            ctx.draw(ScrollStitcher.copyRows(doc, offset..<(offset + viewport))!, in: CGRect(x: 0, y: 0, width: w, height: viewport))
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(side), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(sidebar, in: CGRect(x: 0, y: 0, width: viewport, height: side))
            ctx.restoreGState()
            return ctx.makeImage()!
        }
        var offsets = [0], o = 0
        while o < docHeight - viewport { o = min(o + 170, docHeight - viewport); offsets.append(o) }
        guard let stitcher = ScrollStitcher(first: frame(at: 0)) else { return false }
        let statuses = offsets.dropFirst().map { stitcher.add(frame(at: $0)) }
        guard let result = stitcher.finish(), let got = PixelFrame(result), let want = PixelFrame(doc) else { return false }
        // Only the content beside the sidebar has one right answer.
        var bad = 0
        if got.height == want.height {
            for y in 0..<got.height where got.pixels[(y * w + side) * 4..<(y + 1) * w * 4] != want.pixels[(y * w + side) * 4..<(y + 1) * w * 4] { bad += 1 }
        }
        let ok = got.height == want.height && bad == 0 && statuses.allSatisfy { if case .appended = $0 { return true } else { return false } }
        print("stitchtest: fixed sidebar \(ok ? "OK" : "FAILED") (\(got.height) rows, \(bad) differ beside it, \(statuses))")
        return ok
    }

    /// A sticky summary panel over the right 30% of the top three quarters, as on a checkout page: its columns never
    /// change while the content on the left scrolls in small steps. Scrolling must not get lost, the content
    /// must be exact, and the panel must appear once, at the top, with the page background below it.
    private static func stickyPanelTest() -> Bool {
        let w = 600, side = 180, docHeight = 3000, viewport = 1000, panelHeight = 750
        let page = rgbContext(w, docHeight)
        page.setFillColor(gray: 0.1, alpha: 1)
        page.fill(CGRect(x: 0, y: 0, width: w, height: docHeight))
        page.draw(syntheticDocument(width: w - side, height: docHeight), in: CGRect(x: 0, y: 0, width: w - side, height: docHeight))
        let doc = page.makeImage()!
        let panel = syntheticDocument(width: side, height: panelHeight * 3)
        func withPanel(_ image: CGImage) -> CGImage {
            let ctx = rgbContext(image.width, image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(panel, in: CGRect(x: w - side, y: image.height - panelHeight, width: side, height: panelHeight))
            return ctx.makeImage()!
        }
        let maxOffset = docHeight - viewport
        var offsets = Array(stride(from: 0, to: 600, by: 24)), o = 600
        while o < maxOffset { o = min(o + 150, maxOffset); offsets.append(o) }
        guard let stitcher = ScrollStitcher(first: withPanel(ScrollStitcher.copyRows(doc, 0..<viewport)!)) else { return false }
        let statuses = offsets.dropFirst().map { stitcher.add(withPanel(ScrollStitcher.copyRows(doc, $0..<($0 + viewport))!)) }
        let appended = statuses.allSatisfy { if case .appended = $0 { return true } else { return false } }
        guard let result = stitcher.finish(), let got = PixelFrame(result), let want = PixelFrame(withPanel(doc)) else { return false }
        let same = got.height == want.height && got.pixels == want.pixels
        if !same, got.height == want.height { print("stitchtest: sticky panel differing rows \(differingRows(got, want))") }
        let ok = appended && same
        print("stitchtest: sticky side panel \(ok ? "OK" : "FAILED") (\(got.height) rows, want \(docHeight), panel once at the top\(appended ? "" : ", \(statuses)"))")
        return ok
    }

    /// Equal-height list rows above varied content: after scrolling exactly one row the frame has changed,
    /// yet every comparison strip still sits in the repeating rows and also matches in place.
    private static func repeatingTest() -> Bool {
        let w = 400, rowH = 60, listRows = 8, viewport = 600
        let varied = syntheticDocument(width: w, height: 1200)
        let total = listRows * rowH + varied.height
        let ctx = rgbContext(w, total)
        ctx.draw(varied, in: CGRect(x: 0, y: 0, width: w, height: varied.height))
        for i in 0..<listRows {
            let top = total - (i + 1) * rowH
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: top, width: w, height: rowH))
            ctx.setFillColor(gray: 0.2, alpha: 1)
            for j in 0..<6 { ctx.fill(CGRect(x: 20 + j * 50, y: top + 10 + j * 6, width: 30, height: 8)) } // same in every row
            ctx.setFillColor(gray: 0.85, alpha: 1); ctx.fill(CGRect(x: 0, y: top, width: w, height: 1))
        }
        let doc = ctx.makeImage()!
        func frame(_ o: Int) -> CGImage { ScrollStitcher.copyRows(doc, o..<(o + viewport))! }
        guard let stitcher = ScrollStitcher(first: frame(0)) else { return false }
        let statuses = [60, 120].map { stitcher.add(frame($0)) }
        let ok = statuses == [.appended(60), .appended(60)] && stitcher.height == viewport + 120
        print("stitchtest: repeating rows \(ok ? "OK" : "FAILED") \(statuses) height=\(stitcher.height)")
        return ok
    }

    /// Row ranges where two equally sized frames differ, for diagnosing a failed comparison.
    private static func differingRows(_ a: PixelFrame, _ b: PixelFrame) -> [ClosedRange<Int>] {
        let rowBytes = a.width * 4
        var bands: [ClosedRange<Int>] = []
        for y in 0..<a.height where a.pixels[(y * rowBytes)..<((y + 1) * rowBytes)] != b.pixels[(y * rowBytes)..<((y + 1) * rowBytes)] {
            if let last = bands.last, last.upperBound == y - 1 { bands[bands.count - 1] = last.lowerBound...y } else { bands.append(y...y) }
        }
        return bands
    }

    /// Bands of pseudo-random colours with small blocks, so every stretch of rows looks different.
    private static func syntheticDocument(width: Int, height: Int) -> CGImage {
        let ctx = rgbContext(width, height)
        var seed: UInt32 = 12345
        func next() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12345; return CGFloat((seed >> 16) & 0xff) / 255 }
        var y = 0
        while y < height {
            let band = 12 + Int(next() * 30)
            ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            ctx.fill(CGRect(x: 0, y: height - y - band, width: width, height: band))
            for _ in 0..<6 {
                ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
                ctx.fill(CGRect(x: Int(next() * CGFloat(width - 40)), y: height - y - band + 2, width: 8 + Int(next() * 60), height: max(2, band - 4)))
            }
            y += band
        }
        return ctx.makeImage()!
    }

    /// Bands 60–140 rows tall in pale colours with lines of dark text-like blocks, all left of x = 250.
    private static func plainDocument(width: Int, height: Int) -> CGImage {
        let ctx = rgbContext(width, height)
        var y = 0, i = 0
        while y < height {
            let band = 60 + (i * 37) % 80
            ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
                0.75 + 0.2 * CGFloat(i % 3) / 2, 0.8 + 0.15 * CGFloat(i % 5) / 4, 0.7 + 0.25 * CGFloat(i % 4) / 3, 1])!)
            ctx.fill(CGRect(x: 0, y: height - y - band, width: width, height: band))
            ctx.setFillColor(gray: 0.1, alpha: 1)
            for (k, line) in stride(from: 6, to: band - 16, by: 24).enumerated() {
                ctx.fill(CGRect(x: 24 + (i * 29 + k * 13) % 60, y: height - y - line - 14, width: 40 + ((i + k) * 37) % 180, height: 14))
            }
            y += band; i += 1
        }
        return ctx.makeImage()!
    }

    private static func solid(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = rgbContext(w, h)
        ctx.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 20, y: h / 3, width: w / 3, height: h / 3)) // a "title" so the bar isn't blank
        return ctx.makeImage()!
    }

    private static func compose(_ w: Int, _ parts: [CGImage]) -> CGImage {
        let total = parts.reduce(0) { $0 + $1.height }
        let ctx = rgbContext(w, total)
        var top = 0
        for p in parts {
            ctx.draw(p, in: CGRect(x: 0, y: total - top - p.height, width: p.width, height: p.height))
            top += p.height
        }
        return ctx.makeImage()!
    }

    private static func rgbContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
