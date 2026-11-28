import Foundation
import PrintCore

/// True redaction (the Windows app's `Redaction`): every page with areas to redact is drawn (with its annotations and
/// form fields) as a picture, the areas are painted solid black in the pixels, and the page's content is replaced by that
/// picture. Nothing from the original page (text, vector art, images, annotations, form widgets, thumbnails, alternate
/// text in the structure tree) survives, so the redacted content can't be recovered or copied. Redacted pages become
/// pictures: their text is no longer selectable or searchable (the app lays recognized text back over them). A form
/// field an area touches is emptied on every page (its value would otherwise survive in its other widgets). Tagged PDFs
/// lose the redacted page's part of the structure tree. Other pages and the document metadata are left untouched.
public enum Redaction {
    /// A redacted document (`applyWithText`). `textSkipped`: its redacted pages were left without text (the reading was
    /// cancelled); `recognized`: the words laid back over them.
    public struct RedactedData: Equatable, Sendable {
        public var data: [UInt8]
        public var textSkipped: Bool
        public var recognized: Int
        /// What is black on each redacted page (`RedactedPages.blacked`).
        public var blacked: [Int: [RectD]] = [:]
        /// The words the redaction moved (`RedactedPages.moved`).
        public var moved = RedactionMoves.none
    }

    /// A redacted document (`redact`) and what is black on each redacted page, page space: the boxes where the lines laid
    /// out again put them, and the rest of each area as it was drawn; and the words kept on lines laid out again, and where
    /// they went.
    public struct RedactedPages: Equatable, Sendable {
        public var data: [UInt8]
        public var blacked: [Int: [RectD]]
        public var moved = RedactionMoves.none
    }

    /// How a pattern run's redacted pages are read back into text: cleaned, no suspect words (nobody reviews a redacted
    /// page's words), only the text written.
    public static let textBackOptions = RecognizeOptions(clean: true, checkWords: false)

    /// `apply`, then `textBack`: Apply Redactions, Redact by Pattern and Batch's Redact Patterns all redact through these
    /// two (the Windows Core's `ApplyWithText`). Without a recognizer, just `apply`.
    public static func applyWithText(_ data: [UInt8], _ password: String?, _ areasByPage: [Int: [RectD]], recognize: Recognizer?,
                                     language: String? = nil, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil,
                                     skipText: CancelToken? = nil) throws -> RedactedData {
        let redaction = try redact(data, password, areasByPage, cancel: cancel)
        let redacted = redaction.data
        var result = RedactedData(data: redacted, textSkipped: false, recognized: 0)
        if let recognize, redacted != data {
            result = try textBack(redacted, password, redaction.blacked, recognize, language: language, progress: progress, cancel: cancel, skipText: skipText)
        }
        result.blacked = redaction.blacked
        result.moved = redaction.moved
        return result
    }

    /// The redacted pages of `redacted`, pictures now, recognized and given their text again as an invisible text layer, so
    /// they stay searchable and selectable; what a black box covers isn't kept: a word that reaches into a blacked-out area
    /// at all goes (Windows drops only those mostly inside one), as its letters over the black would be text that doesn't
    /// show, and the recognizer may have guessed them. `progress`: (pages read, pages). `skipText` fired: the pages stay
    /// without text (`textSkipped`), the redaction is kept.
    public static func textBack(_ redacted: [UInt8], _ password: String?, _ areasByPage: [Int: [RectD]], _ recognize: Recognizer,
                                language: String? = nil, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil,
                                skipText: CancelToken? = nil) throws -> RedactedData {
        let pages = areasByPage.keys.sorted()
        do {
            // Each page watches both: Cancel ends the edit, skipping ends only the reading (`cancel` isn't caught below).
            let watched: Recognizer = { engine, page, token in
                try cancel.check()
                return try recognize(engine, page, token)
            }
            var (words, _) = try PageOcr.recognizePages(redacted, password, pages, watched, exclude: areasByPage, cancel: skipText ?? cancel, progress: progress)
            try cancel.check()
            for (page, list) in words {
                let black = (areasByPage[page] ?? []).map { $0.inflate(1) }
                words[page] = list.filter { w in !black.contains { !$0.intersect(w.rect).isEmpty } }
            }
            let n = words.values.reduce(0) { $0 + $1.count }
            if n == 0 { return RedactedData(data: redacted, textSkipped: false, recognized: 0) }
            try skipText.check()
            return RedactedData(data: try TextLayer.addInvisibleText(redacted, password, words, language: language), textSkipped: false, recognized: n)
        } catch is CancellationError where skipText?.isCancelled == true {
            // The whole edit cancelled (Batch's Stop, the same token): nothing is kept.
            if cancel?.isCancelled == true { throw CancellationError() }
            return RedactedData(data: redacted, textSkipped: true, recognized: 0)
        }
    }

