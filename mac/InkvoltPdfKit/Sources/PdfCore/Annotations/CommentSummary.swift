import Foundation

/// Summarize Comments (Tools › Annotate › Summarize Comments…, Batch; the Windows app's `CommentSummary`): a new PDF with
/// each page that has comments beside its comments, on landscape Letter sheets. The page sits at the left, scaled to fit,
/// drawn as it prints with its comments flattened onto it; the comments are listed at the right in page order, each with
/// its type, author, date and text, replies indented under it. Every comment has a number, shown in a disc at its place
/// on the page and at its entry in the list, and a line connects the two. A list too long for one sheet flows onto
/// continuation sheets that show the page again with the numbers of the comments listed there.
public enum CommentSummary {
    private static let sheetW = 792.0, sheetH = 612.0, margin = 36.0, gutter = 30.0, headerH = 26.0
    private static let textSize = 9.5, metaSize = 7.5, leading = 1.25, disc = 7.0, entryGap = 9.0, replyIndent = 14.0
    private static let listX = margin + (sheetW - 2 * margin - gutter) / 2 + gutter
    private static let listW = sheetW - margin - listX
    private static let textX = listX + 2 * disc + 6

    /// One comment as the summary lists it. `number`: its number (replies carry their comment's); `depth`: 0 for a
    /// comment, 1 and more for replies.
    public struct Entry: Sendable {
        public var number: Int
        public var depth: Int
        public var comment: AnnotationInfo
    }

