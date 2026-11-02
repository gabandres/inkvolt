import CryptoKit
import Foundation

/// Writes a PowerPoint presentation (.pptx, Office Open XML) from laid-out pages, one slide per page (the Windows app's
/// `PptxWriter`): each paragraph an editable text box where the page has it (a list one box with real bullets), the page's
/// first top heading the slide's title, tables as tables, pictures as pictures, simple shapes as shapes. A slide's order is
/// its reading order, shapes and pictures that lie under something first. A presentation has one slide size: the size most
/// pages have. Pages of another size are shrunk to fit it, type included, and centered. Pictures are stored as they are
/// added (`addImage`), so a long document's images needn't all be held in memory.
final class PptxWriter {
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let contentBase = "application/vnd.openxmlformats-officedocument.presentationml."

    // What PowerPoint allows for a slide: 1 to 56 inches.
    private static let minSlide = 72.0, maxSlide = 4032.0

    private let zip: ZipWriter
    private var byContent: [String: String] = [:] // SHA-256 of a picture -> its id
    private var targets: [String: String] = [:]   // id -> media part
    private var media = 0
    private var finished = false

    init(_ sink: ByteSink) { zip = ZipWriter(sink) }

    /// Stores a picture (PNG or JPEG bytes) and returns its id for `ExportImage.ref`. The same picture again (a logo on
    /// every page) is stored once and gets the same id.
    func addImage(_ data: [UInt8], _ ext: String) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        if let known = byContent[hash] { return known }
        media += 1
        let kind = ext == "jpeg" ? "jpeg" : "png"
        try zip.add("ppt/media/image\(media).\(kind)", data, compress: false) // already compressed
        let id = "rIdImg\(media)"
        targets[id] = "../media/image\(media).\(kind)"
        byContent[hash] = id
        return id
    }

    func finish(_ slides: [SlidePage], _ title: String?, _ language: String?) throws {
        precondition(!finished, "Already finished.")
        finished = true
        let lang = AccessibilityCheck.isLanguage(language) ? language : nil
        let (width, height) = Self.slideSize(slides)
        var parts: [(part: String, type: String)] = [
            ("/ppt/presentation.xml", Self.contentBase + "presentation.main+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", Self.contentBase + "slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", Self.contentBase + "slideLayout+xml"),
            ("/ppt/slideLayouts/slideLayout2.xml", Self.contentBase + "slideLayout+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
        ]
        for (i, page) in slides.enumerated() {
            let slide = SlideXml(page, width, height, lang)
            try entry("ppt/slides/slide\(i + 1).xml", slide.write)
            var seen = Set<String>()
            let pictures = slide.pictures.filter { seen.insert($0).inserted }
            try entry("ppt/slides/_rels/slide\(i + 1).xml.rels") { w in
                OpenXmlParts.relationships(w, [("rIdLayout", Self.relBase + "slideLayout", "../slideLayouts/slideLayout\(slide.hasTitle ? 1 : 2).xml")]
                    + pictures.map { ($0, Self.relBase + "image", self.targets[$0] ?? "") })
            }
            parts.append(("/ppt/slides/slide\(i + 1).xml", Self.contentBase + "slide+xml"))
        }
        try entry("ppt/presentation.xml") { Self.presentation($0, slides.count, width, height) }
        try entry("ppt/_rels/presentation.xml.rels") { w in
            OpenXmlParts.relationships(w, [
                ("rIdMaster", Self.relBase + "slideMaster", "slideMasters/slideMaster1.xml"),
                ("rIdTheme", Self.relBase + "theme", "theme/theme1.xml"),
            ] + (0..<slides.count).map { ("rIdSlide\($0 + 1)", Self.relBase + "slide", "slides/slide\($0 + 1).xml") })
        }
        try raw("ppt/theme/theme1.xml", Self.theme)
        try raw("ppt/slideMasters/slideMaster1.xml", Self.master(width, height))
        try entry("ppt/slideMasters/_rels/slideMaster1.xml.rels") { w in
            OpenXmlParts.relationships(w, [
                ("rId1", Self.relBase + "slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", Self.relBase + "slideLayout", "../slideLayouts/slideLayout2.xml"),
                ("rId3", Self.relBase + "theme", "../theme/theme1.xml"),
            ])
        }
        try raw("ppt/slideLayouts/slideLayout1.xml", Self.layout("titleOnly", "Title Only", Self.titleSp("<p:spPr/>")))
        try raw("ppt/slideLayouts/slideLayout2.xml", Self.layout("blank", "Blank", ""))
        for i in 1...2 {
            try entry("ppt/slideLayouts/_rels/slideLayout\(i).xml.rels") {
                OpenXmlParts.relationships($0, [("rId1", Self.relBase + "slideMaster", "../slideMasters/slideMaster1.xml")])
            }
        }
        try entry("_rels/.rels") { w in
            OpenXmlParts.relationships(w, [
                ("rId1", Self.relBase + "officeDocument", "ppt/presentation.xml"),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                ("rId3", Self.relBase + "extended-properties", "docProps/app.xml"),
            ])
        }
        try entry("docProps/core.xml") { OpenXmlParts.coreProperties($0, title) }
        try entry("docProps/app.xml", OpenXmlParts.appProperties)
        try entry("[Content_Types].xml") { OpenXmlParts.contentTypes($0, parts) }
        try zip.finish()
    }

    private func entry(_ name: String, _ write: (XmlOut) -> Void) throws { try OpenXmlParts.entry(zip, name, write) }

    private func raw(_ name: String, _ xml: String) throws { try zip.add(name, Array(xml.utf8), compress: true) }

    /// The size most pages have (the first such, when tied), within what PowerPoint allows.
    private static func slideSize(_ slides: [SlidePage]) -> (width: Double, height: Double) {
        if slides.isEmpty { return (612, 792) }
        var order: [String] = []
        var groups: [String: (count: Int, layout: DocPage)] = [:]
        for s in slides {
            let key = "\(bankers(s.layout.width))x\(bankers(s.layout.height))"
            if let g = groups[key] {
                groups[key] = (g.count + 1, g.layout)
            } else {
                groups[key] = (1, s.layout)
                order.append(key)
            }
        }
        // The most pages; a tie goes to the size seen first.
        var best = order[0]
        for key in order where groups[key]!.count > groups[best]!.count { best = key }
        let common = groups[best]!.layout
        let fit = min(1, maxSlide / max(common.width, common.height))
        return (min(max(common.width * fit, minSlide), maxSlide), min(max(common.height * fit, minSlide), maxSlide))
    }

    static func emu(_ pt: Double) -> String { OpenXmlParts.emu(pt) }

    private static func presentation(_ w: XmlOut, _ slides: Int, _ width: Double, _ height: Double) {
        w.start("p:presentation", [("xmlns:p", p), ("xmlns:a", a), ("xmlns:r", r)])
        w.start("p:sldMasterIdLst")
        w.empty("p:sldMasterId", [("id", "2147483648"), ("r:id", "rIdMaster")])
        w.end()
        if slides > 0 {
            w.start("p:sldIdLst")
            for i in 1...slides { w.empty("p:sldId", [("id", String(255 + i)), ("r:id", "rIdSlide\(i)")]) }
            w.end()
        }
        w.empty("p:sldSz", [("cx", emu(width)), ("cy", emu(height))])
        w.empty("p:notesSz", [("cx", "6858000"), ("cy", "9144000")])
        w.end()
    }

    // ---- one slide ----

    /// One slide's XML, and which pictures it uses.
    private final class SlideXml {
        let page: SlidePage
        let slideWidth: Double, slideHeight: Double
        let lang: String?
        let scale: Double
        let title: DocParagraph?
        private var titleUsed = false
        private var id = 1
        private(set) var pictures: [String] = []

        var hasTitle: Bool { title != nil }

        init(_ page: SlidePage, _ slideWidth: Double, _ slideHeight: Double, _ lang: String?) {
            self.page = page
            self.slideWidth = slideWidth
            self.slideHeight = slideHeight
            self.lang = lang
            scale = min(1, min(slideWidth / max(1, page.layout.width), slideHeight / max(1, page.layout.height)))
            title = Self.titleOf(page)
        }

        private var dx: Double { (slideWidth - page.layout.width * scale) / 2 }
        private var dy: Double { (slideHeight - page.layout.height * scale) / 2 }

        /// The first of the page's top headings, a running head never.
        private static func titleOf(_ page: SlidePage) -> DocParagraph? {
            let headings = page.layout.paragraphs.filter { p in
                p.headingLevel > 0 && p.list == .none && p.box.height > 0 && !p.text.isBlank
                    && !page.running.contains { $0.contains(p.box.centerX, p.box.centerY) }
            }
            guard let top = headings.map(\.headingLevel).min() else { return nil }
            return headings.first { $0.headingLevel == top }
        }

        func write(_ w: XmlOut) {
            w.start("p:sld", [("xmlns:p", PptxWriter.p), ("xmlns:a", PptxWriter.a), ("xmlns:r", PptxWriter.r)])
            w.start("p:cSld")
            w.start("p:spTree")
            w.start("p:nvGrpSpPr")
            cNvPr(w, "")
            w.empty("p:cNvGrpSpPr")
            w.empty("p:nvPr")
            w.end()
            w.empty("p:grpSpPr")
            content(w)
            w.end()
            w.end()
            w.start("p:clrMapOvr")
            w.empty("a:masterClrMapping")
            w.end()
            w.end()
        }

        /// A slide's order is both what lies over what and the reading order: what must lie under something comes first.
        private func content(_ w: XmlOut) {
            // Sideways text has no height in the flow: here it is a turned box of its own, where the page has it.
            let blocks = page.layout.blocks.filter { $0.box.height > 0 }
            let words = blocks.filter { $0.paragraph != nil || $0.table != nil }.map(\.box)
            let ruled = blocks.compactMap(\.table).filter(\.ruled).map { $0.box.inflate(2) }
            func inTable(_ s: ExportShape) -> Bool { s.fill == nil && ruled.contains { $0.contains(s.box.centerX, s.box.centerY) } }
            let shapes = page.source.shapes.filter { !inTable($0) }
            let outlines = shapes.filter { $0.fill == nil }
            let covering = words + outlines.map(\.box)
            func isUnder(_ p: DocPicture) -> Bool { covering.contains { !$0.intersect(p.box).isEmpty } }

            for s in shapes where s.fill != nil { shape(w, s) }
            let under = blocks.compactMap(\.picture).filter(isUnder)
            for p in under { picture(w, p.image, p.box) }
            for s in outlines { shape(w, s) }
            var b = 0
            while b < blocks.count {
                switch blocks[b] {
                case .paragraph(let p) where p.list != .none:
                    var items: [DocParagraph] = []
                    while b < blocks.count, let item = blocks[b].paragraph, item.list != .none {
                        items.append(item)
                        b += 1
                    }
                    b -= 1
                    textBox(w, items)
                case .paragraph(let p):
                    if !p.text.isBlank { textBox(w, [p]) }
                case .table(let t):
                    table(w, t)
                    for cell in t.rows.joined() {
                        for pic in cell.pictures { picture(w, pic.image, pic.box) }
                    }
                case .picture(let pic):
                    if !under.contains(pic) { picture(w, pic.image, pic.box) }
                }
                b += 1
            }
            for line in page.source.lines where line.sideways && !line.text.isBlank { turned(w, line) }
        }

        private func x(_ v: Double) -> String { PptxWriter.emu(v * scale + dx) }
        private func y(_ v: Double) -> String { PptxWriter.emu(v * scale + dy) }
        private func len(_ d: Double) -> String { PptxWriter.emu(max(0, d) * scale) }

        private func cNvPr(_ w: XmlOut, _ name: String, _ description: String? = nil) {
            w.start("p:cNvPr", [("id", String(id)), ("name", name.isEmpty ? "" : "\(name) \(id)")])
            id += 1
            if let description, !description.isBlank {
                w.attr("descr", OpenXmlParts.clean(description).replacingOccurrences(of: "\t", with: " "))
            }
            w.end()
        }

        /// An a:xfrm or p:xfrm. `box`: where it is on the page, unturned.
        private func xfrm(_ w: XmlOut, _ box: RectD, _ ns: String = "a", quarterTurns: Int = 0) {
            w.start(ns + ":xfrm")
            if quarterTurns != 0 { w.attr("rot", String(quarterTurns * 5_400_000)) }
            w.empty("a:off", [("x", x(box.x)), ("y", y(box.y))])
            w.empty("a:ext", [("cx", len(box.width)), ("cy", len(box.height))])
            w.end()
        }

        private static func geometry(_ w: XmlOut, _ preset: String) {
            w.start("a:prstGeom", [("prst", preset)])
            w.empty("a:avLst")
            w.end()
        }

        private static func solidFill(_ w: XmlOut, _ color: UInt32) {
            w.start("a:solidFill")
            w.empty("a:srgbClr", [("val", String(format: "%06X", color & 0xFFFFFF))])
            w.end()
        }

        private func ln(_ w: XmlOut, _ color: UInt32, _ width: Double) {
            w.start("a:ln", [("w", PptxWriter.emu(max(0.25, width * scale)))])
            Self.solidFill(w, color)
            w.end()
        }

        // ---- shapes and pictures ----

        private func shape(_ w: XmlOut, _ s: ExportShape) {
            if s.kind == .line {
                // Along the middle of a rule, as wide as it is thick.
                let horizontal = s.box.width >= s.box.height
                let line = horizontal ? RectD(s.box.x, s.box.centerY, s.box.width, 0) : RectD(s.box.centerX, s.box.y, 0, s.box.height)
                w.start("p:cxnSp")
                w.start("p:nvCxnSpPr")
                cNvPr(w, "Line")
                w.empty("p:cNvCxnSpPr")
                w.empty("p:nvPr")
                w.end()
                w.start("p:spPr")
                xfrm(w, line)
                Self.geometry(w, "line")
                ln(w, s.stroke ?? 0, s.strokeWidth)
                w.end()
                w.end()
                return
            }
            w.start("p:sp")
            w.start("p:nvSpPr")
            cNvPr(w, s.kind == .ellipse ? "Ellipse" : "Rectangle")
            w.empty("p:cNvSpPr")
            w.empty("p:nvPr")
            w.end()
            w.start("p:spPr")
            xfrm(w, s.box)
            Self.geometry(w, s.kind == .ellipse ? "ellipse" : "rect")
            if let fill = s.fill { Self.solidFill(w, fill) } else { w.empty("a:noFill") }
            w.start("a:ln")
            if let stroke = s.stroke {
                w.attr("w", PptxWriter.emu(max(0.25, s.strokeWidth * scale)))
                Self.solidFill(w, stroke)
            } else {
                w.empty("a:noFill")
            }
            w.end()
            w.end()
            w.end()
        }

        private func picture(_ w: XmlOut, _ image: ExportImage, _ box: RectD) {
            guard let rel = image.ref else { return }
            pictures.append(rel)
            w.start("p:pic")
            w.start("p:nvPicPr")
            cNvPr(w, "Picture", image.alt)
            w.start("p:cNvPicPr")
            w.empty("a:picLocks", [("noChangeAspect", "1")])
            w.end()
            w.empty("p:nvPr")
            w.end()
            w.start("p:blipFill")
            w.empty("a:blip", [("r:embed", rel)])
            w.start("a:stretch")
            w.empty("a:fillRect")
            w.end()
            w.end()
            w.start("p:spPr")
            // On a page turned upright a picture keeps its pixels: turned back here, it stands as the page shows it.
            let turn = ((4 - image.turn) % 4 + 4) % 4
            xfrm(w, turn % 2 == 1 ? RectD(box.centerX - box.height / 2, box.centerY - box.width / 2, box.height, box.width) : box, "a", quarterTurns: turn)
            Self.geometry(w, "rect")
            w.end()
            w.end()
        }

        // ---- text ----

        private func textBox(_ w: XmlOut, _ paragraphs: [DocParagraph]) {
            var isTitle = false
            if let title, !titleUsed, paragraphs.count == 1, paragraphs[0] == title {
                isTitle = true
                titleUsed = true
            }
            var box = paragraphs.dropFirst().reduce(paragraphs[0].box) { $0.union($1.box) }
            // One line stays one line whatever font PowerPoint has. Longer ones wrap: a little room for a font that runs wider.
            let oneLine = paragraphs.allSatisfy { $0.lineCount <= 1 && !$0.text.contains("\n") }
            if !oneLine { box = RectD(box.x, box.y, box.width + paragraphs.map(\.size).max()! / 2, box.height) }
            openSp(w, isTitle ? "Title" : "Text", isTitle, box, oneLine)
            for (i, p) in paragraphs.enumerated() {
                paragraph(w, p, i == 0 ? 0 : max(0, p.box.y - paragraphs[i - 1].box.bottom), p.box.x - box.x)
            }
            Self.closeSp(w)
        }

        private func openSp(_ w: XmlOut, _ name: String, _ isTitle: Bool, _ box: RectD, _ oneLine: Bool, quarterTurns: Int = 0) {
            w.start("p:sp")
            w.start("p:nvSpPr")
            cNvPr(w, name)
            w.start("p:cNvSpPr")
            if isTitle { w.empty("a:spLocks", [("noGrp", "1")]) } else { w.attr("txBox", "1") }
            w.end()
            w.start("p:nvPr")
            if isTitle { w.empty("p:ph", [("type", "title")]) }
            w.end()
            w.end()
            w.start("p:spPr")
            xfrm(w, box, "a", quarterTurns: quarterTurns)
            Self.geometry(w, "rect")
            w.empty("a:noFill")
            w.end()
            w.start("p:txBody")
            w.start("a:bodyPr", [("wrap", oneLine ? "none" : "square")])
            for inset in ["lIns", "tIns", "rIns", "bIns"] { w.attr(inset, "0") }
            w.attr("rtlCol", "0")
            w.attr("anchor", "t")
            w.empty("a:noAutofit")
            w.end()
            w.empty("a:lstStyle")
        }

        private static func closeSp(_ w: XmlOut) {
            w.end()
            w.end()
        }

        /// A line reading sideways: its box, unturned about its center, is as long as the line.
        private func turned(_ w: XmlOut, _ line: ExportLine) {
            let b = line.box
            let turn = line.reads
            let box = turn % 2 == 1 ? RectD(b.centerX - b.height / 2, b.centerY - b.width / 2, b.height, b.width) : b
            openSp(w, "Text", false, box, true, quarterTurns: turn)
            w.start("a:p")
            for s in line.spans { run(w, s) }
            w.end()
            Self.closeSp(w)
        }

        /// `left`: how far the paragraph sits from the box's left edge.
        private func paragraph(_ w: XmlOut, _ p: DocParagraph, _ spaceBefore: Double, _ left: Double, inCell: Bool = false) {
            w.start("a:p")
            w.start("a:pPr")
            // The marker hangs 18 pt to the left of the text, as the Word export's lists do.
            let hang = p.list != .none ? 18 : p.firstLine < 0 ? -p.firstLine : 0
            let first = p.list != .none ? -18 : p.firstLine
            let margin = max(0, left) + hang
            if margin > 0 { w.attr("marL", PptxWriter.emu(margin * scale)) }
            if abs(first) > 0.01 { w.attr("indent", String(Int(bankers(first * scale * 12700)))) }
            w.attr("algn", p.align == .center ? "ctr" : p.align == .right ? "r" : "l")
            if p.lineCount > 1 && p.linePitch > 0 {
                w.start("a:lnSpc")
                Self.spcPts(w, p.linePitch * scale)
                w.end()
            }
            w.start("a:spcBef")
            Self.spcPts(w, spaceBefore * scale)
            w.end()
            if p.list == .bullet {
                w.empty("a:buFont", [("typeface", "Arial")])
                w.empty("a:buChar", [("char", "\u{2022}")])
            } else {
                w.empty("a:buNone")
            }
            if !p.tabs.isEmpty && !inCell { tabs(w, p) }
            w.end()
            for s in p.runs { run(w, s) }
            w.end()
        }

        /// Tab stops, measured from the box. PowerPoint's tabs have no leaders: the dots of a contents page aren't shown.
        private func tabs(_ w: XmlOut, _ p: DocParagraph) {
            let from = p.indent + min(0, p.firstLine)
            let stops = p.tabs.map { (pos: $0.position - from, right: $0.right) }.filter { $0.pos > 0 }.prefix(32)
            if stops.isEmpty { return }
            w.start("a:tabLst")
            for stop in stops { w.empty("a:tab", [("pos", PptxWriter.emu(stop.pos * scale)), ("algn", stop.right ? "r" : "l")]) }
            w.end()
        }

        private static func spcPts(_ w: XmlOut, _ pt: Double) {
            w.empty("a:spcPts", [("val", String(min(max(Int(bankers(pt * 100)), 0), 158_400)))])
        }

        private func run(_ w: XmlOut, _ s: ExportSpan) {
            let text = OpenXmlParts.clean(s.text)
            if text.isEmpty { return }
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    w.start("a:br")
                    runProperties(w, s)
                    w.end()
                }
                if part.isEmpty { continue }
                w.start("a:r")
                runProperties(w, s)
                w.element("a:t", String(part))
                w.end()
            }
        }

        private func runProperties(_ w: XmlOut, _ s: ExportSpan) {
            w.start("a:rPr")
            if let lang { w.attr("lang", lang) }
            w.attr("sz", hundredths(s.size))
            w.attr("b", s.bold ? "1" : "0")
            w.attr("i", s.italic ? "1" : "0")
            Self.solidFill(w, s.color)
            let family = OpenXmlParts.clean(FontNames.family(s.font)).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            let font = OpenXmlParts.cut(family.trimmedWS, 31)
            if !font.isEmpty {
                for kind in ["a:latin", "a:cs"] {
                    // What kind of font it is: PowerPoint picks a like one when this one is missing.
                    w.empty(kind, [("typeface", font), ("pitchFamily", s.mono ? "49" : s.serif ? "18" : "34")])
                }
            }
            w.end()
        }

        private func hundredths(_ size: Double) -> String { String(min(max(Int(bankers(size * scale * 100)), 100), 400_000)) }

        // ---- tables ----

        private func table(_ w: XmlOut, _ t: DocTable) {
            let columns = max(t.columnWidths.count, t.rows.map { $0.reduce(0) { $0 + max(1, $1.colSpan) } }.max() ?? 0)
            if columns == 0 || t.rows.isEmpty { return }
            let widths = (0..<columns).map { $0 < t.columnWidths.count ? max(1, t.columnWidths[$0]) : 36.0 }
            let heights = (0..<t.rows.count).map { r -> Double in
                if let h = t.rowHeights, r < h.count { return max(1, h[r]) }
                return max(1, t.box.height / Double(t.rows.count))
            }
            w.start("p:graphicFrame")
            w.start("p:nvGraphicFramePr")
            cNvPr(w, "Table")
            w.start("p:cNvGraphicFramePr")
            w.empty("a:graphicFrameLocks", [("noGrp", "1")])
            w.end()
            w.empty("p:nvPr")
            w.end()
            xfrm(w, RectD(t.box.x, t.box.y, widths.reduce(0, +), heights.reduce(0, +)), "p")
            w.start("a:graphic")
            w.start("a:graphicData", [("uri", "http://schemas.openxmlformats.org/drawingml/2006/table")])
            w.start("a:tbl")
            w.empty("a:tblPr")
            w.start("a:tblGrid")
            for width in widths { w.empty("a:gridCol", [("w", len(width))]) }
            w.end()
            for (r, row) in t.rows.enumerated() {
                w.start("a:tr", [("h", len(heights[r]))])
                var at = 0
                for cell in row {
                    if at >= columns { break }
                    let span = min(max(1, cell.colSpan), columns - at)
                    self.cell(w, cell, span, t.ruled)
                    for _ in stride(from: 1, to: span, by: 1) { self.cell(w, nil, -1, t.ruled) }
                    at += span
                }
                while at < columns {
                    self.cell(w, nil, 1, t.ruled)
                    at += 1
                }
                w.end()
            }
            w.end()
            w.end()
            w.end()
            w.end()
        }

        /// `span`: columns it spans; -1: a column another cell spans over.
        private func cell(_ w: XmlOut, _ cell: DocCell?, _ span: Int, _ ruled: Bool) {
            w.start("a:tc")
            if span > 1 { w.attr("gridSpan", String(span)) }
            if span < 0 { w.attr("hMerge", "1") }
            w.start("a:txBody")
            w.empty("a:bodyPr")
            w.empty("a:lstStyle")
            let paragraphs = cell?.paragraphs.filter { !$0.text.isEmpty } ?? []
            if paragraphs.isEmpty {
                // Small, or an empty cell's default 18 pt would make its row taller.
                w.start("a:p")
                w.empty("a:endParaRPr", [("sz", "600")])
                w.end()
            }
            for p in paragraphs { paragraph(w, p, 0, 0, inCell: true) }
            w.end()
            w.start("a:tcPr")
            for margin in ["marL", "marR"] { w.attr(margin, PptxWriter.emu(2 * scale)) }
            for margin in ["marT", "marB"] { w.attr(margin, PptxWriter.emu(1 * scale)) }
            if ruled {
                for side in ["a:lnL", "a:lnR", "a:lnT", "a:lnB"] {
                    w.start(side, [("w", PptxWriter.emu(max(0.25, 0.75 * scale)))])
                    Self.solidFill(w, 0)
                    w.end()
                }
            }
            w.empty("a:noFill")
            w.end()
            w.end()
        }
    }

    // ---- the parts that are always the same ----

    private static let ns = "xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\""
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let treeStart = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"

    private static func titleSp(_ shapeProperties: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr>"
            + shapeProperties + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>"
    }

    private static func layout(_ type: String, _ name: String, _ shapes: String) -> String {
        "\(header)<p:sldLayout \(ns) type=\"\(type)\" preserve=\"1\"><p:cSld name=\"\(name)\">\(treeStart)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    }

    private static func master(_ width: Double, _ height: Double) -> String {
        let level = "<a:lvl1pPr marL=\"0\" indent=\"0\" algn=\"l\"><a:buNone/><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr>"
        let titleBox = "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(emu(width))\" cy=\"\(emu(min(72, height)))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
        return "\(header)<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>\(treeStart)\(titleSp(titleBox))</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>"
            + "<p:txStyles><p:titleStyle>\(level)</p:titleStyle><p:bodyStyle>\(level)</p:bodyStyle><p:otherStyle>\(level)</p:otherStyle></p:txStyles></p:sldMaster>"
    }

    private static let theme: String = {
        func color(_ name: String, _ rgb: String) -> String { "<a:\(name)><a:srgbClr val=\"\(rgb)\"/></a:\(name)>" }
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\">\(fill)</a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        let font = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        var s = "\(header)<a:theme xmlns:a=\"\(a)\" name=\"Inkvolt\"><a:themeElements><a:clrScheme name=\"Inkvolt\">"
        s += color("dk1", "000000") + color("lt1", "FFFFFF") + color("dk2", "44546A") + color("lt2", "E7E6E6")
        s += color("accent1", "4472C4") + color("accent2", "ED7D31") + color("accent3", "A5A5A5") + color("accent4", "FFC000")
        s += color("accent5", "5B9BD5") + color("accent6", "70AD47") + color("hlink", "0563C1") + color("folHlink", "954F72")
        s += "</a:clrScheme><a:fontScheme name=\"Inkvolt\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme>"
        s += "<a:fmtScheme name=\"Inkvolt\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
        s += "<a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        return s
    }()
}
