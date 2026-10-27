import Foundation

/// A recognized word and its box in page space (points, top-left origin of the displayed, rotated and cropped page).
public struct OcrWord: Equatable, Sendable {
    public var text: String
    public var rect: RectD

    public init(_ text: String, _ rect: RectD) {
        self.text = text
        self.rect = rect
    }
}

/// Invisible text over scanned pages (an OCR text layer, the Windows app's `TextLayer`): the page looks the same, but its
/// words can be selected, copied and searched. Each word is written with text render mode 3 (no paint), stretched
/// horizontally to its box, in a content stream of its own placed before the page's content (so the existing content's
/// graphics state, balanced or not, can't leak into it). Windows embeds a subset of Arial (CIDFontType2, shaped by
/// HarfBuzz); the Mac embeds `GlyphlessFont`, whose glyphs draw nothing, with a /ToUnicode per page that returns the
/// words as recognized: one code per Unicode scalar, right-to-left runs written in visual order as Windows writes them.
public enum TextLayer {
    /// - Parameter wordsByPage: words per page index, in reading order.
    /// - Returns: the same bytes when no page has a usable word.
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func addInvisibleText(_ data: [UInt8], _ password: String?, _ wordsByPage: [Int: [OcrWord]]) throws -> [UInt8] {
        func usable(_ w: OcrWord) -> Bool {
            !w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !w.rect.isEmpty && w.rect.width.isFinite && w.rect.height.isFinite
                && w.rect.x.isFinite && w.rect.y.isFinite
        }
        let pages = wordsByPage.filter { $0.value.contains(where: usable) }.sorted { $0.key < $1.key }
        if pages.isEmpty { return data }

        return try PageEditor.edit(data, password) { doc in
            let count = try doc.pageCount()
            var descendant: PObj?
            for (index, all) in pages {
                guard index >= 0 && index < count else { throw PdfEditError("There is no page \(index + 1).") }
                let page = doc.page(index)
                let frame = PageBoxes.frame(page)
                let words = all.filter(usable)
                let resources = ContentEditor.ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
                let fonts = ContentEditor.ownDict(doc, resources, "Font")
                var name = "PdOcr"
                var n = 1
                while fonts.keys.contains(where: { $0.hasPrefix(name) }) {
                    name = "PdOcr\(n)_"
                    n += 1
                }
                name += "0"
                let layer = Layer()
                var ops = "q BT 3 Tr 0 Tc 0 Tw 0 Ts\n"
                let em = Double(GlyphlessFont.advance) / 1000
                let ascent = Double(GlyphlessFont.ascent) / 1000, descent = Double(GlyphlessFont.descent) / 1000
                for (i, w) in words.enumerated() {
                    let codes = layer.codes(w.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if codes.isEmpty { continue }
                    let size = w.rect.height / (ascent - descent)
                    let baseline = w.rect.bottom + descent * size
                    ops += place(frame, w.rect.x, baseline, w.rect.width / (Double(codes.count) * em * size))
                    ops += "/\(name) \(PdfNum.f(size)) Tf <\(codes.map(GlyphlessFont.hex4).joined())> Tj\n"

                    // An explicit space, stretched over the gap, to the next word on the same line (not across columns).
                    guard i + 1 < words.count else { continue }
                    let next = words[i + 1].rect
                    let overlap = min(w.rect.bottom, next.bottom) - max(w.rect.y, next.y)
                    let gap = next.x - w.rect.right
                    if overlap > 0.5 * min(w.rect.height, next.height) && gap > 0.01 && gap < 2 * max(w.rect.height, next.height) {
                        ops += place(frame, w.rect.right, baseline, gap / (em * size))
                        ops += "<\(GlyphlessFont.hex4(layer.code(" ")))> Tj\n"
                    }
                }
                ops += "ET Q\n"
                let shared = descendant ?? GlyphlessFont.descendant(doc)
                descendant = shared
                fonts.set(name, GlyphlessFont.font(doc, shared, layer.units))

                // The layer goes first, in the page's initial graphics state: whatever the existing content does to the
                // state (a scaling cm left in an unbalanced q, or a stray Q that pops more than it pushed) can't reach it,
                // and as the text is invisible, painting order doesn't matter. The existing content is wrapped in q…Q so
                // what follows it (another tool's additions) starts clean too.
                let contents = doc.array([doc.addStream(Array(ops.utf8), deflate: true), doc.addStream(Array("q\n".utf8), deflate: false)])
                if let existing = page["Contents"] {
                    if existing.isArray {
                        for e in existing.elements { contents.append(e) }
                    } else if existing.isStream {
                        contents.append(existing)
                    }
                }
                contents.append(doc.addStream(Array("\nQ\n".utf8), deflate: false))
                page.set("Contents", contents)
            }
        }
    }

    /// Whether MuPDF finds any text on the page (a page that already has text needs no OCR).
    public static func hasText(_ engine: PdfEngine, _ page: Int, cancel: CancelToken? = nil) throws -> Bool {
        try engine.text(page, cancel: cancel).text.contains { !$0.isWhitespace }
    }

    /// Sets the text matrix so text runs left to right along the displayed page from (`x`, `baseline`) in page space,
    /// whatever the page's /Rotate, stretched by `scale`.
    private static func place(_ frame: PageFrame, _ x: Double, _ baseline: Double, _ scale: Double) -> String {
        let o = frame.toPdf(x, baseline)
        let u = frame.toPdf(x + 1, baseline)
        let v = frame.toPdf(x, baseline - 1)
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
            let highest = levels.max() ?? 0
            let lowestOdd = levels.filter { $0 % 2 == 1 }.min() ?? highest + 1
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
