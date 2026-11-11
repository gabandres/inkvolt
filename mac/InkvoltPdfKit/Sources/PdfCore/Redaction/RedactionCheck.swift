import CryptoKit
import Foundation
import PrintCore

/// What `RedactionCheck` finds: something of what was redacted (or covered) that can still be recovered.
public enum RedactionLeak: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// Text still in the page under a box, a highlight or other cover, or drawn so it doesn't show (black on black, white
    /// on white): it can be selected, searched and copied.
    case coveredText
    /// A picture or drawing still under a dark box: taking the box away shows it.
    case coveredContent
    /// A redaction mark (a Redact annotation) that was never applied: what it marks is still there.
    case unappliedMark
    /// Text right beside a box keeps its original positions, so the width of what was removed can be measured.
    case glyphSpacing
    /// A redacted value is still in the text of a page.
    case pageText
    /// Text in a page's content that doesn't show: outside the page, in a hidden layer, clipped away, invisible.
    case hiddenText
    /// Hidden layers, hidden comments or hidden form fields: in the file, not shown.
    case hiddenContent
    /// A comment's text, author, subject or appearance.
    case annotation
    /// A form field's value, default, choices, tooltip or appearance (also an XFA form's copy of the values).
    case formField
    case bookmark
    /// Document properties (the Info dictionary) or XMP metadata.
    case metadata
    /// An attached file: its name, description or contents.
    case attachment
    /// The structure tree (tags): alternate text, actual text, titles.
    case structureTree
    /// An earlier version of the file, kept by an incremental save (signing, appending).
    case earlierRevision
    /// Other data in the file: objects nothing uses, scripts, bytes outside the objects.
    case fileData
    /// A redacted area that still shows content, or still holds the original picture unchanged.
    case areaNotRemoved

    public static func < (a: RedactionLeak, b: RedactionLeak) -> Bool { a.rawValue < b.rawValue }
}

/// How a finding can be fixed with what Inkvolt PDF already does.
public enum RedactionFix: Sendable, Equatable {
    case none
    /// Redact its area (`Redaction.apply`: the page becomes a picture).
    case redact
    /// Sanitize Document with `RedactionFinding.sanitize`.
    case sanitize
    /// Rewrite the file as a single version (earlier versions and unused objects go).
    case rewrite
}

/// One thing the check found.
public struct RedactionFinding: Equatable, Sendable {
    public var kind: RedactionLeak
    /// Where it is, in words ("Page 2", "Bookmark", "Earlier version 1 of the file").
    public var place: String
    /// What was found (the text, or what is wrong).
    public var text: String
    /// Its page (index), or -1.
    public var page = -1
    /// Its area on `page` (page space), when it has one: what a fix redacts. Outside the page (text that doesn't show):
    /// the redaction draws the page again as a picture, without it, and blacks out nothing.
    public var box = RectD.zero
    /// The kind of content Sanitize Document removes it with.
    public var sanitize: SanitizeItem?
    /// Rewriting the file as a single version removes it.
    public var rewrite = false

    public init(_ kind: RedactionLeak, _ place: String, _ text: String, page: Int = -1, box: RectD = .zero,
                sanitize: SanitizeItem? = nil, rewrite: Bool = false) {
        self.kind = kind
        self.place = place
        self.text = text
        self.page = page
        self.box = box
        self.sanitize = sanitize
        self.rewrite = rewrite
    }

    public var fix: RedactionFix {
        if sanitize != nil { return .sanitize }
        if rewrite { return .rewrite }
        let redactable: Set<RedactionLeak> = [.coveredText, .coveredContent, .unappliedMark, .glyphSpacing, .pageText, .hiddenText, .areaNotRemoved]
        return page >= 0 && !box.isEmpty && redactable.contains(kind) ? .redact : .none
    }
}

/// What the check knows about the redaction it checks (nothing, for a file received from someone else).
public struct RedactionCheckOptions: Sendable {
    /// What was redacted (text): looked for everywhere in the file. See `RedactionCheck.valuesUnder`.
    public var values: [String]
    /// The areas redacted in this file (page index → areas, page space): each must show nothing of what was there.
    public var areas: [Int: [RectD]]?
    /// The document before it was redacted (opened with the same password): none of its pictures may be under a
    /// redacted area unchanged.
    public var original: [UInt8]?
    /// Pages a search before the check skipped (from 0): what was there wasn't looked for, so the check is incomplete.
    public var skipped: [Int]
    /// What redaction by pattern looked for: whatever those patterns find in the comments, fields, bookmarks, properties,
    /// attachments and tags (which no page shows, so no page search saw them) is looked for too, and reported where it is.
    public var patterns: RedactionPatternOptions?
    /// What the person chose to keep: not looked for, though `patterns` would find it.
    public var kept: [String]
    /// Look only for the values and what `patterns` read, earlier versions too: no covers, hidden comments or earlier
    /// versions' other text (a batch's check of its own redaction).
    public var valuesOnly: Bool

    public init(values: [String] = [], areas: [Int: [RectD]]? = nil, original: [UInt8]? = nil, skipped: [Int] = [],
                patterns: RedactionPatternOptions? = nil, kept: [String] = [], valuesOnly: Bool = false) {
        self.values = values
        self.areas = areas
        self.original = original
        self.skipped = skipped
        self.patterns = patterns
        self.kept = kept
        self.valuesOnly = valuesOnly
    }
}

/// What the check found.
public struct RedactionCheckReport: Sendable {
    public var findings: [RedactionFinding]
    /// The text looked for: `RedactionCheckOptions.values` and what was found under covers.
    public var values: [String]
    /// What couldn't be checked, and why.
    public var notes: [String]
    /// Not everything was looked at (a page the engine refused, here or in the search before): clean doesn't mean clean.
    /// `notes` say why.
    public var incomplete = false

    public var isClean: Bool { findings.isEmpty }

    /// Some findings can be fixed (`RedactionCheck.fix`).
    public var canFix: Bool { findings.contains { $0.fix != .none } }

    /// "3 things found: text under a cover (2), bookmark (1).", or that nothing was found.
    public var summary: String {
        if isClean { return loc("Nothing of what was redacted was found in the file.") }
        var counts: [RedactionLeak: Int] = [:]
        for f in findings { counts[f.kind, default: 0] += 1 }
        let parts = counts.keys.sorted().map { k -> String in
            let name = RedactionCheck.name(k)
            let lower: String = name.prefix(1).lowercased() + name.dropFirst()
            return loc("{0} ({1})", lower, CoreLanguage.number(counts[k]!))
        }
        let list = parts.joined(separator: ", ")
        return findings.count == 1 ? loc("{0} thing found: {1}.", 1, list) : loc("{0} things found: {1}.", CoreLanguage.number(findings.count), list)
    }
}

