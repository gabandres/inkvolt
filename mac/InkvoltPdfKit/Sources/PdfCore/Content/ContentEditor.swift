import Foundation

/// A piece of text as a page's content draws it: one text-showing operator (Tj, TJ, ' or ") of the page's own content,
/// which is usually a line or a word. Page space (points, top-left origin of the page as shown).
public struct TextRun: Sendable {
    public let pageIndex: Int
    /// The operator's place in the page's content (with `text`, how an edit finds it again).
    public let id: Int
    public let text: String
    /// Where it shows (the bounding box when it is turned).
    public let box: RectD
    /// Its size on the page, in points.
    public let fontSize: Double
    public let fontName: String
    public let bold: Bool
    public let italic: Bool
    /// Its fill color (0xRRGGBB) when it is a plain gray, RGB or CMYK color, else black.
    public let color: Int
    /// The direction of its baseline on the page, degrees clockwise from left-to-right.
    public let angle: Double
    /// Why it can't be edited, as the end of a sentence ("it is …"); nil when it can.
    public let blocked: String?
    /// The run's width as drawn (points along the baseline, to the end of its last glyph).
    public let oldWidth: Double

    let font: TextFont?
    /// Page points per text-space unit along the baseline.
    let scale: Double
    var size = 0.0, charSpacing = 0.0, wordSpacing = 0.0, hScale = 1.0
    var gapEms = 0.25
    var info: ContentEditor.RunInfo?

    /// The width `text` would take written into this run (points), and the characters the font can't draw.
    public func check(_ text: String) -> TextCheck {
        guard font != nil, let info else { return TextCheck(width: oldWidth, oldWidth: oldWidth, missing: []) }
        let plan = ContentEditor.plan(info, self, ContentEditor.oneLine(text))
        return TextCheck(width: width(plan.parts) * scale, oldWidth: oldWidth, missing: plan.middle.missing)
    }

    /// To the end of the last glyph's ink, in text space (as `oldWidth` measures the run).
    func width(_ parts: [ContentEditor.Part]) -> Double {
        guard let font else { return 0 }
        var w = 0.0, end = 0.0
        for p in parts {
            guard let c = p.code else {
                w -= p.number / 1000 * size * hScale
                continue
            }
            let glyph = font.widthOf(c) / 1000 * size * hScale
            end = w + glyph
            w += glyph + (charSpacing + (!font.twoByte && c == 32 ? wordSpacing : 0)) * hScale
        }
        return end
    }
}

/// What new text would look like: its width and the run's (points), and characters the font has no glyph for.
public struct TextCheck: Sendable, Equatable {
    public var width: Double
    public var oldWidth: Double
    public var missing: [String]
}

/// A picture the page draws: an image XObject (Do) or an inline image (BI … EI). Page space.
public struct PageImage: Sendable, Equatable {
    public let pageIndex: Int
    /// The operator's place in the page's content.
    public let id: Int
    /// Where it shows (the bounding box when it is turned).
    public let box: RectD
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

    public static let empty = PageContent(runs: [], images: [])

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

    public init(_ message: String, missing: [String] = []) {
        self.message = message
        self.missing = missing
    }

    public var description: String { message }
}

/// Edit Text & Images (the Windows app's `ContentEditor`): replaces the text of one text-showing operator in the same
/// font (only when every glyph is in it; no other font is substituted and nothing reflows), and moves, resizes, replaces
/// or deletes one picture by rewriting its placement. Works on the page's own content (all its content streams, read as
/// one); text and pictures inside form XObjects are listed but not edited. Each edit is bytes in → bytes out, saved
/// through `PdfEdit.save` (signed files appended to, protection kept).
public enum ContentEditor {
    private static let maxDepth = 8

