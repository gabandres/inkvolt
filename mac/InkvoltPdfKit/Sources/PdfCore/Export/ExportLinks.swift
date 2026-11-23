import Foundation

/// A page's links on the text an export reads (the Windows app's link handling in `GetExportPage`): each link's boxes
/// (its /QuadPoints', or its area), where it leads, and whether its area must hold one line of text to count.
struct ExportLinkArea {
    var boxes: [RectD]
    var to: ExportLink
    var oneLine: Bool
}

extension PdfEngine {
    /// Most links of a page an export carries (each character is checked against each).
    static let maxExportLinks = Links.maxPerPage

    /// The page's links that `links` carries, with their boxes; none when `links` is nil or MuPDF can't read them (the
    /// text then goes without them). The cap counts links carried, not links dropped (a page of javascript: links mustn't
    /// crowd out its real ones).
    func linkAreas(_ page: Int, _ links: ((PageLink) -> (to: ExportLink, quads: [RectD])?)?, _ cancel: CancelToken?) throws -> [ExportLinkArea] {
        guard let links else { return [] }
        let read: [PageLink]
        do {
            read = try self.links(page, cancel: cancel)
        } catch is PdfEngineError {
            read = [] // unreadable links: the text goes without them
        }
        var areas: [ExportLinkArea] = []
        for l in read {
            if areas.count >= Self.maxExportLinks { break }
            guard l.area.width > 0, l.area.height > 0, let to = links(l) else { continue }
            let quads = to.quads.filter { $0.width > 0 && $0.height > 0 }
            // Boxes when it has a few; when it has none, or more than are read, its area (one line's only).
            if !quads.isEmpty && quads.count <= Links.maxQuads {
                areas.append(ExportLinkArea(boxes: quads, to: to.to, oneLine: false))
            } else {
                areas.append(ExportLinkArea(boxes: [l.area], to: to.to, oneLine: true))
            }
        }
        return areas
    }

    /// Two runs of text are on the same line: across the lines' direction (`turn`: up and down for text that reads
    /// across) they overlap by half the smaller at least.
    static func sameLine(_ a: RectD, _ b: RectD, _ turn: Int) -> Bool {
        let across = turn % 2 == 0
        let a0 = across ? a.y : a.x, a1 = across ? a.bottom : a.right
        let b0 = across ? b.y : b.x, b1 = across ? b.bottom : b.right
        return min(a1, b1) - max(a0, b0) >= 0.5 * min(a1 - a0, b1 - b0)
    }

    /// Links the characters of `composed` (a list per line of the page, `turns` each) whose middles lie in a link's
    /// boxes. A link known only by its area counts when the text in it is one line; a space is linked only between two
    /// characters of the same link, so one at a link's edge stays outside it.
    static func link(_ composed: inout [[ExportGlyph]], _ found: [ExportLinkArea], turns: [Int]) {
        func inside(_ boxes: [RectD], _ g: ExportGlyph) -> Bool { boxes.contains { $0.contains(g.rect.centerX, g.rect.centerY) } }
        let areas = found.filter { a in
            if !a.oneLine { return true }
            // Every line with a character there lies across the others (along the lines' own direction), not above or below.
            var held: [(box: RectD, turn: Int)] = []
            for i in composed.indices {
                let inArea = composed[i].filter { inside(a.boxes, $0) }
                guard let first = inArea.first else { continue }
                var box = first.rect
                for g in inArea.dropFirst() { box = box.union(g.rect) }
                held.append((box, i < turns.count ? turns[i] : 0))
            }
            return held.allSatisfy { x in held.allSatisfy { y in sameLine(x.box, y.box, x.turn) } }
        }
        if areas.isEmpty { return }
        for i in composed.indices {
            for k in composed[i].indices {
                if let a = areas.first(where: { inside($0.boxes, composed[i][k]) }) { composed[i][k].look.link = a.to }
            }
            unlinkEdgeSpaces(&composed[i])
        }
    }

    /// A space keeps its link only between two characters that aren't space and have that link.
    private static func unlinkEdgeSpaces(_ glyphs: inout [ExportGlyph]) {
        // The link of the next character that isn't space (none past the end).
        var next = [ExportLink?](repeating: nil, count: glyphs.count + 1)
        for k in stride(from: glyphs.count - 1, through: 0, by: -1) {
            next[k] = glyphs[k].text.isBlank ? next[k + 1] : glyphs[k].look.link
        }
        var last: ExportLink?
        var seenInk = false
        for k in glyphs.indices {
            if !glyphs[k].text.isBlank {
                last = glyphs[k].look.link
                seenInk = true
                continue
            }
            guard let link = glyphs[k].look.link else { continue }
            if !seenInk || last != link || next[k + 1] != link { glyphs[k].look.link = nil }
        }
    }
}
