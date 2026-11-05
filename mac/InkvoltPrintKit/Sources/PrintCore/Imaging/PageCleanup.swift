import Foundation

// The scan review's clean up (roadmap 2.3): the Windows app's `InkvoltPrint.Core/Imaging/PageCleanup.cs`, ported as is
// (plain loops over bytes), so a page cleans up the same on both platforms. The app decodes the page (ImageIO and Core
// Graphics in PrintMac's `ScanImaging`), hands the pixels here and encodes what comes back. Colour pixels are RGB on the
// Mac (Windows' are BGR). A stop (`BatchStop`, .NET's CancellationToken) is checked between rows; it throws
// `CancellationError`.

/// What a scanned page is cleaned up with, per scan and per preset. Stored as its number, as Windows stores it.
public struct PageFilters: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The crop was (or is to be) found at the paper's edge (`PaperEdge`).
    public static let cropToPaper = PageFilters(rawValue: 1)

    /// Whiten the background, remove specks (`PageBackground`).
    public static let whiten = PageFilters(rawValue: 2)

    /// Take the screen out of printed pictures (`Descreen`).
    public static let descreen = PageFilters(rawValue: 4)

    /// Restore a faded print's range and colors (`FadedColors`).
    public static let restoreColors = PageFilters(rawValue: 8)

    /// The filters that change pixels.
    public static let pixelFilters: PageFilters = [.whiten, .descreen, .restoreColors]

    public static let all: PageFilters = [.cropToPaper, .pixelFilters]
}

/// What `PageCleanup.apply` gives: the page, what really changed it, and the specks removed.
public struct CleanedPage: Equatable, Sendable {
    public var pixels: [UInt8]
    public var done: PageFilters
    public var specks: Int
}

/// The review's filters on a page's pixels: descreen, then restore colors, then whiten, each on what the one before left.
/// Pixels in, new pixels out. Rows of width × channels bytes, no padding; 1 = grey, 3 = RGB.
public enum PageCleanup {
    /// Past this a page is left as it is, with nothing done (a 1200 dpi A3 page is 278 million pixels). The filters take
    /// about five times the page's own memory at their peak.
    public static let maxPixels = 300_000_000

    public static func tooLarge(_ width: Int, _ height: Int) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow || pixels > maxPixels
    }

    /// A resolution a scan can have: the filters size their blocks and reach by it.
    static func scanDpi(_ dpi: Int) -> Int { min(max(dpi, 1), 9600) }

    /// The page cleaned up by `filters`. A page whose pixels don't match its size and channels (1 or 3) is left as it is,
    /// as is one past `maxPixels`.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func apply(_ pixels: [UInt8], width: Int, height: Int, channels: Int, dpi: Int, _ filters: PageFilters,
                             stop: BatchStop? = nil) throws -> CleanedPage {
        try stop?.check()
        let unchanged = CleanedPage(pixels: pixels, done: [], specks: 0)
        if filters.isDisjoint(with: .pixelFilters) || tooLarge(width, height) || width < 1 || height < 1 || !(channels == 1 || channels == 3)
            || pixels.count != width * height * channels { return unchanged }
        let dpi = scanDpi(dpi)
        var page = pixels
        var done: PageFilters = []
        var specks = 0
        if filters.contains(.descreen), try Descreen.apply(&page, width, height, channels, dpi, stop) { done.insert(.descreen) }
        if filters.contains(.restoreColors), try FadedColors.restore(&page, width, height, channels, stop) { done.insert(.restoreColors) }
        if filters.contains(.whiten), try PageBackground.whiten(&page, width, height, channels, dpi, specks: &specks, stop) { done.insert(.whiten) }
        return CleanedPage(pixels: page, done: done, specks: specks)
    }

    /// "cropped to the paper, whitened": what a set of filters does, in the review's words. Empty for none.
    public static func describe(_ filters: PageFilters) -> String {
        var parts: [String] = []
        if filters.contains(.cropToPaper) { parts.append("cropped to the paper") }
        if filters.contains(.whiten) { parts.append("whitened") }
        if filters.contains(.descreen) { parts.append("descreened") }
        if filters.contains(.restoreColors) { parts.append("colors restored") }
        return parts.joined(separator: ", ")
    }
}

/// Finds the sheet on a scan of the glass, by the lid's level as `PhotoFinder` does: what differs from the lid is the
/// sheet. The lid is looked for along the scan's four edges (a sheet in a corner of the glass touches two of them), each
/// level tried in turn. A crop only ever removes lid: it is refused unless what differs from the level is one solid
/// rectangle and nothing else lies outside it but specks, faint marks included. So a page printed to its edges, a white
/// sheet under a white lid (no edge to see), a dark lid or a page with a picture and a caption is kept whole.
public enum PaperEdge {
    private static let contrast = 16
    private static let minSide = 1.0, minShare = 0.25, minFill = 0.92, pad = 0.03, nothingToCrop = 0.99

