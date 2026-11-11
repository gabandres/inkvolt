import Foundation
import PrintCore

/// A line of Redact by Pattern's list: a hit, a page to look at by hand, or an area marked by hand before this search.
public struct RedactionReviewRow: Sendable {
    public enum Item: Sendable {
        case hit(RedactionMatch)
        case look(RedactionLook)
        case earlier(page: Int, rect: RectD)
    }

    public let item: Item
    /// Ticked: it goes (a hit, an earlier area), or a look's places nothing could read are blacked out too.
    public var accepted: Bool

    public var page: Int {
        switch item {
        case .hit(let h): h.page
        case .look(let l): l.page
        case .earlier(let page, _): page
        }
    }

    /// "Page 3".
    public var place: String { loc("Page {0}", CoreLanguage.number(page + 1)) }

    /// What it is: the kind (read by OCR, when it was), an area marked earlier, or a page to look at.
    public var kind: String {
        switch item {
        case .hit(let h): h.fromOcr ? loc("{0} (read by OCR)", RedactionPatterns.name(h.pattern)) : RedactionPatterns.name(h.pattern)
        case .look: loc("Look at this page by hand")
        case .earlier: loc("An area you marked earlier")
        }
    }

    /// The words before a hit (at most 28 characters shown), the hit as it reads (safe to show), and what follows it, or
    /// what the line says.
    public var before: String {
        guard case .hit(let h) = item else { return "" }
        let units = Array(h.before.utf16)
        return units.count > 28 ? "…" + String(decoding: units.suffix(28), as: UTF16.self) : h.before
    }

    public var value: String {
        guard case .hit(let h) = item else { return "" }
        return RedactionPatterns.displayable(h.text)
    }

    public var after: String {
        switch item {
        case .hit(let h):
            let units = Array(h.after.utf16)
            return units.count > 28 ? String(decoding: units.prefix(28), as: UTF16.self) + "…" : h.after
        case .look(let l): return l.short
        case .earlier: return loc("Goes with the rest. Untick to leave it as a mark.")
        }
    }

    /// Whether the line has a box to tick: a look only when it has places nothing could read.
    public var tickable: Bool {
        if case .look(let l) = item { return !l.unread.isEmpty }
        return true
    }

    /// What the line is about on its page: the hit's boxes, the places nothing could read, the earlier area.
    public var boxes: [RectD] {
        switch item {
        case .hit(let h): h.rects
        case .look(let l): l.unread
        case .earlier(_, let rect): [rect]
        }
    }

    /// The line for a screen reader.
    public var spoken: String {
        switch item {
        case .hit: loc("{0}, {1}: {2}. Checked: it will be redacted.", place, kind, before + value + after)
        case .earlier: loc("{0}, {1}. Checked: it will be redacted.", place, kind)
        case .look(let l): loc("{0}: {1} Checked: the places where nothing was read will be blacked out.", place, l.text)
        }
    }
}

/// What the person chose: the hits to remove and to keep, the places nothing could read chosen to be blacked out whatever
/// they say, and the areas marked by hand before the search that go with the rest or stay marks.
public struct RedactionReviewChoice: Sendable {
    public var accepted: [RedactionMatch]
    public var skipped: [RedactionMatch]
    public var lookAreas: [(page: Int, rect: RectD)]
    public var earlierApplied: [(page: Int, rect: RectD)]
    public var earlierKept: [(page: Int, rect: RectD)]
}

/// Redact by Pattern's list (the Windows app's `RedactReviewDialog` rows): every hit with its page and the words around it,
/// accepted or skipped one by one or all, before anything is applied. In page order, a page to look at just before its hits
/// (a long scan's flags mustn't push every hit out of sight); the list never lets a scan pass as looked at.
public struct RedactionReviewList: Sendable {
    public private(set) var rows: [RedactionReviewRow]

    /// `earlier`: areas marked by hand before the search; they go with the rest unless unticked.
    public init(_ found: RedactionSearchResult, earlier: [(page: Int, rect: RectD)]) {
        let all = found.looks.map { RedactionReviewRow(item: .look($0), accepted: false) }
            + found.hits.map { RedactionReviewRow(item: .hit($0), accepted: true) }
            + earlier.map { RedactionReviewRow(item: .earlier(page: $0.page, rect: $0.rect), accepted: true) }
        func key(_ r: RedactionReviewRow) -> (Int, Int, Double, Double) {
            let first = r.boxes.first ?? .zero
            if case .look = r.item { return (r.page, 0, 0, 0) }
            return (r.page, 1, first.y, first.x)
        }
        rows = all.enumerated().sorted { a, b in
            let (ka, kb) = (key(a.element), key(b.element))
            if ka != kb { return ka < kb }
            return a.offset < b.offset
        }.map(\.element)
    }