    /// - Parameters:
    ///   - areasByPage: areas to black out per page index, in page space (points, displayed page's top-left).
    ///   - dpi: resolution of the replacement page pictures.
    /// - Returns: the same bytes when there is nothing to redact.
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func apply(_ data: [UInt8], _ password: String?, _ areasByPage: [Int: [RectD]], dpi: Double = 300,
                             cancel: CancelToken? = nil) throws -> [UInt8] {
        try redact(data, password, areasByPage, dpi: dpi, cancel: cancel).data
    }

    /// `apply`, with what is black afterwards. A line an area cuts, with some of its own text left beside the box, is laid
    /// out again (`RedactionLines`): its words keep their order and letters but not their places, and its box takes a
    /// width rounded to whole steps, so neither the box nor the text around it gives the removed width away. The boxes
    /// then sit where the layout put them, not where the areas were: `RedactedPages.blacked` says where (what the
    /// redaction check and the text laid back are told).
    public static func redact(_ data: [UInt8], _ password: String?, _ areasByPage: [Int: [RectD]], dpi: Double = 300,
                              cancel: CancelToken? = nil) throws -> RedactedPages {
        let pages = areasByPage.filter { $0.value.contains { !$0.isEmpty } }.sorted { $0.key < $1.key }
        if pages.isEmpty { return RedactedPages(data: data, blacked: [:]) }
        let dpi = min(max(dpi, 36), 1200)
        let cleared = try clearRedactedFields(data, password, pages)

        let engine = try PdfEngine.open(cleared, password: password)
        defer { engine.close() }
        var blackedByPage: [Int: [RectD]] = [:]
        var movedByPage: [Int: [RedactionMoves.Move]] = [:]
        let out = try PageEditor.edit(cleared, password, rewrite: true) { doc in
            let count = try doc.pageCount()
            for (index, areas) in pages {
                guard index >= 0 && index < count && index < engine.pageCount else { throw PdfEditError(loc("There is no page {0}.", CoreLanguage.number(index + 1))) }
                try cancel.check()
                let scale = dpi / 72
                let img = try engine.render(index, scale: scale, cancel: cancel)
                var rgb = img.pixels
                let drawn = areas.filter { !$0.isEmpty }
                for a in drawn {
                    let x0 = pixel((a.x * scale).rounded(.down), img.width, 0), x1 = pixel((a.right * scale).rounded(.up), img.width, img.width)
                    let y0 = pixel((a.y * scale).rounded(.down), img.height, 0), y1 = pixel((a.bottom * scale).rounded(.up), img.height, img.height)
                    if x1 <= x0 { continue }
                    for y in y0..<max(y0, y1) {
                        let row = (y * img.width + x0) * 3
                        for i in row..<row + (x1 - x0) * 3 { rgb[i] = 0 }
                    }
                }
                var moved: [RedactionMoves.Move] = []
                var laidOut: [RectD] = []
                let page = doc.page(index)
                let canvas = RedactionLines.Canvas(rgb, img.width, img.height, scale, drawn)
                let text = try engine.text(index, cache: false, cancel: cancel)
                blackedByPage[index] = relay(text, drawn, earlierBoxes(page), canvas, &moved, &laidOut)
                if !moved.isEmpty { movedByPage[index] = moved }
                replacePage(doc, page, img.width, img.height, canvas.rgb, laidOut)
            }
        }
        return RedactedPages(data: out, blacked: blackedByPage, moved: RedactionMoves(movedByPage))
    }

