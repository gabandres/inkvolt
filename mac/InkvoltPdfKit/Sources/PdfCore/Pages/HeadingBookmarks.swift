import Foundation
import PrintCore

/// A heading found on a page: its text, level (1-6), page and where its first line is (points from the page's top).
public struct FoundHeading: Equatable, Sendable {
    public var title: String
    public var level: Int
    public var pageIndex: Int
    public var top: Double

    public init(_ title: String, _ level: Int, _ pageIndex: Int, _ top: Double) {
        self.title = title
        self.level = level
        self.pageIndex = pageIndex
        self.top = top
    }
}

/// Bookmarks from headings (the Windows app's `HeadingBookmarks`, roadmap 4.5): the headings `DocLayout` finds (text set
/// larger than the body, as Export to Word and Make Accessible find them; running headers left out), nested by level,
/// written through `Bookmarks` in place of the document's bookmarks or after them.
public enum HeadingBookmarks {
    /// The most headings made into bookmarks (a document set all in large type would make a heading of every line).
    public static let maxHeadings = 5000

    /// The longest title kept, in UTF-16 units as Windows counts them (a longer one is shortened with "…").
    public static let maxTitle = 200

    /// The document's headings in reading order; `progress` is told (done, total) before each page. A page that can't be
    /// read has none.
    /// - Throws: `CancellationError` when `cancel` fired.
    public static func find(_ engine: PdfEngine, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> [FoundHeading] {
        var pages: [ExportPage] = []
        pages.reserveCapacity(engine.pageCount)
        for p in 0..<engine.pageCount {
            try cancel.check()
            progress?(p, engine.pageCount)
            do {
                pages.append(try engine.exportPage(p, images: false, cancel: cancel, boxesOnly: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pages.append(emptyPage(engine, p)) // a refused or damaged page: no headings on it
            }
        }
        return headings(DocLayout.analyzeForTags(pages).layout)
    }

    /// A page with nothing on it, its size as the engine has it (Letter when even that can't be read).
    private static func emptyPage(_ engine: PdfEngine, _ page: Int) -> ExportPage {
        let g = engine.page(page)
        if g.width.isFinite && g.height.isFinite && g.width > 0 && g.height > 0 { return ExportPage(g.width, g.height, [], [], []) }
        return ExportPage(612, 792, [], [], [])
    }

    /// The headings of a laid-out document (`DocLayout.analyzeForTags`, whose paragraphs say where they are on the page).
    static func headings(_ layout: DocLayoutResult) -> [FoundHeading] {
        var found: [FoundHeading] = []
        for (p, page) in layout.pages.enumerated() where found.count < maxHeadings {
            for paragraph in page.paragraphs {
                let title = title(paragraph.text)
                if paragraph.headingLevel <= 0 || title.isEmpty { continue }
                let top = paragraph.sources.map(\.y).min() ?? paragraph.box.y
                found.append(FoundHeading(title, min(max(paragraph.headingLevel, 1), 6), p, top.isFinite ? max(0, top) : 0))
                if found.count >= maxHeadings { break }
            }
        }
        return found
    }

    /// Whitespace (line breaks, tabs, runs of spaces) as one space, control characters left out, at most `maxTitle` UTF-16
    /// units, a longer one cut between two characters as shown (never inside a surrogate pair, an emoji or a letter with
    /// its accents) and ended with "…".
    static func title(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { word in
            String(String.UnicodeScalarView(word.unicodeScalars.filter { $0.properties.generalCategory != .control && $0 != DocLayout.pageField }))
        }.filter { !$0.isEmpty }
        let title = words.joined(separator: " ")
        if title.utf16.count <= maxTitle { return title }
        var cut = ""
        var length = 0
        for c in title {
            let n = c.utf16.count
            if length + n > maxTitle - 1 { break }
            cut.append(c)
            length += n
        }
        while let last = cut.last, last.isWhitespace { cut.removeLast() }
        return cut + "…"
    }

    /// The headings as a bookmark tree: each under the nearest heading before it of a higher level (a level skipped, as a 1
    /// followed by a 3, nests one step), the first level shown open. Only headings of level `deepest` or higher are kept.
    public static func tree(_ headings: [FoundHeading], deepest: Int = 6) -> [Bookmark] {
        final class Node {
            let heading: FoundHeading
            var children: [Node] = []
            init(_ heading: FoundHeading) { self.heading = heading }

            func bookmark(open: Bool) -> Bookmark {
                var b = Bookmark(heading.title, heading.pageIndex, top: heading.top, children: children.map { $0.bookmark(open: false) })
                b.open = open && !children.isEmpty
                return b
            }
        }
        var roots: [Node] = []
        var path: [Node] = [] // from a root to the last heading placed
        for h in headings where h.level <= deepest {
            while let last = path.last, last.heading.level >= h.level { path.removeLast() }
            let node = Node(h)
            if let parent = path.last { parent.children.append(node) } else { roots.append(node) }
            path.append(node)
        }
        return roots.map { $0.bookmark(open: true) }
    }

    /// Writes the headings' bookmarks: in place of the document's bookmarks (`replace`), or after them. A signed document
    /// gets them as an appended change, as every bookmark edit.
    public static func write(_ data: [UInt8], _ password: String?, _ headings: [FoundHeading], replace: Bool, deepest: Int = 6) throws -> [UInt8] {
        let made = tree(headings, deepest: deepest)
        return try Bookmarks.setOutline(data, password, replace ? made : try Bookmarks.read(data, password) + made)
    }
}
