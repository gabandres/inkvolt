import Foundation
import PrintCore

/// A piece of text as a page's content draws it: one text-showing operator (Tj, TJ, ' or ") of the page's own content,
/// which is usually a line or a word. Page space (points, top-left origin of the page as shown).
public struct TextRun: Sendable {
    public let pageIndex: Int
    /// The operator's place in the page's content (with `text`, how an edit finds it again; negative inside a form XObject).
    public let id: Int
    public let text: String
    /// Where it shows (the bounding box when it is turned).
    public internal(set) var box: RectD
    /// Its size on the page, in points.
    public let fontSize: Double
    public let fontName: String
    public let bold: Bool
    public let italic: Bool
    /// Its fill color (0xRRGGBB) when it is a plain gray, RGB or CMYK color, else black.
    public let color: Int
    /// The direction of its baseline on the page, degrees clockwise from left-to-right.
    public internal(set) var angle: Double
    /// Why it can't be edited, as the end of a sentence ("it is …"); nil when it can.
    public internal(set) var blocked: String?
    /// The run's width as drawn (points along the baseline, to the end of its last glyph).
    public let oldWidth: Double

    var font: TextFont?
    /// Its place among the page's runs as the walk found them: unique, where `id` isn't (an operator drawing columns is a
    /// run for each in a translated copy, see `ContentEditor.RunInfo.columns`).
    var key = 0
    /// Page points per text-space unit along the baseline.
    let scale: Double
    var size = 0.0, charSpacing = 0.0, wordSpacing = 0.0, hScale = 1.0
    var gapEms = 0.25
    var info: ContentEditor.RunInfo?
    /// The name its font has in the resources (no slash).
    var fontKey = ""
    /// Inside the marked content a paragraph edit puts around text it gave a look of its own (see `TextLook`); else nil.
    var tag: ContentEditor.LookTag?
    /// Where its baseline starts on the page (page space, the text rise included).
    var origin = PointD(0, 0)
    /// How far its glyphs reach from `origin` in its own direction (points); nil when its text is mirrored or slanted, so
    /// that it has no upright box.
    var reach: Reach?

    struct Reach: Sendable {
        var back: Double, along: Double, above: Double, below: Double
    }

    /// Drawn in a font a paragraph edit added for characters the paragraph's own font lacks (see `StandInFonts`).
    var standIn: Bool { fontKey.hasPrefix(ContentEditor.standInKey) }

    /// Part of a paragraph an edit gave its own font, size or color.
    var styled: Bool { tag != nil }

    /// The width `text` would take written into this run (points), the characters the font lacks that a stand-in font
    /// draws, and the characters no font here can draw.
    public func check(_ text: String) -> TextCheck {
        guard font != nil, let info else { return TextCheck(width: oldWidth, oldWidth: oldWidth, missing: []) }
        let plan = ContentEditor.plan(info, self, ContentEditor.oneLine(text))
        return TextCheck(width: width(plan.parts) * scale, oldWidth: oldWidth, missing: plan.missing, borrowed: plan.borrowed,
                         standIns: plan.standIns)
    }

    /// To the end of the last glyph's ink, in text space (as `oldWidth` measures the run).
    func width(_ parts: [ContentEditor.Part]) -> Double { measure(parts).end }

    /// How far parts advance and where their last glyph's ink ends (text space), and whether they have any ink.
    func measure(_ parts: [ContentEditor.Part]) -> (advance: Double, end: Double, inked: Bool) {
        guard let font else { return (0, 0, false) }
        var w = 0.0, end = 0.0
        var inked = false
        for p in parts {
            let size: Double = self.size * (p.look?.scale ?? 1) // a part of another size is written at its own font size
            if let s = p.standIn {
                // Drawn in a stand-in font, with no character spacing (see ContentEditor.writeLine).
                w += s.width * size * hScale
                end = w
                inked = true
                continue
            }
            guard let c = p.code else {
                w -= p.number / 1000 * size * hScale
                continue
            }
            let f = p.look?.page?.font ?? font // a stretch in another face of the page's family is measured in it
            let glyph: Double = f.widthOf(c) / 1000 * size * hScale
            end = w + glyph
            inked = true
            let spacing: Double = charSpacing + (!f.twoByte && c == 32 ? wordSpacing : 0)
            w += glyph + spacing * hScale
        }
        return (w, end, inked)
    }
}

/// What new text would look like: its width and the run's (points), and characters no font here has a glyph for.
public struct TextCheck: Sendable, Equatable {
    public var width: Double
    public var oldWidth: Double
    public var missing: [String]
    /// Characters the run's own font lacks, drawn from installed fonts (`standIns`).
    public var borrowed: [String] = []
    /// The installed fonts they come from ("Arial Bold"), closest first.
    public var standIns: [String] = []
}

/// A picture the page draws: an image XObject (Do) or an inline image (BI … EI). Page space.
public struct PageImage: Sendable, Equatable {
    public let pageIndex: Int
    /// The operator's place in the page's content.
    public let id: Int
    /// Where it shows (the bounding box when it is turned).
    public internal(set) var box: RectD
    public let inline: Bool
    /// Why it can't be edited ("it is …"); nil when it can.
    public let blocked: String?
    /// Turned by other than a quarter turn, or skewed: resizing scales its bounding box.
    public var turned = false
}

/// The text runs and pictures of a page, for Edit Text & Images.
public struct PageContent: Sendable {
    public var runs: [TextRun]
    public var images: [PageImage]
    /// The page's text runs grouped into paragraphs (see `ContentEditor.groupParagraphs`), turned text in its own direction.
    public var paragraphs: [TextParagraph] = []

    public init(runs: [TextRun], images: [PageImage]) {
        self.runs = runs
        self.images = images
    }

    public static let empty = PageContent(runs: [], images: [])

    /// The paragraph a run belongs to, or nil (only spaces).
    public func paragraphOf(_ run: TextRun) -> TextParagraph? { paragraphs.first { $0.runs.contains { $0.id == run.id } } }

    /// The paragraph under a point: the one holding the run there, else (between lines) one of several lines whose box
    /// holds the point and that can be edited as one (a blocked one's lines are edited one by one, so there is nothing
    /// between them).
    public func paragraphAt(_ x: Double, _ y: Double, slop: Double = 1) -> TextParagraph? {
        if let run = runAt(x, y, slop: slop) { return paragraphOf(run) }
        return paragraphs.first { $0.lines.count > 1 && $0.blocked == nil && ContentEditor.holds($0, x, y) }
    }

    /// The text run under a point (the smallest when several overlap), or nil.
    public func runAt(_ x: Double, _ y: Double, slop: Double = 1) -> TextRun? {
        runs.filter { $0.box.inflate(slop).contains(x, y) }.min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    /// The topmost picture under a point, or nil.
    public func imageAt(_ x: Double, _ y: Double) -> PageImage? { images.last { $0.box.contains(x, y) } }
}

/// An edit of existing content that can't be made (the message says why, as a sentence for the user; the Windows app's
/// `ContentEditException`).
public struct ContentEditError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// Characters the font has no glyph for (empty for other reasons).
    public var missing: [String]
    /// A paragraph's new text would run into this (what follows below it, page space); nil for other reasons.
    public var overlaps: RectD?

    public init(_ message: String, missing: [String] = [], overlaps: RectD? = nil) {
        self.message = message
        self.missing = missing
        self.overlaps = overlaps
    }

    public var description: String { message }
}

/// Edit Text & Images (the Windows app's `ContentEditor`): replaces the text of one text-showing operator in its own
/// font (characters it lacks drawn from the closest installed font, `StandInFonts`), rewrites a paragraph
/// (`replaceParagraph`, roadmap 2.1, ContentEditor+Paragraphs), and moves, resizes, replaces or deletes one picture by
/// rewriting its placement. Works on the page's own content (all its content streams, read as one) and on text inside
/// form XObjects (ContentEditor+Forms); pictures inside them are listed but not edited. Each edit is bytes in → bytes
/// out, saved through `PdfEdit.save` (signed files appended to, protection kept).
public enum ContentEditor {
    static let maxDepth = 8

    /// The most form XObject content walked for one page, counting each drawing (and a little for each, however small).
    static let maxFormBytes = 64 << 20

    /// The start of the names stand-in fonts get in a page's resources (characters a paragraph's font lacked).
    static let standInKey = "InkFb"