    /// The boxes an earlier redaction by Inkvolt PDF wrote into the page's picture (`laidOutBoxes`).
    private static func earlierBoxes(_ page: PObj) -> [RectD] {
        guard let xobjects = page.dict("Resources")?.dict("XObject") else { return [] }
        return Array(xobjects.keys.compactMap { xobjects.dict($0) }.flatMap(laidOutBoxes).prefix(maxLaidOut))
    }

    /// The lines the areas cut, laid out again in the page picture (`RedactionLines`); returns what is black: each line's
    /// boxes where they now are, the areas that are blocks as drawn, and what lines left in place keep. Each word and
    /// earlier box moved goes in `moved`; every box that gives no width away, in `laidOut` (a line left in place, because
    /// its space holds a rule or a picture, is left out, so the check reports it). What an area cutting lines laid out
    /// again holds outside their rows (between the lines of a tall area, past a line's end) becomes paper: the area is
    /// rows of lines.
    private static func relay(_ text: PageText, _ areas: [RectD], _ earlier: [RectD], _ canvas: RedactionLines.Canvas,
                              _ moved: inout [RedactionMoves.Move], _ laidOut: inout [RectD]) -> [RectD] {
        let scale = canvas.scale
        var blacked: [RectD] = []
        var rows: [RectD] = []
        var inPlaceRows: [RectD] = []
        var lineAreas = Set<RectD>()
        var inPlaceAreas = Set<RectD>()
        let lines = RedactionLines.find(text, areas, Double(canvas.width) / scale, Double(canvas.height) / scale) { band, vertical in
            darkRuns(canvas, band, vertical)
        }
        for line in lines {
            let r = RedactionLines.relay(canvas, line, RedactionLines.layout(line))
            blacked += r.boxes
            blacked += r.fixed.map(\.now)
            if r.rows.isEmpty { continue }
            let mine = line.areas.map(line.toPage)
            if !r.laidOut {
                inPlaceRows.append(r.rows)
                inPlaceAreas.formUnion(mine)
                continue
            }
            rows.append(r.rows)
            lineAreas.formUnion(mine)
            laidOut += r.boxes
            // An earlier box that was Inkvolt's is still one that gives nothing away; another tool's is still reported.
            laidOut += r.fixed.filter { f in earlier.contains { !$0.intersect(f.was.inflate(-0.5)).isEmpty } }.map(\.now)
            moved += r.moved.map { RedactionMoves.Move(was: $0.was, dx: $0.dx, dy: $0.dy) }
        }
        for a in areas {
            let rest = subtract(subtract([a], rows), inPlaceRows)
            if lineAreas.contains(a) && !inPlaceAreas.contains(a) {
                // Rows of lines: what it holds between and beyond them is paper, so nothing there keeps its drawn edges.
                for piece in rest { paper(canvas, piece) }
                continue
            }
            blacked += rest
            if !inPlaceAreas.contains(a) { laidOut += rest } // a block, as drawn: its width is the area's, not its words'
        }
        return blacked
    }

    /// The rectangles less each of `cuts` (each split into at most four).
    static func subtract(_ rects: [RectD], _ cuts: [RectD]) -> [RectD] {
        var rects = rects
        for c in cuts {
            var next: [RectD] = []
            for r in rects {
                let i = r.intersect(c)
                if i.isEmpty {
                    next.append(r)
                    continue
                }
                if i.y > r.y { next.append(.fromEdges(r.x, r.y, r.right, i.y)) }
                if i.bottom < r.bottom { next.append(.fromEdges(r.x, i.bottom, r.right, r.bottom)) }
                if i.x > r.x { next.append(.fromEdges(r.x, i.y, i.x, i.bottom)) }
                if i.right < r.right { next.append(.fromEdges(i.right, i.y, r.right, i.bottom)) }
            }
            rects = next.filter { $0.width > 1e-6 && $0.height > 1e-6 }
        }
        return rects
    }