/// Redaction check (the Windows app's `RedactionCheck`): verifies that nothing recoverable is left of what was redacted,
/// in a document just redacted (with what was redacted: `RedactionCheckOptions`) or in any PDF. It looks for
/// - covers that hide nothing for good: text under dark boxes, highlights and other content, or drawn in the color behind
///   it (each character is drawn: one that doesn't change a pixel doesn't show); pictures and drawings under dark boxes
///   (the page is drawn again without the box); Redact annotations never applied; text beside a box whose positions give
///   away the removed width;
/// - the redacted text anywhere else: page text, text in the content that doesn't show (hidden layers, off the page),
///   comments and their appearances, form fields (and XFA), bookmarks, document properties and XMP, attached files (also
///   inside zipped Office files and PDFs), the structure tree, scripts, objects nothing uses, earlier versions kept by
///   incremental saves (each version opened on its own, streams decompressed), and the file's raw bytes;
/// - redacted areas that still show something, or still hold the original picture; hidden layers and hidden comments.
///
/// Text that an earlier version showed and the current one no longer does is reported too (it was removed by appending).
/// What can be fixed with Inkvolt PDF's own means says how (`RedactionFinding.fix`; `fix`).
public enum RedactionCheck {
    /// Pixels per point for the visibility test of every character (confirmed at `confirmScale`).
    static let charScale = 0.5, confirmScale = 2.0
    /// Most covers per page drawn again without them (the darkest-box pages of a large file stay bounded).
    static let maxCoversPerPage = 64
    /// Most values looked for; earlier versions examined.
    static let maxValues = 500, maxRevisions = 32
    /// Test hook: the copy of the document without its covers can't be made.
    @TaskLocal static var coversFailForTests = false
    /// A fill this dark (luminance 0-1) counts as a redaction box.
    static let darkLuminance = 0.25
    /// An area just outside the page: redacting it only draws the page again as a picture.
    static let offPage = RectD(-4, -4, 2, 2)

    public static func name(_ kind: RedactionLeak) -> String {
        switch kind {
        case .coveredText: loc("Text under a cover")
        case .coveredContent: loc("Picture or drawing under a box")
        case .unappliedMark: loc("Redaction mark not applied")
        case .glyphSpacing: loc("Spacing that gives away a width")
        case .pageText: loc("Text on a page")
        case .hiddenText: loc("Text that doesn't show")
        case .hiddenContent: loc("Hidden content")
        case .annotation: loc("Comment", context: "a kind of finding")
        case .formField: loc("Form field")
        case .bookmark: loc("Bookmark")
        case .metadata: loc("Metadata")
        case .attachment: loc("Attached file")
        case .structureTree: loc("Tags (alternate text)")
        case .earlierRevision: loc("Earlier version")
        case .fileData: loc("Other data in the file")
        case .areaNotRemoved: loc("Redacted area")
        }
    }

    /// The text under areas about to be redacted (read before applying them): each line's characters whose middle is
    /// inside an area, as one value. These are what `RedactionCheckOptions.values` looks for afterwards. A page the engine
    /// refuses gives none, and goes in `skipped` (for `RedactionCheckOptions.skipped`: the check after applying is then
    /// incomplete).
    public static func valuesUnder(_ engine: PdfEngine, _ areas: [Int: [RectD]], cancel: CancelToken? = nil,
                                   skipped: SkippedPages? = nil) throws -> [String] {
        var values: [String] = []
        let skipped = skipped ?? SkippedPages()
        for (page, rects) in areas.sorted(by: { $0.key < $1.key }) {
            if page < 0 || page >= engine.pageCount || rects.allSatisfy(\.isEmpty) { continue }
            guard let text = try skipped.unlessRefused({ try engine.text(page, cache: false, cancel: cancel) }) else { continue }
            for (start, end) in runs(text, { i in
                let b = text.boxAt(i)
                return rects.contains { !$0.isEmpty && $0.contains(b.centerX, b.centerY) }
            }) {
                values.append(text.string(start, end))
            }
        }
        return clean(values)
    }

    /// Checks the document. Nothing is changed.
    /// - Parameter progress: (steps done, steps): pages read, then pages drawn, then earlier versions.
    /// - Throws: `PasswordRequired` when the password is missing or wrong; `CancellationError`; `PdfEditError` and
    ///   `PdfEngineError` for a file that can't be read.
    public static func run(_ data: [UInt8], _ password: String?, _ options: RedactionCheckOptions = RedactionCheckOptions(),
                           progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> RedactionCheckReport {
        try Check(data, password, options, progress, cancel).run()
    }

    /// A finding about what was just redacted still being in the file, rather than about the file as it came (a box that
    /// hides text elsewhere, a hidden layer).
    public static func isLeftover(_ kind: RedactionLeak) -> Bool {
        ![.coveredText, .coveredContent, .unappliedMark, .glyphSpacing, .hiddenContent].contains(kind)
    }

    /// The areas to redact to fix the findings that a redaction fixes, per page.

    public static func redactAreas(_ findings: [RedactionFinding]) -> [Int: [RectD]] {
        var out: [Int: [RectD]] = [:]
        for f in findings where f.fix == .redact {
            let r = f.box.inflate(0.5)
            if !(out[f.page] ?? []).contains(r) { out[f.page, default: []].append(r) }
        }
        return out
    }

    /// What Sanitize Document removes to fix the findings it fixes.
    public static func sanitizeItems(_ findings: [RedactionFinding]) -> Set<SanitizeItem> {
        Set(findings.filter { $0.fix == .sanitize }.compactMap(\.sanitize))
    }

    /// Fixes what can be fixed: redacts the areas of covered and leftover text (`Redaction.apply`), then sanitizes the
    /// kinds that hold leftovers, which also rewrites the file as one version (earlier versions and unused objects go).
    /// Findings without a fix are left as they are. A signed file needs the rewrite allowed (`SignedEdits.run`).
    public static func fix(_ data: [UInt8], _ password: String?, _ findings: [RedactionFinding]) throws -> [UInt8] {
        var data = data
        let areas = redactAreas(findings)
        if !areas.isEmpty { data = try Redaction.apply(data, password, areas) }
        let items = sanitizeItems(findings)
        if !items.isEmpty || findings.contains(where: { $0.fix == .rewrite }) { data = try Sanitizer.sanitize(data, password, items).data }
        return data
    }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.3 * r + 0.59 * g + 0.11 * b }