    /// The comments of each page in the order the summary lists them, numbered from 1 through the document.
    public static func plan(_ comments: [AnnotationInfo]) -> [(page: Int, entries: [Entry])] {
        let listed = comments.filter { !$0.isInkvoltPdfStamp && $0.kind != .redact }
        let ids = Set(listed.map(\.id))
        func isReply(_ c: AnnotationInfo) -> Bool { c.replyTo.map { ids.contains($0) && $0 != c.id } ?? false }
        var replies: [String: [AnnotationInfo]] = [:]
        for c in listed where isReply(c) { replies[c.replyTo!, default: []].append(c) }
        for key in replies.keys { replies[key]?.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) } }

        var byPage: [Int: [AnnotationInfo]] = [:]
        for c in listed where !isReply(c) { byPage[c.pageIndex, default: []].append(c) }
        var number = 0
        var result: [(page: Int, entries: [Entry])] = []
        for page in byPage.keys.sorted() {
            let tops = byPage[page]!.enumerated().sorted { a, b in
                let ya = (a.element.rect.y / 4).rounded(.toNearestOrEven), yb = (b.element.rect.y / 4).rounded(.toNearestOrEven)
                if ya != yb { return ya < yb }
                if a.element.rect.x != b.element.rect.x { return a.element.rect.x < b.element.rect.x }
                return a.offset < b.offset
            }.map(\.element)
            var entries: [Entry] = []
            for top in tops {
                number += 1
                entries.append(Entry(number: number, depth: 0, comment: top))
                var seen: Set<String> = [top.id]
                func add(_ id: String, _ depth: Int) {
                    guard depth <= 16, let list = replies[id] else { return }
                    for r in list where seen.insert(r.id).inserted {
                        entries.append(Entry(number: number, depth: depth, comment: r))
                        add(r.id, depth + 1)
                    }
                }
                add(top.id, 1)
            }
            result.append((page, entries))
        }
        return result
    }

    /// The summary PDF. `title`: the document's name ("Comments on <title>"). Throws `PdfEditError` when the document has
    /// no comments.
    public static func make(_ data: [UInt8], _ password: String?, title: String, locale: Locale = .current) throws -> [UInt8] {
        let plan = plan(try Annotations.read(data, password))
        if plan.isEmpty { throw PdfEditError("This document has no comments to summarize.") }

        // The pages as they print, comments included (drawn into them), so the summary shows what the reviewers marked.
        let flat = try SignedEdits.run({ try Flattener.flatten(data, password, FlattenOptions(annotations: true, formFields: true)) },
                                       allowRewrite: true).0
        let doc = try MuDoc.create()
        let src = try PageEditor.openSource(PdfSource(flat, password, title), in: doc)
        let graft = try Graft(into: doc)
        let docTitle = "Comments on \(title)"
        InfoDict.set(doc, "Title", docTitle)
        InfoDict.set(doc, "Creator", "Inkvolt PDF")

        var texts = [docTitle]
        for (_, entries) in plan {
            for e in entries { texts += [meta(e, locale), e.comment.contents] }
        }
        let regular = TextPainter(.helvetica, texts)
        let bold = TextPainter(StdFont(.helvetica, true, false), texts)
        bold.namePrefix = "/PdB"
        var sheets: [PObj] = []

        for (pageIndex, entries) in plan {
            let (form, w, h) = try pageForm(doc, src, graft, pageIndex)
            let scale = min((listX - gutter - margin) / w, (sheetH - 2 * margin - headerH) / h)
            let ox = margin, oy = sheetH - margin - headerH - h * scale
            func onSheet(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
                (ox + min(max(px, 0), w) * scale, oy + (h - min(max(py, 0), h)) * scale)
            }

            let lines = layout(entries, regular, locale)
            var at = 0
            var continued = false
            while at < lines.count {
                // Lines that fit this sheet (an entry's header never ends a sheet).
                let top = sheetH - margin - headerH
                var y = top
                var end = at
                while end < lines.count && y - lines[end].height >= margin {
                    y -= lines[end].height
                    end += 1
                }
                if end > at + 1 && lines[end - 1].isMeta && end < lines.count { end -= 1 }
                if end == at { end = at + 1 }

                var ops = "q \(f(scale)) 0 0 \(f(scale)) \(f(ox)) \(f(oy)) cm /Pg Do Q\n"
                ops += "q 0.6 G 0.5 w \(f(ox)) \(f(oy)) \(f(w * scale)) \(f(h * scale)) re S Q\n"
                var bytes = Array(ops.utf8)
                bold.draw(continued ? "Page \(pageIndex + 1) (continued)" : "Page \(pageIndex + 1)", margin, sheetH - margin - 12, 12)
                bytes += bold.ops("/F2", black)
                regular.draw(docTitle, listX, sheetH - margin - 12, metaSize + 1)
                bytes += regular.ops("/F1", gray)

                // The list, then the discs and the lines joining them (drawn under the discs).
                var markers: [(entry: Entry, y: Double)] = []
                y = top
                for k in at..<end {
                    let line = lines[k]
                    y -= line.height
                    let x = textX + Double(line.entry.depth) * replyIndent
                    if line.isMeta {
                        (line.entry.depth == 0 ? bold : regular).draw(line.text, x, y + 2, metaSize)
                        if line.entry.depth == 0 { markers.append((line.entry, y + 2 + metaSize * 0.35)) }
                    } else {
                        regular.draw(line.text, x, y + 2, textSize)
                    }
                }
                bytes += regular.ops("/F1", black)
                bytes += bold.ops("/F2", gray)

                for (entry, my) in markers {
                    let c = entry.comment
                    let p = onSheet(c.rect.x, c.rect.y)
                    let color = rgb(c.color)
                    var marks = "q \(color) RG 0.6 w [2 1.5] 0 d \(f(p.x)) \(f(p.y)) m \(f(listX + disc)) \(f(my)) l S Q\n"
                    for (cx, cy) in [(p.x, p.y), (listX + disc, my)] {
                        marks += "q \(color) rg 0.3 G 0.5 w " + circle(cx, cy, disc) + " B Q\n"
                        let label = String(entry.number)
                        let size = label.count > 2 ? 6.5 : 8
                        bold.draw(label, cx - bold.measure(label) * size / 2, cy - size * 0.35, size)
                    }
                    bytes += Array(marks.utf8)
                    bytes += bold.ops("/F2", light(c.color) ? black : white)
                }

                sheets.append(sheet(doc, bytes, form))
                at = end
                continued = true
            }
        }

        // One font dictionary for every sheet, each font subset to the glyphs of all of them.
        let fonts = doc.dict()
        for (painter, name) in [(regular, "/F1"), (bold, "/F2")] {
            guard let f = painter.resources(doc, name).dict("Font") else { continue }
            for key in f.keys {
                if let v = f[key] { fonts.set(key == "F1" || key == "F2" ? PdfNames.bare(name) : key, v) }
            }
        }
        let fontsRef = doc.add(fonts)
        for res in sheets { res.set("Font", fontsRef) }
        InfoDict.setDate(doc, "CreationDate", Date())
        try doc.checkFailure()
        return try doc.write("garbage=compact")
    }

    private struct Line {
        var isMeta: Bool
        var text: String
        var entry: Entry
        var height: Double
    }

    /// The list as lines: each entry's "Type · author · date" line, then its text wrapped to the column.
    private static func layout(_ entries: [Entry], _ painter: TextPainter, _ locale: Locale) -> [Line] {
        var lines: [Line] = []
        for e in entries {
            let width = listW - (textX - listX) - Double(e.depth) * replyIndent
            let gap = e.depth == 0 && !lines.isEmpty ? entryGap : 3
            lines.append(Line(isMeta: true, text: meta(e, locale), entry: e, height: metaSize * leading + gap))
            let text = e.comment.contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let shown = text.count > 20_000 ? String(text.prefix(20_000)) + "…" : text
            for l in painter.wrap(shown, width, textSize) { lines.append(Line(isMeta: false, text: l, entry: e, height: textSize * leading)) }
        }
        return lines
    }

    private static func meta(_ e: Entry, _ locale: Locale) -> String {
        let c = e.comment
        let kind = CommentFiles.kindName(c.subtype)
        var parts = [e.depth > 0 ? "Reply" : kind.prefix(1).uppercased() + kind.dropFirst()]
        if let author = c.author?.trimmingCharacters(in: .whitespaces), !author.isEmpty { parts.append(author) }
        if let m = c.modified {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .short
            f.timeStyle = .short
            parts.append(f.string(from: m))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// The page as a form XObject in the summary's document, in displayed-page coordinates (rotation and crop applied),
    /// and its displayed size.
    private static func pageForm(_ doc: MuDoc, _ src: MuDoc, _ graft: Graft, _ pageIndex: Int) throws -> (form: PObj, w: Double, h: Double) {
        let at = try doc.pageCount()
        try graft.page(src, pageIndex, to: at)
        let page = doc.page(at)
        let (w, h) = PageBoxes.displaySize(page)
        let b = PageBoxes.visibleBox(page)
        let m = PageMarks.displayMatrix(page) // displayed → user space; the form needs the inverse
        let det = m[0] * m[3] - m[1] * m[2]
        let inv: [Double] = abs(det) < 1e-12 ? [1, 0, 0, 1, -b.x1, -b.y1] : [
            m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
            (m[2] * m[5] - m[3] * m[4]) / det, (m[1] * m[4] - m[0] * m[5]) / det,
        ]
        let resources = page.dict("Resources") ?? doc.dict()
        let form = doc.formXObject(ContentEditor.contentBytes(page), b.x1, b.y1, b.x2, b.y2, resources, matrix: doc.realArray(inv))
        if let group = page.dict("Group") { form.set("Group", group) }
        try doc.deletePages([at])
        return (form, w, h)
    }

    /// A landscape Letter sheet drawing `ops` with the page's form as /Pg; its resources (the fonts come at the end).
    private static func sheet(_ doc: MuDoc, _ ops: [UInt8], _ form: PObj) -> PObj {
        let resources = doc.dict([("XObject", doc.dict([("Pg", form)]))])
        let contents = doc.addStream(ops, deflate: true)
        let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, sheetW, sheetH)), ("Contents", contents),
                                     ("Resources", resources)]))
        doc.insertPage(page, at: (try? doc.pageCount()) ?? 0)
        return resources
    }

    private static let black = PdfColorValue(c: [0, 0, 0]), gray = PdfColorValue(c: [0.4, 0.4, 0.4]), white = PdfColorValue(c: [1, 1, 1])

    private static func rgb(_ c: AnnotColor?) -> String { c.map { "\(f($0.r)) \(f($0.g)) \(f($0.b))" } ?? "0.35 0.45 0.75" }

    private static func light(_ c: AnnotColor?) -> Bool { c.map { 0.299 * $0.r + 0.587 * $0.g + 0.114 * $0.b > 0.6 } ?? false }

    private static func f(_ v: Double) -> String { PdfNum.f(v) }

    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
        let k = 0.5523
        let a = "\(f(cx + r)) \(f(cy)) m \(f(cx + r)) \(f(cy + r * k)) \(f(cx + r * k)) \(f(cy + r)) \(f(cx)) \(f(cy + r)) c "
        let b = "\(f(cx - r * k)) \(f(cy + r)) \(f(cx - r)) \(f(cy + r * k)) \(f(cx - r)) \(f(cy)) c "
        let c = "\(f(cx - r)) \(f(cy - r * k)) \(f(cx - r * k)) \(f(cy - r)) \(f(cx)) \(f(cy - r)) c "
        let d = "\(f(cx + r * k)) \(f(cy - r)) \(f(cx + r)) \(f(cy - r * k)) \(f(cx + r)) \(f(cy)) c h"
        return a + b + c + d
    }
}
