import Foundation

/// A quarter turn of a page for its turned text in a translated copy (a table set sideways, a landscape page's text on a
/// portrait page; the Windows app's `TranslationFrame`): the frame `ExportPage.turned` uses, where text of that direction
/// reads left to right and the page's box starts at (0, 0), so a table's rows and columns are found there as on an
/// upright page and the room a paragraph has is worked out the same way. `turn`: quarter turns clockwise the text reads
/// in (1 top to bottom, 2 upside down, 3 bottom to top, as `ExportLine.reads`).
struct TranslationFrame: Sendable {
    let turn: Int
    let pageWidth: Double, pageHeight: Double

    /// The direction of the frame's text on the page, as `TextRun.angle`.
    var angle: Double { turn == 1 ? 90 : turn == 2 ? 180 : -90 }

    /// The page's size in the frame.
    var width: Double { turn == 2 ? pageWidth : pageHeight }
    var height: Double { turn == 2 ? pageHeight : pageWidth }

    // ContentEditor.toFrame turns about the page's origin; this moves the turned page back to (0, 0).
    private var offset: PointD { turn == 1 ? PointD(0, pageWidth) : turn == 2 ? PointD(pageWidth, pageHeight) : PointD(pageHeight, 0) }

    func into(_ p: PointD) -> PointD {
        let t = ContentEditor.toFrame(p, angle)
        return PointD(t.x + offset.x, t.y + offset.y)
    }

    func out(_ p: PointD) -> PointD { ContentEditor.fromFrame(PointD(p.x - offset.x, p.y - offset.y), angle) }

    func into(_ r: RectD) -> RectD { box(r, into) }

    func out(_ r: RectD) -> RectD { box(r, out) }

    private func box(_ r: RectD, _ map: (PointD) -> PointD) -> RectD {
        let a = map(PointD(r.x, r.y)), b = map(PointD(r.right, r.bottom))
        return .fromEdges(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
    }
}

/// A page's text of one quarter turn in its frame (`TranslationFrame`), the table cells found there, and each run
/// there's run on the page (by key).
struct TurnedPart {
    let frame: TranslationFrame
    let content: PageContent
    let cells: [RectD]
    let page: [Int: TextRun]
}

extension ContentEditor {
    /// A page's turned text a translated copy rewrites: each quarter turn its runs read in (within half a degree; text
    /// at another angle, mirrored or slanted stays and is named), in its frame with the cells `cells` found there (by
    /// quarter turn, in the frame). In the frame the direction's runs are upright with their own boxes, every other run
    /// is in the way where it is (no angle, so never grouped there), and each run's clip is turned too.
    static func turnedParts(_ content: PageContent, _ pageWidth: Double, _ pageHeight: Double, _ cells: [Int: [RectD]]) -> [TurnedPart] {
        var parts: [TurnedPart] = []
        var byKey: [Int: TextRun] = [:]
        for r in content.runs { byKey[r.key] = r }
        for turn in 1...3 {
            let frame = TranslationFrame(turn: turn, pageWidth: pageWidth, pageHeight: pageHeight)
            let mine = Set(content.runs.filter { r in
                r.reach != nil && !trimmed(r.text).isEmpty && r.fontSize > 0.5 && abs(self.turn(r.angle - frame.angle)) < 0.5
            }.map(\.id))
            if mine.isEmpty { continue }
            let (framedContent, _) = framed(content, frame.angle, mine)
            // framed turns about the page's origin: moved so the page starts at (0, 0), as ExportPage.turned does.
            let o = frame.into(PointD(0, 0))
            func moved(_ b: RectD) -> RectD { RectD(b.x + o.x, b.y + o.y, b.width, b.height) }
            var page: [Int: TextRun] = [:]
            var runs: [TextRun] = []
            runs.reserveCapacity(framedContent.runs.count)
            for r in framedContent.runs {
                var m = r
                m.box = moved(r.box)
                m.origin = PointD(r.origin.x + o.x, r.origin.y + o.y)
                if let clip = r.info?.clip { m.info!.clip = frame.into(clip) }
                page[m.key] = byKey[r.key] ?? r
                runs.append(m)
            }
            let images = framedContent.images.map { i -> PageImage in
                var t = i
                t.box = moved(i.box)
                return t
            }
            parts.append(TurnedPart(frame: frame, content: PageContent(runs: runs, images: images), cells: cells[turn] ?? [], page: page))
        }
        return parts
    }

    /// A paragraph grouped in a turned part's frame, on the page: its runs the page's (same order), its boxes turned back,
    /// the frame's paragraph kept as `upright`.
    static func onPage(_ framed: TextParagraph, _ part: TurnedPart) -> TextParagraph {
        var p = framed
        p.runs = framed.runs.map { part.page[$0.key] ?? $0 }
        p.spaces = framed.spaces.map { part.page[$0.key] ?? $0 }
        p.lines = framed.lines.map(part.frame.out)
        p.box = part.frame.out(framed.box)
        p.below = framed.below.map(part.frame.out)
        p.angle = part.frame.angle
        p.uprightStore = [framed]
        return p
    }

    /// New lines by the run they are written at, from a turned part's frame onto the page: the page's runs, the lines'
    /// starts turned back.
    static func onPage(_ lines: [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])], _ part: TurnedPart)
        -> [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])] {
        var result: [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])] = [:]
        for (key, entry) in lines {
            let run = part.page[key] ?? entry.run
            result[run.key] = (run, entry.lines.map { (part.frame.out($0.origin), $0.parts) })
        }
        return result
    }
}