    /// Paints a rectangle (page space) with the paper beside it, row by row.
    private static func paper(_ canvas: RedactionLines.Canvas, _ r: RectD) {
        let x0 = pixel((r.x * canvas.scale).rounded(.down), canvas.width, 0), x1 = pixel((r.right * canvas.scale).rounded(.up), canvas.width, 0)
        let y0 = pixel((r.y * canvas.scale).rounded(.down), canvas.height, 0), y1 = pixel((r.bottom * canvas.scale).rounded(.up), canvas.height, 0)
        if x1 <= x0 || y1 <= y0 { return }
        for y in y0..<y1 {
            let (red, green, blue) = canvas.paperBeside(false, x0, x1, y)
            for x in x0..<x1 {
                let o = (y * canvas.width + x) * 3
                (canvas.rgb[o], canvas.rgb[o + 1], canvas.rgb[o + 2]) = (red, green, blue)
            }
        }
    }

    /// Boxes already on a line (an earlier redaction's, Inkvolt's or another tool's): along the line and up to three line
    /// heights beyond its ends, stretches at least 0.6 line heights long that are dark across the middle half of its band
    /// in the page as it was (line space).
    private static func darkRuns(_ canvas: RedactionLines.Canvas, _ band: RectD, _ vertical: Bool) -> [(x: Double, right: Double)] {
        let s = canvas.scale
        let along = vertical ? canvas.height : canvas.width
        let across = vertical ? canvas.width : canvas.height
        let h = band.height
        func clamp(_ v: Double, _ hi: Int) -> Int { pixel((v * s).rounded(.toNearestOrEven), hi, 0) }
        let a0 = clamp(band.x - 3 * h, along), a1 = clamp(band.right + 3 * h, along)
        let c0 = clamp(band.y + h / 4, across), c1 = max(clamp(band.bottom - h / 4, across), c0 + 1)
        if c1 > across { return [] }
        func dark(_ a: Int) -> Bool {
            var n = 0
            for c in c0..<c1 {
                let o = vertical ? (a * canvas.width + c) * 3 : (c * canvas.width + a) * 3
                if Int(canvas.before[o]) * 30 + Int(canvas.before[o + 1]) * 59 + Int(canvas.before[o + 2]) * 11 < 70 * 100 { n += 1 }
            }
            return Double(n) >= 0.95 * Double(c1 - c0)
        }
        var runs: [(x: Double, right: Double)] = []
        var a = a0
        while a < a1 {
            if !dark(a) {
                a += 1
                continue
            }
            var end = a
            while end < a1 && dark(end) { end += 1 }
            if Double(end - a) / s >= 0.6 * h { runs.append((Double(a) / s, Double(end) / s)) }
            a = end
        }
        return runs
    }

    /// Where Inkvolt PDF writes, in a redacted page's picture, the boxes of the lines it laid out again (x y w h, page space).
    private static let laidOutKey = "PdLaidOut"

    /// Most boxes read back from `laidOutKey`.
    private static let maxLaidOut = 1000

    /// The boxes a redacted page's picture says were laid out with their lines (`RedactionLines`): the redaction check
    /// doesn't count the text beside them as giving a width away.
    static func laidOutBoxes(_ image: PObj) -> [RectD] {
        guard let a = image.array(laidOutKey) else { return [] }
        var out: [RectD] = []
        var i = 0
        let n = min(a.count, 4 * maxLaidOut)
        while i + 3 < n {
            let r = RectD(a.num(i), a.num(i + 1), a.num(i + 2), a.num(i + 3))
            if !r.isEmpty && (r.x + r.y + r.width + r.height).isFinite { out.append(r) }
            i += 4
        }
        return out
    }

    /// `v` as a pixel column or row within 0...`hi`, checked as a Double first (an area's edge can be anything); `nan` when
    /// it isn't a number, so such an area blacks out to the image's edge rather than not at all.
    private static func pixel(_ v: Double, _ hi: Int, _ nan: Int) -> Int { Int(exactly: min(max(v, 0), Double(hi))) ?? nan }