    /// Runs of characters (one line at a most) that `pick` chooses, spaces between chosen ones included, trimmed.
    static func runs(_ text: PageText, _ pick: (Int) -> Bool) -> [(start: Int, end: Int)] {
        let s = Array(text.text.utf16)
        var out: [(Int, Int)] = []
        var start = -1, last = -1
        for i in 0...s.count {
            let end = i == s.count || s[i] == 10
            if !end && PageText.isWhiteSpace(s[i]) { continue }
            if !end && pick(i) {
                if start < 0 { start = i }
                last = i
                continue
            }
            if start >= 0 { out.append((start, last + 1)) }
            start = -1
        }
        return out
    }

    /// Values worth looking for: trimmed, spaces collapsed, at least three letters or digits, each once.
    static func clean(_ values: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for v in values {
            let joined = v.replacingOccurrences(of: "\u{AD}", with: "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard joined.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 3 else { continue }
            if seen.insert(joined.lowercased()).inserted { out.append(joined) }
        }
        return out
    }

    /// A printable character (not a space, control, combining mark or format character).
    static func visible(_ u: UInt16) -> Bool {
        guard let s = Unicode.Scalar(u) else { return true } // a surrogate: part of a character that shows
        if s.properties.isWhitespace { return false }
        switch s.properties.generalCategory {
        case .control, .nonspacingMark, .format: return false
        default: return true
        }
    }
}

// ---- What a page draws ----

/// What a page draws that can hide something (dark boxes, dark comments, Redact marks), and what a cover can hide besides
/// text: pictures and shadings, and paths that aren't white, each with its place in the drawing order.
final class PageScan {
    var covers: [Cover] = []
    var pictures: [(box: RectD, image: PObj?)] = []
    var drawn: [(box: RectD, order: Int, picture: Bool)] = []
    var lightBoxes: [RectD] = []
    var marks: [[RectD]] = []

    /// Something other than text was drawn under the cover before it: a picture reaching into it, or a path mostly inside
    /// it (not a rule or a frame that just crosses it).
    func anythingUnder(_ c: Cover) -> Bool {
        drawn.contains { d in
            guard d.order < c.order else { return false }
            let i = c.box.intersect(d.box)
            if i.isEmpty { return false }
            return d.picture ? i.width * i.height > 1 : i.width * i.height >= 0.5 * max(0.01, d.box.width * d.box.height)
        }
    }
}

/// A dark box in the content (`form` nil: the page's own; its fill operator ends at `opEnd`) or a dark comment (`annot`:
/// its index in /Annots, drawn after the content).
struct Cover {
    var box: RectD
    var rectLike: Bool
    /// The form XObject's object number, when the box is drawn in one.
    var form: Int?
    var opEnd: Int, opLength: Int
    var order: Int
    var annot = -1
    var inForm: Bool { form != nil }
}

/// Walks a page's content (and the forms it draws, a few levels deep) for dark filled boxes and pictures, in page space.
/// A box is a path filled with a dark gray, RGB or CMYK color (black when no color was set).
final class ContentWalker {
    private static let maxDepth = 8, maxOperators = 400_000
    private let frame: PageFrame
    private let scan: PageScan
    private let cancel: CancelToken?
    private var ops = 0, order = 0
    private var active = Set<UInt>()
    /// Not all of the content was walked: past `maxOperators`, forms nested deeper than `maxDepth`, a form that can't be
    /// read (boxes there may have been missed).
    private(set) var cut = false

    private struct State {
        var ctm: ContentEditor.Mat
        var dark = true, light = false
    }

    init(_ page: PObj, _ scan: PageScan, _ cancel: CancelToken?) {
        frame = PageBoxes.frame(page)
        self.scan = scan
        self.cancel = cancel
    }

