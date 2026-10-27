import CryptoKit
import Foundation

/// Writes a Word document (.docx, Office Open XML) from laid-out pages: paragraphs with their fonts, sizes, bold, italic
/// and colors; headings as Heading 1-6 (so they show in Word's navigation pane); bullets as Word bullets; tables;
/// pictures inline; each PDF page its own section (its size and orientation), so pages break where the PDF's did.
/// Pictures are stored as they are added (`addImage`), so a long document's images needn't all be held in memory.
final class DocxWriter {
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let namespaces: [(String, String)] = [
        ("xmlns:w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
        ("xmlns:r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships"),
        ("xmlns:wp", "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"),
        ("xmlns:a", "http://schemas.openxmlformats.org/drawingml/2006/main"),
        ("xmlns:pic", "http://schemas.openxmlformats.org/drawingml/2006/picture"),
    ]
    private static let picUri = "http://schemas.openxmlformats.org/drawingml/2006/picture"

    private let zip: ZipWriter
    private var rels: [(id: String, type: String, target: String)] = []
    private var byContent: [String: String] = [:] // SHA-256 of a picture -> its id
    private var targets: [String: String] = [:]   // id -> media part
    private var media = 0
    private var drawing = 0
    // The fonts the runs name, with what kind of font each is (for Word's font table, so a missing one is replaced well).
    private var fonts: [(name: String, serif: Bool, mono: Bool)] = []
    private var fontKeys = Set<String>()
    // The share of the page's spacing the page being written keeps (less than 1 when it wouldn't fit on one Word page).
    private var spacing = 1.0
    private var finished = false

    init(_ sink: ByteSink) { zip = ZipWriter(sink) }

    /// Stores a picture (PNG or JPEG bytes) and returns its id for `ExportImage.ref`. The same picture again (a logo on
    /// every page, an icon in every row) is stored once and gets the same id.
    func addImage(_ data: [UInt8], _ ext: String) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        if let known = byContent[hash] { return known }
        media += 1
        let target = "media/image\(media).\(ext == "jpeg" ? "jpeg" : "png")"
        try zip.add("word/" + target, data, compress: false) // already compressed
        let id = "rIdImg\(media)"
        rels.append((id, Self.relBase + "image", target))
        targets[id] = target
        byContent[hash] = id
        return id
    }