    /// The page's text runs, pictures and paragraphs.
    /// - Throws: `PdfEngineError` for a page past the end; `PdfEditError`, `PasswordRequired` when the file can't be read.
    public static func read(_ data: [UInt8], _ password: String?, _ pageIndex: Int, cancel: CancelToken? = nil) throws -> PageContent {
        let doc = try PdfEdit.openToRead(data, password)
        let count = try doc.pageCount()
        guard pageIndex >= 0 && pageIndex < count else {
            throw PdfEngineError(message: loc("Page {0} isn't in this document.", CoreLanguage.number(pageIndex + 1)))
        }
        let page = doc.page(pageIndex)
        let walked = try walk(doc, page, pageIndex, ContentLexer.parse(streams(page).bytes, cancel: cancel), cancel)
        return withParagraphs(walked.content)
    }

    /// Several pages' text runs, pictures and paragraphs (a page that can't be read comes back empty).
    public static func read(_ data: [UInt8], _ password: String?, pages: [Int], cancel: CancelToken? = nil) throws -> [Int: PageContent] {
        let doc = try PdfEdit.openToRead(data, password)
        let count = try doc.pageCount()
        var result: [Int: PageContent] = [:]
        for p in pages where p >= 0 && p < count {
            let page = doc.page(p)
            do {
                let walked = try walk(doc, page, p, ContentLexer.parse(streams(page).bytes, cancel: cancel), cancel)
                result[p] = withParagraphs(walked.content)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result[p] = .empty // a damaged page: nothing to edit on it
            }
        }
        return result
    }

    // ---- Text ----

    /// Replaces a run's text, written in the run's own font (characters it lacks in the closest installed font).
    /// - Throws: `ContentEditError` when no font can draw the text (the message names the missing characters), the run
    ///   can't be edited, or the page changed.
    public static func replaceText(_ data: [UInt8], _ password: String?, _ run: TextRun, _ newText: String) throws -> [UInt8] {
        let text = oneLine(newText)
        if Array(text.utf16) == Array(run.text.utf16) { return data }
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        let page = try pageOf(doc, run.pageIndex)
        let content = streams(page)
        let ops = ContentLexer.parse(content.bytes)
        let walked = try walk(doc, page, run.pageIndex, ops, nil)
        // The run where it was; else (an earlier edit moved the page's operators) the same text in the same place.
        let now = walked.textRuns.first { $0.id == run.id && same($0.text, run.text) }
            ?? walked.textRuns.filter { same($0.text, run.text) && near($0.box, run.box) }
            .min { distance($0.box, run.box) < distance($1.box, run.box) }
        if let why = now?.blocked { throw ContentEditError(loc("This text can't be edited: {0}.", why)) }
        guard let now, let info = walked.runs[now.id], let font = now.font, let fontDict = walked.fontDicts[ObjectIdentifier(font)] else {
            throw ContentEditError(loc("The page changed since this text was picked. Pick it again."))
        }

        let planned = plan(info, now, text)
        if !planned.missing.isEmpty { throw missingGlyphs(font, planned.missing) }
        // The font first: copying a shared form for this page (targetOf) may give the page resources of its own.
        font.prepare(doc, fontDict, planned.codes, planned.ownText)
        let target = try targetOf(doc, page, content, ops, walked, now)
        let op = target.opOf(now, walked)
        let replacement: String
        if planned.standIns.isEmpty {
            replacement = writeShow(op, info, font, planned.parts)
        } else {
            // Characters the font lacks: drawn in stand-in fonts, embedded as Type 3 fonts (as a paragraph edit does).
            let writer = Type3FontWriter(namePrefix: standInPrefix(target), standIn: true)
            var sb = ""
            if op.name == "'" {
                sb += "T* "
            } else if op.name == "\"" {
                sb += "\(ContentLexer.number(op.n(0))) Tw \(ContentLexer.number(op.n(1))) Tc T* "
            }
            writeLine(&sb, info.hex, now, planned.parts, now, writer, wordSpacing: now.wordSpacing)
            replacement = sb
            addFonts(doc, target.resourceOwner, writer.buildFonts(doc))
        }
        try writeTarget(doc, page, target, [(op.start, op.end, latin1Bytes(replacement))])
        SignedEdits.noteRemoval() // the old text stays in a signed file's earlier revision
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    static func distance(_ a: RectD, _ b: RectD) -> Double { abs(a.x - b.x) + abs(a.y - b.y) }

    /// A glyph code, or (with no code) a TJ adjustment, of rewritten text; or characters drawn in a stand-in font
    /// (`standIn`); with the look its stretch was given (`look`, nil: the paragraph's own).
    struct Part {
        var code: Int?
        var number: Double
        var standIn: ShapedLine?
        var look: PartLook?

        init(_ code: Int?, _ number: Double, _ standIn: ShapedLine? = nil, _ look: PartLook? = nil) {
            self.code = code
            self.number = number
            self.standIn = standIn
            self.look = look
        }
    }

    /// A run's new text as it will be written: its parts; the codes of its own font and the text they stand for (for
    /// `TextFont.prepare`); characters no font here has; characters the run's font lacks that stand-in fonts draw, and
    /// those fonts' names.
    struct RunPlan {
        var parts: [Part]
        var codes: [Int]
        var ownText: String
        var missing: [String]
        var borrowed: [String]
        var standIns: [String]
    }

    /// How a run's new text is written: what didn't change is kept (with its kerning), the changed middle is encoded in
    /// the run's font with the run's own kerning pairs, characters the font lacks drawn in stand-in fonts
    /// (`StandInFonts`). Adjustments touching the change go with it, except the one before the first glyph (where the
    /// run starts) and any after the last.
    static func plan(_ info: RunInfo, _ run: TextRun, _ text: String) -> RunPlan {
        let items = info.items
        let t = Array(text.utf16)
        var pre = 0, preLen = 0
        while pre < items.count && t[preLen...].starts(with: items[pre].units) {
            preLen += items[pre].units.count
            pre += 1
        }
        while pre > 0 && items[pre - 1].isNumber && items[pre - 1].units.isEmpty { pre -= 1 }
        var lead = 0
        while lead < items.count && items[lead].isNumber { lead += 1 }
        pre = max(pre, lead)
        preLen = items.prefix(pre).reduce(0) { $0 + $1.units.count }
        var suf = 0, sufLen = 0
        while suf < items.count - pre {
            let t1 = items[items.count - 1 - suf].units
            guard preLen + sufLen + t1.count <= t.count, t[..<(t.count - sufLen)].reversed().starts(with: t1.reversed()) else { break }
            sufLen += t1.count
            suf += 1
        }
        while suf > 0 {
            let last = items[items.count - suf]
            guard last.isNumber && last.units.isEmpty && !last.trailing else { break }
            suf -= 1
        }
        sufLen = items.suffix(suf).reduce(0) { $0 + $1.units.count }
        let lo = min(preLen, t.count)
        let middle = String(decoding: t[lo..<max(lo, t.count - sufLen)], as: UTF16.self)

        let font = run.font!
        var parts: [Part] = []
        for it in items.prefix(pre) { parts.append(Part(it.isNumber ? nil : it.code, it.number)) }
        let enc = font.encode(middle)
        var codes = enc.codes
        var ownText = middle
        var missing = enc.missing
        var borrowed: [String] = [], names: [String] = []
        let pairs = kerning([info]) // the run's own pairs, kept where they survive in the new text
        if enc.missing.isEmpty {
            parts += partsOf(run, enc.codes, pairs)
        } else {
            // Characters the font lacks: each stretch of them drawn in the closest installed font that has them.
            var lacking: [String] = []
            for el in middle.map(String.init) where !isBlank(el) && !font.encode(el).missing.isEmpty && !lacking.contains(el) {
                lacking.append(el)
            }
            var cps: [UInt32] = []
            for cp in lacking.flatMap(TrueTypeFont.codePoints) where !cps.contains(cp) { cps.append(cp) }
            let standIns = StandInFonts.forFont(font, cps)
            var left: [String] = []
            for el in lacking {
                let points = TrueTypeFont.codePoints(el)
                if points.allSatisfy({ standIns[$0] != nil }), let face = standIns[StandInFonts.key(el)], StandInFonts.drawable(el, face.font) {
                    borrowed.append(el)
                    for cp in points where !StandInFonts.inkless(cp) && !names.contains(standIns[cp]!.name) { names.append(standIns[cp]!.name) }
                } else {
                    left.append(el)
                }
            }
            missing = left
            var own: [Int] = []
            var ownSb = ""
            var chunk = ""
            var cur: StandInFont?
            func flush() {
                if chunk.isEmpty { return }
                if let cur {
                    parts.append(Part(nil, 0, StandInFonts.shape(chunk, cur.font)))
                } else {
                    let e = font.encode(chunk)
                    own += e.codes
                    ownSb += chunk
                    parts += partsOf(run, e.codes, pairs)
                }
                chunk = ""
            }
            for el in middle.map(String.init) {
                let face = borrowed.contains(el) ? standIns[StandInFonts.key(el)] : nil
                if face !== cur { flush() }
                cur = face
                chunk += el
            }
            flush()
            codes = own
            ownText = ownSb
        }
        for it in items.suffix(suf) { parts.append(Part(it.isNumber ? nil : it.code, it.number)) }
        return RunPlan(parts: parts, codes: codes, ownText: ownText, missing: missing, borrowed: borrowed, standIns: names)
    }

    /// Only white space (a text element of it).
    static func isBlank(_ s: String) -> Bool { s.unicodeScalars.allSatisfy(\.properties.isWhitespace) }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// A character named for the user: “x”, or U+XXXX for one that doesn't show (a control, private use, unassigned).
    static func shownCharacter(_ c: String) -> String {
        if c == " " { return loc("space") }
        if let u = c.unicodeScalars.first {
            switch u.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned: return String(format: "U+%04X", u.value)
            default: break
            }
        }
        return "“\(c)”"
    }