    func run(_ content: [UInt8], _ resources: PObj?, _ ctm: ContentEditor.Mat, _ form: Int?, _ depth: Int) throws {
        let list = try ContentLexer.parse(content, cancel: cancel)
        var state = State(ctm: ctm)
        var stack: [State] = []
        var points: [(x: Double, y: Double)] = []
        var rects = 0, subpaths = 0
        var curved = false
        for op in list {
            ops += 1
            if ops > Self.maxOperators {
                cut = true
                return
            }
            if ops & 1023 == 0 { try cancel.check() }
            let n = op.operands.count
            switch op.name {
            case "q":
                if stack.count < 256 { stack.append(state) }
            case "Q":
                if let s = stack.popLast() { state = s }
            case "cm" where n >= 6:
                state.ctm = ContentEditor.Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5)).times(state.ctm)
            case "g" where n >= 1:
                fill(&state, op.n(0))
            case "rg" where n >= 3:
                fill(&state, RedactionCheck.luminance(op.n(0), op.n(1), op.n(2)))
            case "k" where n >= 4:
                fill(&state, cmyk(op))
            case "sc", "scn":
                if !op.operands.allSatisfy({ $0.kind == .number }) {
                    fill(&state, 0.5)
                } else {
                    switch n {
                    case 1: fill(&state, op.n(0))
                    case 3: fill(&state, RedactionCheck.luminance(op.n(0), op.n(1), op.n(2)))
                    case 4: fill(&state, cmyk(op))
                    default: fill(&state, 0.5)
                    }
                }
            case "cs":
                fill(&state, 0) // a new color space starts at black (or full ink)
            case "sh":
                order += 1
                scan.drawn.append((RectD(-1e5, -1e5, 2e5, 2e5), order, true)) // a shading fills the clip: anywhere
            case "m" where n >= 2:
                subpaths += 1
                points.append((op.n(0), op.n(1)))
            case "l" where n >= 2:
                points.append((op.n(0), op.n(1)))
            case "c" where n >= 6:
                curved = true
                points += [(op.n(0), op.n(1)), (op.n(2), op.n(3)), (op.n(4), op.n(5))]
            case "v" where n >= 4, "y" where n >= 4:
                curved = true
                points += [(op.n(0), op.n(1)), (op.n(2), op.n(3))]
            case "re" where n >= 4:
                rects += 1
                subpaths += 1
                points += [(op.n(0), op.n(1)), (op.n(0) + op.n(2), op.n(1) + op.n(3))]
            case "f", "F", "f*", "B", "B*", "b", "b*", "S", "s", "n":
                let fills = !["S", "s", "n"].contains(op.name)
                if op.name != "n" && !points.isEmpty {
                    let box = box(points, state.ctm)
                    let rectLike = subpaths == 1 && (rects == 1 || (!curved && (points.count == 4 || points.count == 5) && Self.axis(points)))
                    if fills && state.dark && box.width >= 3 && box.height >= 3 && scan.covers.count < RedactionCheck.maxCoversPerPage * 4 {
                        order += 1
                        scan.covers.append(Cover(box: box, rectLike: rectLike, form: form, opEnd: op.end, opLength: op.name.utf8.count, order: order))
                    } else if !(state.light && ["f", "F", "f*"].contains(op.name)) {
                        order += 1
                        scan.drawn.append((box, order, false))
                    } else if rectLike && scan.lightBoxes.count < RedactionCheck.maxCoversPerPage * 4 {
                        scan.lightBoxes.append(box)
                    }
                }
                points.removeAll()
                rects = 0
                subpaths = 0
                curved = false
            case "Do" where n > 0 && op.operands[0].kind == .name:
                guard let entry = resources?.dict("XObject")?[op.operands[0].name], entry.isDict else { break }
                let sub = entry.name("Subtype")
                if sub == "Image" {
                    let box = box([(0, 0), (1, 1), (0, 1), (1, 0)], state.ctm)
                    scan.pictures.append((box, entry))
                    order += 1
                    scan.drawn.append((box, order, true))
                } else if sub == "Form" && depth >= Self.maxDepth {
                    cut = true // nested deeper than walked
                } else if sub == "Form" && entry.isRef && active.insert(entry.identity).inserted {
                    var m = ContentEditor.Mat.identity
                    if let a = entry.array("Matrix"), a.count == 6 { m = ContentEditor.Mat(a.num(0), a.num(1), a.num(2), a.num(3), a.num(4), a.num(5)) }
                    let bytes = entry.streamData ?? []
                    if bytes.isEmpty && !(entry.rawStreamData ?? []).isEmpty { cut = true } // a filter that fails on its data
                    try run(bytes, entry.dict("Resources") ?? resources, m.times(state.ctm), entry.num, depth + 1)
                    active.remove(entry.identity)
                }
            case "BI":
                let box = box([(0, 0), (1, 1), (0, 1), (1, 0)], state.ctm)
                scan.pictures.append((box, nil))
                order += 1
                scan.drawn.append((box, order, true))
            default:
                break
            }
        }
    }

    /// The fill color: dark enough to cover, or (nearly) white.
    private func fill(_ state: inout State, _ luminance: Double) {
        state.dark = luminance <= RedactionCheck.darkLuminance
        state.light = luminance >= 0.95
    }

    private func cmyk(_ op: COp) -> Double {
        let k = op.n(3)
        return RedactionCheck.luminance((1 - op.n(0)) * (1 - k), (1 - op.n(1)) * (1 - k), (1 - op.n(2)) * (1 - k))
    }

    /// Four (or five, closing) points on two x and two y values: an upright rectangle drawn with lines.
    private static func axis(_ pts: [(x: Double, y: Double)]) -> Bool {
        Set(pts.map { ($0.x * 10).rounded() }).count == 2 && Set(pts.map { ($0.y * 10).rounded() }).count == 2
    }

    private func box(_ pts: [(x: Double, y: Double)], _ ctm: ContentEditor.Mat) -> RectD {
        var l = Double.greatestFiniteMagnitude, t = Double.greatestFiniteMagnitude
        var r = -Double.greatestFiniteMagnitude, b = -Double.greatestFiniteMagnitude
        for p in pts {
            let u = ctm.apply(p.x, p.y)
            let q = frame.toPage(u.x, u.y)
            l = min(l, q.x)
            r = max(r, q.x)
            t = min(t, q.y)
            b = max(b, q.y)
        }
        return l.isFinite && r.isFinite && t.isFinite && b.isFinite && l <= r && t <= b ? .fromEdges(l, t, r, b) : .zero
    }
}

// ---- One run of the check ----

extension RedactionCheck {
    final class Check {
        let data: [UInt8]
        let password: String?
        let options: RedactionCheckOptions
        let progress: ((Int, Int) -> Void)?
        let cancel: CancelToken?

        var findings: [RedactionFinding] = []
        var notes: [String] = []
        /// Values found under covers and marks.
        var found: [String] = []
        var texts: [PageText] = []
        /// Per page: characters already reported.
        var reported: [Set<Int>] = []
        /// Values found somewhere.
        var hits = Set<Int>()
        var hiddenLayers = 0
        /// Pages the engine refused (and those the search before skipped, `RedactionCheckOptions.skipped`): not looked at,
        /// which the notes say, and the report is incomplete.
        let skipped = SkippedPages()
        /// A page of an earlier version the engine refused: not compared.
        var incomplete = false
        private var done = 0, total = 0

        init(_ data: [UInt8], _ password: String?, _ options: RedactionCheckOptions, _ progress: ((Int, Int) -> Void)?, _ cancel: CancelToken?) {
            self.data = data
            self.password = password
            self.options = options
            self.progress = progress
            self.cancel = cancel
        }

        func step(_ n: Int = 1) {
            done += n
            progress?(min(done, total), total)
        }

        func add(_ f: RedactionFinding) {
            if !findings.contains(where: { $0.kind == f.kind && $0.page == f.page && $0.place == f.place && $0.text == f.text && $0.box == f.box }) {
                findings.append(f)
            }
        }

