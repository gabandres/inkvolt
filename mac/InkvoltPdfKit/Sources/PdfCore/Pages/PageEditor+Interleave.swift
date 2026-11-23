import Foundation
import PrintCore

/// Interleave (the Windows app's `PageEditor.Interleave`, roadmap 4.3): two scans of a stack of two-sided sheets, the
/// fronts and then the backs, put together as front 1, back 1, front 2, back 2… The backs of a stack turned over to be fed
/// again come last page first: `reverseBacks` puts them back in order. Uneven counts are fine (a back left blank, a missed
/// sheet): what one side has left over follows.
extension PageEditor {
    /// The page order after interleaving `fronts` and `backs` (pages of one document, each in its order): the interleaved
    /// pages take the place of the first of them, the other pages stay as they are.
    /// - Throws: `PdfEditError` when a side is empty, a page is out of range, or a page is on both sides.
    public static func interleaveOrder(_ pageCount: Int, _ fronts: [Int], _ backs: [Int], reverseBacks: Bool) throws -> [Int] {
        if fronts.isEmpty || backs.isEmpty { throw PdfEditError(loc("Choose pages for both the fronts and the backs.")) }
        if (fronts + backs).contains(where: { $0 < 0 || $0 >= pageCount }) { throw PdfEditError(loc("No pages selected.")) }
        let used = Set(fronts + backs)
        if used.count != fronts.count + backs.count { throw PdfEditError(loc("A page can't be both a front and a back.")) }

        let back = reverseBacks ? Array(backs.reversed()) : backs
        var merged: [Int] = []
        merged.reserveCapacity(used.count)
        for i in 0..<max(fronts.count, back.count) {
            if i < fronts.count { merged.append(fronts[i]) }
            if i < back.count { merged.append(back[i]) }
        }
        let at = used.min()!
        var rest = (0..<pageCount).filter { !used.contains($0) }
        rest.insert(contentsOf: merged, at: rest.filter { $0 < at }.count)
        return rest
    }

    /// Interleaves two sets of this document's pages (`interleaveOrder`), as one edit.
    public static func interleave(_ data: [UInt8], _ password: String?, _ fronts: [Int], _ backs: [Int], reverseBacks: Bool) throws -> [UInt8] {
        try edit(data, password) { doc, labels in
            try applyOrder(doc, interleaveOrder(doc.pageCount(), fronts, backs, reverseBacks: reverseBacks))
            try relabel(doc, &labels, (fronts + backs).min()!, fronts.count + backs.count)
        }
    }

    /// Page labels after an interleave: the interleaved run (`count` pages from `at`) numbered on from the label its first
    /// place had, so no label shows twice; labels that were plain 1, 2, 3 are dropped (the pages show their numbers
    /// anyway). Other pages keep theirs.
    private static func relabel(_ doc: MuDoc, _ labels: inout Labels?, _ at: Int, _ count: Int) throws {
        guard var list = labels, !list.isEmpty else { return }
        if isPlain(list.map(\.label)) {
            labels = []
            return
        }
        let first = list[min(max(at, 0), list.count - 1)].label
        var index: [ObjId: Int] = [:]
        for (i, l) in list.enumerated() where index[l.page] == nil { index[l.page] = i }
        let pages = try doc.pages()
        for k in 0..<count where at + k < pages.count {
            var label = first
            label.number = PageLabels.add(first.number, k)
            let page = pages[at + k].id
            if let i = index[page] { list[i] = (page, label) } else { list.append((page, label)) } // a back brought in from another file
        }
        labels = list
    }

    /// The document's pages are the fronts; the pages of `backs` (another file, or the backs just scanned) are brought in
    /// with their links, bookmarks and fields, as Insert brings them, and interleaved with them.
    public static func interleaveWith(_ data: [UInt8], _ password: String?, _ backs: PdfSource, reverseBacks: Bool) throws -> [UInt8] {
        try edit(data, password) { doc, labels in
            let src = try openSource(backs, in: doc)
            let srcCount = try src.pageCount()
            if srcCount == 0 { throw PdfEditError(loc("Choose pages for both the fronts and the backs.")) }
            let fronts = try doc.pageCount()
            let graft = try Graft(into: doc)
            var imported: [(source: Int, page: PObj)] = []
            for k in 0..<srcCount {
                try graft.page(src, k, to: fronts + k)
                imported.append((k, doc.page(fronts + k)))
            }
            let importer = try PdfStructure.Import(doc, src, graft, imported)
            try importer.copyAnnotations()
            importer.fixLinks()
            try PdfStructure.writeOutline(doc, PdfStructure.readOutline(doc) + importer.outline())
            try importer.registerFields()
            try PdfStructure.dropStrayReferences(doc)
            try applyOrder(doc, interleaveOrder(doc.pageCount(), Array(0..<fronts), Array(fronts..<(fronts + srcCount)), reverseBacks: reverseBacks))
            try relabel(doc, &labels, 0, doc.pageCount())
        }
    }
}