    /// A form field whose widget an area covers loses its value everywhere: its widgets on other pages would otherwise
    /// keep showing it (and /V would keep it in the file). Done first, so the drawn pages already show the field empty.
    private static func clearRedactedFields(_ data: [UInt8], _ password: String?, _ pages: [(key: Int, value: [RectD])]) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        let count = try doc.pageCount()
        var hit = Set<UInt>()
        for (index, areas) in pages where index >= 0 && index < count {
            let page = doc.page(index)
            for w in page.array("Annots")?.elements ?? [] where w.isDict {
                guard w.name("Subtype") == "Widget", let r = w.array("Rect") else { continue }
                let rect = PageBoxes.rectToPage(page, r)
                if areas.contains(where: { !$0.isEmpty && !$0.intersect(rect).isEmpty }) { hit.insert(w.identity) }
            }
        }
        guard !hit.isEmpty, try FormEditor.clearFields(doc, hit) else { return data }
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password, rewrite: true)
    }

    private static func replacePage(_ doc: MuDoc, _ page: PObj, _ width: Int, _ height: Int, _ rgb: [UInt8], _ laidOut: [RectD]) {
        var entries: [(String, PObj)] = [
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(width)), ("Height", doc.int(height)),
            ("ColorSpace", doc.name("DeviceRGB")), ("BitsPerComponent", doc.int(8)),
        ]
        if !laidOut.isEmpty {
            let numbers = laidOut.prefix(maxLaidOut).flatMap { [$0.x, $0.y, $0.width, $0.height] }
            entries.append((laidOutKey, doc.array(numbers.map { doc.real(($0 * 100).rounded(.toNearestOrEven) / 100) })))
        }
        let image = doc.addStream(rgb, dict: doc.dict(entries), deflate: true)

        // The picture is upright as displayed; map its unit square onto the (turned) visible box.
        let (dw, dh) = PageBoxes.displaySize(page)
        let o = PageBoxes.toPdf(page, 0, dh), u = PageBoxes.toPdf(page, dw, dh), v = PageBoxes.toPdf(page, 0, 0)
        let f = PdfNum.f
        let ops = "q \(f(u.x - o.x)) \(f(u.y - o.y)) \(f(v.x - o.x)) \(f(v.y - o.y)) \(f(o.x)) \(f(o.y)) cm /PdRedacted Do Q\n"
        let parentKeys = StructTree.parentKeys(page)
        page.set("Contents", doc.addStream(Array(ops.utf8), deflate: false))
        page.set("Resources", doc.dict([("XObject", doc.dict([("PdRedacted", image)]))]))

        var removed = Set<UInt>()
        if let annots = page.array("Annots") {
            let acro = doc.catalog.dict("AcroForm")
            var widgets = false
            for a in annots.elements where a.isDict {
                removed.insert(a.identity)
                if a.name("Subtype") != "Widget" { continue }
                removeWidget(acro, a, &removed)
                widgets = true
            }
            if let acro {
                // Fields dropped above must not stay reachable through the calculation order (with their /V)...
                if let co = acro.array("CO") {
                    for i in stride(from: co.count - 1, through: 0, by: -1) where co[i].map({ $0.isDict && removed.contains($0.identity) }) == true {
                        co.remove(at: i)
                    }
                }
                // ...and an XFA form keeps its own copy of every value (datasets): once a field went, AcroForm fields are
                // what remains. Comments and links alone leave the form (and its XFA) as it was.
                if widgets { acro.remove("XFA") }
            }
            // Annotations elsewhere pointing at removed ones (a popup's /Parent, a reply's /IRT) would keep them reachable.
            if let count = try? doc.pageCount() {
                for i in 0..<count {
                    let other = doc.page(i)
                    if other.identity == page.identity { continue }
                    for a in other.array("Annots")?.elements ?? [] where a.isDict {
                        for key in ["Parent", "IRT"] {
                            if let target = a.dict(key), removed.contains(target.identity) { a.remove(key) }
                        }
                    }
                }
            }
        }
        // What else a page can carry of its old content: thumbnail picture, application data (PieceInfo), separations,
        // article beads, actions, its XMP, and PDF 2.0 associated files (/AF: e.g. the source the page was made from).
        for key in ["Annots", "Thumb", "PieceInfo", "StructParents", "Group", "B", "Metadata", "SeparationInfo", "AA", "AF"] {
            page.remove(key)
        }
        scrubStructure(doc, page, removed)
        StructTree.prune(doc, gonePages: [page], goneKeys: parentKeys) { removed.contains($0.identity) }
    }

    /// Takes a widget out of the field tree, dropping fields left without widgets.
    static func removeWidget(_ acro: PObj?, _ widget: PObj, _ removed: inout Set<UInt>) {
        var node = widget
        for _ in 0..<64 {
            let parent = node.dict("Parent")
            guard let list = parent.map({ $0.array("Kids") }) ?? acro?.array("Fields") else { return }
            for i in stride(from: list.count - 1, through: 0, by: -1) where list[i]?.identity == node.identity && list[i]?.isDict == true {
                list.remove(at: i)
            }
            guard let parent, list.count == 0 else { return }
            node = parent
            removed.insert(node.identity)
        }
    }

    /// Drops what the structure tree keeps of the page: alternate/actual text (it can repeat the redacted words), and
    /// references to its annotations (OBJR, which would keep a widget and its value reachable) and to marked-content
    /// streams (MCR /Stm).
    private static func scrubStructure(_ doc: MuDoc, _ page: PObj, _ removed: Set<UInt>) {
        // Each dictionary and array once: a tree can share them (or loop), and walking every path can take forever.
        var seen = Set<UInt>()
        func visit(_ item: PObj?, _ onPage: Bool, _ depth: Int) {
            guard let item, depth <= 128 else { return }
            if item.isArray {
                guard seen.insert(item.identity).inserted else { return }
                for e in item.elements { visit(e, onPage, depth + 1) }
            } else if item.isDict {
                guard seen.insert(item.identity).inserted else { return }
                var onPage = onPage
                if item.has("Pg") { onPage = item["Pg"]?.identity == page.identity }
                if onPage { for key in ["Alt", "ActualText", "E", "Stm", "StmOwn"] { item.remove(key) } }
                if let obj = item.dict("Obj"), onPage || removed.contains(obj.identity) { item.remove("Obj") }
                visit(item["K"], onPage, depth + 1)
            }
        }
        visit(doc.catalog.dict("StructTreeRoot")?["K"], false, 0)
    }
}

