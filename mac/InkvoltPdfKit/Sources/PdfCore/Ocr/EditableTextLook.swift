import CoreGraphics
import CoreText
import Foundation

extension EditableText {
    /// What one Make Text Editable run keeps across its pages (the Windows app's `FontMatch`): each word drawn in each face
    /// (once, at `em` pixels to the em), and the families short-listed on the first page with enough words, which the next
    /// pages compare alone. Windows draws the words on one PDF page with MuPDF; the Mac draws each with Core Graphics.
    final class FontMatch {
        /// The size words are drawn at to compare (pixels to the em).
        static let em = 40.0

        /// The widest word drawn (pixels): a longer one is no word to compare.
        static let maxWidth = 2000.0

        /// A word drawn: grey pixels around its ink, the ink's box in them.
        struct Drawn {
            var pixels: [UInt8]
            var width: Int, height: Int
            var inkLeft: Double, inkTop: Double, inkWidth: Double, inkHeight: Double
        }

        private struct Key: Hashable {
            var font: ObjectIdentifier
            var text: String
        }

        private let cancel: CancelToken?
        private var drawn: [Key: Drawn?] = [:]
        private var sized: [ObjectIdentifier: CTFont] = [:]
        private let inks = Inks()
        private(set) var shortlist: [Family]?
        private var representatives: [Family] = []

        init(_ cancel: CancelToken?) { self.cancel = cancel }

        func keep(_ shortlist: [Family], _ representatives: [Family]) {
            self.shortlist = shortlist
            self.representatives = representatives
        }

        /// The families a heading may be set in: the page's, the short list, and the common serif, sans serif and monospaced.
        func headingFamilies(_ page: Family) -> [Family] {
            var all: [Family] = []
            for f in [page] + (shortlist ?? []) + representatives where !all.contains(f) { all.append(f) }
            return all
        }

        func get(_ font: TrueTypeFont, _ text: String) -> Drawn? { drawn[Key(font: ObjectIdentifier(font), text: text)] ?? nil }

        /// Draws every (face, word) not drawn yet.
        /// - Throws: `CancellationError` when the run's token fires.
        func draw(_ wanted: [(TrueTypeFont, String)]) throws {
            for (font, text) in wanted {
                let key = Key(font: ObjectIdentifier(font), text: text)
                if drawn.keys.contains(key) { continue }
                try cancel.check()
                drawn[key] = .some(picture(font, text))
            }
        }

        /// `text` in `font` at `em` pixels to the em, black on white, a pixel around its ink; nil when the font lacks a
        /// character of it or it is too wide.
        private func picture(_ font: TrueTypeFont, _ text: String) -> Drawn? {
            let em = Self.em
            let ink = inks.of(text, font)
            guard let (x0, y0, x1, y1) = Self.inkBox(ink, em) else { return nil }
            let (w, h) = (x1 - x0, y1 - y0)
            guard w > 0, h > 0, w <= Int(Self.maxWidth) + 4, h <= 4 * Int(em) * 4,
                  let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(gray: 0, alpha: 1)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            let ctFont = sized[ObjectIdentifier(font)] ?? CTFontCreateCopyWithAttributes(font.font, CGFloat(em), nil, nil)
            sized[ObjectIdentifier(font)] = ctFont
            let shaped = TextShaper.shape(text, font, visualOrder: true)
            var glyphs = shaped.glyphs.map { CGGlyph(clamping: $0.glyph) }
            // The pen at -x0, the baseline y0 pixels below the top (Core Graphics counts up from the bottom row).
            var positions = shaped.glyphs.map { CGPoint(x: Double(-x0) + $0.x * em, y: Double(h + y0) + $0.y * em) }
            CTFontDrawGlyphs(ctFont, &glyphs, &positions, glyphs.count, context)
            guard let data = context.data else { return nil }
            let stride = context.bytesPerRow
            let bytes = data.bindMemory(to: UInt8.self, capacity: stride * h)
            var pixels = [UInt8](repeating: 255, count: w * h)
            for y in 0..<h {
                for x in 0..<w { pixels[y * w + x] = bytes[y * stride + x] }
            }
            return Drawn(pixels: pixels, width: w, height: h, inkLeft: ink.left * em - Double(x0), inkTop: -ink.top * em - Double(y0),
                         inkWidth: ink.width * em, inkHeight: ink.height * em)
        }