        func run() throws -> RedactionCheckReport {
            let engine = try PdfEngine.open(data, password: password)
            defer { engine.close() }
            let doc = try PdfEdit.openToRead(data, password)
            let pages = engine.pageCount
            for p in options.skipped where p >= 0 { skipped.insert(p) }
            let docPages = try doc.pageCount()
            let revisions = RedactionCheck.revisions(data)
            total = pages * 2 + min(revisions.count, RedactionCheck.maxRevisions)
            reported = Array(repeating: [], count: pages)

            // The pages' text first (the engine reads text in a context of its own; Windows reads it on another thread
            // while it walks the pages).
            texts = try (0..<pages).map { p in try skipped.unlessRefused { try engine.text(p, cache: false, cancel: cancel) } ?? .empty }
            if options.valuesOnly {
                step(pages * 2)
            } else {
                var scans: [PageScan] = []
                for p in 0..<pages {
                    try cancel.check()
                    scans.append(p < docPages ? try scanPage(doc, p) : PageScan())
                    step()
                }
                var hidden: [[(start: Int, end: Int)]] = []
                for p in 0..<pages {
                    hidden.append(try hiddenChars(engine, p, scans[p]))
                    marks(p, scans[p])
                    step()
                }
                try covers(engine, scans)
                for p in 0..<pages { hiddenRuns(p, hidden[p], scans[p]) }
                if let areas = options.areas, !areas.isEmpty { try self.areas(engine, scans, areas) }
                hiddenContent(doc)
            }

            let kept = Set(RedactionCheck.clean(options.kept).map { $0.lowercased() })
            // What the patterns found outside the pages goes first: those are leftovers for certain, not just possible ones.
            let outside = RedactionCheck.clean(try patternValues(doc)).filter { !kept.contains($0.lowercased()) }
            let all = RedactionCheck.clean(outside + options.values + found).filter { !kept.contains($0.lowercased()) }
            let values = Array(all.prefix(RedactionCheck.maxValues))
            if all.count > values.count {
                // With the patterns run over the rest of the file, what they read there has been looked for anyway; a value they
                // didn't read there (a removed page value, one under a cover) wasn't looked for in earlier versions or the raw
                // bytes, so the check is incomplete (stricter than Windows, which counts on the patterns alone).
                let read = Set(outside.map { $0.lowercased() })
                if options.patterns == nil || all.dropFirst(values.count).contains(where: { !read.contains($0.lowercased()) }) { incomplete = true }
                let first = CoreLanguage.number(values.count), of = CoreLanguage.number(all.count)
                notes.append(loc("Only the first {0} of {1} redacted values were looked for as written in the rest of the file.", first, of))
            }
            let matcher = ValueMatcher(values)
            if !matcher.isEmpty {
                for p in 0..<pages { pageValues(p, matcher) }
                let inFile = try objects(doc, matcher)
                try earlierVersions(engine, matcher, inFile, revisions)
                try rawBytes(doc, matcher, inFile)
                // What the patterns read but the search for it as written didn't place (an attached PDF's kerned text) is still there.
                let outsideKeys = Set(outside.map { $0.lowercased() })
                for v in 0..<values.count where !hits.contains(v) && outsideKeys.contains(values[v].lowercased()) {
                    add(RedactionFinding(.fileData, loc("Another part of the file"), values[v]))
                }
            } else {
                try earlierVersions(engine, nil, [], revisions)
            }
            // A value search that couldn't be made, or stopped for its time: not looked for everywhere.
            if matcher.tooLong {
                incomplete = true
                notes.append(loc("A redacted value was too long to look for in the rest of the file."))
            }
            if matcher.timedOut.isSet {
                incomplete = true
                notes.append(loc("Looking for the redacted values took too long in part of the file, so that part wasn't searched to the end."))
            }

            let order = findings.enumerated().sorted { a, b in
                let pa = a.element.page < 0 ? Int.max : a.element.page, pb = b.element.page < 0 ? Int.max : b.element.page
                if pa != pb { return pa < pb }
                if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
                return a.offset < b.offset
            }.map(\.element)
            if let note = skipped.note { notes.append(note) }
            var report = RedactionCheckReport(findings: order, values: values, notes: notes)
            report.incomplete = incomplete || !skipped.list.isEmpty
            return report
        }

        // ---- Covers ----

        /// The page's dark boxes, dark comments, Redact marks and pictures.
        private func scanPage(_ doc: MuDoc, _ index: Int) throws -> PageScan {
            let scan = PageScan()
            let page = doc.page(index)
            var walked = false
            do {
                let content = ContentEditor.content(page)
                let walker = ContentWalker(page, scan, cancel)
                try walker.run(content.bytes, PageBoxes.inherited(page, "Resources"), .identity, nil, 0)
                walked = !content.unreadable && !walker.cut
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                walked = false
            }
            if !walked {
                incomplete = true
                notes.append(loc("Page {0}: part of its content couldn't be read, so boxes on it may have been missed.", CoreLanguage.number(index + 1)))
            }
            guard let annots = page.array("Annots") else { return scan }
            for i in 0..<annots.count {
                guard let a = annots[i], a.isDict, let r = a.array("Rect") else { continue }
                if (a.int("F") ?? 0) & 2 != 0 { continue } // hidden: reported with hidden content
                let rect = PageBoxes.rectToPage(page, r)
                let subtype = a.name("Subtype") ?? ""
                if subtype == "Redact" {
                    let quads = Self.quads(page, a)
                    scan.marks.append(quads.isEmpty ? [rect] : quads)
                } else if ["Square", "Circle", "Polygon", "Highlight", "Ink", "FreeText", "Squiggly", "StrikeOut", "Underline", "PolyLine"].contains(subtype)
                            && (Self.isDark(a.array("IC")) || Self.isDark(a.array("C"))) && !rect.isEmpty {
                    scan.covers.append(Cover(box: rect, rectLike: subtype == "Square" || subtype == "Highlight", form: nil, opEnd: 0, opLength: 0,
                                             order: Int.max, annot: i))
                }
            }
            return scan
        }

        private static func quads(_ page: PObj, _ annot: PObj) -> [RectD] {
            var list: [RectD] = []
            guard let q = annot.array("QuadPoints") else { return list }
            var i = 0
            while i + 7 < q.count {
                var l = Double.greatestFiniteMagnitude, t = Double.greatestFiniteMagnitude
                var r = -Double.greatestFiniteMagnitude, b = -Double.greatestFiniteMagnitude
                for k in stride(from: 0, to: 8, by: 2) {
                    let p = PageBoxes.toPage(page, q.num(i + k), q.num(i + k + 1))
                    l = min(l, p.x)
                    r = max(r, p.x)
                    t = min(t, p.y)
                    b = max(b, p.y)
                }
                if r - l > 0.1 && b - t > 0.1 { list.append(.fromEdges(l, t, r, b)) }
                i += 8
            }
            return list
        }

        /// A color array (gray, RGB or CMYK) dark enough to hide what is under it.
        private static func isDark(_ c: PObj?) -> Bool {
            guard let c else { return false }
            switch c.count {
            case 1: return c.num(0) <= darkLuminance
            case 3: return luminance(c.num(0), c.num(1), c.num(2)) <= darkLuminance
            case 4:
                let k = c.num(3)
                return luminance((1 - c.num(0)) * (1 - k), (1 - c.num(1)) * (1 - k), (1 - c.num(2)) * (1 - k)) <= darkLuminance
            default: return false
            }
        }