    func finish(_ layout: DocLayoutResult, _ title: String?) throws {
        precondition(!finished, "Already finished.")
        finished = true
        let pages = layout.pages
        let bodyGroups = groupedInOrder(pages.flatMap(\.paragraphs).filter { $0.headingLevel == 0 }, by: \.size)
        let body = bodyGroups.max { a, b in
            a.items.reduce(0) { $0 + $1.text.utf16.count } < b.items.reduce(0) { $0 + $1.text.utf16.count }
        }?.key ?? 11
        rels.append(("rIdStyles", Self.relBase + "styles", "styles.xml"))
        rels.append(("rIdNumbering", Self.relBase + "numbering", "numbering.xml"))
        rels.append(("rIdSettings", Self.relBase + "settings", "settings.xml"))
        rels.append(("rIdFontTable", Self.relBase + "fontTable", "fontTable.xml"))

        var parts: [(part: String, type: String)] = []
        let textWidth = pages.isEmpty ? 468 : Section(pages[0]).textWidth
        for (running, kind, id) in [(layout.header, "header", Self.headerId), (layout.footer, "footer", Self.footerId)] {
            guard let running else { continue }
            let root = kind == "header" ? "w:hdr" : "w:ftr"
            let type = "application/vnd.openxmlformats-officedocument.wordprocessingml.\(kind)+xml"
            if pages.indices.contains(where: { !running.onPages.contains($0) }) {
                // Pages that had none of it (a cover page) point at an empty one.
                rels.append((id + "None", Self.relBase + kind, "\(kind)2.xml"))
                try entry("word/\(kind)2.xml") { self.running($0, root, DocRunning(rows: []), textWidth) }
                parts.append(("/word/\(kind)2.xml", type))
            }
            rels.append((id, Self.relBase + kind, "\(kind)1.xml"))
            try entry("word/\(kind)1.xml") { self.running($0, root, running, textWidth) }
            var pictures: [String] = []
            for p in running.pictures { if let r = p.image.ref, !pictures.contains(r) { pictures.append(r) } }
            if !pictures.isEmpty {
                try entry("word/_rels/\(kind)1.xml.rels") { w in
                    OpenXmlParts.relationships(w, pictures.map { ($0, Self.relBase + "image", self.targets[$0]!) })
                }
            }
            parts.append(("/word/\(kind)1.xml", type))
        }
        try entry("word/document.xml") { self.document($0, pages, layout.header, layout.footer) }
        try entry("word/styles.xml") { Self.styles($0, body) }
        try entry("word/numbering.xml", Self.numbering)
        try entry("word/settings.xml", Self.settings)
        try entry("word/fontTable.xml", fontTable)
        try entry("word/_rels/document.xml.rels") { OpenXmlParts.relationships($0, self.rels) }
        try entry("_rels/.rels") { w in
            OpenXmlParts.relationships(w, [
                ("rId1", Self.relBase + "officeDocument", "word/document.xml"),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                ("rId3", Self.relBase + "extended-properties", "docProps/app.xml"),
            ])
        }
        try entry("docProps/core.xml") { OpenXmlParts.coreProperties($0, title) }
        try entry("docProps/app.xml", OpenXmlParts.appProperties)
        try entry("[Content_Types].xml") { w in
            OpenXmlParts.contentTypes(w, [
                ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
                ("/word/styles.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"),
                ("/word/numbering.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"),
                ("/word/settings.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"),
                ("/word/fontTable.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"),
            ] + parts)
        }
        try zip.finish()
    }

    private func entry(_ name: String, _ write: (XmlOut) -> Void) throws { try OpenXmlParts.entry(zip, name, write) }

    // ---- document.xml ----

    private static let headerId = "rIdHeader"
    private static let footerId = "rIdFooter"

    private func document(_ w: XmlOut, _ pages: [DocPage], _ header: DocRunning?, _ footer: DocRunning?) {
        w.start("w:document", Self.namespaces)
        w.start("w:body")
        if pages.isEmpty { paragraph(w, nil, nil, 0) }
        for (i, page) in pages.enumerated() {
            var section = Section(page)
            section.header = header.map { $0.onPages.contains(i) ? Self.headerId : Self.headerId + "None" }
            section.footer = footer.map { $0.onPages.contains(i) ? Self.footerId : Self.footerId + "None" }
            let last = i == pages.count - 1
            let blocks = page.blocks
            spacing = spacingToFit(page, section)
            for b in blocks.indices {
                // A page's last paragraph carries its section (size, margins); the last page's section closes the body.
                let carries = !last && b == blocks.count - 1 && blocks[b].table == nil ? section : nil
                switch blocks[b] {
                case .paragraph(let p):
                    paragraph(w, p, carries, section.textWidth)
                case .picture(let pic):
                    picture(w, pic, page, section, carries)
                case .table(let t):
                    if b > 0, case .table(let above) = blocks[b - 1] {
                        // Word joins two tables with nothing between them into one: a paragraph keeps them apart, as tall
                        // as the gap the page leaves.
                        let gap = max(0, t.box.y - above.box.bottom) * spacing
                        w.start("w:p")
                        w.start("w:pPr")
                        w.empty("w:spacing", [("w:before", "0"), ("w:after", "0"), ("w:line", OpenXmlParts.twips(clamp(gap, 1, 200))),
                                              ("w:lineRule", "exact")])
                        w.end()
                        w.end()
                    }
                    table(w, t, section)
                }
            }
            let endsWithTable = blocks.last?.table != nil
            if !last && (blocks.isEmpty || endsWithTable) { paragraph(w, nil, section, 0) }
            if last {
                if blocks.isEmpty || endsWithTable { paragraph(w, nil, nil, 0) } // Word wants the body to end with a paragraph
                sectionProperties(w, section)
            }
        }
        if pages.isEmpty { sectionProperties(w, Section(DocPage(width: 612, height: 792, content: .zero, blocks: []))) }
        w.end()
        w.end()
    }