    /// The page's text runs and pictures.
    /// - Throws: `PdfEngineError` for a page past the end; `PdfEditError`, `PasswordRequired` when the file can't be read.
    public static func read(_ data: [UInt8], _ password: String?, _ pageIndex: Int, cancel: CancelToken? = nil) throws -> PageContent {
        let doc = try PdfEdit.openToRead(data, password)
        let count = try doc.pageCount()
        guard pageIndex >= 0 && pageIndex < count else {
            throw PdfEngineError(message: "Page \(pageIndex + 1) isn't in this document.")
        }
        let page = doc.page(pageIndex)
        return try walk(page, pageIndex, ContentLexer.parse(streams(page).bytes, cancel: cancel), cancel).content
    }

    /// Several pages' text runs and pictures (a page that can't be read comes back empty).
    public static func read(_ data: [UInt8], _ password: String?, pages: [Int], cancel: CancelToken? = nil) throws -> [Int: PageContent] {
        let doc = try PdfEdit.openToRead(data, password)
        let count = try doc.pageCount()
        var result: [Int: PageContent] = [:]
        for p in pages where p >= 0 && p < count {
            let page = doc.page(p)
            do {
                result[p] = try walk(page, p, ContentLexer.parse(streams(page).bytes, cancel: cancel), cancel).content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result[p] = .empty // a damaged page: nothing to edit on it
            }
        }
        return result
    }

    // ---- Text ----

