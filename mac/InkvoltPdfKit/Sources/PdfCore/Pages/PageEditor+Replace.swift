import Foundation
import PrintCore

/// Replace Pages (the Windows app's `PageEditor.Replace`, roadmap 4.13): pages of this document swapped, one for one, for
/// pages of another PDF (a corrected page, a signed page scanned back). Bookmarks, links, named destinations and the
/// opening view that led to a replaced page lead to the page that took its place; the replaced page's own comments,
/// links and fields go with it, and the new page brings its own, as Insert brings them. Each new page keeps the replaced
/// page's label.
extension PageEditor {
    /// - Parameters:
    ///   - pages: the pages replaced (this document), in the order `sourcePages` replace them.
    ///   - sourcePages: the pages of `source` that take their places, as many as `pages`.
    /// - Throws: `PdfEditError` when the counts differ, a page is out of range, or a page (of either document) is named
    ///   twice: a page of the other PDF takes one page's place, so the same page isn't brought in twice.
    public static func replace(_ data: [UInt8], _ password: String?, _ pages: [Int], _ source: PdfSource, _ sourcePages: [Int]) throws -> [UInt8] {
        if pages.isEmpty || pages.count != sourcePages.count { throw PdfEditError(loc("Choose as many pages to put in as pages to replace.")) }
        if Set(pages).count != pages.count { throw PdfEditError(loc("A page to replace is named twice: each can be replaced once.")) }
        if Set(sourcePages).count != sourcePages.count {
            throw PdfEditError(loc("A page of the other PDF is named twice: each can take only one page's place."))
        }
        return try edit(data, password) { doc, labels in
            let src = try openSource(source, in: doc)
            let count = try doc.pageCount(), srcCount = try src.pageCount()
            if pages.contains(where: { $0 < 0 || $0 >= count }) || sourcePages.contains(where: { $0 < 0 || $0 >= srcCount }) {
                throw PdfEditError(loc("No pages selected."))
            }
            let old = pages.map { doc.page($0) }
            let graft = try Graft(into: doc)
            var imported: [(source: Int, page: PObj)] = []
            var map: [ObjId: PObj] = [:]
            // Each new page goes right after the page it replaces, the last first, so the indices before it hold.
            for k in pages.indices.sorted(by: { pages[$0] > pages[$1] }) {
                try graft.page(src, sourcePages[k], to: pages[k] + 1)
                let added = doc.page(pages[k] + 1)
                imported.append((sourcePages[k], added))
                map[old[k].id] = added
                if let before = labels?[pages[k]].label { labels?.append((added.id, before)) } // the label it replaces
            }
            let importer = try PdfStructure.Import(doc, src, graft, imported)
            try importer.copyAnnotations()
            importer.fixLinks()
            try importer.registerFields()
            retargetDestinations(doc, map)
            let ids = try doc.pages().map(\.id)
            try PdfStructure.removePages(doc, old.compactMap { o in ids.firstIndex(of: o.id) })
            SignedEdits.noteRemoval()
        }
    }

    /// Points every explicit destination ([page /XYZ …], [page /Fit] …) that leads to a page in `map` at the page it maps
    /// to: in bookmarks, links, actions, named destinations, the opening view, wherever the document holds one.
    static func retargetDestinations(_ doc: MuDoc, _ map: [ObjId: PObj]) {
        forEachDestination(doc) { dest, page in
            if let to = map[page] { dest.replace(at: 0, with: to) }
        }
    }
}