/// Words a redaction moved along their lines (`RedactionLines`): where each was (page space) and how far it went.
public struct RedactionMoves: Equatable, Sendable {
    public struct Move: Equatable, Sendable {
        public var was: RectD
        public var dx: Double, dy: Double
    }

    private let moves: [Int: [Move]]

    init(_ moves: [Int: [Move]]) { self.moves = moves }

    public static let none = RedactionMoves([:])

    public var isEmpty: Bool { moves.isEmpty }

    /// Where a box of text that was kept on `page` (or an earlier redaction's box) is now (as it was, when it didn't move).
    public func now(_ page: Int, _ box: RectD) -> RectD {
        for m in moves[page] ?? [] where m.was.contains(box.centerX, box.centerY) {
            return RectD(box.x + m.dx, box.y + m.dy, box.width, box.height)
        }
        return box
    }
}

/// Keeps a tagged PDF's structure tree (/StructTreeRoot) consistent when pages lose their content (the Windows app's
/// `StructTree`): marked-content references (MCIDs, MCRs) and object references (OBJR) to those pages are removed,
/// structure elements left without content go too, and the /ParentTree and /IDTree entries that pointed at them are
/// dropped. Nothing in the tree then leads to the removed content, so saving no longer carries it along.
enum StructTree {
    private static let maxDepth = 256

    /// The /ParentTree keys a page uses: its /StructParents and its annotations' /StructParent.
    static func parentKeys(_ page: PObj) -> [Int] {
        var keys: [Int] = []
        if let k = page.int("StructParents") { keys.append(k) }
        for a in page.array("Annots")?.elements ?? [] where a.isDict {
            if let k = a.int("StructParent") { keys.append(k) }
        }
        return keys
    }