    private static func missingGlyphs(_ font: TextFont, _ missing: [String]) -> ContentEditError {
        let shown = missing.prefix(12).map(shownCharacter).joined(separator: ", ")
        let list = missing.count > 12 ? loc("{0} and {1} more", shown, CoreLanguage.number(missing.count - 12)) : shown
        let message: String
        if font.name.isEmpty {
            message = missing.count == 1
                ? loc("Neither this text's font nor any font on this Mac has {0}, so it can't be written. Leave it out, or add a text box instead.", list)
                : loc("Neither this text's font nor any font on this Mac has {0}, so it can't be written. Leave them out, or add a text box instead.", list)
        } else {
            message = missing.count == 1
                ? loc("Neither the font “{0}” nor any font on this Mac has {1}, so it can't be written. Leave it out, or add a text box instead.", font.name, list)
                : loc("Neither the font “{0}” nor any font on this Mac has {1}, so it can't be written. Leave them out, or add a text box instead.", font.name, list)
        }
        return ContentEditError(message, missing: missing)
    }

    /// The text-showing operator rewritten with new parts (strings of codes and TJ adjustments).
    static func writeShow(_ op: COp, _ info: RunInfo, _ font: TextFont, _ parts: [Part]) -> String {
        var tokens: [String] = []
        var codes: [Int] = []
        func flush() {
            if codes.isEmpty { return }
            let bytes = font.toBytes(codes)
            tokens.append(info.hex ? ContentLexer.hexString(bytes) : ContentLexer.literal(bytes))
            codes.removeAll()
        }
        for p in parts {
            if let code = p.code {
                codes.append(code)
            } else if abs(p.number) > 1e-9 {
                flush()
                tokens.append(ContentLexer.number(p.number))
            }
        }
        flush()
        let plain = tokens.count <= 1 && !parts.contains { $0.code == nil && abs($0.number) > 1e-9 }
        let str = tokens.count == 1 ? tokens[0] : info.hex ? "<>" : "()"
        let array = "[" + tokens.joined(separator: " ") + "]"
        switch op.name {
        case "Tj": return plain ? "\(str) Tj" : "\(array) TJ"
        case "'": return plain ? "\(str) '" : "T* \(array) TJ"
        case "\"":
            let tw = ContentLexer.number(op.n(0)), tc = ContentLexer.number(op.n(1))
            return plain ? "\(tw) \(tc) \(str) \"" : "\(tw) Tw \(tc) Tc T* \(array) TJ"
        default: return "\(array) TJ"
        }
    }

    // ---- Pictures ----

    /// An edit of content: the byte ranges to replace, and with what.
    typealias Edits = [(start: Int, end: Int, bytes: [UInt8])]

    /// Moves and/or resizes a picture so its bounding box becomes `box` (page space).
    public static func moveImage(_ data: [UInt8], _ password: String?, _ image: PageImage, _ box: RectD) throws -> [UInt8] {
        if box.width < 1 || box.height < 1 { throw ContentEditError(loc("A picture can't be made that small.")) }
        return try editImage(data, password, image) { _, page, found, op, ctm, ops, content in
            let p2u = pageToUser(PageBoxes.frame(page))
            guard let u2p = p2u.inverted() else { throw ContentEditError(loc("This page's size can't be read.")) }
            let old = found.box
            let sx: Double = box.width / old.width, sy: Double = box.height / old.height
            let d = Mat(sx, 0, 0, sy, box.x - old.x * sx, box.y - old.y * sy)
            let dUser = u2p.times(d).times(p2u)
            guard let inv = ctm.inverted() else { throw ContentEditError(loc("This picture is drawn squashed flat, so it can't be moved.")) }
            let m = ctm.times(dUser).times(inv) // inserted before the Do, the image lands on CTM × D
            let at = ops.firstIndex(where: { $0 === op })!
            // "q a b c d e f cm /Im Do Q": change that cm; otherwise wrap the Do.
            if at >= 2 && at + 1 < ops.count && ops[at - 2].name == "q" && ops[at - 1].name == "cm" && ops[at - 1].operands.count == 6
                && ops[at + 1].name == "Q" {
                let cm = ops[at - 1]
                let c = Mat(cm.n(0), cm.n(1), cm.n(2), cm.n(3), cm.n(4), cm.n(5))
                return [(cm.start, cm.end, latin1Bytes(m.times(c).write() + " cm"))]
            }
            return [(op.start, op.end, latin1Bytes("q \(m.write()) cm ") + slice(op, content) + latin1Bytes(" Q"))]
        }
    }

    /// Removes a picture from the page.
    public static func deleteImage(_ data: [UInt8], _ password: String?, _ image: PageImage) throws -> [UInt8] {
        try editImage(data, password, image, dropName: true) { _, _, _, op, _, ops, _ in
            SignedEdits.noteRemoval()
            let at = ops.firstIndex(where: { $0 === op })!
            if at >= 2 && at + 1 < ops.count && ops[at - 2].name == "q" && ops[at - 1].name == "cm" && ops[at + 1].name == "Q" {
                return [(ops[at - 2].start, ops[at + 1].end, [32])]
            }
            return [(op.start, op.end, [32])]
        }
    }

    /// Puts another picture (an image file) in a picture's place, upright and fitted in its box with its own proportions.
    /// - Throws: `PdfEditError` when the file isn't an image that can be read.
    public static func replaceImage(_ data: [UInt8], _ password: String?, _ image: PageImage, _ file: [UInt8], _ fileName: String) throws -> [UInt8] {
        try editImage(data, password, image, dropName: true) { doc, page, found, op, ctm, _, _ in
            let stored = try ImageImport.storeImage(doc, file, fileName)
            let name = addXObject(doc, page, stored.image)
            var dw = Double(stored.width) / stored.dpiX, dh = Double(stored.height) / stored.dpiY
            if (5...8).contains(stored.orientation) { (dw, dh) = (dh, dw) }
            let b = found.box
            var fw = b.width, fh = b.height
            if dw / dh > b.width / b.height { fh = b.width * dh / dw } else { fw = b.height * dw / dh }
            let x: Double = b.x + (b.width - fw) / 2, y: Double = b.y + (b.height - fh) / 2
            // Placement works y-up: place in "page space flipped" (Y' = -Y), then back to page space and on to user space.
            let place = ImageImport.placement(stored.orientation, x, -(y + fh), fw, fh)
            let total = Mat(place[0], place[1], place[2], place[3], place[4], place[5]).times(Mat(1, 0, 0, -1, 0, 0))
                .times(pageToUser(PageBoxes.frame(page)))
            let m = total.times(ctm.inverted() ?? .identity)
            SignedEdits.noteRemoval()
            return [(op.start, op.end, latin1Bytes("q \(m.write()) cm /\(name) Do Q"))]
        }
    }