    /// Word's line height for one line of type (single spacing), as a share of the size, rounded up.
    private static let lineHeight = 1.2

    /// How much of the page's spacing to keep so that it fits on one Word page as it did in the PDF: 1 when it fits,
    /// less when the lines (as tall as Word makes them, which is often taller than the PDF set them), tables and pictures
    /// leave less room than the page's gaps need; 1 too when they overflow the page whatever the spacing. Text that
    /// wraps differently in Word isn't known here.
    private func spacingToFit(_ page: DocPage, _ section: Section) -> Double {
        let available = (section.height - section.top - section.bottom) * 0.97
        var content = 0.0, space = 0.0
        func lines(_ p: DocParagraph) -> Double { Double(p.lineCount) * Self.lineHeight * max(1, p.size) }
        for (b, block) in page.blocks.enumerated() {
            switch block {
            case .paragraph(let p):
                content += lines(p)
                space += p.spaceBefore.map { $0 + (p.spaceAfter ?? 0) } ?? 6
            case .table(let t):
                for (r, row) in t.rows.enumerated() {
                    let text = row.map { c in c.paragraphs.reduce(0.0) { $0 + lines($1) + ($1.spaceBefore ?? 0) } }.max() ?? 0
                    content += max(text, t.rowHeights.flatMap { r < $0.count ? $0[r] : nil } ?? 0)
                }
                if b > 0, case .table(let above) = page.blocks[b - 1] { space += max(0, t.box.y - above.box.bottom) }
            case .picture(let pic):
                content += min(pic.box.height, section.height - section.top - section.bottom)
            }
        }
        // Fits, or can't fit whatever the spacing (columns run into one, a long table): the page's spacing stays.
        if content + space <= available || space <= 0 || content >= available { return 1 }
        return clamp((available - content) / space, 0, 1)
    }

    /// A PDF page as a Word section: its size, and margins from where its content sits (between 0.25 and 1 inch).
    private struct Section {
        var width, height, left, right, top, bottom: Double
        /// Where the page's content starts on the PDF page (indents are measured from the margin, which may differ).
        var contentLeft: Double
        /// The header and footer parts the section shows (relationship ids), if any.
        var header: String?
        var footer: String?

        init(_ page: DocPage) {
            width = clamp(page.width, 72, 1584) // Word's page size limits: 1 to 22 inches
            height = clamp(page.height, 72, 1584)
            let c = page.content
            let empty = c.width <= 0 || c.height <= 0
            left = empty ? 72 : clamp(c.x, 18, 72)
            right = empty ? 72 : clamp(page.width - c.right, 18, 72)
            top = empty ? 72 : clamp(c.y, 18, 72)
            bottom = empty ? 72 : clamp(page.height - c.bottom, 18, 72)
            if width - left - right < 72 { (left, right) = (18, 18) }
            if height - top - bottom < 72 { (top, bottom) = (18, 18) }
            contentLeft = empty ? left : c.x
        }

        var textWidth: Double { width - left - right }
    }

    private func sectionProperties(_ w: XmlOut, _ s: Section) {
        w.start("w:sectPr")
        if let id = s.header { w.empty("w:headerReference", [("w:type", "default"), ("r:id", id)]) }
        if let id = s.footer { w.empty("w:footerReference", [("w:type", "default"), ("r:id", id)]) }
        var size = [("w:w", OpenXmlParts.twips(s.width)), ("w:h", OpenXmlParts.twips(s.height))]
        if s.width > s.height { size.append(("w:orient", "landscape")) }
        w.empty("w:pgSz", size)
        w.empty("w:pgMar", [
            ("w:top", OpenXmlParts.twips(s.top)), ("w:right", OpenXmlParts.twips(s.right)), ("w:bottom", OpenXmlParts.twips(s.bottom)),
            ("w:left", OpenXmlParts.twips(s.left)), ("w:header", OpenXmlParts.twips(min(36, s.top / 2))),
            ("w:footer", OpenXmlParts.twips(min(36, s.bottom / 2))), ("w:gutter", "0"),
        ])
        w.end()
    }