    /// Replaces a run's text, written in the run's own font.
    /// - Throws: `ContentEditError` when the font can't draw the text (the message names the missing characters), the
    ///   run can't be edited, or the page changed.
    public static func replaceText(_ data: [UInt8], _ password: String?, _ run: TextRun, _ newText: String) throws -> [UInt8] {
        let text = oneLine(newText)
        if Array(text.utf16) == Array(run.text.utf16) { return data }
        let doc = try PdfEdit.open(data, password, failure: "This PDF can't be edited")
        let page = try pageOf(doc, run.pageIndex)
        let content = streams(page)
        let ops = ContentLexer.parse(content.bytes)
        let walked = try walk(page, run.pageIndex, ops, nil)
        // The run where it was; else (an earlier edit moved the page's operators) the same text in the same place.
        let now = walked.textRuns.first { $0.id == run.id && same($0.text, run.text) }
            ?? walked.textRuns.filter { same($0.text, run.text) && near($0.box, run.box) }
            .min { distance($0.box, run.box) < distance($1.box, run.box) }
        if let why = now?.blocked { throw ContentEditError("This text can't be edited: \(why).") }
        guard let now, let info = walked.runs[now.id], let font = now.font, let fontDict = walked.fontDicts[ObjectIdentifier(font)] else {
            throw ContentEditError("The page changed since this text was picked. Pick it again.")
        }

        let planned = plan(info, now, text)
        if !planned.middle.missing.isEmpty { throw missingGlyphs(font, planned.middle.missing) }
        font.prepare(doc, fontDict, planned.middle.codes, planned.middleText)
        let op = ops[now.id]
        let replacement = writeShow(op, info, font, planned.parts)
        _ = try writeContent(doc, page, content, ops, [(op.start, op.end, latin1Bytes(replacement))])
        SignedEdits.noteRemoval() // the old text stays in a signed file's earlier revision
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    private static func distance(_ a: RectD, _ b: RectD) -> Double { abs(a.x - b.x) + abs(a.y - b.y) }

    /// A glyph code, or (with no code) a TJ adjustment, of rewritten text.
    struct Part: Sendable {
        var code: Int?
        var number: Double
    }

    /// How a run's new text is written: what didn't change is kept (with its kerning), the changed middle is encoded
    /// plainly. Adjustments touching the change go with it, except the one before the first glyph (where the run starts)
    /// and any after the last.
    static func plan(_ info: RunInfo, _ run: TextRun, _ text: String) -> (parts: [Part], middle: EncodedText, middleText: String) {
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

        let enc = run.font!.encode(middle)
        var parts: [Part] = []
        for it in items.prefix(pre) { parts.append(Part(code: it.isNumber ? nil : it.code, number: it.number)) }
        for c in enc.codes { parts.append(c == TextFont.gap ? Part(code: nil, number: -run.gapEms * 1000) : Part(code: c, number: 0)) }
        for it in items.suffix(suf) { parts.append(Part(code: it.isNumber ? nil : it.code, number: it.number)) }
        return (parts, enc, middle)
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    private static func missingGlyphs(_ font: TextFont, _ missing: [String]) -> ContentEditError {
        func show(_ c: String) -> String {
            if c == " " { return "space" }
            if let u = c.utf16.first, c.unicodeScalars.first?.properties.generalCategory == .control { return String(format: "U+%04X", u) }
            return "“\(c)”"
        }
        let list = missing.prefix(12).map(show).joined(separator: ", ") + (missing.count > 12 ? " and \(missing.count - 12) more" : "")
        let name = font.name.isEmpty ? "This text's font" : "The font “\(font.name)”"
        return ContentEditError(
            "\(name) has no \(missing.count == 1 ? "glyph" : "glyphs") for \(list) in this PDF (an embedded font usually holds only the "
                + "characters the document uses). Use characters already in this text, or add a text box instead.",
            missing: missing)
    }

    /// The text-showing operator rewritten with new parts (strings of codes and TJ adjustments).
    private static func writeShow(_ op: COp, _ info: RunInfo, _ font: TextFont, _ parts: [Part]) -> String {
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

    /// An edit of a picture: the byte ranges of the page's content to replace, and with what.
    private typealias Edits = [(start: Int, end: Int, bytes: [UInt8])]

    /// Moves and/or resizes a picture so its bounding box becomes `box` (page space).
    public static func moveImage(_ data: [UInt8], _ password: String?, _ image: PageImage, _ box: RectD) throws -> [UInt8] {
        if box.width < 1 || box.height < 1 { throw ContentEditError("A picture can't be made that small.") }
        return try editImage(data, password, image) { _, page, found, op, ctm, ops, content in
            let p2u = pageToUser(PageBoxes.frame(page))
            guard let u2p = p2u.inverted() else { throw ContentEditError("This page's size can't be read.") }
            let old = found.box
            let sx: Double = box.width / old.width, sy: Double = box.height / old.height
            let d = Mat(sx, 0, 0, sy, box.x - old.x * sx, box.y - old.y * sy)
            let dUser = u2p.times(d).times(p2u)
            guard let inv = ctm.inverted() else { throw ContentEditError("This picture is drawn squashed flat, so it can't be moved.") }
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
        let doc = try PdfEdit.open(data, password, failure: "This PDF can't be edited")
        let page = try pageOf(doc, image.pageIndex)
        let content = streams(page)
        let ops = ContentLexer.parse(content.bytes)
        let walked = try walk(page, image.pageIndex, ops, nil)
        let now = walked.images.first { $0.id == image.id && near($0.box, image.box) } ?? walked.images.last { near($0.box, image.box) }
        if let why = now?.blocked { throw ContentEditError("This picture can't be edited: \(why).") }
        guard let now, let ctm = walked.imageCtm[now.id] else {
            throw ContentEditError("The page changed since this picture was picked. Pick it again.")
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

    private static func near(_ a: RectD, _ b: RectD) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// A dictionary entry the page may change: its own (direct) one, or a copy of a shared one put in its place.
    static func ownDict(_ doc: MuDoc, _ parent: PObj, _ key: String, _ inherited: PObj? = nil) -> PObj {
        let current = parent[key] ?? inherited
        if let current, current.isDict, !current.isRef, parent[key] != nil { return current }
        let copy = doc.dict()
        if let current, current.isDict {
            for k in current.keys { if let v = current[k] { copy.set(k, v) } }
        }
        parent.set(key, copy)
        return parent[key] ?? copy
    }

    /// Adds an image XObject to the page's own resources (copying shared ones first), under a fresh name.
    private static func addXObject(_ doc: MuDoc, _ page: PObj, _ xobject: PObj) -> String {
        let res = ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
        let xo = ownDict(doc, res, "XObject")
        var n = 1
        while xo.has("InkImg\(n)") { n += 1 }
        xo.set("InkImg\(n)", xobject)
        return "InkImg\(n)"
    }

    // ---- Content ----

    private static func pageOf(_ doc: MuDoc, _ index: Int) throws -> PObj {
        let count = try doc.pageCount()
        guard index >= 0 && index < count else { throw ContentEditError("This page is no longer in the document.") }
        return doc.page(index)
    }

    /// One content stream of a page: where its bytes sit in the page's content read as one, its place in the /Contents
    /// array (-1: the only one).
    private struct ContentPart {
        var start: Int, end: Int, slot: Int
        var unreadable: Bool
    }

    /// A page's content streams read as one (they are one content stream split at token boundaries).
    private struct PageStreams {
        var bytes: [UInt8]
        var parts: [ContentPart]
    }

    static func contentBytes(_ page: PObj) -> [UInt8] { streams(page).bytes }

    private static func streams(_ page: PObj) -> PageStreams {
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
    private static func writeContent(_ doc: MuDoc, _ page: PObj, _ streams: PageStreams, _ ops: [COp], _ edits: Edits) throws -> [UInt8] {
        let updated = splice(streams.bytes, edits)
        if streams.parts.count > 1, !edits.isEmpty, let old = page["Contents"], old.isArray {
            let lo = edits.map(\.start).min()!, hi = edits.map(\.end).max()!
            if let part = streams.parts.first(where: { lo >= $0.start && hi <= $0.end }),
               !ops.contains(where: { ($0.start < part.start && $0.end > part.start) || ($0.start < part.end && $0.end > part.end) }) {
                let bytes = splice(Array(streams.bytes[part.start..<part.end]), edits.map { ($0.start - part.start, $0.end - part.start, $0.bytes) })
                let array = doc.array(old.elements) // the page's own: another page may share the old one
                array.replace(at: part.slot, with: doc.addStream(bytes, deflate: true))
                page.set("Contents", array)
                return updated
            }
        }
        if streams.parts.contains(where: \.unreadable) {
            throw ContentEditError("Part of this page's content can't be read (it is damaged), so the page can't be rewritten without losing it.")
        }
        page.set("Contents", doc.addStream(updated, deflate: true))
        return updated
    }

    private static func splice(_ content: [UInt8], _ edits: Edits) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(content.count + 256)
        var at = 0
        for e in edits.sorted(by: { $0.start < $1.start }) {
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

    private static func escapeName(_ name: String) -> String {
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
    private static func pageToUser(_ f: PageFrame) -> Mat {
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

    /// One glyph or TJ adjustment of a run, with the text it stands for (as UTF-16 units).
    struct RunItem: Sendable {
        var code: Int
        var number: Double
        var units: [UInt16]
        var isNumber: Bool
        var trailing = false
    }

    struct RunInfo: Sendable {
        var items: [RunItem]
        var hex: Bool
    }

    private final class Walked {
        var textRuns: [TextRun] = []
        var images: [PageImage] = []
        var runs: [Int: RunInfo] = [:]
        var imageCtm: [Int: Mat] = [:]
        /// Things inside form XObjects get negative ids (they aren't page operators).
        var nested = 0
        var fonts: [ObjId: TextFont] = [:]
        /// Each font's dictionary, for an edit to add widths and ToUnicode entries to.
        var fontDicts: [ObjectIdentifier: PObj] = [:]
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
        var size = 1.0, tc = 0.0, tw = 0.0, th = 1.0, tl = 0.0, rise = 0.0
        var render = 0
        var fill = 0
    }

    private static func walk(_ page: PObj, _ pageIndex: Int, _ ops: [COp], _ cancel: CancelToken?) throws -> Walked {
        let w = Walked(PageBoxes.frame(page), pageIndex, cancel)
        try run(w, ops, PageBoxes.inherited(page, "Resources").flatMap { $0.isDict ? $0 : nil }, GState(), 0, nil)
        return w
    }

    private static let formBlocked =
        "it is part of a form XObject (a drawing the page reuses), and only the page's own content can be edited in this version"
    private static let actualTextBlocked =
        "it carries replacement text for copying and reading aloud (ActualText) that an edit would leave wrong"

    private static func run(_ w: Walked, _ ops: [COp], _ resources: PObj?, _ start: GState, _ depth: Int, _ blocked: String?) throws {
        var gs = start
        var stack: [GState] = []
        var marked: [Bool] = [] // marked-content sequences: does one carry /ActualText?
        var actualText = 0
        var tm = Mat.identity, tlm = Mat.identity
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
            case "q":
                if stack.count < 256 { stack.append(gs) }
            case "Q":
                if let top = stack.popLast() { gs = top }
            case "cm" where count >= 6:
                gs.ctm = Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5)).times(gs.ctm)
            case "g" where count >= 1:
                gs.fill = gray(op.n(0))
            case "rg" where count >= 3:
                gs.fill = rgb(op.n(0), op.n(1), op.n(2))
            case "k" where count >= 4:
                gs.fill = cmyk(op.n(0), op.n(1), op.n(2), op.n(3))
            case "sc" where [1, 3, 4].contains(count) && op.operands.allSatisfy({ $0.kind == .number }),
                 "scn" where [1, 3, 4].contains(count) && op.operands.allSatisfy({ $0.kind == .number }):
                gs.fill = count == 1 ? gray(op.n(0)) : count == 3 ? rgb(op.n(0), op.n(1), op.n(2)) : cmyk(op.n(0), op.n(1), op.n(2), op.n(3))
            case "cs":
                gs.fill = 0
            case "BT":
                tm = .identity
                tlm = .identity
            case "BMC", "BDC":
                var has = false
                if op.name == "BDC" && count >= 2 {
                    let props = op.operands[1]
                    if props.kind == .dict {
                        has = props["ActualText"] != nil
                    } else if props.kind == .name {
                        has = resources?.dict("Properties")?.dict(props.name)?.has("ActualText") ?? false
                    }
                }
                if marked.count < 256 {
                    marked.append(has)
                    if has { actualText += 1 }
                }
            case "EMC":
                if let top = marked.popLast(), top { actualText -= 1 }
            case "Tf" where count >= 2:
                gs.fontKey = op.operands[0].name
                gs.font = resources?.dict("Font")?.dict(gs.fontKey).map(w.font)
                gs.size = op.n(1)
            case "Tc": gs.tc = op.n(0)
            case "Tw": gs.tw = op.n(0)
            case "Tz": gs.th = op.n(0) / 100
            case "TL": gs.tl = op.n(0)
            case "Ts": gs.rise = op.n(0)
            case "Tr": gs.render = Int(op.n(0))
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
                tm = showText(w, id, arg, gs, tm, blocked ?? (actualText > 0 ? actualTextBlocked : nil))
            case "Do" where count > 0 && op.operands[0].kind == .name:
                guard let xobj = resources?.dict("XObject")?.dict(op.operands[0].name) else { break }
                let sub = xobj.name("Subtype")
                if sub == "Image" {
                    addImage(w, id, gs.ctm, false, blocked)
                } else if sub == "Form" && depth < maxDepth {
                    var m = Mat.identity
                    if let a = xobj.array("Matrix"), a.count == 6 { m = Mat(a.num(0), a.num(1), a.num(2), a.num(3), a.num(4), a.num(5)) }
                    var inner = gs
                    inner.ctm = m.times(gs.ctm)
                    let formOps = try ContentLexer.parse(xobj.streamData ?? [], cancel: w.cancel)
                    try run(w, formOps, xobj.dict("Resources") ?? resources, inner, depth + 1, formBlocked)
                }
            case "BI":
                addImage(w, id, gs.ctm, true, blocked ?? (op.broken ? "where its data ends can't be told for sure, so changing it could damage the page" : nil))
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
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded(.toNearestOrEven)) }
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
    private static func showText(_ w: Walked, _ id: Int, _ arg: CObj, _ gs: GState, _ tm: Mat, _ blocked: String?) -> Mat {
        let font = gs.font
        var items: [RunItem] = []
        var hex = false
        var adv = 0.0, gaps = 0.0, end = 0.0 // end: where the last glyph's ink ends (before its spacing)
        var gapCount = 0
        let fs = gs.size
        func glyphs(_ s: CObj) {
            hex = hex || s.hex
            guard let font else {
                for b in s.bytes {
                    items.append(RunItem(code: Int(b), number: 0, units: [UInt16(b)], isNumber: false))
                    end = adv + 0.5 * fs * gs.th
                    adv += (0.5 * fs + gs.tc) * gs.th
                }
                return
            }
            for g in font.decode(s.bytes) {
                items.append(RunItem(code: g.code, number: 0, units: Array(g.text.utf16), isNumber: false))
                end = adv + g.width * fs * gs.th
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
                    items.append(RunItem(code: 0, number: el.num, units: space ? [32] : [], isNumber: true))
                    adv -= el.num / 1000 * fs * gs.th
                    if space {
                        gaps += -el.num / 1000
                        gapCount += 1
                    }
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

        let trm = Mat(1, 0, 0, 1, 0, gs.rise).times(tm).times(gs.ctm)
        let asc: Double = (font?.ascent ?? 0.8) * fs
        let desc: Double = (font?.descent ?? -0.2) * fs
        let box = boxOf(w.frame, trm, 0, desc, end, asc)
        let b0 = project(w.frame, trm, 0, 0), b1 = project(w.frame, trm, 1, 0), v0 = project(w.frame, trm, 0, 1)
        let scale = ((b1.x - b0.x) * (b1.x - b0.x) + (b1.y - b0.y) * (b1.y - b0.y)).squareRoot()
        let vscale = ((v0.x - b0.x) * (v0.x - b0.x) + (v0.y - b0.y) * (v0.y - b0.y)).squareRoot()
        let angle: Double = atan2(b1.y - b0.y, b1.x - b0.x) * 180 / .pi
        let text = String(decoding: items.flatMap(\.units), as: UTF16.self)

        var why = blocked
        if why == nil {
            if font == nil {
                why = "its font is missing from the page"
            } else if let fb = font?.blocked {
                why = fb
            } else if gs.render == 3 || gs.render == 7 {
                why = "it is invisible text (recognized text over a scan)"
            } else if text.contains("\u{FFFD}") {
                why = "some of its characters can't be read"
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                why = "it is only spaces"
            }
        }
        let info = RunInfo(items: items, hex: hex)
        var run = TextRun(pageIndex: w.pageIndex, id: id, text: text, box: box, fontSize: abs(fs) * vscale, fontName: font?.name ?? gs.fontKey,
                          bold: font?.bold ?? false, italic: font?.italic ?? false, color: gs.fill, angle: angle, blocked: why,
                          oldWidth: end * scale, font: font, scale: scale)
        run.size = fs
        run.charSpacing = gs.tc
        run.wordSpacing = gs.tw
        run.hScale = gs.th
        run.gapEms = gapCount > 0 ? gaps / Double(gapCount) : 0.25
        run.info = why == nil ? info : nil
        if !text.isEmpty { w.textRuns.append(run) }
        if why == nil { w.runs[id] = info }
        return Mat(1, 0, 0, 1, adv, 0).times(tm)
    }
}