    /// - Parameters:
    ///   - gonePages: pages whose content no longer exists.
    ///   - goneKeys: the `parentKeys` of those pages, collected before they were changed.
    ///   - objectGone: objects (annotations) that were removed; OBJRs to them are dropped.
    static func prune(_ doc: MuDoc, gonePages: [PObj], goneKeys: [Int], objectGone: ((PObj) -> Bool)? = nil) {
        guard let root = doc.catalog.dict("StructTreeRoot") else { return }
        var live = Set<UInt>(), liveIds = Set<Int>()
        for i in 0..<((try? doc.pageCount()) ?? 0) {
            let p = doc.page(i)
            live.insert(p.identity)
            if p.isRef { liveIds.insert(p.num) }
        }
        let gone = Set(gonePages.map(\.identity))
        func pageGone(_ pg: PObj?) -> Bool {
            guard let pg, pg.isDict else { return false }
            if gone.contains(pg.identity) { return true }
            if live.contains(pg.identity) { return false }
            return !(pg.isRef && liveIds.contains(pg.num))
        }

        var removed = Set<UInt>()
        var seen = Set<UInt>()

        // Prunes the kids of a node; true when the node had content and has none left.
        func pruneKids(_ node: PObj, _ page: PObj?, _ depth: Int) -> Bool {
            guard let k = node["K"] else { return false }
            if k.isArray {
                if k.count == 0 { return false }
                for i in stride(from: k.count - 1, through: 0, by: -1) where !keep(k[i], page, depth + 1) { k.remove(at: i) }
                if k.count > 0 { return false }
            } else if keep(k, page, depth + 1) {
                return false
            }
            node.remove("K")
            return true
        }

        func keep(_ item: PObj?, _ page: PObj?, _ depth: Int) -> Bool {
            guard let item, depth <= maxDepth else { return true }
            if item.kind == .int { return !pageGone(page) }
            guard item.isDict else { return true }
            let type = item.name("Type")
            let pg = item.has("Pg") ? item["Pg"] : page
            if type == "MCR" { return !pageGone(pg) }
            if type == "OBJR" {
                if pageGone(pg) { return false }
                guard let obj = item.dict("Obj") else { return false }
                return !(objectGone?(obj) == true || (obj.has("P") && pageGone(obj["P"])))
            }
            if !seen.insert(item.identity).inserted { return !removed.contains(item.identity) }
            let empty = pruneKids(item, pg, depth)
            let ownGone = item.has("Pg") && pageGone(item["Pg"])
            if empty || (ownGone && !item.has("K")) {
                removed.insert(item.identity)
                // Still referenced elsewhere (an outline's /SE, a stale parent tree)? Then at least lead nowhere.
                item.remove("Pg")
                item.remove("K")
                return false
            }
            if ownGone { item.remove("Pg") } // its remaining content names its own pages
            return true
        }

        _ = pruneKids(root, nil, 0)

        let keys = Set(goneKeys)
        editTree(root.dict("ParentTree"), "Nums") { key, value in
            if let n = key.int, keys.contains(n) { return false }
            guard let value else { return true }
            if value.isArray {
                var any = false
                for i in 0..<value.count {
                    if let e = value[i], e.isDict, removed.contains(e.identity) {
                        value.replace(at: i, with: doc.null)
                    } else if let e = value[i], e.kind != .null {
                        any = true
                    }
                }
                return any
            }
            if value.isDict { return !removed.contains(value.identity) }
            return true
        }
        editTree(root.dict("IDTree"), "Names") { _, value in
            guard let value, value.isDict else { return true }
            return !removed.contains(value.identity)
        }
    }

    /// Removes the key/value pairs of a name or number tree that `keep` rejects.
    private static func editTree(_ node: PObj?, _ pairsKey: String, _ depth: Int = 0, _ keep: (PObj, PObj?) -> Bool) {
        guard let node, depth <= 64 else { return }
        if let pairs = node.array(pairsKey) {
            for i in stride(from: (pairs.count & ~1) - 2, through: 0, by: -2) {
                guard let key = pairs[i] else { continue }
                if !keep(key, pairs[i + 1]) {
                    pairs.remove(at: i + 1)
                    pairs.remove(at: i)
                }
            }
        }
        for kid in node.array("Kids")?.elements ?? [] where kid.isDict { editTree(kid, pairsKey, depth + 1, keep) }
    }
}