    private static func val(_ w: XmlOut, _ element: String, _ value: String) { w.empty(element, [("w:val", value)]) }

    /// A paragraph (nil: an empty one), optionally ending a section. `width`: the text width, to cap indents.
    private func paragraph(_ w: XmlOut, _ p: DocParagraph?, _ endsSection: Section?, _ width: Double, inCell: Bool = false) {
        w.start("w:p")
        let style: String? = p.flatMap { p in p.headingLevel > 0 ? "Heading\(p.headingLevel)" : p.list != ListKind.none ? "ListParagraph" : nil }
        var hasPPr = style != nil || endsSection != nil || inCell
        if let p, p.align != .left || p.indent > 0 || p.firstLine != 0 || p.list != ListKind.none || !p.tabs.isEmpty || p.spaceBefore != nil {
            hasPPr = true
        }
        if hasPPr {
            w.start("w:pPr")
            if let style { Self.val(w, "w:pStyle", style) }
            if let p, p.list == .bullet {
                w.start("w:numPr")
                Self.val(w, "w:ilvl", "0")
                Self.val(w, "w:numId", "1")
                w.end()
            }
            if let p, !p.tabs.isEmpty {
                // Positions from the margin (or the cell's edge), within the text width.
                w.start("w:tabs")
                var last = -1.0
                for tab in p.tabs {
                    // Stops in order, none twice (one clamped to the width stands for all past it).
                    let pos = clamp(tab.position, 0, max(0, width))
                    if pos <= last + 0.5 { continue }
                    last = pos
                    var a = [("w:val", tab.right ? "right" : "left")]
                    if tab.leader != "\0" { a.append(("w:leader", tab.leader == "_" ? "underscore" : tab.leader == "-" ? "hyphen" : "dot")) }
                    a.append(("w:pos", OpenXmlParts.twips(pos)))
                    w.empty("w:tab", a)
                }
                w.end()
            }
            if inCell || p?.spaceBefore != nil {
                var a: [(String, String)] = []
                if let before = p?.spaceBefore { a.append(("w:before", OpenXmlParts.twips(before * spacing))) }
                a.append(("w:after", OpenXmlParts.twips(inCell ? 0 : (p?.spaceAfter ?? 0) * spacing)))
                w.empty("w:spacing", a)
            }
            if let p, p.indent > 0 || p.firstLine != 0 || p.list != ListKind.none {
                let cap = max(0, width / 2)
                let left = min(p.indent, cap)
                if p.list != ListKind.none {
                    // The marker hangs 18 pt to the left of the text, as Word's own lists do.
                    w.empty("w:ind", [("w:left", OpenXmlParts.twips(left + 18)), ("w:hanging", OpenXmlParts.twips(18))])
                } else {
                    var a = [("w:left", OpenXmlParts.twips(left))]
                    if p.firstLine > 0 {
                        a.append(("w:firstLine", OpenXmlParts.twips(min(p.firstLine, cap))))
                    } else if p.firstLine < 0 {
                        a.append(("w:hanging", OpenXmlParts.twips(min(-p.firstLine, left))))
                    }
                    w.empty("w:ind", a)
                }
            }
            // The page's spacing applies between list items too (List Paragraph's style would drop it).
            if p?.spaceBefore != nil && style == "ListParagraph" { Self.val(w, "w:contextualSpacing", "0") }
            if p?.align == .center { Self.val(w, "w:jc", "center") } else if p?.align == .right { Self.val(w, "w:jc", "right") }
            if let endsSection { sectionProperties(w, endsSection) }
            w.end()
        }
        if let p { for r in p.runs { run(w, r) } }
        w.end()
    }