        /// Characters that don't show: each character's box is looked at in the page as drawn (with its comments); one
        /// whose pixels are all the same color draws nothing visible there (it is covered, or in the color behind it).
        /// The first look is small and takes the box with its edge pixels; characters that pass it, and those under a
        /// cover, a white box or a picture smaller than the page, are looked at again larger, inside their box only (a
        /// cover fitted to the glyphs must not let the page around it count as ink). Characters outside the page are
        /// reported here too.
        private func hiddenChars(_ engine: PdfEngine, _ p: Int, _ scan: PageScan) throws -> [(start: Int, end: Int)] {
            let text = texts[p]
            let units = Array(text.text.utf16)
            let g = engine.page(p)
            let page = RectD(0, 0, g.width, g.height)
            var hidden = Set<Int>(), offPage = Set<Int>()
            var candidates: [Int] = []
            for i in 0..<units.count where RedactionCheck.visible(units[i]) {
                let b = text.boxAt(i)
                if !page.contains(b.centerX, b.centerY) {
                    offPage.insert(i)
                } else {
                    candidates.append(i)
                }
            }
            if !candidates.isEmpty {
                let pixels = max(1, g.width * g.height)
                let scale = min(RedactionCheck.charScale, (8_000_000 / pixels).squareRoot())
                guard let img = try skipped.unlessRefused({ try engine.render(p, scale: scale, cancel: cancel) }) else { return [] }
                let over = (scan.covers.map(\.box) + scan.lightBoxes + scan.pictures.map(\.box)).filter { $0.width * $0.height < 0.5 * pixels }
                let maybe = candidates.filter { i in
                    let b = text.boxAt(i)
                    return over.contains { $0.contains(b.centerX, b.centerY) } || Self.uniform(img, b, scale, .zero, inner: false)
                }
                if !maybe.isEmpty {
                    let big = min(RedactionCheck.confirmScale, (30_000_000 / pixels).squareRoot())
                    guard let close = try skipped.unlessRefused({ try engine.render(p, scale: big, cancel: cancel) }) else { return [] }
                    for i in maybe {
                        guard let c = Self.uniformColor(close, text.boxAt(i), big, .zero, inner: true) else { continue }
                        // Text drawn invisibly (an OCR layer over a scan or a redacted page) shows nothing by design: it is
                        // a leftover only over a dark area (a box over a picture of the words), not over the page's paper.
                        if text.isInvisible(i)
                            && RedactionCheck.luminance(Double(c.0) / 255, Double(c.1) / 255, Double(c.2) / 255) > RedactionCheck.darkLuminance {
                            continue
                        }
                        hidden.insert(i)
                    }
                }
            }
            for (start, end) in RedactionCheck.runs(text, offPage.contains) {
                // Its box is outside the page: redacting it draws the page again as a picture, without it, and blacks out nothing.
                let box = text.rects(start, end).reduce(RectD.zero) { $0.union($1) }
                let value = text.string(start, end)
                add(RedactionFinding(.hiddenText, loc("Page {0}, outside the visible page", CoreLanguage.number(p + 1)), value, page: p, box: box))
                found.append(value)
                for i in start..<end { reported[p].insert(i) }
            }
            return RedactionCheck.runs(text, hidden.contains)
        }

        /// The pixels of `box` (page points) in an image of `origin` at `scale` are all one color: those it touches, or
        /// (`inner`) those wholly inside it, else the middle one.
        static func uniform(_ img: RenderedImage, _ box: RectD, _ scale: Double, _ origin: RectD, inner: Bool) -> Bool {
            uniformColor(img, box, scale, origin, inner: inner) != nil
        }

        /// `uniform`'s color (the darkest of each channel) when the pixels are all one color, else nil.
        static func uniformColor(_ img: RenderedImage, _ box: RectD, _ scale: Double, _ origin: RectD, inner: Bool) -> (Int, Int, Int)? {
            // A box that isn't a number has no pixels to look at; one far off the image is brought to just outside it,
            // which finds the same pixels (none), so each conversion below is of a value near the image's size.
            func near(_ v: Double, _ size: Int) -> Double { min(max(v, -2), Double(size) + 2) }
            let (lx, rx) = ((box.x - origin.x) * scale, (box.right - origin.x) * scale)
            let (ty, by) = ((box.y - origin.y) * scale, (box.bottom - origin.y) * scale)
            guard lx.isFinite, rx.isFinite, ty.isFinite, by.isFinite else { return nil }
            let l = near(lx, img.width), rt = near(rx, img.width), t = near(ty, img.height), b0 = near(by, img.height)
            var x0 = Int(inner ? l.rounded(.up) : l.rounded(.down)), x1 = Int(inner ? rt.rounded(.down) : rt.rounded(.up)) // bounded: near the image (above)
            var y0 = Int(inner ? t.rounded(.up) : t.rounded(.down)), y1 = Int(inner ? b0.rounded(.down) : b0.rounded(.up)) // bounded: near the image (above)
            if x1 <= x0 {
                x1 = Int(((l + rt) / 2).rounded(.down)) + 1 // bounded: near the image (above)
                x0 = x1 - 1
            }
            if y1 <= y0 {
                y1 = Int(((t + b0) / 2).rounded(.down)) + 1 // bounded: near the image (above)
                y0 = y1 - 1
            }
            x0 = min(max(x0, 0), img.width)
            x1 = min(max(x1, 0), img.width)
            y0 = min(max(y0, 0), img.height)
            y1 = min(max(y1, 0), img.height)
            if x1 <= x0 || y1 <= y0 { return nil }
            var min0 = 255, min1 = 255, min2 = 255, max0 = 0, max1 = 0, max2 = 0
            img.pixels.withUnsafeBufferPointer { px in
                for y in y0..<y1 {
                    let row = y * img.stride
                    for x in x0..<x1 {
                        let o = row + x * 3
                        let a = Int(px[o]), g = Int(px[o + 1]), c = Int(px[o + 2])
                        min0 = min(min0, a)
                        max0 = max(max0, a)
                        min1 = min(min1, g)
                        max1 = max(max1, g)
                        min2 = min(min2, c)
                        max2 = max(max2, c)
                    }
                }
            }
            return max0 - min0 <= 24 && max1 - min1 <= 24 && max2 - min2 <= 24 ? (min0, min1, min2) : nil
        }

        /// Redact marks never applied, with the text under them.
        private func marks(_ p: Int, _ scan: PageScan) {
            let text = texts[p]
            for rects in scan.marks {
                let runs = RedactionCheck.runs(text) { i in
                    let b = text.boxAt(i)
                    return rects.contains { $0.contains(b.centerX, b.centerY) }
                }
                let words = runs.map { text.string($0.start, $0.end) }.joined(separator: " ")
                let box = rects.reduce(RectD.zero) { $0.union($1) }
                add(RedactionFinding(.unappliedMark, loc("Page {0}", CoreLanguage.number(p + 1)), words.isEmpty ? loc("(no text under it: what it covers is still in the page)") : words,
                                     page: p, box: box))
                for (s, e) in runs {
                    found.append(text.string(s, e))
                    for i in s..<e { reported[p].insert(i) }
                }
            }
        }