        /// The ink's box at `em` pixels to the em (pixels from the pen and the baseline, y down), a pixel around it; nil
        /// when the font lacks a character, the ink has no width or the word is too wide (`maxWidth`), and for an ink a
        /// font's glyph boxes made absurd: NaN, infinite, or farther from the pen or the baseline than `maxWidth` pixels.
        static func inkBox(_ ink: Ink, _ em: Double) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
            let reach = maxWidth / em
            let edges = [ink.left, ink.right, ink.top, ink.bottom]
            // abs(NaN) <= reach is false: an edge that isn't a number fails here too.
            guard !ink.missing, edges.allSatisfy({ abs($0) <= reach }), ink.width > 0,
                  (max(0, ink.right) - min(0, ink.left)) * em + 16 <= maxWidth else { return nil }
            // Each edge within maxWidth / em ems (checked above), so each value within maxWidth + 1 pixels.
            let (x0, x1) = (Int((ink.left * em).rounded(.down)) - 1, Int((ink.right * em).rounded(.up)) + 1) // bounded: |edge| <= maxWidth px
            let (y0, y1) = (Int((-ink.top * em).rounded(.down)) - 1, Int((-ink.bottom * em).rounded(.up)) + 1) // bounded: |edge| <= maxWidth px
            return (x0, y0, x1, y1)
        }
    }

    /// A scanned page as it shows, drawn at about 150 dpi (the Windows app's `ScanLook`): its words compared with the same
    /// words drawn in a face (`resemblance`), its ink's colour and its paper's.
    final class ScanLook {
        /// The words compared to choose the page's family (spread over the page).
        static let samples = 40

        /// A word compared is brought to this height (pixels), with this much room around it.
        private static let canvasHeight = 20, padX = 3, padY = 6

        let match: FontMatch
        private let engine: PdfEngine
        private let page: Int
        private let cancel: CancelToken?
        private var image: RenderedImage?
        private var scale = 1.0
        private var canvases: [ObjectIdentifier: (pixels: [Double], width: Int, paper: Double)] = [:]

        init(_ engine: PdfEngine, _ page: Int, _ match: FontMatch, _ cancel: CancelToken?) {
            self.engine = engine
            self.page = page
            self.match = match
            self.cancel = cancel
        }

        private func rendered() throws -> RenderedImage {
            if let image { return image }
            let g = engine.page(page)
            scale = min(150 / 72.0, (6_000_000 / max(1, g.width * g.height)).squareRoot())
            let made = try engine.render(page, scale: scale, cancel: cancel, annotations: false)
            image = made
            return made
        }

        /// Draws (once for the run) what the next comparisons need.
        func draw(_ wanted: [(TrueTypeFont, String)]) throws {
            _ = try rendered()
            try match.draw(wanted)
        }

        /// The scan's grey at a page point (bilinear; white off the page).
        private func grayAt(_ img: RenderedImage, _ x: Double, _ y: Double) -> Double {
            let (sx, sy) = (x * scale - 0.5, y * scale - 0.5)
            guard sx > -1 && sy > -1 && sx < Double(img.width) && sy < Double(img.height) else { return 255 }
            let (x0, y0) = (Int(sx.rounded(.down)), Int(sy.rounded(.down))) // bounded: within (-1, the image's size) by the guard, which NaN fails
            let (fx, fy) = (sx - Double(x0), sy - Double(y0))
            func at(_ a: Int, _ b: Int) -> Double {
                if a < 0 || b < 0 || a >= img.width || b >= img.height { return 255 }
                let o = b * img.stride + a * 3
                return Double(Int(img.pixels[o]) * 77 + Int(img.pixels[o + 1]) * 150 + Int(img.pixels[o + 2]) * 29) / 256
            }
            return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
        }

        /// How much `sample`'s words drawn in `font` look like the scan's: each word's scan and its drawing brought to one
        /// height (the drawing scaled to the scan word's width, centred on its height, so a face with other proportions,
        /// slant or serifs shows), Pearson's correlation between them less how far the ink each covers differs (|ln| of the
        /// ratio: another weight); the mean over the words, or over the best `share` of them (a page's family is judged on
        /// its words in that family's look, not on the italic or bold ones among them). Words not drawn (`draw` first)
        /// aren't counted; −1 when none is.
        func resemblance(_ font: TrueTypeFont, _ sample: [(line: PlanLine, word: PlanWord)], share: Double = 1) -> Double {
            guard let img = try? rendered() else { return -1 }
            var scores: [Double] = []
            let (padX, padY, canvasHeight) = (Self.padX, Self.padY, Self.canvasHeight)
            for (line, word) in sample {
                guard let d = match.get(font, word.text), word.width > 0, word.height > 0 else { continue }
                let (scan, cw, paper) = canvas(img, line, word)
                let k = Double(cw) / d.inkWidth
                let (w, h) = (cw + 2 * padX, canvasHeight + 2 * padY)
                var (sx, sy, sxx, syy, sxy, inkScan, inkDrawn) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                let n = Double(w * h)
                for j in 0..<h {
                    let iy = (Double(j) + 0.5 - (Double(padY) + Double(canvasHeight) / 2)) / k + d.inkTop + d.inkHeight / 2 - 0.5
                    for i in 0..<w {
                        let ix = (Double(i) + 0.5 - Double(padX)) / k + d.inkLeft - 0.5
                        let b = Self.bilinear(d.pixels, d.width, d.height, ix, iy)
                        let a = scan[j * w + i]
                        sx += a
                        sy += b
                        sxx += a * a
                        syy += b * b
                        sxy += a * b
                        inkScan += paper - a
                        inkDrawn += 255 - b
                    }
                }
                let va = sxx - sx * sx / n, vb = syy - sy * sy / n
                if va <= 0 || vb <= 0 { continue }
                let weight = inkScan > 0 && inkDrawn > 0 ? abs(log(inkDrawn / inkScan)) : 1
                scores.append((sxy - sx * sy / n) / (va * vb).squareRoot() - weight)
            }
            return Self.meanOfBest(scores, share)
        }

        /// The mean of the best `share` of the scores (at least one; all of them for a share that isn't a number or
        /// takes more than all); -1 for none.
        static func meanOfBest(_ scores: [Double], _ share: Double) -> Double {
            if scores.isEmpty { return -1 }
            let taken = Int(exactly: (Double(scores.count) * share).rounded(.up)) ?? scores.count
            let best = scores.sorted(by: >).prefix(min(max(1, taken), scores.count))
            return best.reduce(0, +) / Double(best.count)
        }

        /// A scan word brought to `canvasHeight` (once a page, whatever the faces it is compared with), its width and its
        /// paper's grey.
        private func canvas(_ img: RenderedImage, _ line: PlanLine, _ word: PlanWord) -> (pixels: [Double], width: Int, paper: Double) {
            if let known = canvases[ObjectIdentifier(word)] { return known }
            let (padX, padY, canvasHeight) = (Self.padX, Self.padY, Self.canvasHeight)
            // A word box infinite both ways is NaN wide here: the narrowest canvas.
            let wide = (Double(canvasHeight) * word.width / word.height).rounded(.toNearestOrEven)
            let cw = wide.isNaN ? 4 : Int(min(max(wide, 4), 240)) // bounded: clamped to 4...240, NaN is 4
            let (w, h) = (cw + 2 * padX, canvasHeight + 2 * padY)
            var scan = [Double](repeating: 0, count: w * h)
            var paper = 0.0
            for j in 0..<h {
                for i in 0..<w {
                    let fx = word.left + (Double(i) + 0.5 - Double(padX)) * word.width / Double(cw)
                    let fy = word.top + (Double(j) + 0.5 - Double(padY)) * word.height / Double(canvasHeight)
                    let p = EditableText.toPage(line.angle, fx, fy)
                    let v = grayAt(img, p.x, p.y)
                    scan[j * w + i] = v
                    paper = max(paper, v)
                }
            }
            let made = (scan, cw, paper)
            canvases[ObjectIdentifier(word)] = made
            return made
        }

        /// A drawn word's grey at (x, y) in its pixels (bilinear; white off them, and where x or y isn't a number).
        static func bilinear(_ px: [UInt8], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Double {
            // Off the pixels all four neighbours are white anyway: 255, as they would give.
            guard x > -1 && y > -1 && x < Double(w) && y < Double(h) else { return 255 }
            let (x0, y0) = (Int(x.rounded(.down)), Int(y.rounded(.down))) // bounded: within (-1, w) and (-1, h) by the guard, which NaN fails
            let (fx, fy) = (x - Double(x0), y - Double(y0))
            func at(_ a: Int, _ b: Int) -> Double { a < 0 || b < 0 || a >= w || b >= h ? 255 : Double(px[b * w + a]) }
            return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
        }

        /// What was collected of the pixels: per lightness level, how many and their summed R, G, B.
        private struct Levels {
            var count = [Int](repeating: 0, count: 256)
            var r = [Double](repeating: 0, count: 256), g = [Double](repeating: 0, count: 256), b = [Double](repeating: 0, count: 256)
        }

        /// The pixels inside a polygon's bounding box on the page, by lightness.
        private func collect(_ img: RenderedImage, _ corners: [(x: Double, y: Double)], _ levels: inout Levels) {
            guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(), let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max(),
                  minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { return }
            func clamp(_ v: Double, _ hi: Int) -> Int { Int(min(max(v, 0), Double(hi))) } // bounded: clamped to the image
            let (x0, x1) = (clamp((minX * scale).rounded(.down), img.width), clamp((maxX * scale).rounded(.up), img.width))
            let (y0, y1) = (clamp((minY * scale).rounded(.down), img.height), clamp((maxY * scale).rounded(.up), img.height))
            if x0 >= x1 || y0 >= y1 { return }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = y * img.stride + x * 3
                    let (rr, gg, bb) = (Int(img.pixels[o]), Int(img.pixels[o + 1]), Int(img.pixels[o + 2]))
                    let light = (bb * 29 + gg * 150 + rr * 77) >> 8
                    levels.count[light] += 1
                    levels.r[light] += Double(rr)
                    levels.g[light] += Double(gg)
                    levels.b[light] += Double(bb)
                }
            }
        }

        /// The mean colour (0 to 1) of the lightest (`lightest`) or darkest share of what was collected; nil for nothing.
        private static func mean(_ levels: Levels, _ share: Double, lightest: Bool) -> Rgb? {
            let total = levels.count.reduce(0, +)
            if total == 0 { return nil }
            let want = max(1, Int(Double(total) * share))
            var (n, sr, sg, sb) = (0.0, 0.0, 0.0, 0.0)
            for k in 0..<256 where n < Double(want) {
                let level = lightest ? 255 - k : k
                let c = levels.count[level]
                if c == 0 { continue }
                // A level only partly needed counts in proportion.
                let take = Double(min(c, want - Int(n))) / Double(c) // bounded: n counts pixels
                n += Double(c) * take
                sr += levels.r[level] * take
                sg += levels.g[level] * take
                sb += levels.b[level] * take
            }
            return (sr / n / 255, sg / n / 255, sb / n / 255)
        }

        /// The paper's colour behind a line (the corners of what covers it): the lightest 15% of what is under it,
        /// averaged; nearly white is white.
        func paper(_ corners: [(x: Double, y: Double)]) throws -> Rgb {
            let img = try rendered()
            var levels = Levels()
            collect(img, corners, &levels)
            guard let p = Self.mean(levels, 0.15, lightest: true) else { return (1, 1, 1) }
            func round3(_ v: Double) -> Double { (v * 1000).rounded(.toNearestOrEven) / 1000 }
            return min(p.r, p.g, p.b) >= 0.96 ? (1, 1, 1) : (round3(p.r), round3(p.g), round3(p.b))
        }

        /// A paragraph's ink colour: the darkest tenth of what is inside its words' boxes, averaged. Ink with little colour
        /// in it (a scan's black or grey print) is black; a clear colour (blue, red) is kept, rounded to a twentieth.
        func inkColor(_ lines: [PlanLine]) -> Rgb {
            guard let img = try? rendered() else { return (0, 0, 0) }
            var levels = Levels()
            for line in lines {
                for w in line.words.prefix(20) {
                    let corners = [(w.left, w.top), (w.right, w.top), (w.right, w.bottom), (w.left, w.bottom)].map { EditableText.toPage(line.angle, $0.0, $0.1) }
                    collect(img, corners, &levels)
                }
            }
            guard let c = Self.mean(levels, 0.1, lightest: false) else { return (0, 0, 0) }
            let chroma = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
            func round20(_ v: Double) -> Double { (v * 20).rounded(.toNearestOrEven) / 20 }
            if chroma < 0.15 {
                // Grey print: black when dark (a scan's black is never quite black), else its grey.
                let l = (c.r + c.g + c.b) / 3
                return l < 0.35 ? (0, 0, 0) : (round20(l), round20(l), round20(l))
            }
            return (round20(c.r), round20(c.g), round20(c.b))
        }
    }
}