    private func run(_ w: XmlOut, _ s: ExportSpan) {
        let text = OpenXmlParts.clean(s.text)
        if text.isEmpty { return }
        w.start("w:r")
        w.start("w:rPr")
        // Windows font names are at most 31 characters.
        let font = OpenXmlParts.cut(OpenXmlParts.clean(FontNames.family(s.font)).trimmedWS, 31)
        if !font.isEmpty {
            if fontKeys.insert(font.lowercased()).inserted { fonts.append((font, s.serif, s.mono)) }
            w.empty("w:rFonts", [("w:ascii", font), ("w:hAnsi", font), ("w:cs", font)])
        }
        if s.bold { w.empty("w:b") }
        if s.italic { w.empty("w:i") }
        if s.color & 0xFFFFFF != 0 { Self.val(w, "w:color", String(format: "%06X", s.color & 0xFFFFFF)) }
        let half = String(Int(clamp(bankers(s.size * 2), 2, 3276)))
        Self.val(w, "w:sz", half)
        Self.val(w, "w:szCs", half)
        w.end()
        // Tabs in the text become Word tabs.
        for (i, part) in text.split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { w.empty("w:tab") }
            if part.isEmpty { continue }
            w.start("w:t", [("xml:space", "preserve")])
            w.text(String(part))
            w.end()
        }
        w.end()
    }

    private func picture(_ w: XmlOut, _ pic: DocPicture, _ page: DocPage, _ section: Section, _ endsSection: Section?) {
        guard let rel = pic.image.ref else { return }
        let scale = min(1, min(section.textWidth / max(1, pic.box.width), (section.height - section.top - section.bottom) / max(1, pic.box.height)))
        let cx = pic.box.width * scale, cy = pic.box.height * scale
        w.start("w:p")
        let centered = page.content.width > 0 && abs(pic.box.centerX - page.content.centerX) <= max(6, 0.03 * page.content.width)
            && pic.box.width < 0.9 * page.content.width
        let indent = clamp(pic.box.x - section.contentLeft, 0, max(0, section.textWidth - cx))
        if centered || indent > 6 || endsSection != nil {
            w.start("w:pPr")
            if !centered && indent > 6 { w.empty("w:ind", [("w:left", OpenXmlParts.twips(indent))]) }
            if centered { Self.val(w, "w:jc", "center") }
            if let endsSection { sectionProperties(w, endsSection) }
            w.end()
        }
        inline(w, rel, cx, cy)
        w.end() // p
    }

    /// A run holding an inline picture of `cx` by `cy` points.
    private func inline(_ w: XmlOut, _ rel: String, _ cx: Double, _ cy: Double) {
        drawing += 1
        w.start("w:r")
        w.start("w:drawing")
        w.start("wp:inline", [("distT", "0"), ("distB", "0"), ("distL", "0"), ("distR", "0")])
        w.empty("wp:extent", [("cx", OpenXmlParts.emu(cx)), ("cy", OpenXmlParts.emu(cy))])
        w.empty("wp:docPr", [("id", String(drawing)), ("name", "Picture \(drawing)")])
        w.start("wp:cNvGraphicFramePr")
        w.empty("a:graphicFrameLocks", [("noChangeAspect", "1")])
        w.end()
        w.start("a:graphic")
        w.start("a:graphicData", [("uri", Self.picUri)])
        w.start("pic:pic")
        w.start("pic:nvPicPr")
        w.empty("pic:cNvPr", [("id", String(drawing)), ("name", "Picture \(drawing)")])
        w.empty("pic:cNvPicPr")
        w.end()
        w.start("pic:blipFill")
        w.empty("a:blip", [("r:embed", rel)])
        w.start("a:stretch")
        w.empty("a:fillRect")
        w.end()
        w.end()
        w.start("pic:spPr")
        w.start("a:xfrm")
        w.empty("a:off", [("x", "0"), ("y", "0")])
        w.empty("a:ext", [("cx", OpenXmlParts.emu(cx)), ("cy", OpenXmlParts.emu(cy))])
        w.end()
        w.start("a:prstGeom", [("prst", "rect")])
        w.empty("a:avLst")
        w.end()
        w.end()
        w.end() // pic
        w.end() // graphicData
        w.end() // graphic
        w.end() // inline
        w.end() // drawing
        w.end() // r
    }

    private func table(_ w: XmlOut, _ t: DocTable, _ section: Section) {
        let total = t.columnWidths.reduce(0, +)
        let scale = total > section.textWidth && total > 0 ? section.textWidth / total : 1
        let widths = t.columnWidths.map { max(12, $0 * scale) }
        let sum = widths.reduce(0, +)
        let indent = clamp(t.box.x - section.contentLeft, 0, max(0, section.textWidth - sum))
        w.start("w:tbl")
        w.start("w:tblPr")
        w.empty("w:tblW", [("w:w", OpenXmlParts.twips(sum)), ("w:type", "dxa")])
        if indent > 1 { w.empty("w:tblInd", [("w:w", OpenXmlParts.twips(indent)), ("w:type", "dxa")]) }
        w.start("w:tblBorders")
        for side in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            w.empty("w:" + side, [("w:val", t.ruled ? "single" : "none"), ("w:sz", t.ruled ? "4" : "0"), ("w:space", "0"), ("w:color", "auto")])
        }
        w.end()
        w.empty("w:tblLayout", [("w:type", "fixed")])
        // Narrow cell padding (Word's default is 5.4 pt a side), so tight PDF columns of numbers don't wrap digit by digit.
        w.start("w:tblCellMar")
        for side in ["left", "right"] {
            w.empty("w:" + side, [("w:w", OpenXmlParts.twips(clamp((widths.min() ?? 90) * 0.06, 1, 5.4))), ("w:type", "dxa")])
        }
        w.end()
        w.end() // tblPr
        w.start("w:tblGrid")
        for c in widths { w.empty("w:gridCol", [("w:w", OpenXmlParts.twips(c))]) }
        w.end()
        for (rowIndex, row) in t.rows.enumerated() {
            w.start("w:tr")
            if let heights = t.rowHeights, rowIndex < heights.count, heights[rowIndex] > 1 {
                // At least as tall as on the page (a form's empty boxes keep their room to write in).
                w.start("w:trPr")
                w.empty("w:trHeight", [("w:val", OpenXmlParts.twips(heights[rowIndex])), ("w:hRule", "atLeast")])
                w.end()
            }
            var col = 0
            for cell in row {
                let span = max(1, min(cell.colSpan, widths.count - col))
                let cw = widths.dropFirst(col).prefix(span).reduce(0, +)
                col += span
                w.start("w:tc")
                w.start("w:tcPr")
                w.empty("w:tcW", [("w:w", OpenXmlParts.twips(cw)), ("w:type", "dxa")])
                if span > 1 { Self.val(w, "w:gridSpan", String(span)) }
                w.end()
                if cell.paragraphs.isEmpty && cell.pictures.isEmpty { paragraph(w, nil, nil, cw, inCell: true) }
                // Text and pictures top to bottom; indents are from the cell's edge.
                let blocks = (cell.paragraphs.map(DocBlock.paragraph) + cell.pictures.map(DocBlock.picture)).sorted { $0.box.y < $1.box.y }
                for block in blocks {
                    switch block {
                    case .paragraph(let p): paragraph(w, p, nil, cw, inCell: true)
                    case .picture(let pic): if let rel = pic.image.ref { cellPicture(w, pic, rel, cw) }
                    case .table: break
                    }
                }
                w.end()
            }
            if col == 0 { // a row needs a cell
                w.start("w:tc")
                paragraph(w, nil, nil, 0, inCell: true)
                w.end()
            }
            w.end()
        }
        w.end()
    }

    /// A picture in a table cell: its own paragraph, centered when it sat in the middle, no wider than the cell.
    private func cellPicture(_ w: XmlOut, _ pic: DocPicture, _ rel: String, _ cellWidth: Double) {
        let scale = min(1, max(1, cellWidth - 10) / max(1, pic.box.width))
        w.start("w:p")
        w.start("w:pPr")
        w.empty("w:spacing", [("w:after", "0")])
        Self.val(w, "w:jc", "center")
        w.end()
        inline(w, rel, pic.box.width * scale, pic.box.height * scale)
        w.end()
    }

    /// A header or footer part: each row one paragraph with a centered tab in the middle and a right tab at the margin, so
    /// left, middle and right parts land where they were; the page number is Word's PAGE field.
    private func running(_ w: XmlOut, _ root: String, _ running: DocRunning, _ textWidth: Double) {
        w.start(root, Self.namespaces)
        for p in running.pictures {
            guard let ref = p.image.ref else { continue }
            let scale = min(1, textWidth / max(1, p.image.box.width))
            w.start("w:p")
            w.start("w:pPr")
            w.empty("w:spacing", [("w:after", "0")])
            if p.zone != .left { Self.val(w, "w:jc", p.zone == .center ? "center" : "right") }
            w.end()
            inline(w, ref, p.image.box.width * scale, p.image.box.height * scale)
            w.end()
        }
        if running.rows.isEmpty && running.pictures.isEmpty { w.empty("w:p") } // an empty one
        for row in running.rows {
            w.start("w:p")
            w.start("w:pPr")
            w.start("w:tabs")
            for (kind, pos) in [("center", textWidth / 2), ("right", textWidth)] {
                w.empty("w:tab", [("w:val", kind), ("w:pos", OpenXmlParts.twips(pos))])
            }
            w.end()
            w.empty("w:spacing", [("w:after", "0")])
            w.end()
            var at = 0
            var any = false
            for part in row.parts {
                let target = part.zone == .center ? 1 : part.zone == .right ? 2 : 0
                if any && target <= at { run(w, part.span.with(text: " ")) } // another part in the same place
                any = true
                while at < target {
                    w.start("w:r")
                    w.empty("w:tab")
                    w.end()
                    at += 1
                }
                let pieces = part.span.text.split(separator: Character(DocLayout.pageField), omittingEmptySubsequences: false)
                for (i, piece) in pieces.enumerated() {
                    if i > 0 {
                        w.start("w:fldSimple", [("w:instr", " PAGE ")])
                        run(w, part.span.with(text: "1"))
                        w.end()
                    }
                    if !piece.isEmpty { run(w, part.span.with(text: String(piece))) }
                }
            }
            w.end()
        }
        w.end()
    }

    // ---- styles, numbering, settings ----

    private static func styles(_ w: XmlOut, _ body: Double) {
        w.start("w:styles", [namespaces[0]])
        w.start("w:docDefaults")
        w.start("w:rPrDefault")
        w.start("w:rPr")
        w.empty("w:rFonts", ["ascii", "hAnsi", "eastAsia", "cs"].map { ("w:" + $0, "Calibri") })
        let half = String(Int(clamp(bankers(body * 2), 2, 3276)))
        val(w, "w:sz", half)
        val(w, "w:szCs", half)
        w.end()
        w.end()
        w.start("w:pPrDefault")
        w.start("w:pPr")
        w.empty("w:spacing", [("w:after", "120"), ("w:line", "240"), ("w:lineRule", "auto")])
        w.end()
        w.end()
        w.end() // docDefaults

        style(w, "paragraph", "Normal", "Normal", isDefault: true)
        for level in 1...6 {
            style(w, "paragraph", "Heading\(level)", "heading \(level)", basedOn: "Normal", next: "Normal", priority: 9, pPr: {
                w.empty("w:keepNext")
                w.empty("w:spacing", [("w:before", level <= 2 ? "240" : "160"), ("w:after", "120")])
                val(w, "w:outlineLvl", String(level - 1))
            })
        }
        style(w, "paragraph", "ListParagraph", "List Paragraph", basedOn: "Normal", priority: 34, pPr: {
            w.empty("w:ind", [("w:left", "720")])
            w.empty("w:contextualSpacing")
        })
        style(w, "table", "TableNormal", "Normal Table", isDefault: true, priority: 99, tblPr: {
            w.empty("w:tblInd", [("w:w", "0"), ("w:type", "dxa")])
            w.start("w:tblCellMar")
            for (side, v) in [("top", "0"), ("left", "108"), ("bottom", "0"), ("right", "108")] {
                w.empty("w:" + side, [("w:w", v), ("w:type", "dxa")])
            }
            w.end()
        })
        w.end()
    }

    private static func style(_ w: XmlOut, _ type: String, _ id: String, _ name: String, isDefault: Bool = false, basedOn: String? = nil,
                              next: String? = nil, priority: Int? = nil, pPr: (() -> Void)? = nil, tblPr: (() -> Void)? = nil) {
        var a = [("w:type", type)]
        if isDefault { a.append(("w:default", "1")) }
        a.append(("w:styleId", id))
        w.start("w:style", a)
        val(w, "w:name", name)
        if let basedOn { val(w, "w:basedOn", basedOn) }
        if let next { val(w, "w:next", next) }
        if let priority { val(w, "w:uiPriority", String(priority)) }
        if type == "paragraph" { w.empty("w:qFormat") }
        if let pPr {
            w.start("w:pPr")
            pPr()
            w.end()
        }
        if let tblPr {
            w.start("w:tblPr")
            tblPr()
            w.end()
        }
        w.end()
    }

    private static func numbering(_ w: XmlOut) {
        w.start("w:numbering", [namespaces[0]])
        w.start("w:abstractNum", [("w:abstractNumId", "0")])
        val(w, "w:multiLevelType", "singleLevel")
        w.start("w:lvl", [("w:ilvl", "0")])
        val(w, "w:start", "1")
        val(w, "w:numFmt", "bullet")
        val(w, "w:lvlText", "\u{2022}")
        val(w, "w:lvlJc", "left")
        w.start("w:pPr")
        w.empty("w:ind", [("w:left", "360"), ("w:hanging", "360")])
        w.end()
        w.end() // lvl
        w.end() // abstractNum
        w.start("w:num", [("w:numId", "1")])
        val(w, "w:abstractNumId", "0")
        w.end()
        w.end()
    }

    /// The fonts the document names, each with its kind (serif, sans serif, monospaced) and a typical shape, so Word
    /// shows a PDF's own fonts it can't find (often embedded subsets) with a like font rather than any.
    private func fontTable(_ w: XmlOut) {
        w.start("w:fonts", [Self.namespaces[0]])
        for (name, serif, mono) in fonts {
            w.start("w:font", [("w:name", name)])
            // PANOSE of Courier New, Times New Roman and Arial.
            Self.val(w, "w:panose1", mono ? "02070309020205020404" : serif ? "02020603050405020304" : "020B0604020202020204")
            Self.val(w, "w:family", mono ? "modern" : serif ? "roman" : "swiss")
            Self.val(w, "w:pitch", mono ? "fixed" : "variable")
            w.end()
        }
        w.end()
    }

    private static func settings(_ w: XmlOut) {
        w.start("w:settings", [namespaces[0]])
        val(w, "w:defaultTabStop", "720")
        w.start("w:compat")
        // Word 2013+ layout, so the file doesn't open in compatibility mode.
        w.empty("w:compatSetting", [("w:name", "compatibilityMode"), ("w:uri", "http://schemas.microsoft.com/office/word"), ("w:val", "15")])
        w.end()
        w.end()
    }
}
