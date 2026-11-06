import Foundation
import PrintCore

/// A recognized word and its box in page space (points, top-left origin of the displayed, rotated and cropped page). The
/// box is the word's own, level box, turned `angle` degrees clockwise about its centre (a word on a skewed scan runs at
/// the scan's skew). `suspect`: why it is a suspect word, if it is one.
public struct OcrWord: Equatable, Sendable {
    public var text: String
    public var rect: RectD
    public var angle: Double
    public var suspect: SuspectReasons

    public init(_ text: String, _ rect: RectD, angle: Double = 0, suspect: SuspectReasons = []) {
        self.text = text
        self.rect = rect
        self.angle = angle
        self.suspect = suspect
    }
}

/// A page's Inkvolt text layer as read back: its words, and the language they were recognized in (when known).
public struct OcrLayer: Equatable, Sendable {
    public var words: [OcrWord]
    public var language: String?
}

/// Invisible text over scanned pages (an OCR text layer, the Windows app's `TextLayer`): the page looks the same, but its
/// words can be selected, copied and searched. Each word is written with text render mode 3 (no paint), stretched along
/// its box and turned with it, in a content stream of its own placed before the page's content (so the existing content's
/// graphics state, balanced or not, can't leak into it). The layer starts with comment lines, byte for byte as Windows
/// writes them (`marker` and the language, the page's frame, then one per word: its suspect reasons, box, angle and text
/// as UTF-8 hex), so its words can be read back (`words`), reviewed and corrected on either platform: a corrected layer
/// replaces the old one in place. Windows embeds a subset of Arial (CIDFontType2, shaped by HarfBuzz); the Mac embeds
/// `GlyphlessFont`, whose glyphs draw nothing, with a /ToUnicode per page that returns the words as recognized: one code
/// per Unicode scalar, right-to-left runs written in visual order as Windows writes them.
public enum TextLayer {
    /// The first line of an Inkvolt text layer (a content-stream comment; viewers skip it).
    public static let marker = "%InkvoltOCR 1"

    /// The start of the names of a text layer's fonts in a page's resources: a file whose bytes never mention it (nor keep
    /// compressed objects, which hide every name) has no Inkvolt text layer.
    public static let fontPrefix = "PdOcr"

    // Further than this (pt) from a page's corner no word lies, even on the largest page PDF allows; a layer is untrusted input.
    private static let maxCoordinate = 1e6

    /// - Parameter wordsByPage: words per page index, in reading order. A page that already has an Inkvolt text layer gets
    ///   it replaced.
    /// - Parameter language: the language they were recognized in (a BCP-47 tag), kept with them for their review.
    /// - Returns: the same bytes when no page has a usable word.
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func addInvisibleText(_ data: [UInt8], _ password: String?, _ wordsByPage: [Int: [OcrWord]], language: String? = nil) throws -> [UInt8] {
        let pages = wordsByPage.filter { $0.value.contains(where: usable) }.sorted { $0.key < $1.key }
        if pages.isEmpty { return data }
        return try PageEditor.edit(data, password) { doc in
            let count = try doc.pageCount()
            var descendant: PObj?
            for (index, words) in pages {
                guard index >= 0 && index < count else { throw PdfEditError(loc("There is no page {0}.", CoreLanguage.number(index + 1))) }
                setLayer(doc, doc.page(index), words, language, &descendant)
            }
        }
    }

    /// The words of each page's Inkvolt text layer (pages without one, or with one made before 2.2, aren't listed).
    public static func words(_ data: [UInt8], _ password: String?) throws -> [Int: OcrLayer] {
        let doc = try PdfEdit.openToRead(data, password)
        var result: [Int: OcrLayer] = [:]
        for i in 0..<(try doc.pageCount()) {
            let page = doc.page(i)
            if let layer = findLayer(page), let words = parseWords(layer.text), !words.isEmpty {
                result[i] = OcrLayer(words: inFrameOf(page, words, layer.text), language: languageOf(layer.text))
            }
        }
        return result
    }