    public mutating func set(_ index: Int, _ accepted: Bool) {
        guard rows.indices.contains(index), rows[index].tickable else { return }
        rows[index].accepted = accepted
    }

    /// Accept All / Skip All: the hits only (a look's unread places and earlier areas keep their own ticks).
    public mutating func setAll(_ accepted: Bool) {
        for i in rows.indices { if case .hit = rows[i].item { rows[i].accepted = accepted } }
    }

    public var hitCount: Int { rows.filter { if case .hit = $0.item { true } else { false } }.count }

    /// How many things go when the person presses Redact: hits, unread places and earlier areas ticked.
    public var redactCount: Int {
        rows.reduce(0) { n, r in
            guard r.accepted else { return n }
            if case .look(let l) = r.item { return n + l.unread.count }
            return n + 1
        }
    }

    /// The button's title: Redact N, or Keep All when nothing is ticked.
    public var redactTitle: String {
        redactCount == 0 ? loc("Keep All") : loc("Redact {0}", CoreLanguage.number(redactCount))
    }

    public var choice: RedactionReviewChoice {
        var c = RedactionReviewChoice(accepted: [], skipped: [], lookAreas: [], earlierApplied: [], earlierKept: [])
        for r in rows {
            switch r.item {
            case .hit(let h): if r.accepted { c.accepted.append(h) } else { c.skipped.append(h) }
            case .look(let l): if r.accepted { c.lookAreas += l.unread.map { (l.page, $0) } }
            case .earlier(let page, let rect): if r.accepted { c.earlierApplied.append((page, rect)) } else { c.earlierKept.append((page, rect)) }
            }
        }
        return c
    }

    /// What the list says first: how many matches, nothing removed until Redact.
    public static func heading(_ found: RedactionSearchResult) -> String {
        let n = found.hits.count
        let matches = n == 0 ? loc("Nothing matching was found.")
            : n == 1 ? loc("{0} match was found. Untick it to keep it.", CoreLanguage.number(1))
            : loc("{0} matches were found. Untick any you want to keep.", CoreLanguage.number(n))
        return matches + " " + loc("Nothing is removed until you press Redact. Pages with something to remove become pictures, and you can undo it until you save.")
    }

    /// The warning about pages only text recognition could read, or none could; nil when there are none.
    public static func lookWarning(_ found: RedactionSearchResult) -> String? {
        if found.looks.isEmpty { return nil }
        return loc("Look at {0} yourself, whatever the list says: {1}, so these pages can't be taken as clean. Each is flagged in the list.",
                   RedactionReport.pages(found.looks.map(\.page)), RedactionLook.why(found.looks))
    }

    /// The note about areas marked by hand before the search; nil when there are none.
    public static func earlierNote(_ earlier: [(page: Int, rect: RectD)]) -> String? {
        if earlier.isEmpty { return nil }
        let pages = RedactionReport.pages(earlier.map(\.page))
        return earlier.count == 1
            ? loc("{0} area you marked earlier, on {1}, will go too. It is in the list: select it to see it, untick it to leave it as a mark, or Cancel to change nothing.", CoreLanguage.number(1), pages)
            : loc("{0} areas you marked earlier, on {1}, will go too. They are in the list: select one to see it, untick to leave it as a mark, or Cancel to change nothing.", CoreLanguage.number(earlier.count), pages)
    }
}

extension RedactionReport {
    /// What the report's page says first: why a failed file mustn't be shared, or the headline.
    public var opening: String {
        let failed = files.filter { $0.failure != nil }
        if failed.isEmpty { return headline }
        let many = files.count > 1
        let reasons = failed.prefix(5).map { (many ? $0.file + ": " : "") + ($0.failure ?? "") }.joined(separator: " ")
        return many ? loc("{1} of {2} files failed. Don't share a failed result: {0}", reasons, CoreLanguage.number(failed.count), CoreLanguage.number(files.count))
            : loc("Don't share a failed result: {0}", reasons)
    }

    /// The pages to look at by hand and why, never saying they are clean; nil when there are none.
    public var lookNote: String? {
        guard hasLooks else { return nil }
        let many = files.count > 1
        let pages = files.filter { !$0.looks.isEmpty }.prefix(8).map { (many ? $0.file + ": " : "") + RedactionReport.pages($0.looks.map(\.page)) }
        return loc("This doesn't say those pages are clean. Look by hand at {0}: {1}.", pages.joined(separator: "; "), RedactionLook.why(files.flatMap(\.looks)))
    }
}