        /// Covers drawn over pictures or drawings: the page is drawn again without its dark boxes and dark comments (a
        /// copy, in memory), and a cover that hides something (pixels that show without it and are the cover's color
        /// with it) is reported, with the text under it if there is any (text under a cover alone is found character by
        /// character). A box with nothing under it but text right beside it on the same line gives the removed width away.
        private func covers(_ engine: PdfEngine, _ scans: [PageScan]) throws {
            for scan in scans where scan.covers.count > RedactionCheck.maxCoversPerPage {
                scan.covers.removeSubrange(RedactionCheck.maxCoversPerPage...)
            }
            let pages = scans.indices.filter { p in scans[p].covers.contains(where: scans[p].anythingUnder) }
            for p in scans.indices where !pages.contains(p) { beside(p, scans[p]) }
            if pages.isEmpty { return }

            let bare: [UInt8]
            do {
                bare = try withoutCovers(scans, pages)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                incomplete = true
                notes.append(loc("What is under the dark boxes couldn't be drawn (the file can't be copied without them), so only text under them was looked for."))
                for p in pages { beside(p, scans[p]) }
                return
            }
            let without = try PdfEngine.open(bare)
            defer { without.close() }
            for p in pages {
                try cancel.check()
                let g = engine.page(p)
                let text = texts[p]
                for cover in scans[p].covers where scans[p].anythingUnder(cover) {
                    let area = cover.box.intersect(RectD(0, 0, g.width, g.height))
                    if area.width < 1 || area.height < 1 || p >= without.pageCount { continue }
                    let scale = min(1.5, (1_500_000 / (area.width * area.height)).squareRoot())
                    guard let with = try skipped.unlessRefused({ try engine.render(p, scale: scale, region: area, cancel: cancel) }),
                          let behind = try skipped.unlessRefused({ try without.render(p, scale: scale, region: area, cancel: cancel) })
                    else { break }
                    if !Self.hidesSomething(with, behind) { continue }
                    let under = RedactionCheck.runs(text) { i in
                        let b = text.boxAt(i)
                        return area.contains(b.centerX, b.centerY)
                    }
                    let place = cover.annot >= 0 ? loc("Page {0}, under a dark comment", CoreLanguage.number(p + 1)) : loc("Page {0}, under a dark box", CoreLanguage.number(p + 1))
                    if !under.isEmpty {
                        add(RedactionFinding(.coveredText, place, under.map { text.string($0.start, $0.end) }.joined(separator: " "), page: p, box: area))
                        for (s, e) in under {
                            found.append(text.string(s, e))
                            for i in s..<e { reported[p].insert(i) }
                        }
                    } else {
                        add(RedactionFinding(.coveredContent, place, loc("A picture or drawing is still under it"), page: p, box: area))
                    }
                }
                beside(p, scans[p])
            }
        }

        /// Pixels that show without the cover (differ from what is most common there) and are the cover's color with it.
        private static func hidesSomething(_ with: RenderedImage, _ without: RenderedImage) -> Bool {
            guard with.width == without.width, with.height == without.height, !with.pixels.isEmpty else { return false }
            let cover = dominant(with), behind = dominant(without)
            let n = with.width * with.height
            var count = 0
            for i in stride(from: 0, to: n * 3, by: 3) {
                if distance(without.pixels, i, behind) <= 60 { continue } // nothing drawn there without the cover
                if distance(with.pixels, i, cover) <= 45 { count += 1 } // and with it, just the cover's color
            }
            return count >= max(6, n / 300)
        }

        static func distance(_ px: [UInt8], _ i: Int, _ c: (Int, Int, Int)) -> Int {
            abs(Int(px[i]) - c.0) + abs(Int(px[i + 1]) - c.1) + abs(Int(px[i + 2]) - c.2)
        }

        /// The most common color (in steps of 16), as its middle.
        static func dominant(_ img: RenderedImage) -> (Int, Int, Int) {
            var counts = [Int](repeating: 0, count: 4096)
            var i = 0
            img.pixels.withUnsafeBufferPointer { px in
                while i + 2 < px.count {
                    counts[(Int(px[i]) >> 4) << 8 | (Int(px[i + 1]) >> 4) << 4 | Int(px[i + 2]) >> 4] += 1
                    i += 3
                }
            }
            var k = 0
            for j in 1..<4096 where counts[j] > counts[k] { k = j }
            return (((k >> 8) & 15) * 16 + 8, ((k >> 4) & 15) * 16 + 8, (k & 15) * 16 + 8)
        }

        /// A box (wider than tall, so not a bullet or a check box) with no text under it, beside text on its line: the
        /// text around it keeps the positions it had, so the removed width can be measured from them.
        private func beside(_ p: Int, _ scan: PageScan) {
            let text = texts[p]
            let units = Array(text.text.utf16)
            for cover in scan.covers where cover.rectLike && cover.box.width >= 12 && cover.box.width >= 1.5 * cover.box.height && cover.box.height >= 4 {
                let box = cover.box
                var inside = false
                var near: [Int] = []
                for i in 0..<units.count where RedactionCheck.visible(units[i]) {
                    let b = text.boxAt(i)
                    if box.inflate(-0.5).contains(b.centerX, b.centerY) {
                        inside = true
                        break
                    }
                    let gap = b.right <= box.x + 0.5 ? box.x - b.right : b.x >= box.right - 0.5 ? b.x - box.right : Double.greatestFiniteMagnitude
                    if b.centerY >= box.y && b.centerY <= box.bottom && b.height >= 0.4 * box.height && b.height <= 2.5 * box.height
                        && gap <= max(2, b.height) {
                        near.append(i)
                    }
                }
                if inside || near.isEmpty || near.contains(where: reported[p].contains) { continue }
                // The text on either side, with the box between: "Name: ▮ lives here".
                var lines: [(start: Int, end: Int)] = []
                for i in near {
                    let l = text.lineAt(i)
                    if !lines.contains(where: { $0.start == l.start && $0.end == l.end }) { lines.append(l) }
                }
                lines.sort { text.boxAt($0.start).x < text.boxAt($1.start).x }
                let left = lines.filter { text.boxAt($0.start).x < box.x }.map { text.string($0.start, $0.end).trimmingCharacters(in: .whitespaces) }
                let right = lines.filter { text.boxAt($0.start).x >= box.x }.map { text.string($0.start, $0.end).trimmingCharacters(in: .whitespaces) }
                add(RedactionFinding(.glyphSpacing, loc("Page {0}, beside a dark box", CoreLanguage.number(p + 1)), (left + ["▮"] + right).joined(separator: " "), page: p, box: box))
            }
        }

        /// Characters found not to show (not reported yet): under a dark box or comment, or else under other content or
        /// in the color behind them.
        private func hiddenRuns(_ p: Int, _ runs: [(start: Int, end: Int)], _ scan: PageScan) {
            let text = texts[p]
            for (start, end) in runs {
                if (start..<end).contains(where: reported[p].contains) { continue }
                let box = text.rects(start, end).reduce(RectD.zero) { $0.union($1) }
                let cover = scan.covers.first { $0.box.inflate(0.5).contains(box.centerX, box.centerY) }
                let place = cover == nil ? loc("Page {0}, covered or drawn in the color behind it", CoreLanguage.number(p + 1))
                    : cover!.annot >= 0 ? loc("Page {0}, under a dark comment", CoreLanguage.number(p + 1)) : loc("Page {0}, under a dark box", CoreLanguage.number(p + 1))
                let value = text.string(start, end)
                add(RedactionFinding(.coveredText, place, value, page: p, box: cover?.box ?? box))
                found.append(value)
                for i in start..<end { reported[p].insert(i) }
            }
        }