    /// Whether any page's Inkvolt text layer has a suspect word left to check (Recognize Text's, Batch's or Scan's: a file
    /// opened later lists them for review). A file that can't have a layer (`mayHaveLayer`) isn't opened at all.
    public static func hasSuspectWords(_ data: [UInt8], _ password: String?) throws -> Bool {
        guard mayHaveLayer(data) else { return false }
        let doc = try PdfEdit.openToRead(data, password)
        for i in 0..<(try doc.pageCount()) {
            if let layer = findLayer(doc.page(i)), let words = parseWords(layer.text), words.contains(where: { !$0.suspect.isEmpty }) { return true }
        }
        return false
    }

    /// False only when the bytes never mention a text layer's font (`fontPrefix`) and keep no compressed objects (an
    /// object stream hides every name): such a file has no Inkvolt text layer, so it needn't be parsed for one.
    public static func mayHaveLayer(_ data: [UInt8]) -> Bool {
        mentions(data, "/" + fontPrefix) || mentions(data, "/ObjStm")
    }

    /// Whether the bytes hold `name` anywhere (memmem: a document's whole bytes, at each change).
    private static func mentions(_ data: [UInt8], _ name: String) -> Bool {
        let needle = Array(name.utf8)
        guard data.count >= needle.count else { return false }
        return data.withUnsafeBytes { hay in
            needle.withUnsafeBytes { n in memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil }
        }
    }