    /// Marks this close (inches) belong together; dust is under `dustSide` inches on its shorter side.
    private static let together = 0.1, dustSide = 0.09

    /// The sheet as a crop of the straightened page (`deskew` degrees undone), or nil when there is no edge to be sure of.
    /// `img` is the scan as scanned, at `ppi` pixels an inch (the analysis copy).
    public static func find(_ img: GrayImage, ppi: Double, deskew: Double = 0) -> CropBox? {
        let (w, h) = (img.width, img.height)
        // No sheet this page could hold, nor a strip of it to measure; nor pixels that don't fill the image, nor a resolution no scan has.
        guard w >= 32, h >= 32, img.pixels.count == w * h, ppi.isFinite, ppi >= 20, ppi <= 9600, deskew.isFinite,
              Double(min(w, h)) >= minSide * ppi else { return nil }
        for lid in lidLevels(img, ppi) {
            let pixels = deskew == 0 ? img.pixels
                : PageRotate.rotate(img.pixels, width: w, height: h, stride: w, channels: 1, degrees: -deskew, fill: UInt8(lid))
            if let box = sheet(pixels, w, h, lid, ppi) { return box }
        }
        return nil
    }

    /// The light level each edge of the scan mostly has, when it mostly has one.
    private static func lidLevels(_ img: GrayImage, _ ppi: Double) -> [Int] {
        let strip = max(2, Int((ppi * 0.05).rounded(.toNearestOrEven)))
        let (w, h) = (img.width, img.height)
        var levels: [Int] = []
        for (x0, y0, x1, y1) in [(0, 0, w, strip), (0, h - strip, w, h), (0, 0, strip, h), (w - strip, 0, w, h)] {
            let level = GrayImage.median(img, x0, y0, x1, y1)
            if level < 128 { continue } // a dark lid or a dark page: nothing here tells them apart
            var (near, all) = (0, 0)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    all += 1
                    if abs(Int(img.pixels[y * w + x]) - level) <= contrast { near += 1 }
                }
            }
            if near * 10 >= all * 6 && !levels.contains(where: { abs($0 - level) <= contrast / 2 }) { levels.append(level) }
        }
        return levels
    }

    private static func sheet(_ pixels: [UInt8], _ w: Int, _ h: Int, _ lid: Int, _ ppi: Double) -> CropBox? {
        let cell = max(1, Int((ppi / 50).rounded(.toNearestOrEven)))
        let (gw, gh) = ((w + cell - 1) / cell, (h + cell - 1) / cell)
        var mask = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var (on, all) = (0, 0)
                for y in (gy * cell)..<min(h, (gy + 1) * cell) {
                    for x in (gx * cell)..<min(w, (gx + 1) * cell) {
                        all += 1
                        if abs(Int(pixels[y * w + x]) - lid) > contrast { on += 1 }
                    }
                }
                mask[gy * gw + gx] = 2 * on > all
            }
        }
        let cellsPerInch = ppi / Double(cell)
        let open = max(1, Int((0.04 * cellsPerInch).rounded(.toNearestOrEven)))
        let close = max(1, Int((0.08 * cellsPerInch).rounded(.toNearestOrEven)))
        mask = PhotoFinder.dilate(PhotoFinder.erode(mask, gw, gh, open), gw, gh, open)
        mask = PhotoFinder.closing(mask, gw, gh, close)
        PhotoFinder.fillHoles(&mask, gw, gh)
        guard let part = largest(mask, gw, gh) else { return nil }

        let (bw, bh) = (part.maxX - part.minX + 1, part.maxY - part.minY + 1)
        if Double(part.count) < minFill * Double(bw * bh) { return nil } // not a solid rectangle
        if Double(bw * bh) < minShare * Double(gw * gh) || Double(bw) < minSide * cellsPerInch || Double(bh) < minSide * cellsPerInch { return nil }

        let padding = Int((pad * ppi).rounded(.up))
        let (x0, y0) = (max(0, part.minX * cell - padding), max(0, part.minY * cell - padding))
        let (x1, y1) = (min(w, (part.maxX + 1) * cell + padding), min(h, (part.maxY + 1) * cell + padding))
        if Double(x1 - x0) >= nothingToCrop * Double(w) && Double(y1 - y0) >= nothingToCrop * Double(h) { return nil }
        if anythingOutside(pixels, w, h, lid, x0, y0, x1, y1, ppi) { return nil }
        return CropBox(Double(x0) / Double(w), Double(y0) / Double(h), Double(x1 - x0) / Double(w), Double(y1 - y0) / Double(h)).clamp()
    }

    private static func largest(_ mask: [Bool], _ w: Int, _ h: Int) -> (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var seen = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        var best: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for start in mask.indices where mask[start] && !seen[start] {
            var (count, minX, minY, maxX, maxY) = (0, w, h, -1, -1)
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let (x, y) = (i % w, i / w)
                count += 1
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where n >= 0 && mask[n] && !seen[n] {
                    seen[n] = true
                    stack.append(n)
                }
            }
            if best == nil || count > best!.count { best = (count, minX, minY, maxX, maxY) }
        }
        return best
    }

    /// Whether anything but dust differs from the lid outside the box, down to faint marks: a threshold just above the
    /// scan's noise out there (measured, at least 8 levels). Marks a tenth of an inch apart count as one, so a line of tiny
    /// letters is seen for what it is. Dust is what stays small (`dustSide`), a lone letter isn't.
    private static func anythingOutside(_ pixels: [UInt8], _ w: Int, _ h: Int, _ lid: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int,
                                        _ ppi: Double) -> Bool {
        func isIn(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
        var histogram = [Int](repeating: 0, count: 256)
        var outside = 0
        for y in 0..<h {
            for x in 0..<w where !isIn(x, y) {
                histogram[abs(Int(pixels[y * w + x]) - lid)] += 1
                outside += 1
            }
        }
        if outside == 0 { return false }
        var (median, seenSoFar) = (0, 0)
        while median < 255 {
            seenSoFar += histogram[median]
            if seenSoFar > outside / 2 { break }
            median += 1
        }
        let limit = max(8, median * 3 + 2)

        // Marks: pixels past the limit with another beside them (a lone one is noise).
        func past(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && !isIn(x, y) && abs(Int(pixels[y * w + x]) - lid) > limit }
        var marks: [Int] = []
        var isMark = [Bool](repeating: false, count: pixels.count)
        for y in 0..<h {
            for x in 0..<w where past(x, y) {
                var alone = true
                for dy in -1...1 where alone {
                    for dx in -1...1 where (dx != 0 || dy != 0) && past(x + dx, y + dy) { alone = false }
                }
                if alone { continue }
                isMark[y * w + x] = true
                marks.append(y * w + x)
            }
        }

        let reach = max(2, Int((ppi * together).rounded(.toNearestOrEven)))
        let longest = ppi * together * 4
        let dust = ppi * dustSide
        var seen = [Bool](repeating: false, count: pixels.count)
        var stack: [Int] = []
        for start in marks where !seen[start] {
            var (minX, minY, maxX, maxY) = (w, h, -1, -1)
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let (x, y) = (i % w, i / w)
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                for ny in max(0, y - reach)...min(h - 1, y + reach) {
                    for nx in max(0, x - reach)...min(w - 1, x + reach) {
                        let n = ny * w + nx
                        if seen[n] || !isMark[n] { continue }
                        seen[n] = true
                        stack.append(n)
                    }
                }
            }
            let (across, down) = (Double(maxX - minX + 1), Double(maxY - minY + 1))
            if max(across, down) >= longest || min(across, down) >= dust { return true }
        }
        return false
    }
}