        /// A copy of the document without the covers, unencrypted: dark fills become unpainted paths, dark comments go.
        private func withoutCovers(_ scans: [PageScan], _ pages: [Int]) throws -> [UInt8] {
            if RedactionCheck.coversFailForTests { throw PdfEditError("The copy without covers failed (a test).") } // English: for a developer
            let copy = try PdfEdit.openToRead(data, password)
            var forms: [Int: [Cover]] = [:]
            for p in pages {
                let page = copy.page(p)
                let own = scans[p].covers.filter { $0.annot < 0 && !$0.inForm }
                if !own.isEmpty { page.set("Contents", copy.addStream(Self.unpaint(ContentEditor.contentBytes(page), own), deflate: true)) }
                for c in scans[p].covers where c.inForm { forms[c.form!, default: []].append(c) }
                if let annots = page.array("Annots") {
                    let indices = Set(scans[p].covers.filter { $0.annot >= 0 && $0.annot < annots.count }.map(\.annot)).sorted(by: >)
                    let list = copy.array(annots.elements)
                    for i in indices { list.remove(at: i) }
                    page.set("Annots", list)
                }
            }
            for (num, covers) in forms {
                let form = copy.object(num)
                guard form.isStream, let bytes = form.streamData else { continue }
                var unique: [Cover] = []
                for c in covers where !unique.contains(where: { $0.opEnd == c.opEnd }) { unique.append(c) }
                form.setStream(Self.unpaint(bytes, unique), deflate: true)
            }
            try copy.checkFailure()
            return try copy.write("encrypt=no")
        }

        /// The content with the covers' fill operators turned into "n" (the path is dropped unpainted).
        private static func unpaint(_ content: [UInt8], _ covers: [Cover]) -> [UInt8] {
            var copy = content
            for c in covers {
                let at = c.opEnd - c.opLength
                if at < 0 || c.opEnd > copy.count { continue }
                copy[at] = UInt8(ascii: "n")
                for i in at + 1..<c.opEnd { copy[i] = 32 }
            }
            return copy
        }

        // ---- Redacted areas ----

        /// Each redacted area must be one solid color now (a few edge pixels aside), and no picture placed under it may be
        /// one the original held, byte for byte (a box drawn over a picture that was never changed).
        private func areas(_ engine: PdfEngine, _ scans: [PageScan], _ areas: [Int: [RectD]]) throws {
            let originals = originalPictures()
            for (p, rects) in areas.sorted(by: { $0.key < $1.key }) {
                if p < 0 || p >= engine.pageCount { continue }
                let g = engine.page(p)
                for rect in rects {
                    let area = rect.inflate(-1).intersect(RectD(0, 0, g.width, g.height))
                    if area.isEmpty { continue }
                    let scale = min(1, (1_500_000 / (area.width * area.height)).squareRoot())
                    guard let img = try skipped.unlessRefused({ try engine.render(p, scale: scale, region: area, cancel: cancel) }) else { break }
                    let main = Self.dominant(img)
                    let n = img.width * img.height
                    var off = 0
                    for i in stride(from: 0, to: img.pixels.count - 2, by: 3) where Self.distance(img.pixels, i, main) > 60 { off += 1 }
                    if off > max(4, n / 50) {
                        add(RedactionFinding(.areaNotRemoved, loc("Page {0}", CoreLanguage.number(p + 1)), loc("The redacted area still shows content"), page: p, box: rect))
                    }
                    if !originals.isEmpty && scans[p].pictures.contains(where: { pic in
                        guard let im = pic.image, !pic.box.intersect(area).isEmpty else { return false }
                        return originals.contains(Self.hash(im))
                    }) {
                        add(RedactionFinding(.areaNotRemoved, loc("Page {0}", CoreLanguage.number(p + 1)), loc("The picture under the redacted area is the original, unchanged"), page: p, box: rect))
                    }
                }
            }
        }

        private func originalPictures() -> Set<String> {
            var set = Set<String>()
            guard let original = options.original else { return set }
            do {
                let doc = try PdfEdit.openToRead(original, password)
                for o in doc.allObjects() where o.isStream && o.name("Subtype") == "Image" { set.insert(Self.hash(o)) }
            } catch {
                incomplete = true
                notes.append(loc("The document before redaction couldn't be read, so pictures under the redacted areas weren't compared with it."))
            }
            return set
        }

        private static func hash(_ image: PObj) -> String {
            SHA256.hash(data: Data(image.rawStreamData ?? [])).map { String(format: "%02X", $0) }.joined()
        }

        /// Hidden layers and hidden comments or fields hold content nobody sees (Sanitize Document removes them).
        private func hiddenContent(_ doc: MuDoc) {
            let scan = Sanitizer.scan(doc)
            hiddenLayers = scan[.hiddenLayers]
            let layers = scan[.hiddenLayers]
            if layers > 0 {
                let detail = layers == 1 ? loc("{0} layer that don't show, with what they draw", 1) : loc("{0} layers that don't show, with what they draw", CoreLanguage.number(layers))
                add(RedactionFinding(.hiddenContent, loc("Hidden layers"), detail,
                                     sanitize: .hiddenLayers))
            }
            let annots = scan[.hiddenAnnotations]
            if annots > 0 {
                let detail = annots == 1 ? loc("{0} comment or field that don't show", 1) : loc("{0} comments and fields that don't show", CoreLanguage.number(annots))
                add(RedactionFinding(.hiddenContent, loc("Hidden comments and form fields"), detail, sanitize: .hiddenAnnotations))
            }
        }

        /// The values in each page's text (characters already reported under a cover aside).
        private func pageValues(_ p: Int, _ matcher: ValueMatcher) {
            let text = texts[p]
            for (v, start, length) in matcher.matches(text.text) {
                hits.insert(v)
                if (start..<start + length).contains(where: reported[p].contains) { continue } // reported under its cover
                let box = text.rects(start, start + length).reduce(RectD.zero) { $0.union($1) }
                let value = text.string(start, start + length).replacingOccurrences(of: "\n", with: " ")
                add(RedactionFinding(.pageText, loc("Page {0}", CoreLanguage.number(p + 1)), value, page: p, box: box))
                for i in start..<start + length { reported[p].insert(i) }
            }
        }
    }
}