    private static func editImage(_ data: [UInt8], _ password: String?, _ image: PageImage, dropName: Bool = false,
                                  _ edit: (MuDoc, PObj, PageImage, COp, Mat, [COp], [UInt8]) throws -> Edits) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        let page = try pageOf(doc, image.pageIndex)
        let content = streams(page)
        let ops = ContentLexer.parse(content.bytes)
        let walked = try walk(doc, page, image.pageIndex, ops, nil)
        let now = walked.images.first { $0.id == image.id && near($0.box, image.box) } ?? walked.images.last { near($0.box, image.box) }
        if let why = now?.blocked { throw ContentEditError(loc("This picture can't be edited: {0}.", why)) }
        guard let now, let ctm = walked.imageCtm[now.id] else {
            throw ContentEditError(loc("The page changed since this picture was picked. Pick it again."))
        }
        let op = ops[now.id]
        let oldName = op.name == "Do" ? op.operands[0].name : nil
        let edits = try edit(doc, page, now, op, ctm, ops, content.bytes)
        let updated = try writeContent(doc, page, content, ops, edits)
        // A picture no longer drawn anywhere on the page leaves the page's resources (when they are the page's own and no
        // form XObject that borrows the page's resources draws it).
        if dropName, let oldName, !draws(ContentLexer.parse(updated), oldName), let res = page["Resources"], !res.isRef, res.isDict,
           let xo = res["XObject"], !xo.isRef, xo.isDict, !usedByInheritingForm(xo, oldName) {
            xo.remove(oldName)
        }
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    private static func draws(_ ops: [COp], _ name: String) -> Bool {
        ops.contains { $0.name == "Do" && !$0.operands.isEmpty && $0.operands[0].name == name }
    }

    /// Whether a form XObject without resources of its own (so it uses the page's) draws `name`, at any depth.
    private static func usedByInheritingForm(_ xobjects: PObj, _ name: String) -> Bool {
        var seen = Set<ObjId>()
        func visit(_ xo: PObj?, _ depth: Int) -> Bool {
            guard let xo, depth <= maxDepth else { return false }
            for key in xo.keys {
                guard let form = xo.dict(key), form.name("Subtype") == "Form", seen.insert(form.id).inserted else { continue }
                let own = form.dict("Resources")
                if own == nil && draws(ContentLexer.parse(form.streamData ?? []), name) { return true }
                if visit(own?.dict("XObject"), depth + 1) { return true }
            }
            return false
        }
        return visit(xobjects, 0)
    }

    static func near(_ a: RectD, _ b: RectD) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// A dictionary entry the page may change: its own (direct) one, or a copy of a shared one put in its place.
    static func ownDict(_ doc: MuDoc, _ parent: PObj, _ key: String, _ inherited: PObj? = nil) -> PObj {
        let current = parent[key] ?? inherited
        if let current, current.isDict, !current.isRef, parent[key] != nil { return current }
        let copy = doc.dict()
        if let current, current.isDict {
            for k in current.keys { if let v = current[k] { copy.set(k, ownCopy(doc, v)) } }
        }
        parent.set(key, copy)
        return parent[key] ?? copy
    }

    /// A direct dictionary or array copied all the way down (references stay references). A direct object must have one
    /// parent: shared by a copied /Resources and its original (a /Font dictionary inside resources several pages refer
    /// to), it would be renumbered once through each when MuPDF compacts the file, and its fonts would point at other
    /// objects.
    static func ownCopy(_ doc: MuDoc, _ obj: PObj, _ depth: Int = 0) -> PObj {
        if obj.isRef || depth > 32 { return obj }
        if obj.isDict {
            let d = doc.dict()
            for k in obj.keys { if let v = obj[k] { d.set(k, ownCopy(doc, v, depth + 1)) } }
            return d
        }
        if obj.isArray { return doc.array((0..<obj.count).map { i in obj[i].map { ownCopy(doc, $0, depth + 1) } ?? doc.null }) }
        return obj
    }

    /// Adds an XObject to the page's own resources (copying shared ones first), under a fresh name.
    static func addXObject(_ doc: MuDoc, _ page: PObj, _ xobject: PObj, prefix: String = "InkImg") -> String {
        let res = ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
        let xo = ownDict(doc, res, "XObject")
        var n = 1
        while xo.has("\(prefix)\(n)") { n += 1 }
        xo.set("\(prefix)\(n)", xobject)
        return "\(prefix)\(n)"
    }

    // ---- Content ----

    static func pageOf(_ doc: MuDoc, _ index: Int) throws -> PObj {
        let count = try doc.pageCount()
        guard index >= 0 && index < count else { throw ContentEditError(loc("This page is no longer in the document.")) }
        return doc.page(index)
    }

    /// One content stream of a page: where its bytes sit in the page's content read as one, its place in the /Contents
    /// array (-1: the only one).
    struct ContentPart {
        var start: Int, end: Int, slot: Int
        var unreadable: Bool
    }

    /// A page's content streams read as one (they are one content stream split at token boundaries).
    struct PageStreams {
        var bytes: [UInt8]
        var parts: [ContentPart]
    }

    static func contentBytes(_ page: PObj) -> [UInt8] { streams(page).bytes }

    /// The page's content read as one, and whether part of it holds data but decodes to nothing (a damaged filter).
    static func content(_ page: PObj) -> (bytes: [UInt8], unreadable: Bool) {
        let s = streams(page)
        return (s.bytes, s.parts.contains(where: \.unreadable))
    }

    static func streams(_ page: PObj) -> PageStreams {
        var parts: [ContentPart] = []
        var all: [UInt8] = []
        func add(_ s: PObj, _ slot: Int) {
            let bytes = s.streamData ?? [] // a filter that fails on its data
            // A stream that holds data but decodes to nothing (a damaged filter) must not be dropped by a rewrite.
            let unreadable = bytes.isEmpty && !(s.rawStreamData ?? []).isEmpty
            let start = all.count
            all += bytes
            parts.append(ContentPart(start: start, end: all.count, slot: slot, unreadable: unreadable))
            all.append(10)
        }
        if let contents = page["Contents"] {
            if contents.isStream {
                add(contents, -1)
            } else if contents.isArray {
                for (i, part) in contents.elements.enumerated() where part.isStream { add(part, i) }
            }
        }
        return PageStreams(bytes: all, parts: parts)
    }

    /// Writes the page's content with the edits. When every edit falls in one of several content streams and no operator
    /// crosses that stream's edges, only that stream is replaced (the others stay as they are, readable or not); otherwise
    /// the page gets one new stream, which a stream that can't be read would be lost from: refused. Returns the page's
    /// content as now read as one.
    @discardableResult
    static func writeContent(_ doc: MuDoc, _ page: PObj, _ streams: PageStreams, _ ops: [COp], _ edits: Edits) throws -> [UInt8] {
        let updated = try splice(streams.bytes, edits)
        if streams.parts.count > 1, !edits.isEmpty, let old = page["Contents"], old.isArray {
            let lo = edits.map(\.start).min()!, hi = edits.map(\.end).max()!
            if let part = streams.parts.first(where: { lo >= $0.start && hi <= $0.end }),
               !ops.contains(where: { ($0.start < part.start && $0.end > part.start) || ($0.start < part.end && $0.end > part.end) }) {
                let bytes = try splice(Array(streams.bytes[part.start..<part.end]), edits.map { ($0.start - part.start, $0.end - part.start, $0.bytes) })
                let array = doc.array(old.elements) // the page's own: another page may share the old one
                array.replace(at: part.slot, with: doc.addStream(bytes, deflate: true))
                page.set("Contents", array)
                return updated
            }
        }
        if streams.parts.contains(where: \.unreadable) {
            throw ContentEditError(loc("Part of this page's content can't be read (it is damaged), so the page can't be rewritten without losing it."))
        }
        page.set("Contents", doc.addStream(updated, deflate: true))
        return updated
    }

    /// Whether part of the page's content holds data but decodes to nothing (a damaged filter): a rewrite would lose it.
    static func hasUnreadableContent(_ page: PObj) -> Bool { streams(page).parts.contains(where: \.unreadable) }