/// Evens the paper out to white, for keeps. The white point follows the scan's own noise, so a quiet scan keeps marks a
/// few levels darker than its paper. A thin stroke a median would smooth away (a hairline, a pencil signature) is found as
/// a connected run of pixels darker than the noise and keeps them. Blocks that aren't paper (a picture: mostly mid-tones or
/// dark, or at a level no slow shading leads to) are divided by the paper around them, never darkened, and never snapped
/// to white. A page whose paper is dark is left alone. Then lone specks go (`CleanupDespeckle`).
enum PageBackground {
    private static let flatBand = 12, minStrokePixels = 16
    private static let minStrokeContrast: Float = 10, maxStep: Float = 0.03

    /// Whether it changed the page. In place.
    static func whiten(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, specks: inout Int,
                       _ stop: BatchStop?) throws -> Bool {
        specks = 0
        if width < 8 || height < 8 { return false }
        let gray = channels == 1 ? pixels : try CleanupGray.of(pixels, width, height, stop)
        let smooth = try CleanupSmooth.median3(gray, width, height, stop)

        let block = max(8, dpi / 6)
        let (cols, rows) = ((width + block - 1) / block, (height + block - 1) / block)
        var levels = [Float](repeating: 0, count: cols * rows)
        var picture = [Bool](repeating: false, count: cols * rows)
        var noiseRaw = [Float](repeating: 0, count: cols * rows)
        var noiseSmooth = [Float](repeating: 0, count: cols * rows)
        try gray.withUnsafeBufferPointer { g in
            try smooth.withUnsafeBufferPointer { s in
                try levels.withUnsafeMutableBufferPointer { levelsOut in
                    try picture.withUnsafeMutableBufferPointer { pictureOut in
                        try noiseRaw.withUnsafeMutableBufferPointer { rawOut in
                            try noiseSmooth.withUnsafeMutableBufferPointer { smoothOut in
                                let (lv, pc, nr, ns) = (levelsOut, pictureOut, rawOut, smoothOut)
                                try cleanupRows(rows, stop) { by in
                                    var hs = [Int](repeating: 0, count: 256)
                                    var hr = [Int](repeating: 0, count: 256)
                                    for bx in 0..<cols {
                                        for k in 0..<256 {
                                            hs[k] = 0
                                            hr[k] = 0
                                        }
                                        let (x0, y0) = (bx * block, by * block)
                                        let (x1, y1) = (min(width, x0 + block), min(height, y0 + block))
                                        for y in y0..<y1 {
                                            for x in x0..<x1 {
                                                hs[Int(s[y * width + x])] += 1
                                                hr[Int(g[y * width + x])] += 1
                                            }
                                        }
                                        let all = (x1 - x0) * (y1 - y0)
                                        let level = percentile(hs, all, 90)
                                        var (mid, dark) = (0, 0)
                                        var v = 0
                                        while v < level - flatBand && v < 256 {
                                            if Double(v) <= 0.35 * Double(level) { dark += hs[v] } else { mid += hs[v] }
                                            v += 1
                                        }
                                        let i = by * cols + bx
                                        lv[i] = Float(level)
                                        pc[i] = mid * 100 >= all * 60 || dark * 100 >= all * 60
                                        // Noise: the spread of the paper's top half, 90th percentile to the top half's middle, in a block that is mostly paper.
                                        ns[i] = Float(level - percentileOfTop(hs, level, flatBand)) / 0.67
                                        let levelRaw = percentile(hr, all, 90)
                                        nr[i] = Float(levelRaw - percentile(hr, all, 70)) / 0.75
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        let candidates = levels.indices.filter { !picture[$0] }.map { levels[$0] }.sorted()
        if candidates.isEmpty { return false }
        let paper = candidates[Int(Double(candidates.count) * 0.9)]
        if paper < 128 { return false } // a dark page, not paper to whiten

        // Paper is what connects to the page's lightest level in small steps: shading changes slowly, a picture's edge doesn't.
        var known = paperBlocks(levels, picture, paper, cols, rows)
        let paperIndices = known.indices.filter { known[$0] }
        if paperIndices.isEmpty { return false }
        let sigmaRaw = median(paperIndices.map { noiseRaw[$0] })
        let sigmaSmooth = median(paperIndices.map { noiseSmooth[$0] })
        let isPaper = known
        fillUnknown(&levels, &known, cols, rows)
        let map = PaperMap(width: width, height: height, block: block, columns: cols, rows: rows, levels: levels)

        let white = min(max(1 - 3.8 * sigmaSmooth / paper, 0.90), 0.97) // below 90% thin serifs go (ocr-corpus README)
        let strokes = try Self.strokes(gray, width, height, map, max(minStrokeContrast, 2.5 * sigmaRaw), max(8, minStrokePixels * dpi / 300), stop)
        var result = [UInt8](repeating: 0, count: gray.count)
        try gray.withUnsafeBufferPointer { g in
            try smooth.withUnsafeBufferPointer { s in
                try strokes.withUnsafeBufferPointer { strokes in
                    try isPaper.withUnsafeBufferPointer { isPaper in
                        try result.withUnsafeMutableBufferPointer { out in
                            let out = out
                            try cleanupRows(height, stop) { y in
                                let row = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                                defer { row.deallocate() }
                                map.row(y, into: row)
                                for x in 0..<width {
                                    let i = y * width + x
                                    let level = row[x]
                                    let gi = Float(g[i])
                                    if !isPaper[y / block * cols + x / block] {
                                        out[i] = min(cleanupByte(gi * 255 / max(level, gi)), 254)
                                        continue
                                    }
                                    let si = Float(s[i])
                                    if si >= white * level {
                                        out[i] = strokes[i] ? min(cleanupByte(gi * 255 / (level * white)), 254) : 255
                                    } else {
                                        out[i] = min(cleanupByte(min(si, gi) * 255 / (level * white)), 254) // the darker of the two: a serif the median thins stays
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        specks = try CleanupDespeckle.remove(&result, width, height, dpi, stop)

        if channels == 1 {
            pixels = result
            return true
        }
        try result.withUnsafeBufferPointer { r in
            try gray.withUnsafeBufferPointer { g in
                try pixels.withUnsafeMutableBufferPointer { p in
                    let p = p
                    try cleanupRows(height, stop) { y in
                        for x in 0..<width {
                            let i = y * width + x
                            if r[i] == 255 {
                                p[i * 3] = 255
                                p[i * 3 + 1] = 255
                                p[i * 3 + 2] = 255
                                continue
                            }
                            // Every channel by what the grey level got, so a colored stamp stays its color.
                            var scale: Float = g[i] > 0 ? Float(r[i]) / Float(g[i]) : 1
                            if r[i] < g[i] { scale = 1 } // a pixel the smoothing darkened keeps its color as it was
                            for c in 0..<3 { p[i * 3 + c] = cleanupByte(Float(p[i * 3 + c]) * scale) }
                        }
                    }
                }
            }
        }
        return true
    }

    private static func percentile(_ histogram: [Int], _ all: Int, _ percent: Int) -> Int {
        let target = all * percent / 100
        var seen = 0
        for v in 0..<256 {
            seen += histogram[v]
            if seen > target { return v }
        }
        return 255
    }

    /// The middle of the pixels within `band` below `level` and above: the paper's own.
    private static func percentileOfTop(_ histogram: [Int], _ level: Int, _ band: Int) -> Int {
        let from = max(0, level - band)
        var all = 0
        for v in from..<256 { all += histogram[v] }
        var seen = 0
        for v in from..<256 {
            seen += histogram[v]
            if seen * 2 > all { return v }
        }
        return level
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Blocks with no paper of their own take the average of their neighbours', from the edges of the known ones inward.
    private static func fillUnknown(_ levels: inout [Float], _ known: inout [Bool], _ cols: Int, _ rows: Int) {
        var pending = true
        while pending {
            pending = false
            var next = known
            for y in 0..<rows {
                for x in 0..<cols {
                    let i = y * cols + x
                    if known[i] { continue }
                    var sum: Float = 0
                    var n = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let (nx, ny) = (x + dx, y + dy)
                            if nx < 0 || ny < 0 || nx >= cols || ny >= rows || !known[ny * cols + nx] { continue }
                            sum += levels[ny * cols + nx]
                            n += 1
                        }
                    }
                    if n > 0 {
                        levels[i] = sum / Float(n)
                        next[i] = true
                    } else {
                        pending = true
                    }
                }
            }
            known = next
        }
    }

    /// Blocks reached from the lightest ones through neighbours close in level, never through a picture.
    private static func paperBlocks(_ levels: [Float], _ picture: [Bool], _ paper: Float, _ cols: Int, _ rows: Int) -> [Bool] {
        var known = [Bool](repeating: false, count: levels.count)
        var stack: [Int] = []
        for i in levels.indices where !picture[i] && levels[i] >= paper - Float(flatBand) {
            known[i] = true
            stack.append(i)
        }
        func visit(_ n: Int, _ from: Int) {
            if known[n] || picture[n] || levels[n] < 0.55 * paper || abs(levels[n] - levels[from]) > maxStep * levels[from] { return }
            known[n] = true
            stack.append(n)
        }
        while let i = stack.popLast() {
            let (x, y) = (i % cols, i / cols)
            if x > 0 { visit(i - 1, i) }
            if x < cols - 1 { visit(i + 1, i) }
            if y > 0 { visit(i - cols, i) }
            if y < rows - 1 { visit(i + cols, i) }
        }
        return known
    }

    /// Pixels on a line of faint ink a median would smooth away: darker than the paper by more than the noise, in a
    /// connected run too long for chance (a hairline, hard pencil, a signature's tail). Noise this far out of the paper's
    /// range is sparse, so it rarely links up.
    private static func strokes(_ gray: [UInt8], _ width: Int, _ height: Int, _ map: PaperMap, _ contrast: Float, _ minPixels: Int,
                                _ stop: BatchStop?) throws -> [Bool] {
        var candidate = [Bool](repeating: false, count: gray.count)
        try gray.withUnsafeBufferPointer { g in
            try candidate.withUnsafeMutableBufferPointer { c in
                let c = c
                try cleanupRows(height, stop) { y in
                    let row = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                    defer { row.deallocate() }
                    map.row(y, into: row)
                    for x in 0..<width { c[y * width + x] = Float(g[y * width + x]) < row[x] - contrast }
                }
            }
        }
        var strokes = [Bool](repeating: false, count: gray.count)
        var seen = [Bool](repeating: false, count: gray.count)
        var stack: [Int] = []
        var run: [Int] = []
        try candidate.withUnsafeBufferPointer { candidate in
            try seen.withUnsafeMutableBufferPointer { seen in
                try strokes.withUnsafeMutableBufferPointer { strokes in
                    for start in 0..<candidate.count {
                        if start % width == 0 { try stop?.check() }
                        if !candidate[start] || seen[start] { continue }
                        run.removeAll(keepingCapacity: true)
                        seen[start] = true
                        stack.append(start)
                        while let i = stack.popLast() {
                            run.append(i)
                            let (x, y) = (i % width, i / width)
                            // Two pixels away still counts: a pencil line has gaps in its grain.
                            for ny in max(0, y - 2)...min(height - 1, y + 2) {
                                for nx in max(0, x - 2)...min(width - 1, x + 2) {
                                    let n = ny * width + nx
                                    if seen[n] || !candidate[n] { continue }
                                    seen[n] = true
                                    stack.append(n)
                                }
                            }
                        }
                        if run.count >= minPixels {
                            for i in run { strokes[i] = true }
                        }
                    }
                }
            }
        }
        return strokes
    }
}

/// Takes the printing screen out of pictures: blocks whose pixels repeat at a short period both across and down (a
/// halftone at any usual angle; text repeats at most along a line, a bar code in one direction) are blurred just enough to
/// lose the dots, fading out at their edges. Everything else keeps its pixels byte for byte. Below 150 dpi there are no
/// dots left to take out.
enum Descreen {
    private static let minCorrelation = 0.3
    private static let minVariance = 16.0, samples = 6

    /// Whether any of the page was a screen. In place.
    static func apply(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, _ stop: BatchStop?) throws -> Bool {
        if dpi < 150 || width < 64 || height < 64 { return false }
        let gray = channels == 1 ? pixels : try CleanupGray.of(pixels, width, height, stop)
        let block = max(32, dpi / 6)
        let maxLag = max(8, dpi / 25)
        let (cols, rows) = (width / block, height / block)
        if cols < 1 || rows < 1 { return false }
        var periods = [Int](repeating: 0, count: cols * rows)
        try gray.withUnsafeBufferPointer { g in
            try periods.withUnsafeMutableBufferPointer { out in
                let out = out
                try cleanupRows(rows, stop) { by in
                    for bx in 0..<cols { out[by * cols + bx] = blockPeriod(g, width, bx * block, by * block, block, maxLag) }
                }
            }
        }

        var screened = [Bool](repeating: false, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols where periods[y * cols + x] != 0 {
                // One block alone is chance: a screen goes on.
                var company = 0
                for dy in -1...1 {
                    for dx in -1...1 where (dx != 0 || dy != 0) && x + dx >= 0 && y + dy >= 0 && x + dx < cols && y + dy < rows
                        && periods[(y + dy) * cols + x + dx] != 0 { company += 1 }
                }
                screened[y * cols + x] = company >= 2
            }
        }
        let found = periods.indices.filter { screened[$0] }.map { periods[$0] }.sorted()
        if found.isEmpty { return false }
        let period = found[found.count / 2]

        var grown = PhotoFinder.dilate(screened, cols, rows, 1)
        PhotoFinder.fillHoles(&grown, cols, rows)
        grown = PhotoFinder.erode(grown, cols, rows, 1)
        for i in grown.indices where screened[i] { grown[i] = true }

        // Where the blur goes: every block of the screen, with room for its fading edge.
        var (minX, minY, maxX, maxY) = (cols, rows, -1, -1)
        for y in 0..<rows {
            for x in 0..<cols where grown[y * cols + x] { (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)) }
        }
        let fade = max(2, block / 8)
        let (x0, y0) = (max(0, minX * block - fade), max(0, minY * block - fade))
        let x1 = maxX == cols - 1 ? width : min(width, (maxX + 1) * block + fade)
        let y1 = maxY == rows - 1 ? height : min(height, (maxY + 1) * block + fade)
        let (rw, rh) = (x1 - x0, y1 - y0)

        // Just enough to lose the dots (about 4% of their strength left), so type on a tint stays readable.
        let sigma = 0.4 * Double(period)
        let radius = max(1, Int(sigma * 0.7))
        let passes = max(3, Int((sigma * sigma / (Double(radius * (radius + 1)) / 3)).rounded(.up)))
        var blurred = [UInt8](repeating: 0, count: rw * rh * channels)
        for y in 0..<rh {
            let from = (y0 + y) * width * channels + x0 * channels
            blurred.replaceSubrange((y * rw * channels)..<((y + 1) * rw * channels), with: pixels[from..<(from + rw * channels)])
        }
        try blurred.withUnsafeMutableBufferPointer { data in
            for _ in 0..<passes {
                try boxAcross(data, rw, rh, channels, radius, stop)
                try boxDown(data, rw, rh, channels, radius, stop)
            }
        }

        // Weight by distance to a screened block's edge, per pixel from its block's neighbours.
        try blurred.withUnsafeBufferPointer { b in
            try grown.withUnsafeBufferPointer { grown in
                try pixels.withUnsafeMutableBufferPointer { p in
                    let p = p
                    try cleanupRows(rh, stop) { ry in
                        let y = y0 + ry
                        for rx in 0..<rw {
                            let x = x0 + rx
                            let weight = Self.weight(grown, cols, rows, block, fade, x, y, width, height)
                            if weight <= 0 { continue }
                            for c in 0..<channels {
                                let at = (y * width + x) * channels + c
                                let v = Float(p[at]) + (Float(b[(ry * rw + rx) * channels + c]) - Float(p[at])) * weight
                                p[at] = cleanupByte(v)
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    private static func weight(_ grown: UnsafeBufferPointer<Bool>, _ cols: Int, _ rows: Int, _ block: Int, _ fade: Int, _ x: Int, _ y: Int,
                               _ width: Int, _ height: Int) -> Float {
        var best: Float = 0
        let (bx, by) = (min(x / block, cols - 1), min(y / block, rows - 1))
        for dy in -1...1 {
            for dx in -1...1 {
                let (nx, ny) = (bx + dx, by + dy)
                if nx < 0 || ny < 0 || nx >= cols || ny >= rows || !grown[ny * cols + nx] { continue }
                // A last row or column of blocks reaches the page's edge.
                let (left, top) = (nx * block, ny * block)
                let right = nx == cols - 1 ? width : left + block
                let bottom = ny == rows - 1 ? height : top + block
                let outX = max(max(left - x, x - (right - 1)), 0)
                let outY = max(max(top - y, y - (bottom - 1)), 0)
                let outside = max(outX, outY)
                if outside >= fade { continue }
                best = max(best, 1 - Float(outside) / Float(fade))
            }
        }
        return best
    }

    /// The screen's period in a block in pixels, or 0 when it repeats at no short period both across and down.
    private static func blockPeriod(_ gray: UnsafeBufferPointer<UInt8>, _ width: Int, _ x0: Int, _ y0: Int, _ block: Int, _ maxLag: Int) -> Int {
        var (sum, squares) = (0, 0)
        for y in y0..<(y0 + block) {
            for x in x0..<(x0 + block) {
                let v = Int(gray[y * width + x])
                sum += v
                squares += v * v
            }
        }
        let n = Double(block * block)
        let mean = Double(sum) / n
        if Double(squares) / n - mean * mean < minVariance { return 0 }

        let across = firstPeak(block, maxLag, samples) { line, i in gray[(y0 + (line * 2 + 1) * block / (samples * 2)) * width + x0 + i] }
        if across == 0 { return 0 }
        let down = firstPeak(block, maxLag, samples) { line, i in gray[(y0 + i) * width + x0 + (line * 2 + 1) * block / (samples * 2)] }
        if down == 0 || max(across, down) > 2 * min(across, down) { return 0 }
        // A screen at 45° repeats less often along a row than its dots lie apart; along the diagonal it says so. The dots' true wavelength.
        let wave = max(across, down)
        let diagonal = firstPeak(block, maxLag, samples) { line, i in
            let start = (line * 2 + 1) * block / (samples * 2)
            return gray[(y0 + (start + i) % block) * width + x0 + i]
        }
        return diagonal > 0 ? Int(max(2, min(Double(wave), Double(diagonal) * 2.0.squareRoot()).rounded(.toNearestOrEven))) : wave
    }

    /// The first lag of at least 2 where sample lines correlate with themselves, at a local peak of correlation; 0 when
    /// none. Each line is measured against its own mean, so a line of one level says nothing.
    private static func firstPeak(_ length: Int, _ maxLag: Int, _ lines: Int, _ at: (Int, Int) -> UInt8) -> Int {
        let limit = min(maxLag + 1, length / 3)
        if limit < 3 { return 0 }
        var r = [Double](repeating: 0, count: limit + 1)
        var values = [Double](repeating: 0, count: length)
        var energy = 0.0
        for line in 0..<lines {
            var mean = 0.0
            for i in 0..<length {
                values[i] = Double(at(line, i))
                mean += values[i]
            }
            mean /= Double(length)
            for i in 0..<length {
                values[i] -= mean
                energy += values[i] * values[i]
            }
            for lag in 1...limit {
                var s = 0.0
                for i in 0..<(length - lag) { s += values[i] * values[i + lag] }
                r[lag] += s * Double(length) / Double(length - lag)
            }
        }
        if energy < Double(lines * length) { return 0 } // less than a level's variation
        for lag in 2..<limit where r[lag] / energy >= minCorrelation && r[lag] > r[lag - 1] && r[lag] >= r[lag + 1] { return lag }
        return 0
    }

    private static func boxAcross(_ data: UnsafeMutableBufferPointer<UInt8>, _ w: Int, _ h: Int, _ channels: Int, _ radius: Int, _ stop: BatchStop?) throws {
        try cleanupRows(h, stop) { y in
            var line = [Int](repeating: 0, count: w)
            for c in 0..<channels {
                var sum = 0
                for x in -radius...radius { sum += Int(data[(y * w + min(max(x, 0), w - 1)) * channels + c]) }
                for x in 0..<w {
                    line[x] = (sum + radius) / (2 * radius + 1) // rounded: truncating darkens the page a level a pass
                    sum += Int(data[(y * w + min(w - 1, x + radius + 1)) * channels + c]) - Int(data[(y * w + max(0, x - radius)) * channels + c])
                }
                for x in 0..<w { data[(y * w + x) * channels + c] = UInt8(line[x]) }
            }
        }
    }

    private static func boxDown(_ data: UnsafeMutableBufferPointer<UInt8>, _ w: Int, _ h: Int, _ channels: Int, _ radius: Int, _ stop: BatchStop?) throws {
        try cleanupRows(w, stop) { x in
            var line = [Int](repeating: 0, count: h)
            for c in 0..<channels {
                var sum = 0
                for y in -radius...radius { sum += Int(data[(min(max(y, 0), h - 1) * w + x) * channels + c]) }
                for y in 0..<h {
                    line[y] = (sum + radius) / (2 * radius + 1)
                    sum += Int(data[(min(h - 1, y + radius + 1) * w + x) * channels + c]) - Int(data[(max(0, y - radius) * w + x) * channels + c])
                }
                for y in 0..<h { data[(y * w + x) * channels + c] = UInt8(line[y]) }
            }
        }
    }
}

/// Restores a faded print: each channel's darkest and lightest levels (0.5% in from each end) are spread to the full
/// range, which brings blacks back and takes out a color cast; then the mid-tones of the channels are brought level
/// (colored scans). A page with little range (blank), a dark page, or one already at full range is left as it is, or
/// nearly.
enum FadedColors {
    private static let minRange = 32, darkPage = 110, maxGainRange = 64

    /// Whether it changed the page. In place.
    static func restore(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ stop: BatchStop?) throws -> Bool {
        if width < 1 || height < 1 { return false }
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: channels)
        let rowStep = max(1, height / 2000)
        let columnStep = max(1, width / 2000)
        try pixels.withUnsafeBufferPointer { p in
            for y in Swift.stride(from: 0, to: height, by: rowStep) {
                try stop?.check()
                for x in Swift.stride(from: 0, to: width, by: columnStep) {
                    for c in 0..<channels { histograms[c][Int(p[(y * width + x) * channels + c])] += 1 }
                }
            }
        }
        var luts: [[UInt8]] = []
        for c in 0..<channels {
            var (low, high) = ends(histograms[c])
            if high < darkPage || high - low < minRange { return false }
            if high - low < maxGainRange { low = high - maxGainRange } // a gain past 4 only spreads noise
            luts.append((0..<256).map { v in UInt8(min(max((v - low) * 255 / max(1, high - low), 0), 255)) })
        }

        if channels == 3 { balanceMidTones(&luts, pixels, width, height, rowStep, columnStep) }

        if !luts.contains(where: { lut in lut.indices.contains { Int(lut[$0]) != $0 } }) { return false }
        let tables = luts.flatMap { $0 }
        try tables.withUnsafeBufferPointer { t in
            try pixels.withUnsafeMutableBufferPointer { p in
                let p = p
                try cleanupRows(height, stop) { y in
                    var at = y * width * channels
                    for _ in 0..<width {
                        for c in 0..<channels {
                            p[at] = t[c * 256 + Int(p[at])]
                            at += 1
                        }
                    }
                }
            }
        }
        return true
    }

    /// The levels 0.5% from each end, leaving pure white out (the corners a straightening uncovers, a whitened background).
    private static func ends(_ histogram: [Int]) -> (low: Int, high: Int) {
        var all = 0
        for v in 0..<255 { all += histogram[v] }
        if all == 0 { return (255, 255) }
        let cut = all / 200
        var (low, high) = (0, 254)
        var seen = 0
        while low < 254 {
            seen += histogram[low]
            if seen > cut { break }
            low += 1
        }
        seen = 0
        while high > 0 {
            seen += histogram[high]
            if seen > cut { break }
            high -= 1
        }
        return (low, high)
    }

    private static func balanceMidTones(_ luts: inout [[UInt8]], _ pixels: [UInt8], _ width: Int, _ height: Int, _ rowStep: Int, _ columnStep: Int) {
        var sums = [0.0, 0.0, 0.0]
        var (count, all) = (0, 0)
        for y in Swift.stride(from: 0, to: height, by: rowStep) {
            for x in Swift.stride(from: 0, to: width, by: columnStep) {
                all += 1
                let i = (y * width + x) * 3
                let (r, g, b) = (Int(luts[0][Int(pixels[i])]), Int(luts[1][Int(pixels[i + 1])]), Int(luts[2][Int(pixels[i + 2])]))
                let luma = (r * 77 + g * 150 + b * 29) >> 8
                if luma < 40 || luma > 215 { continue }
                sums[0] += Double(r)
                sums[1] += Double(g)
                sums[2] += Double(b)
                count += 1
            }
        }
        if count * 20 < all { return } // a page of text and paper has no mid-tones to go by
        let target = (sums[0] + sums[1] + sums[2]) / 3 / Double(count) / 255
        for c in 0..<3 {
            let mean = sums[c] / Double(count) / 255
            let gamma = min(max(log(target) / log(mean), 0.7), 1.4)
            for v in 0..<256 {
                let value = (255 * pow(Double(luts[c][v]) / 255, gamma)).rounded(.toNearestOrEven)
                luts[c][v] = UInt8(value.isNaN ? 0 : min(max(value, 0), 255))
            }
        }
    }
}
