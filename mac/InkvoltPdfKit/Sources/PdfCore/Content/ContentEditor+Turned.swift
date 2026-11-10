import Foundation

/// Paragraphs in turned text (roadmap 2.1; the Windows app's ContentEditor.Turned.cs): a page's runs of one direction are
/// turned upright about the page's origin (the paragraph's own frame), grouped and laid out there as upright text is, and
/// the result turned back onto the page. The writing needs nothing more: a line's start on the page goes back into the
/// run's own text space (see `writeParagraph`), which already runs in its direction.
extension ContentEditor {
    /// How many directions of turned text a page is grouped in at most (the ones with the most runs).
    private static let maxDirections = 16

    /// The directions of a page's turned text, each with its runs (by id): runs sorted by angle (degrees clockwise, as
    /// `TextRun.angle`) go in one direction while they are within half a degree of its first, so each run is in one
    /// direction only (and upright text, under half a degree, in none); a direction's angle is its middle run's. At most
    /// `maxDirections`, those with the most runs.
    static func directions(_ content: PageContent) -> [(angle: Double, runs: Set<Int>)] {
        var turned: [(at: Double, id: Int)] = []
        for r in content.runs where r.reach != nil && !trimmed(r.text).isEmpty && r.fontSize > 0.5 && abs(turn(r.angle)) >= 0.5 {
            turned.append(((turn(r.angle) + 360).truncatingRemainder(dividingBy: 360), r.id)) // 0 to 360: 180° and -180° together
        }
        turned.sort { $0.at < $1.at }
        var groups: [[(at: Double, id: Int)]] = []
        for x in turned {
            if let first = groups.last?.first, x.at - first.at < 0.5 {
                groups[groups.count - 1].append(x)
            } else {
                groups.append([x])
            }
        }
        let ranked = groups.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
        return ranked.prefix(maxDirections).map { g in (turn(g[g.count / 2].at), Set(g.map(\.id))) }
    }

    /// An angle as -180 (excluded) to 180 degrees.
    static func turn(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a > 180 {
            a -= 360
        } else if a <= -180 {
            a += 360
        }
        return a
    }

    /// A page point in a frame turned `angle` (the frame's x axis along that direction).
    static func toFrame(_ p: PointD, _ angle: Double) -> PointD {
        let r = angle * .pi / 180
        let s = sin(r), c = cos(r)
        let x: Double = p.x * c + p.y * s, y: Double = -p.x * s + p.y * c
        return PointD(x, y)
    }

    /// A point of a frame turned `angle` back on the page.
    static func fromFrame(_ p: PointD, _ angle: Double) -> PointD { toFrame(p, -angle) }

    /// A rectangle's bounding box once turned by `angle` (`toFrame`).
    static func turned(_ r: RectD, _ angle: Double) -> RectD {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for c in [PointD(r.x, r.y), PointD(r.right, r.y), PointD(r.right, r.bottom), PointD(r.x, r.bottom)] {
            let t = toFrame(c, angle)
            minX = min(minX, t.x)
            minY = min(minY, t.y)
            maxX = max(maxX, t.x)
            maxY = max(maxY, t.y)
        }
        return .fromEdges(minX, minY, maxX, maxY)
    }

    /// The page's content in the frame of `angle`: its runs of that direction upright, with their own boxes there; every
    /// other run and picture as the bounding box of where it is (what a paragraph runs into, or what sits on its lines).
    /// A run of that direction that is mirrored or slanted has no box there and takes no part. Each run in the frame leads
    /// back to the page's (by id). Only the direction's own runs (`mine`, see `directions`) are upright there. Only what
    /// is from the direction's top line down is taken, however far along its lines; what is above can't touch its
    /// paragraphs.
    static func framed(_ content: PageContent, _ angle: Double, _ mine: Set<Int>) -> (framed: PageContent, page: [Int: TextRun]) {
        var page: [Int: TextRun] = [:]
        var runs: [TextRun] = []
        func upright(_ origin: PointD, _ reach: TextRun.Reach) -> RectD {
            .fromEdges(origin.x - reach.back, origin.y - reach.above, origin.x + reach.along, origin.y + reach.below)
        }
        var top = Double.greatestFiniteMagnitude, size = 0.0
        for r in content.runs where mine.contains(r.id) {
            let b = upright(toFrame(r.origin, angle), r.reach!)
            top = min(top, b.y)
            size = max(size, r.fontSize)
        }
        func near(_ b: RectD) -> Bool { b.bottom >= top - 2 * size }
        for r in content.runs {
            let rel = turn(r.angle - angle)
            let origin = toFrame(r.origin, angle)
            var f = r
            // Its own runs, and the spaces drawn on their own in its direction (they go with its paragraphs' text).
            let own = mine.contains(r.id) || (trimmed(r.text).isEmpty && abs(rel) < 0.5 && abs(turn(r.angle)) >= 0.5)
            if own, let reach = r.reach {
                f.box = upright(origin, reach)
                f.origin = origin
                f.angle = rel
            } else {
                let box = turned(r.box, angle)
                if !near(box) { continue }
                // Not this direction's: never grouped here (NaN is no angle), still something on the lines or below.
                f.box = box
                f.origin = origin
                f.angle = abs(rel) < 0.5 ? .nan : rel
            }
            page[r.id] = r
            runs.append(f)
        }
        var images: [PageImage] = []
        for i in content.images {
            var t = i
            t.box = turned(i.box, angle)
            if near(t.box) { images.append(t) }
        }
        return (PageContent(runs: runs, images: images), page)
    }

    /// A paragraph grouped in the frame of `angle`, on the page: its own runs, its boxes' bounding boxes, the frame kept.
    static func turned(_ framed: TextParagraph, _ angle: Double, _ page: [Int: TextRun]) -> TextParagraph {
        var p = framed
        p.runs = framed.runs.map { page[$0.id] ?? $0 }
        p.spaces = framed.spaces.map { page[$0.id] ?? $0 }
        p.lines = framed.lines.map { turned($0, -angle) }
        p.box = turned(framed.box, -angle)
        p.below = framed.below.map { turned($0, -angle) }
        p.angle = angle
        p.uprightStore = [framed]
        return p
    }

    /// A layout made in a turned paragraph's frame, on the page: its lines' starts turned back, its box and what it runs
    /// into as bounding boxes.
    static func onPage(_ layout: ParagraphLayout, _ p: TextParagraph) -> ParagraphLayout {
        var l = layout
        l.check.box = turned(layout.check.box, -p.angle)
        l.check.overlaps = layout.check.overlaps == nil ? nil : p.below
        l.lines = layout.lines.map { (fromFrame($0.origin, p.angle), $0.parts) }
        return l
    }

    /// Whether a page point is inside a paragraph's box (a turned one's in its own direction).
    static func holds(_ p: TextParagraph, _ x: Double, _ y: Double) -> Bool {
        guard let u = p.upright else { return p.box.contains(x, y) }
        let f = toFrame(PointD(x, y), p.angle)
        return u.box.contains(f.x, f.y)
    }
}