    /// - Throws: `ContentEditError` when two edits overlap (or one falls outside the content): they can't both be written.
    static func splice(_ content: [UInt8], _ edits: Edits) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(content.count + 256)
        var at = 0
        for e in edits.sorted(by: { $0.start < $1.start }) {
            guard e.start >= at, e.end >= e.start, e.end <= content.count else {
                throw ContentEditError(loc("These changes overlap in the page's content, so they can't be written."))
            }
            out += content[at..<e.start]
            // Keep the replacement apart from its neighbors (a name or number must not run into the next token).
            out.append(32)
            out += e.bytes
            out.append(32)
            at = e.end
        }
        out += content[at...]
        return out
    }

    /// The drawing operator as written: the Do with its name, or the whole inline image (BI … EI, its bytes as they are).
    private static func slice(_ op: COp, _ content: [UInt8]) -> [UInt8] {
        op.name == "Do" ? latin1Bytes("/\(escapeName(op.operands[0].name)) Do") : Array(content[op.start..<op.end])
    }

    static func escapeName(_ name: String) -> String {
        var s = ""
        for u in name.unicodeScalars {
            let c = u.value
            if c > 32 && c < 127 && !"#/()<>[]{}%".unicodeScalars.contains(u) {
                s.unicodeScalars.append(u)
            } else {
                s += String(format: "#%02X", c & 0xFF)
            }
        }
        return s
    }

    /// Page space (top-left origin, as shown) → PDF user space.
    static func pageToUser(_ f: PageFrame) -> Mat {
        let p0 = f.toPdf(0, 0), px = f.toPdf(1, 0), py = f.toPdf(0, 1)
        return Mat(px.x - p0.x, px.y - p0.y, py.x - p0.x, py.y - p0.y, p0.x, p0.y)
    }

    // ---- Walking the content ----

    /// A PDF matrix [a b c d e f]; points are row vectors, so `a.times(b)` applies a first.
    struct Mat: Sendable, Equatable {
        var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

        init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
            (self.a, self.b, self.c, self.d, self.e, self.f) = (a, b, c, d, e, f)
        }

        static let identity = Mat(1, 0, 0, 1, 0, 0)

        func times(_ m: Mat) -> Mat {
            let na: Double = a * m.a + b * m.c, nb: Double = a * m.b + b * m.d
            let nc: Double = c * m.a + d * m.c, nd: Double = c * m.b + d * m.d
            let ne: Double = e * m.a + f * m.c + m.e, nf: Double = e * m.b + f * m.d + m.f
            return Mat(na, nb, nc, nd, ne, nf)
        }

        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let px: Double = a * x + c * y + e, py: Double = b * x + d * y + f
            return (px, py)
        }

        func inverted() -> Mat? {
            let det: Double = a * d - b * c
            if abs(det) < 1e-12 { return nil }
            let ie: Double = (c * f - d * e) / det, i_f: Double = (b * e - a * f) / det
            return Mat(d / det, -b / det, -c / det, a / det, ie, i_f)
        }

        func write() -> String { [a, b, c, d, e, f].map(ContentLexer.number).joined(separator: " ") }
    }

    /// One glyph or TJ adjustment of a run, with the text it stands for (as UTF-16 units); where it starts along the
    /// operator (`at`) and, for a glyph, where its ink ends (`inkEnd`): text space, from where the operator starts.
    struct RunItem: Sendable {
        var code: Int
        var number: Double
        var units: [UInt16]
        var isNumber: Bool
        var trailing = false
        var at = 0.0
        var inkEnd = 0.0
    }

    /// A run as its operator draws it: its glyphs and adjustments; the text matrix where its first glyph starts (`tm`),
    /// the line matrix after the operator (`tlmAfter`), the CTM, the text rise, and how far the operator advances the
    /// text matrix (text space). A paragraph rewrite needs these to keep what follows in place.
    struct RunInfo: Sendable {
        var items: [RunItem]
        var hex: Bool
        var tm = Mat.identity
        var tlmAfter = Mat.identity
        var ctm = Mat.identity
        var rise = 0.0
        var advance = 0.0
        /// The operators that set the fill color in effect (to set it back after text of another color); nil when that
        /// can't be told (a pattern).
        var fillOp: String?
        /// The drawing of a form XObject the run is in (nil: the page's own content); the walk keeps the form itself.
        var form: FormDraw?
        /// The rectangle text drawn where this operator is shows through (see `GState.clip`); nil when there is none known.
        var clip: RectD?
        /// For a translated copy an operator drawing columns is a run for each (`columnStarts`): which one this is (0: the
        /// first, or the whole operator), of how many (1: it is whole), and where along its operator it starts (text
        /// space, as `RunItem.at`): 0 unless it is a column after the first.
        var column = 0
        var columns = 1
        var start = 0.0
    }

    /// Something the page's own content paints, where in it (`id`), and how far it reaches (nil: anywhere it may); a
    /// filled rectangle is `rect`, with its fill color when that is a plain one (`color`).
    struct Paint: Sendable {
        var box: RectD?
        var id: Int
        var rect: Bool
        var color: Int?
    }

    /// The most fills and paints a walk keeps (a crafted page's millions of rectangles aren't each kept).
    static let maxFills = 5_000

    /// One drawing of a form XObject: the form, and the Do that drew it (its id in the enclosing content, unique on the
    /// page). Two drawings of one form are two pieces of content: one operator draws a line in both.
    struct FormDraw: Hashable, Sendable {
        var form: ObjId
        var draw: Int
    }

    /// Where a run inside a form XObject (a drawing the page reuses) sits: the form, its content parsed, the resources
    /// its operators use, the form this one is drawn by (nil: the page), and the Do that draws it (its id in the
    /// enclosing content and the name it uses).
    final class FormPlace {
        let form: PObj
        let bytes: [UInt8]
        let ops: [COp]
        let resources: PObj?
        let outer: FormPlace?
        let doId: Int
        let doName: String

        init(_ form: PObj, _ bytes: [UInt8], _ ops: [COp], _ resources: PObj?, _ outer: FormPlace?, _ doId: Int, _ doName: String) {
            (self.form, self.bytes, self.ops, self.resources, self.outer, self.doId, self.doName) = (form, bytes, ops, resources, outer, doId, doName)
        }

        /// This form and the ones it is drawn through, innermost first.
        var chain: [PObj] {
            var list: [PObj] = []
            var f: FormPlace? = self
            while let p = f {
                list.append(p.form)
                f = p.outer
            }
            return list
        }
    }

    final class Walked {
        var textRuns: [TextRun] = []
        var images: [PageImage] = []
        var runs: [Int: RunInfo] = [:]
        var imageCtm: [Int: Mat] = [:]
        /// Things inside form XObjects get negative ids (they aren't page operators).
        var nested = 0
        var fonts: [ObjId: TextFont] = [:]
        /// Each font's dictionary, for an edit to add widths and ToUnicode entries to.
        var fontDicts: [ObjectIdentifier: PObj] = [:]
        /// How many times each form XObject is drawn on the page (at any depth).
        var formUses: [ObjId: Int] = [:]
        /// Each run inside a form: where (the form, and its operator's index there).
        var formOf: [Int: (place: FormPlace, index: Int)] = [:]
        /// How much more form content may be read for this page: forms drawing forms can multiply without end in a crafted file.
        var formBudget = maxFormBytes
        /// Rectangles the page's own content fills, and where in it: what text written before one would be painted over by.
        var fills: [(box: RectD, id: Int)] = []
        /// Everything the page's own content paints, in order; past `maxFills` of them, `paintsCut`.
        var paints: [Paint] = []
        var paintsCut = false
        /// For a translated copy: an operator drawing columns becomes a run for each (`columnStarts`).
        var columns = false
        /// Its forms drew each other beyond any sensible amount: not all of the page was read.
        var cutShort: Bool { formBudget < 0 }
        /// The layers the document opens with off (catalog /OCProperties /D /OFF), read once.
        lazy var hiddenLayers: Set<ObjId> = {
            guard let off = doc?.catalog.dict("OCProperties")?.dict("D")?.array("OFF") else { return [] }
            return Set(off.elements.map(\.id))
        }()
        weak var doc: MuDoc?
        let frame: PageFrame
        let pageIndex: Int
        let cancel: CancelToken?

        init(_ frame: PageFrame, _ pageIndex: Int, _ cancel: CancelToken?) {
            self.frame = frame
            self.pageIndex = pageIndex
            self.cancel = cancel
        }

        var content: PageContent { PageContent(runs: textRuns, images: images) }

        func font(_ dict: PObj) -> TextFont {
            if let f = fonts[dict.id] { return f }
            let f = TextFont(dict)
            fonts[dict.id] = f
            fontDicts[ObjectIdentifier(f)] = dict
            return f
        }
    }

    private struct GState {
        var ctm = Mat.identity
        var font: TextFont?
        var fontKey = ""
        var size = 1.0, tc = 0.0, tw = 0.0, th = 1.0, tl = 0.0, rise = 0.0, lineWidth = 1.0
        var render = 0
        /// The rectangles clipping what is drawn, together, in page space (nil: none; other clip shapes aren't followed).
        var clip: RectD?
        var fill = 0
        var fillOp: String? = "0 g"
        var fillSpace: String? = "DeviceGray"
    }

    /// - Parameter columns: for a translated copy: an operator drawing columns becomes a run for each (`columnStarts`).
    static func walk(_ doc: MuDoc, _ page: PObj, _ pageIndex: Int, _ ops: [COp], _ cancel: CancelToken?, columns: Bool = false) throws -> Walked {
        let w = Walked(PageBoxes.frame(page), pageIndex, cancel)
        w.columns = columns
        w.doc = doc
        try run(w, ops, PageBoxes.inherited(page, "Resources").flatMap { $0.isDict ? $0 : nil }, GState(), 0, nil, nil)
        // Text in a form drawn through another form that the page draws more than once: editing it would change every
        // copy (only a form the page draws directly is copied for the edit), so it is edited nowhere.
        for i in w.textRuns.indices {
            let run = w.textRuns[i]
            guard let place = w.formOf[run.id]?.place, place.outer != nil,
                  place.chain.contains(where: { (w.formUses[$0.id] ?? 0) > 1 }) else { continue }
            w.textRuns[i].blocked = loc("it is inside a drawing (a form XObject) that the page draws more than once through another drawing, and an edit would change every copy")
            w.textRuns[i].info = nil
            w.runs[run.id] = nil
        }
        return w
    }

    private static var formImageBlocked: String {
        loc("it is part of a form XObject (a drawing the page reuses), and only the page's own pictures can be edited in this version")
    }
    private static var actualTextBlocked: String {
        loc("it carries replacement text for copying and reading aloud (ActualText) that an edit would leave wrong")
    }

    /// Why text in a layer that is off stays: nobody sees it, so it isn't edited, and it is never sent for translating.
    static var hiddenLayerBlocked: String { loc("it is invisible text (in a hidden layer)") }

    static var invisibleOcrBlocked: String { loc("it is invisible text (recognized text over a scan)") }

    /// Text nobody sees (in a layer that is off, or recognized text over a scan): never sent for translating.
    static func isInvisible(_ why: String?) -> Bool { why != nil && (why == hiddenLayerBlocked || why == invisibleOcrBlocked) }

    /// A layer, or a set of layers (an /OCMD), the document opens with off.
    private static func isHiddenLayer(_ w: Walked, _ oc: PObj?) -> Bool {
        guard let oc, !w.hiddenLayers.isEmpty else { return false }
        func off(_ group: PObj?) -> Bool { group.map { w.hiddenLayers.contains($0.id) } ?? false }
        if oc.name("Type") != "OCMD" { return off(oc) }
        if let groups = oc.array("OCGs"), groups.count > 0 { return groups.elements.allSatisfy { off($0) } }
        return off(oc.dict("OCGs"))
    }

    /// Whether a color space's numbers read as gray, RGB or CMYK: not Separation, DeviceN, Indexed, Lab or a pattern's.
    private static func isPlainColorSpace(_ resources: PObj?, _ name: String?) -> Bool {
        guard let name, !name.hasPrefix("Device") else { return true }
        guard let space = resources?.dict("ColorSpace")?.array(name), space.count > 0, let first = space[0]?.name else { return true }
        return !["Separation", "DeviceN", "Indexed", "Lab", "Pattern"].contains(first)
    }

    /// A color operator written again from its numbers (the last `count` operands).
    private static func fillOpOf(_ op: COp, _ count: Int) -> String {
        op.operands.suffix(count).map { ContentLexer.number($0.num) }.joined(separator: " ") + " " + op.name
    }

    private static func run(_ w: Walked, _ ops: [COp], _ resources: PObj?, _ start: GState, _ depth: Int, _ blocked: String?,
                            _ form: FormPlace?) throws {
        var gs = start
        var stack: [GState] = []
        var marked: [Bool] = [] // marked-content sequences: does one carry /ActualText?
        var looks: [LookTag?] = [] // and is one a look a paragraph edit gave its text?
        var actualText = 0
        var hiddenMarks: [Bool] = [] // marked-content sequences: is one a layer that is off?
        var hiddenLayer = 0
        var tm = Mat.identity, tlm = Mat.identity
        // The path being built, for a clip: one rectangle is followed, any other shape isn't.
        var pathBox: RectD?
        var pathParts = 0
        var clipping = false
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude // all of the path, page space
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func reach(_ x: Double, _ y: Double) {
            let p = project(w.frame, gs.ctm, x, y)
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        func painted(_ box: RectD?, _ id: Int, _ rect: Bool, _ color: Int?) {
            if depth != 0 || w.paintsCut { return }
            if w.paints.count >= maxFills {
                w.paintsCut = true
            } else {
                w.paints.append(Paint(box: box, id: id, rect: rect, color: color))
            }
        }
        for (i, op) in ops.enumerated() {
            if i & 1023 == 1023 { try w.cancel?.check() }
            let id: Int
            if depth == 0 {
                id = i
            } else {
                w.nested += 1
                id = -w.nested
            }
            let count = op.operands.count
            switch op.name {
            case "re" where count >= 4:
                pathParts += 1
                let x = op.n(0), y = op.n(1), wd = op.n(2), ht = op.n(3)
                pathBox = boxOf(w.frame, gs.ctm, x, y, x + wd, y + ht)
                reach(x, y)
                reach(x + wd, y + ht)
                reach(x, y + ht)
                reach(x + wd, y)
            case "m", "l", "c", "v", "y":
                pathParts += 2
                var k = 0
                while k + 1 < count { // a curve's control points hold it
                    reach(op.n(k), op.n(k + 1))
                    k += 2
                }
            case "w" where count >= 1:
                gs.lineWidth = op.n(0)
            case "sh":
                painted(gs.clip, i, false, nil)
            case "W", "W*":
                clipping = true
            case "n", "f", "F", "f*", "B", "B*", "b", "b*", "S", "s":
                if clipping && pathParts == 1, let clip = pathBox { gs.clip = gs.clip.map { $0.intersect(clip) } ?? clip }
                let fills = !["n", "S", "s"].contains(op.name)
                if depth == 0 && fills && pathParts == 1, let filled = pathBox, w.fills.count < maxFills { w.fills.append((filled, i)) }
                if op.name != "n" && maxX >= minX {
                    // A stroke reaches half its width past the path.
                    let det: Double = abs(gs.ctm.a * gs.ctm.d - gs.ctm.b * gs.ctm.c)
                    let half: Double = ["f", "F", "f*"].contains(op.name) ? 0 : abs(gs.lineWidth) / 2 * det.squareRoot()
                    let edges: Double = half + minX + minY + maxX + maxY
                    let box: RectD? = edges.isFinite ? .fromEdges(minX - half, minY - half, maxX + half, maxY + half) : nil
                    let plain = fills && gs.fillOp != nil && isPlainColorSpace(resources, gs.fillSpace)
                    painted(box, i, fills && pathParts == 1 && pathBox != nil, plain ? gs.fill : nil)
                }
                clipping = false
                pathParts = 0
                pathBox = nil
                (minX, minY) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
                (maxX, maxY) = (-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            case "q":
                if stack.count < 256 { stack.append(gs) }
            case "Q":
                if let top = stack.popLast() { gs = top }
            case "cm" where count >= 6:
                gs.ctm = Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5)).times(gs.ctm)
            case "g" where count >= 1:
                gs.fill = gray(op.n(0))
                gs.fillOp = fillOpOf(op, 1)
            case "rg" where count >= 3:
                gs.fill = rgb(op.n(0), op.n(1), op.n(2))
                gs.fillOp = fillOpOf(op, 3)
            case "k" where count >= 4:
                gs.fill = cmyk(op.n(0), op.n(1), op.n(2), op.n(3))
                gs.fillOp = fillOpOf(op, 4)
            case "sc" where [1, 3, 4].contains(count) && op.operands.allSatisfy({ $0.kind == .number }),
                 "scn" where [1, 3, 4].contains(count) && op.operands.allSatisfy({ $0.kind == .number }):
                // A spot color's or an indexed space's number isn't a shade of gray: 1 is full ink, not white.
                if !isPlainColorSpace(resources, gs.fillSpace) {
                    gs.fill = 0
                } else {
                    gs.fill = count == 1 ? gray(op.n(0)) : count == 3 ? rgb(op.n(0), op.n(1), op.n(2)) : cmyk(op.n(0), op.n(1), op.n(2), op.n(3))
                }
                gs.fillOp = gs.fillSpace.map { "/\(escapeName($0)) cs \(fillOpOf(op, count))" }
            case "sc", "scn":
                gs.fillOp = nil // a pattern
            case "cs":
                gs.fill = 0
                gs.fillSpace = count > 0 && op.operands[0].kind == .name ? op.operands[0].name : nil
                gs.fillOp = gs.fillSpace.flatMap { $0.hasPrefix("Device") ? "/\(escapeName($0)) cs" : nil }
            case "BT":
                tm = .identity
                tlm = .identity
            case "BMC", "BDC":
                var has = false
                let props = op.name == "BDC" && count >= 2 ? op.operands[1] : nil
                if let props {
                    if props.kind == .dict {
                        has = props["ActualText"] != nil
                    } else if props.kind == .name {
                        has = resources?.dict("Properties")?.dict(props.name)?.has("ActualText") ?? false
                    }
                }
                if marked.count < 256 {
                    marked.append(has)
                    if has { actualText += 1 }
                    var off = false
                    if op.name == "BDC" && count >= 2 && op.operands[0].name == "OC", let props, props.kind == .name {
                        off = isHiddenLayer(w, resources?.dict("Properties")?.dict(props.name))
                    }
                    hiddenMarks.append(off)
                    if off { hiddenLayer += 1 }
                    if let props, op.operands[0].name == lookTagName, props.kind == .dict {
                        looks.append(LookTag.read(props))
                    } else {
                        looks.append(looks.last ?? nil)
                    }
                }
            case "EMC":
                if let top = marked.popLast(), top { actualText -= 1 }
                if let top = hiddenMarks.popLast(), top { hiddenLayer -= 1 }
                if !looks.isEmpty { looks.removeLast() }
            case "Tf" where count >= 2:
                gs.fontKey = op.operands[0].name
                gs.font = resources?.dict("Font")?.dict(gs.fontKey).map(w.font)
                gs.size = op.n(1)
            case "Tc": gs.tc = op.n(0)
            case "Tw": gs.tw = op.n(0)
            case "Tz": gs.th = op.n(0) / 100
            case "TL": gs.tl = op.n(0)
            case "Ts": gs.rise = op.n(0)
            case "Tr": gs.render = Int(exactly: op.n(0).rounded(.towardZero)) ?? 0
            case "Td" where count >= 2, "TD" where count >= 2:
                if op.name == "TD" { gs.tl = -op.n(1) }
                tlm = Mat(1, 0, 0, 1, op.n(0), op.n(1)).times(tlm)
                tm = tlm
            case "Tm" where count >= 6:
                tlm = Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5))
                tm = tlm
            case "T*":
                tlm = Mat(1, 0, 0, 1, 0, -gs.tl).times(tlm)
                tm = tlm
            case "Tj", "TJ", "'", "\"":
                if op.name == "'" || op.name == "\"" {
                    if op.name == "\"" {
                        gs.tw = op.n(0)
                        gs.tc = op.n(1)
                    }
                    tlm = Mat(1, 0, 0, 1, 0, -gs.tl).times(tlm)
                    tm = tlm
                }
                guard let arg = op.operands.last, arg.kind == (op.name == "TJ" ? .array : .string) else { break }
                if let form { w.formOf[id] = (form, i) }
                let draw = form.map { FormDraw(form: $0.form.id, draw: $0.doId) }
                let why = blocked ?? (hiddenLayer > 0 ? hiddenLayerBlocked : nil) ?? (actualText > 0 ? actualTextBlocked : nil)
                tm = showText(w, id, arg, gs, tm, tlm, why, looks.last ?? nil, draw)
            case "Do" where count > 0 && op.operands[0].kind == .name:
                guard let xobj = resources?.dict("XObject")?.dict(op.operands[0].name) else { break }
                let sub = xobj.name("Subtype")
                if sub == "Image" {
                    addImage(w, id, gs.ctm, false, blocked ?? (form == nil ? nil : formImageBlocked))
                    painted(boxOf(w.frame, gs.ctm, 0, 0, 1, 1), i, false, nil)
                } else if sub == "Form" && depth < maxDepth {
                    try w.cancel?.check()
                    if w.formBudget < 0 { break }
                    var m = Mat.identity
                    if let a = xobj.array("Matrix"), a.count == 6 { m = Mat(a.num(0), a.num(1), a.num(2), a.num(3), a.num(4), a.num(5)) }
                    var inner = gs
                    inner.ctm = m.times(gs.ctm)
                    // What a form paints is anywhere in its box (anywhere at all without one).
                    var formBox: RectD?
                    if let b = xobj.array("BBox"), b.count == 4 { formBox = boxOf(w.frame, inner.ctm, b.num(0), b.num(1), b.num(2), b.num(3)) }
                    painted(formBox, i, false, nil)
                    w.formUses[xobj.id, default: 0] += 1
                    let bytes = xobj.streamData ?? []
                    w.formBudget -= bytes.count + 1024
                    if w.formBudget < 0 { break }
                    if let formBox { inner.clip = inner.clip.map { $0.intersect(formBox) } ?? formBox }
                    let formOps = try ContentLexer.parse(bytes, cancel: w.cancel)
                    let place = FormPlace(xobj, bytes, formOps, xobj.dict("Resources") ?? resources, form, id, op.operands[0].name)
                    let inHidden = hiddenLayer > 0 || isHiddenLayer(w, xobj.dict("OC"))
                    try run(w, formOps, place.resources, inner, depth + 1, blocked ?? (inHidden ? hiddenLayerBlocked : nil), place)
                }
            case "BI":
                let why = form != nil ? formImageBlocked
                    : op.broken ? loc("where its data ends can't be told for sure, so changing it could damage the page") : nil
                addImage(w, id, gs.ctm, true, blocked ?? why)
                painted(boxOf(w.frame, gs.ctm, 0, 0, 1, 1), i, false, nil)
            default:
                break
            }
        }
    }

    private static func gray(_ g: Double) -> Int { rgb(g, g, g) }

    private static func cmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> Int {
        let r: Double = (1 - c) * (1 - k), g: Double = (1 - m) * (1 - k), b: Double = (1 - y) * (1 - k)
        return rgb(r, g, b)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Int {
        func c(_ v: Double) -> Int { Int(exactly: (min(max(v, 0), 1) * 255).rounded(.toNearestOrEven)) ?? 0 } // NaN: an ink of infinity times 0
        return c(r) << 16 | c(g) << 8 | c(b)
    }

    private static func addImage(_ w: Walked, _ id: Int, _ ctm: Mat, _ inline: Bool, _ blocked: String?) {
        let box = boxOf(w.frame, ctm, 0, 0, 1, 1)
        if box.width <= 0 && box.height <= 0 { return }
        let turned = (abs(ctm.b) > 1e-6 && abs(ctm.a) > 1e-6) || (abs(ctm.c) > 1e-6 && abs(ctm.d) > 1e-6)
        w.images.append(PageImage(pageIndex: w.pageIndex, id: id, box: box, inline: inline, blocked: blocked, turned: turned))
        if blocked == nil { w.imageCtm[id] = ctm }
    }

    /// The page-space bounding box of a rectangle in a coordinate system.
    private static func boxOf(_ f: PageFrame, _ m: Mat, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> RectD {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for (x, y) in [(x1, y1), (x2, y1), (x2, y2), (x1, y2)] {
            let u = m.apply(x, y)
            let p = f.toPage(u.x, u.y)
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return .fromEdges(minX, minY, maxX, maxY)
    }

    private static func project(_ f: PageFrame, _ m: Mat, _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let u = m.apply(x, y)
        return f.toPage(u.x, u.y)
    }

    /// Records a text-showing operator as a run and returns the text matrix after it.
    private static func showText(_ w: Walked, _ id: Int, _ arg: CObj, _ gs: GState, _ tm: Mat, _ tlm: Mat, _ blocked: String?,
                                 _ tag: LookTag?, _ form: FormDraw?) -> Mat {
        let font = gs.font
        var items: [RunItem] = []
        var hex = false
        var adv = 0.0
        let fs = gs.size
        func glyphs(_ s: CObj) {
            hex = hex || s.hex
            guard let font else {
                for b in s.bytes {
                    let ink: Double = adv + 0.5 * fs * gs.th
                    items.append(RunItem(code: Int(b), number: 0, units: [UInt16(b)], isNumber: false, at: adv, inkEnd: ink))
                    adv += (0.5 * fs + gs.tc) * gs.th
                }
                return
            }
            for g in font.decode(s.bytes) {
                let ink: Double = adv + g.width * fs * gs.th
                items.append(RunItem(code: g.code, number: 0, units: Array(g.text.utf16), isNumber: false, at: adv, inkEnd: ink))
                let spacing: Double = gs.tc + (!font.twoByte && g.code == 32 ? gs.tw : 0)
                adv += (g.width * fs + spacing) * gs.th
            }
        }
        if arg.kind == .string {
            glyphs(arg)
        } else {
            for el in arg.items {
                if el.kind == .string {
                    glyphs(el)
                } else if el.kind == .number {
                    // A wide gap between words shows (and copies) as a space.
                    let space = -el.num > 180 && !items.isEmpty && items[items.count - 1].units.last != 32
                    items.append(RunItem(code: 0, number: el.num, units: space ? [32] : [], isNumber: true, at: adv))
                    adv -= el.num / 1000 * fs * gs.th
                }
            }
            // An adjustment after the last glyph moves what follows: it isn't part of the text.
            var k = items.count - 1
            while k >= 0 && items[k].isNumber {
                items[k].units = []
                items[k].trailing = true
                k -= 1
            }
        }

        let asc: Double = (font?.ascent ?? 0.8) * fs
        let desc: Double = (font?.descent ?? -0.2) * fs
        let trm = Mat(1, 0, 0, 1, 0, gs.rise).times(tm).times(gs.ctm)
        let b0 = project(w.frame, trm, 0, 0), b1 = project(w.frame, trm, 1, 0), v0 = project(w.frame, trm, 0, 1)
        let bx: Double = b1.x - b0.x, by: Double = b1.y - b0.y
        let vx: Double = v0.x - b0.x, vy: Double = v0.y - b0.y
        let scale = (bx * bx + by * by).squareRoot()
        let vscale = (vx * vx + vy * vy).squareRoot()
        let angle: Double = atan2(by, bx) * 180 / .pi
        let isUpright = upright(bx, by, vx, vy)
        let text = String(decoding: items.flatMap(\.units), as: UTF16.self)

        var why = blocked
        if why == nil {
            if font == nil {
                why = loc("its font is missing from the page")
            } else if let fb = font?.blocked {
                why = fb
            } else if gs.render == 3 || gs.render == 7 {
                why = invisibleOcrBlocked
            } else if text.contains("\u{FFFD}") {
                why = loc("some of its characters can't be read")
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                why = loc("it is only spaces")
            }
        }

        // The run of items [from, to): starting at `at` along the operator, the next one at `next`.
        func make(_ from: Int, _ to: Int, _ at: Double, _ next: Double, _ column: Int, _ columns: Int) -> TextRun {
            let start = at == 0 ? tm : Mat(1, 0, 0, 1, at, 0).times(tm)
            let place = Mat(1, 0, 0, 1, 0, gs.rise).times(start).times(gs.ctm)
            // How far its glyphs reach (right-to-left text written in logical order moves back as it goes), where the last
            // glyph's ink ends (before its spacing), and its word spaces: those between its glyphs (one after its last
            // glyph moves what follows and shows none). A column reaches as far as its ink: the spaces before the next one
            // are the gap between them, not its own.
            var low = 0.0, high = 0.0, end = 0.0, gaps = 0.0, pending = 0.0
            var gapCount = 0, pendingCount = 0
            var inked = false
            for k in from..<to {
                let item = items[k]
                if columns == 1 ? !item.isNumber : inkedItem(item) {
                    low = min(low, item.at - at)
                    end = item.inkEnd - at
                    high = max(high, end)
                    if inked || columns == 1 {
                        gaps += pending
                        gapCount += pendingCount
                    }
                    pending = 0
                    pendingCount = 0
                    inked = true
                } else if item.units == [32] {
                    pending += -item.number / 1000
                    pendingCount += 1
                }
            }
            let mine = from == 0 && to == items.count ? items : Array(items[from..<to])
            let runText = columns == 1 ? text : String(decoding: mine.flatMap(\.units), as: UTF16.self)
            let far: Double = max(end, high)
            let box = boxOf(w.frame, place, low, desc, far, asc)
            let o = project(w.frame, place, 0, 0)
            var info = RunInfo(items: mine, hex: hex)
            info.tm = start
            info.tlmAfter = tlm
            info.ctm = gs.ctm
            info.rise = gs.rise
            info.advance = next - at
            info.fillOp = gs.fillOp
            info.form = form
            info.clip = gs.clip
            info.column = column
            info.columns = columns
            info.start = at
            var run = TextRun(pageIndex: w.pageIndex, id: id, text: runText, box: box, fontSize: abs(fs) * vscale, fontName: font?.name ?? gs.fontKey,
                              bold: font?.bold ?? false, italic: font?.italic ?? false, color: gs.fill, angle: angle, blocked: why,
                              oldWidth: end * scale, font: font, scale: scale)
            run.size = fs
            run.charSpacing = gs.tc
            run.wordSpacing = gs.tw
            run.hScale = gs.th
            run.gapEms = gapCount > 0 ? gaps / Double(gapCount) : 0.25
            run.origin = PointD(o.x, o.y)
            if isUpright { run.reach = TextRun.Reach(back: -low * scale, along: far * scale, above: asc * vscale, below: -desc * vscale) }
            run.fontKey = gs.fontKey
            run.tag = tag
            run.info = info
            return run
        }

        // Columns only up to the most runs a page may have to be translated: past that it is crowded anyway.
        if why == nil && w.columns && isUpright && abs(angle) < 0.5 && adv.isFinite && w.textRuns.count < maxRunsToTranslate,
           let starts = columnStarts(items, fs * gs.th) {
            // Each column from its first glyph to the next column's (the first from where the operator starts): every item in one.
            for k in starts.indices {
                let to = k + 1 < starts.count ? starts[k + 1] : items.count
                let at = k == 0 ? 0 : items[starts[k]].at
                var column = make(starts[k], to, at, to < items.count ? items[to].at : adv, k, starts.count)
                column.key = w.textRuns.count
                w.textRuns.append(column)
            }
            return Mat(1, 0, 0, 1, adv, 0).times(tm)
        }
        var run = make(0, items.count, 0, adv, 0, 1)
        // A run of spaces only can't be edited, but a paragraph rewrite takes it out with the words around it.
        let fontUsable = font != nil && font?.blocked == nil
        let spacesOnly = why != nil && blocked == nil && fontUsable && gs.render != 3 && gs.render != 7 && !text.isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let info = run.info
        if !(why == nil || spacesOnly) { run.info = nil }
        run.key = w.textRuns.count
        if !text.isEmpty { w.textRuns.append(run) }
        if why == nil { w.runs[id] = info }
        return Mat(1, 0, 0, 1, adv, 0).times(tm)
    }

    /// Text whose up (`ux`, `uy`, page space) is square to its baseline's left, as for upright glyphs: not mirrored, not
    /// slanted.
    private static func upright(_ bx: Double, _ by: Double, _ ux: Double, _ uy: Double) -> Bool {
        let b = (bx * bx + by * by).squareRoot(), u = (ux * ux + uy * uy).squareRoot()
        if b < 1e-9 || u < 1e-9 { return false }
        // Up on the page (y down) is the baseline turned a quarter counterclockwise: (by, -bx).
        let turn: Double = (by * ux - bx * uy) / (b * u)
        return turn > 0.999
    }
}