    /// Word `index` of a page's text layer becomes `text` (a correction) and stops being a suspect word; the layer is
    /// written again, so search finds the new text.
    /// - Throws: `PdfEditError` when the page has no Inkvolt text layer, the word isn't there or the text is empty.
    public static func correct(_ data: [UInt8], _ password: String?, _ page: Int, _ index: Int, _ text: String) throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw PdfEditError(loc("A word can't be empty.")) }
        return try change(data, password, page, index) { w in
            var w = w
            w.text = trimmed
            w.suspect = []
            return w
        }
    }

    /// Word `index` is right as recognized: it stops being a suspect word.
    public static func keep(_ data: [UInt8], _ password: String?, _ page: Int, _ index: Int) throws -> [UInt8] {
        try change(data, password, page, index) { w in
            var w = w
            w.suspect = []
            return w
        }
    }

    /// Whether MuPDF finds any text on the page (a page that already has text needs no OCR).
    public static func hasText(_ engine: PdfEngine, _ page: Int, cancel: CancelToken? = nil) throws -> Bool {
        try engine.text(page, cancel: cancel).text.contains { !$0.isWhitespace }
    }

    private static func change(_ data: [UInt8], _ password: String?, _ page: Int, _ index: Int, _ transform: (OcrWord) -> OcrWord) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard page >= 0, page < (try doc.pageCount()), let layer = findLayer(doc.page(page)), let parsed = parseWords(layer.text) else {
                throw PdfEditError(loc("This page has no recognized text to correct."))
            }
            let p = doc.page(page)
            var words = inFrameOf(p, parsed, layer.text)
            guard index >= 0 && index < words.count else { throw PdfEditError(loc("That recognized word isn't on the page any more.")) }
            words[index] = transform(words[index])
            var descendant: PObj?
            setLayer(doc, p, words, languageOf(layer.text), &descendant)
        }
    }

    static func usable(_ w: OcrWord) -> Bool {
        !w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !w.rect.isEmpty && w.angle.isFinite
            && [w.rect.x, w.rect.y, w.rect.width, w.rect.height].allSatisfy { $0.isFinite && abs($0) <= maxCoordinate }
    }

    /// The page's Inkvolt text layer: its place in /Contents (nil when /Contents is that one stream) and its text.
    private static func findLayer(_ page: PObj) -> (index: Int?, text: String)? {
        guard let contents = page["Contents"] else { return nil }
        let marker = Array(self.marker.utf8)
        let items = contents.isArray ? contents.elements : [contents]
        for (i, item) in items.enumerated() where item.isStream {
            guard let bytes = item.streamData, bytes.starts(with: marker) else { continue }
            return (contents.isArray ? i : nil, String(decoding: bytes, as: UTF8.self))
        }
        return nil
    }

    /// The language on the layer's first line, if it has one.
    private static func languageOf(_ layer: String) -> String? {
        let first = (layer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? layer)
            .trimmingCharacters(in: .whitespaces)
        guard first.count > marker.count else { return nil }
        let rest = String(first.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The words kept in a layer's comment lines, in order; nil when they can't be read. A word no page could have (a box
    /// out of range, not a number, empty) is left out, as writing the layer leaves it out.
    private static func parseWords(_ layer: String) -> [OcrWord]? {
        var words: [OcrWord] = []
        for raw in layer.split(separator: "\n", omittingEmptySubsequences: false) where raw.hasPrefix("%w ") {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if f.count != 8 { return nil }
            // As .NET's parse: a number too big for its kind is a word no page has (skipped); anything else unreadable
            // spoils the layer.
            guard let reasons = Int64(f[1]) else {
                if f[1].allSatisfy({ $0.isASCII && $0.isNumber }) && !f[1].isEmpty { continue }
                return nil
            }
            guard reasons >= Int64(Int32.min) && reasons <= Int64(Int32.max) else { continue }
            var n: [Double] = []
            for i in 2...6 {
                guard let v = number(f[i]) else { return nil }
                n.append(v)
            }
            guard let bytes = hexBytes(f[7]) else { return nil }
            let word = OcrWord(String(decoding: bytes, as: UTF8.self), RectD(n[0], n[1], n[2], n[3]), angle: n[4],
                               suspect: SuspectReasons(rawValue: Int(reasons)))
            if usable(word) { words.append(word) }
        }
        return words
    }

    /// A number as .NET's invariant `double.Parse` reads it ("NaN", "Infinity" and exponents included).
    private static func number(_ s: String) -> Double? {
        switch s {
        case "NaN": return .nan
        case "Infinity", "∞": return .infinity
        case "-Infinity", "-∞": return -.infinity
        default:
            guard !s.isEmpty, s.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
            return Double(s)
        }
    }

    private static func hexBytes(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8)
        guard c.count % 2 == 0 else { return nil }
        func v(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 65...70: b - 55
            case 97...102: b - 87
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(c.count / 2)
        var i = 0
        while i < c.count {
            guard let hi = v(c[i]), let lo = v(c[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02X", $0) }.joined() }

    /// The page's frame when the layer was written, from its line "%f rotate x1 y1 x2 y2" (the /Rotate and the visible
    /// box, PDF user space): the words' boxes are in that page space. Nil when the layer has none (written before it was
    /// kept) or it can't be read.
    private static func frameOf(_ layer: String) -> PageFrame? {
        for raw in layer.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("%w ") { break }
            guard raw.hasPrefix("%f ") else { continue }
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let rot = Int(f[1]), [0, 90, 180, 270].contains(rot) else { return nil }
            var n: [Double] = []
            for i in 2...5 {
                guard let v = number(f[i]), v.isFinite else { return nil }
                n.append(v)
            }
            return n[2] > n[0] && n[3] > n[1] ? PageFrame(bx1: n[0], by2: n[3], w: n[2] - n[0], h: n[3] - n[1], rot: rot) : nil
        }
        return nil
    }

    /// The words in the page's space as it is now: a page turned or cropped since its layer was written moves each word's
    /// centre with it and turns the word as much as the page. A layer without its frame is taken as in today's.
    private static func inFrameOf(_ page: PObj, _ words: [OcrWord], _ layer: String) -> [OcrWord] {
        let now = PageBoxes.frame(page)
        guard let was = frameOf(layer),
              !(was.bx1 == now.bx1 && was.by2 == now.by2 && was.w == now.w && was.h == now.h && was.rot == now.rot) else { return words }
        return words.map { w in
            let (x, y) = was.toPdf(w.rect.centerX, w.rect.centerY)
            let (cx, cy) = now.toPage(x, y)
            var angle = (w.angle + Double(now.rot - was.rot)).truncatingRemainder(dividingBy: 360)
            angle = angle > 180 ? angle - 360 : angle <= -180 ? angle + 360 : angle
            var moved = w
            moved.rect = RectD(cx - w.rect.width / 2, cy - w.rect.height / 2, w.rect.width, w.rect.height)
            moved.angle = angle
            return moved
        }.filter(usable)
    }

    /// Writes the page's text layer: in place of its Inkvolt layer when it has one, else before its content.
    private static func setLayer(_ doc: MuDoc, _ page: PObj, _ all: [OcrWord], _ language: String?, _ descendant: inout PObj?) {
        let existing = findLayer(page)
        let frame = PageBoxes.frame(page)
        let resources = ContentEditor.ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
        let fonts = ContentEditor.ownDict(doc, resources, "Font")
        if let old = existing {
            for key in fonts.keys where key.hasPrefix(fontPrefix) && old.text.contains("/\(key) ") { fonts.remove(key) }
        }
        var name = fontPrefix
        var n = 1
        while fonts.keys.contains(where: { $0.hasPrefix(name) }) {
            name = "\(fontPrefix)\(n)_"
            n += 1
        }
        name += "0"
        let layer = Layer()
        let words = all.filter(usable)

        var ops = marker
        if let language, !language.isEmpty, language.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }) { ops += " " + language }
        ops += "\n"
        // The page's frame, so the boxes follow the page when it is turned or cropped later (frameOf).
        let b = PageBoxes.visibleBox(page)
        ops += "%f \(frame.rot) \(PdfNum.f(b.x1)) \(PdfNum.f(b.y1)) \(PdfNum.f(b.x2)) \(PdfNum.f(b.y2))\n"
        for w in words {
            let r = w.rect
            ops += "%w \(w.suspect.rawValue) \(PdfNum.f(r.x)) \(PdfNum.f(r.y)) \(PdfNum.f(r.width)) \(PdfNum.f(r.height)) \(PdfNum.f(w.angle)) "
                + hex(w.text.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
        }
        ops += "q BT 3 Tr 0 Tc 0 Tw 0 Ts\n"
        let em = Double(GlyphlessFont.advance) / 1000
        let ascent = Double(GlyphlessFont.ascent) / 1000, descent = Double(GlyphlessFont.descent) / 1000
        for (i, w) in words.enumerated() {
            let codes = layer.codes(w.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if codes.isEmpty { continue }
            let size = w.rect.height / (ascent - descent)
            let baseline = w.rect.bottom + descent * size
            ops += place(frame, w, w.rect.x, baseline, w.rect.width / (Double(codes.count) * em * size))
            ops += "/\(name) \(PdfNum.f(size)) Tf <\(codes.map(GlyphlessFont.hex4).joined())> Tj\n"

            // An explicit space, stretched over the gap, to the next word on the same line (not across columns), measured
            // along the line: the next word's box as seen from this word's turned frame.
            guard i + 1 < words.count, abs(words[i + 1].angle - w.angle) < 1 else { continue }
            let next = inFrameOf(w, words[i + 1])
            let overlap = min(w.rect.bottom, next.bottom) - max(w.rect.y, next.y)
            let gap = next.x - w.rect.right
            if overlap > 0.5 * min(w.rect.height, next.height) && gap > 0.01 && gap < 2 * max(w.rect.height, next.height) {
                ops += place(frame, w, w.rect.right, baseline, gap / (em * size))
                ops += "<\(GlyphlessFont.hex4(layer.code(" ")))> Tj\n"
            }
        }
        ops += "ET Q\n"
        let shared = descendant ?? GlyphlessFont.descendant(doc)
        descendant = shared
        fonts.set(name, GlyphlessFont.font(doc, shared, layer.units))
        let stream = doc.addStream(Array(ops.utf8), deflate: true)

        if let old = existing {
            if let index = old.index, let list = page["Contents"], list.isArray {
                list.replace(at: index, with: stream)
            } else {
                page.set("Contents", stream)
            }
            return
        }
        // The layer goes first, in the page's initial graphics state: whatever the existing content does to the state (a
        // scaling cm left in an unbalanced q, or a stray Q that pops more than it pushed) can't reach it, and as the text
        // is invisible, painting order doesn't matter. The existing content is wrapped in q…Q so what follows it (another
        // tool's additions) starts clean too.
        let contents = doc.array([stream, doc.addStream(Array("q\n".utf8), deflate: false)])
        if let current = page["Contents"] {
            if current.isArray {
                for e in current.elements { contents.append(e) }
            } else if current.isStream {
                contents.append(current)
            }
        }
        contents.append(doc.addStream(Array("\nQ\n".utf8), deflate: false))
        page.set("Contents", contents)
    }

    /// `other`'s box as seen from `w`'s frame (turned back by its angle about its centre).
    private static func inFrameOf(_ w: OcrWord, _ other: OcrWord) -> RectD {
        if w.angle == 0 { return other.rect }
        let (s, c) = (sin(-w.angle * .pi / 180), cos(-w.angle * .pi / 180))
        let (dx, dy) = (other.rect.centerX - w.rect.centerX, other.rect.centerY - w.rect.centerY)
        let (cx, cy) = (w.rect.centerX + dx * c - dy * s, w.rect.centerY + dx * s + dy * c)
        return RectD(cx - other.rect.width / 2, cy - other.rect.height / 2, other.rect.width, other.rect.height)
    }

    /// Sets the text matrix so text runs along word `w` (left to right in its own frame, turned by its angle about its
    /// centre) from (`x`, `baseline`) of that frame, whatever the page's /Rotate, stretched by `scale`.
    private static func place(_ frame: PageFrame, _ w: OcrWord, _ x: Double, _ baseline: Double, _ scale: Double) -> String {
        let (s, c) = (sin(w.angle * .pi / 180), cos(w.angle * .pi / 180))
        let (dx, dy) = (x - w.rect.centerX, baseline - w.rect.centerY)
        let (px, py) = (w.rect.centerX + dx * c - dy * s, w.rect.centerY + dx * s + dy * c)
        let o = frame.toPdf(px, py)
        let u = frame.toPdf(px + c, py + s) // along the line
        let v = frame.toPdf(px + s, py - c) // up
        let tz = scale.isFinite && scale > 0 ? scale * 100 : 100
        let m = [u.x - o.x, u.y - o.y, v.x - o.x, v.y - o.y, o.x, o.y].map(PdfNum.f).joined(separator: " ")
        return "\(PdfNum.f(tz)) Tz \(m) Tm "
    }

    /// One page's codes: code n (from 1) stands for `units[n - 1]`, one Unicode scalar.
    private final class Layer {
        var units: [String] = []
        private var byUnit: [String: Int] = [:]

        func code(_ unit: String) -> Int {
            if let hit = byUnit[unit] { return hit }
            units.append(unit)
            byUnit[unit] = units.count
            return units.count
        }

        /// The word's codes left to right: right-to-left runs reversed (the bidi algorithm's rule L2), so MuPDF and other
        /// readers, which read text in logical order from where it sits, get the word back as recognized.
        func codes(_ word: String) -> [Int] {
            let scalars = Array(word.unicodeScalars)
            if scalars.isEmpty { return [] }
            let unitLevels = Bidi.levels(word).levels
            var levels: [UInt8] = []
            var at = 0
            for s in scalars {
                levels.append(at < unitLevels.count ? unitLevels[at] : 0)
                at += s.utf16.count
            }
            var order = Array(scalars.indices)
            let highest: UInt8 = levels.max() ?? 0
            let odd: [UInt8] = levels.filter { $0 % 2 == 1 }
            let lowestOdd: UInt8 = odd.min() ?? (highest &+ 1)
            var level = highest
            while level >= lowestOdd && level > 0 {
                var i = 0
                while i < order.count {
                    guard levels[order[i]] >= level else {
                        i += 1
                        continue
                    }
                    var j = i
                    while j < order.count && levels[order[j]] >= level { j += 1 }
                    order[i..<j].reverse()
                    i = j
                }
                level -= 1
            }
            return order.map { code(String(scalars[$0])) }
        }
    }
}
